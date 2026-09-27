const std = @import("std");
const c = @import("platform.zig").c;
const scene = @import("scene.zig");

const Cell = scene.Cell;
const max_cells: usize = scene.cols * scene.rows;
const fence_timeout = std.math.maxInt(u64);
const acquire_timeout_ns = 100_000_000;

const vertex_words = spirvWords(@embedFile("cell.vert.spv"));
const fragment_words = spirvWords(@embedFile("cell.frag.spv"));

pub const Renderer = struct {
    allocator: std.mem.Allocator = std.heap.page_allocator,

    instance: c.VkInstance = null,
    surface: c.VkSurfaceKHR = null,
    physical_device: c.VkPhysicalDevice = null,
    device: c.VkDevice = null,
    graphics_queue: c.VkQueue = null,
    present_queue: c.VkQueue = null,
    graphics_family: u32 = 0,
    present_family: u32 = 0,

    command_pool: c.VkCommandPool = null,
    command_buffer: c.VkCommandBuffer = null,
    image_available: c.VkSemaphore = null,
    frame_fence: c.VkFence = null,

    cell_buffer: c.VkBuffer = null,
    cell_memory: c.VkDeviceMemory = null,
    cell_mapping: ?[*]u8 = null,
    glyph_buffer: c.VkBuffer = null,
    glyph_memory: c.VkDeviceMemory = null,
    glyph_mapping: ?[*]u8 = null,
    capture_buffer: c.VkBuffer = null,
    capture_memory: c.VkDeviceMemory = null,
    capture_mapping: ?[*]u8 = null,
    capture_buffer_size: usize = 0,
    capture_requested: bool = false,
    capture_transfer_supported: bool = false,
    capture_pixels: []const u8 = &.{},
    capture_width: u32 = 0,
    capture_height: u32 = 0,
    capture_bgra: bool = false,

    descriptor_layout: c.VkDescriptorSetLayout = null,
    descriptor_pool: c.VkDescriptorPool = null,
    descriptor_set: c.VkDescriptorSet = null,
    pipeline_layout: c.VkPipelineLayout = null,

    swapchain: c.VkSwapchainKHR = null,
    swapchain_format: c.VkFormat = c.VK_FORMAT_UNDEFINED,
    swapchain_extent: c.VkExtent2D = .{ .width = 0, .height = 0 },
    output_srgb: bool = false,
    swapchain_images: []c.VkImage = &.{},
    image_views: []c.VkImageView = &.{},
    framebuffers: []c.VkFramebuffer = &.{},
    present_semaphores: []c.VkSemaphore = &.{},
    render_pass: c.VkRenderPass = null,
    pipeline: c.VkPipeline = null,

    query_pool: c.VkQueryPool = null,
    timestamp_valid_bits: u32 = 0,
    timestamp_period_ns: f32 = 0,
    timestamp_pending: bool = false,
    gpu_timestamps_available: bool = false,
    last_gpu_frame_ns: u64 = 0,
    gpu_sample_count: u64 = 0,
    presented_frames: u64 = 0,

    requested_width: u32 = 0,
    requested_height: u32 = 0,
    suspended: bool = false,
    retry_counter: u8 = 0,
    initialized: bool = false,

    pub fn init(self: *Renderer, display: ?*c.wl_display, wayland_surface: ?*c.wl_surface, width: u32, height: u32) !void {
        self.* = .{};
        errdefer self.deinit();

        if (display == null or wayland_surface == null) return error.MissingWaylandHandle;
        self.requested_width = width;
        self.requested_height = height;

        try self.createInstance();
        try self.createSurface(display.?, wayland_surface.?);
        try self.selectPhysicalDevice();
        try self.createDevice();
        try self.createCommandResources();
        try self.createBuffers();
        try self.createDescriptors();
        try self.createFrameSync();
        self.initialized = true;
        try self.recreateSwapchain();
    }

    pub fn resize(self: *Renderer, width: u32, height: u32) !void {
        self.requested_width = width;
        self.requested_height = height;
        if (width == 0 or height == 0) {
            self.suspended = true;
            return;
        }
        if (!self.initialized) return;
        try self.recreateSwapchain();
    }

    /// Request one GPU framebuffer readback on the next presented frame.
    /// The returned pixel slice remains valid until deinit.
    pub fn requestCapture(self: *Renderer) !void {
        if (!self.initialized or self.swapchain == null) return error.CaptureUnavailable;
        if (!self.capture_transfer_supported) return error.CaptureUnsupported;
        if (!isCaptureFormat(self.swapchain_format)) return error.CaptureFormatUnsupported;
        if (self.capture_requested or self.capture_pixels.len != 0) return error.CaptureAlreadyUsed;
        self.capture_requested = true;
    }

    pub fn draw(self: *Renderer, cells: []const Cell, cols: u32, rows: u32) !void {
        if (self.requested_width == 0 or self.requested_height == 0) return;
        if (self.suspended or self.swapchain == null) {
            self.retry_counter +%= 1;
            if (self.retry_counter < 15) return;
            self.retry_counter = 0;
            try self.recreateSwapchain();
            if (self.suspended or self.swapchain == null) return;
        }
        if (cols == 0 or rows == 0) return error.InvalidGridSize;
        if (cols > std.math.maxInt(u32) / rows) return error.InvalidGridSize;
        const count: usize = @as(usize, cols) * rows;
        if (cells.len != count) return error.InvalidCellCount;
        if (count > max_cells) return error.CellCapacityExceeded;
        for (cells) |cell| if (cell.glyph >= scene.glyph_bits.len) {
            return error.InvalidGlyph;
        };

        try vkCheck(c.vkWaitForFences(self.device, 1, &self.frame_fence, c.VK_TRUE, fence_timeout));
        self.readGpuTimestamp();

        const byte_count = count * @sizeOf(Cell);
        @memcpy(self.cell_mapping.?[0..byte_count], std.mem.sliceAsBytes(cells));
        if (self.capture_requested) {
            if (!self.capture_transfer_supported) return error.CaptureUnsupported;
            if (!isCaptureFormat(self.swapchain_format)) return error.CaptureFormatUnsupported;
            try self.ensureCaptureBuffer();
        }

        var image_index: u32 = 0;
        const acquired = c.vkAcquireNextImageKHR(
            self.device,
            self.swapchain,
            acquire_timeout_ns,
            self.image_available,
            null,
            &image_index,
        );
        if (acquired == c.VK_ERROR_OUT_OF_DATE_KHR) {
            try self.recreateSwapchain();
            return;
        }
        if (acquired == c.VK_TIMEOUT or acquired == c.VK_NOT_READY) return;
        if (acquired != c.VK_SUCCESS and acquired != c.VK_SUBOPTIMAL_KHR) return error.VulkanAcquireFailed;

        try self.recordFrame(cells, cols, rows, image_index);
        try vkCheck(c.vkResetFences(self.device, 1, &self.frame_fence));

        const wait_stages = [_]c.VkPipelineStageFlags{c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT};
        const submit = c.VkSubmitInfo{
            .sType = c.VK_STRUCTURE_TYPE_SUBMIT_INFO,
            .pNext = null,
            .waitSemaphoreCount = 1,
            .pWaitSemaphores = &self.image_available,
            .pWaitDstStageMask = &wait_stages,
            .commandBufferCount = 1,
            .pCommandBuffers = &self.command_buffer,
            .signalSemaphoreCount = 1,
            .pSignalSemaphores = &self.present_semaphores[image_index],
        };
        try vkCheck(c.vkQueueSubmit(self.graphics_queue, 1, &submit, self.frame_fence));
        self.timestamp_pending = self.query_pool != null;
        if (self.capture_requested) {
            try vkCheck(c.vkWaitForFences(self.device, 1, &self.frame_fence, c.VK_TRUE, fence_timeout));
            const capture_size = @as(usize, self.swapchain_extent.width) * self.swapchain_extent.height * 4;
            self.capture_pixels = self.capture_mapping.?[0..capture_size];
            self.capture_width = self.swapchain_extent.width;
            self.capture_height = self.swapchain_extent.height;
            self.capture_bgra = isCaptureBgra(self.swapchain_format);
            self.capture_requested = false;
        }

        const wait_semaphores = [_]c.VkSemaphore{self.present_semaphores[image_index]};
        const swapchains = [_]c.VkSwapchainKHR{self.swapchain};
        const present = c.VkPresentInfoKHR{
            .sType = c.VK_STRUCTURE_TYPE_PRESENT_INFO_KHR,
            .pNext = null,
            .waitSemaphoreCount = 1,
            .pWaitSemaphores = &wait_semaphores,
            .swapchainCount = 1,
            .pSwapchains = &swapchains,
            .pImageIndices = &image_index,
            .pResults = null,
        };
        const presented = c.vkQueuePresentKHR(self.present_queue, &present);
        if (presented == c.VK_SUCCESS or presented == c.VK_SUBOPTIMAL_KHR) self.presented_frames +%= 1;
        if (presented == c.VK_ERROR_OUT_OF_DATE_KHR or presented == c.VK_SUBOPTIMAL_KHR or acquired == c.VK_SUBOPTIMAL_KHR) {
            try self.recreateSwapchain();
            return;
        }
        try vkCheck(presented);
    }

    pub fn deinit(self: *Renderer) void {
        if (self.device != null) _ = c.vkDeviceWaitIdle(self.device);
        self.destroySwapchainResources();

        if (self.query_pool != null and self.device != null) c.vkDestroyQueryPool(self.device, self.query_pool, null);
        if (self.pipeline_layout != null and self.device != null) c.vkDestroyPipelineLayout(self.device, self.pipeline_layout, null);
        if (self.descriptor_pool != null and self.device != null) c.vkDestroyDescriptorPool(self.device, self.descriptor_pool, null);
        if (self.descriptor_layout != null and self.device != null) c.vkDestroyDescriptorSetLayout(self.device, self.descriptor_layout, null);

        if (self.cell_mapping != null and self.cell_memory != null and self.device != null) c.vkUnmapMemory(self.device, self.cell_memory);
        if (self.glyph_mapping != null and self.glyph_memory != null and self.device != null) c.vkUnmapMemory(self.device, self.glyph_memory);
        if (self.capture_mapping != null and self.capture_memory != null and self.device != null) c.vkUnmapMemory(self.device, self.capture_memory);
        if (self.cell_buffer != null and self.device != null) c.vkDestroyBuffer(self.device, self.cell_buffer, null);
        if (self.glyph_buffer != null and self.device != null) c.vkDestroyBuffer(self.device, self.glyph_buffer, null);
        if (self.capture_buffer != null and self.device != null) c.vkDestroyBuffer(self.device, self.capture_buffer, null);
        if (self.cell_memory != null and self.device != null) c.vkFreeMemory(self.device, self.cell_memory, null);
        if (self.glyph_memory != null and self.device != null) c.vkFreeMemory(self.device, self.glyph_memory, null);
        if (self.capture_memory != null and self.device != null) c.vkFreeMemory(self.device, self.capture_memory, null);

        if (self.frame_fence != null and self.device != null) c.vkDestroyFence(self.device, self.frame_fence, null);
        if (self.image_available != null and self.device != null) c.vkDestroySemaphore(self.device, self.image_available, null);
        if (self.command_pool != null and self.device != null) c.vkDestroyCommandPool(self.device, self.command_pool, null);
        if (self.device != null) c.vkDestroyDevice(self.device, null);
        if (self.surface != null and self.instance != null) c.vkDestroySurfaceKHR(self.instance, self.surface, null);
        if (self.instance != null) c.vkDestroyInstance(self.instance, null);
        self.* = .{};
    }

    fn createInstance(self: *Renderer) !void {
        const app = c.VkApplicationInfo{
            .sType = c.VK_STRUCTURE_TYPE_APPLICATION_INFO,
            .pNext = null,
            .pApplicationName = "ASCII-Life",
            .applicationVersion = c.VK_MAKE_VERSION(0, 0, 1),
            .pEngineName = "ASCII-Life",
            .engineVersion = c.VK_MAKE_VERSION(0, 0, 1),
            .apiVersion = c.VK_API_VERSION_1_0,
        };
        const extensions = [_][*:0]const u8{ "VK_KHR_surface", "VK_KHR_wayland_surface" };
        const info = c.VkInstanceCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .pApplicationInfo = &app,
            .enabledLayerCount = 0,
            .ppEnabledLayerNames = null,
            .enabledExtensionCount = extensions.len,
            .ppEnabledExtensionNames = &extensions,
        };
        try vkCheck(c.vkCreateInstance(&info, null, &self.instance));
    }

    fn createSurface(self: *Renderer, display: *c.wl_display, wayland_surface: *c.wl_surface) !void {
        const info = c.VkWaylandSurfaceCreateInfoKHR{
            .sType = c.VK_STRUCTURE_TYPE_WAYLAND_SURFACE_CREATE_INFO_KHR,
            .pNext = null,
            .flags = 0,
            .display = display,
            .surface = wayland_surface,
        };
        try vkCheck(c.vkCreateWaylandSurfaceKHR(self.instance, &info, null, &self.surface));
    }

    fn selectPhysicalDevice(self: *Renderer) !void {
        var count: u32 = 0;
        try vkCheck(c.vkEnumeratePhysicalDevices(self.instance, &count, null));
        if (count == 0) return error.NoVulkanPhysicalDevice;
        const devices = try self.allocator.alloc(c.VkPhysicalDevice, count);
        defer self.allocator.free(devices);
        try vkCheck(c.vkEnumeratePhysicalDevices(self.instance, &count, devices.ptr));

        for (devices) |device| {
            if (!try hasDeviceExtension(self.allocator, device, "VK_KHR_swapchain")) continue;
            const families = (try findQueueFamilies(self.allocator, device, self.surface)) orelse continue;
            var format_count: u32 = 0;
            var mode_count: u32 = 0;
            try vkCheck(c.vkGetPhysicalDeviceSurfaceFormatsKHR(device, self.surface, &format_count, null));
            try vkCheck(c.vkGetPhysicalDeviceSurfacePresentModesKHR(device, self.surface, &mode_count, null));
            if (format_count == 0 or mode_count == 0) continue;
            self.physical_device = device;
            self.graphics_family = families.graphics;
            self.present_family = families.present;
            self.timestamp_valid_bits = families.timestamp_bits;
            var properties: c.VkPhysicalDeviceProperties = undefined;
            c.vkGetPhysicalDeviceProperties(device, &properties);
            self.timestamp_period_ns = properties.limits.timestampPeriod;
            self.gpu_timestamps_available = families.timestamp_bits != 0 and self.timestamp_period_ns > 0;
            return;
        }
        return error.NoPresentableVulkanDevice;
    }

    fn createDevice(self: *Renderer) !void {
        const priority: f32 = 1;
        const graphics_queue = c.VkDeviceQueueCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .queueFamilyIndex = self.graphics_family,
            .queueCount = 1,
            .pQueuePriorities = &priority,
        };
        const present_queue = c.VkDeviceQueueCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .queueFamilyIndex = self.present_family,
            .queueCount = 1,
            .pQueuePriorities = &priority,
        };
        const queue_infos = [_]c.VkDeviceQueueCreateInfo{ graphics_queue, present_queue };
        const extensions = [_][*:0]const u8{"VK_KHR_swapchain"};
        const info = c.VkDeviceCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .queueCreateInfoCount = if (self.graphics_family == self.present_family) 1 else 2,
            .pQueueCreateInfos = &queue_infos,
            .enabledLayerCount = 0,
            .ppEnabledLayerNames = null,
            .enabledExtensionCount = extensions.len,
            .ppEnabledExtensionNames = &extensions,
            .pEnabledFeatures = null,
        };
        try vkCheck(c.vkCreateDevice(self.physical_device, &info, null, &self.device));
        c.vkGetDeviceQueue(self.device, self.graphics_family, 0, &self.graphics_queue);
        c.vkGetDeviceQueue(self.device, self.present_family, 0, &self.present_queue);
    }

    fn createCommandResources(self: *Renderer) !void {
        const pool_info = c.VkCommandPoolCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
            .pNext = null,
            .flags = c.VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,
            .queueFamilyIndex = self.graphics_family,
        };
        try vkCheck(c.vkCreateCommandPool(self.device, &pool_info, null, &self.command_pool));

        const allocation = c.VkCommandBufferAllocateInfo{
            .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
            .pNext = null,
            .commandPool = self.command_pool,
            .level = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY,
            .commandBufferCount = 1,
        };
        try vkCheck(c.vkAllocateCommandBuffers(self.device, &allocation, &self.command_buffer));

        if (self.gpu_timestamps_available) {
            const query_info = c.VkQueryPoolCreateInfo{
                .sType = c.VK_STRUCTURE_TYPE_QUERY_POOL_CREATE_INFO,
                .pNext = null,
                .flags = 0,
                .queryType = c.VK_QUERY_TYPE_TIMESTAMP,
                .queryCount = 2,
                .pipelineStatistics = 0,
            };
            try vkCheck(c.vkCreateQueryPool(self.device, &query_info, null, &self.query_pool));
        }
    }

    fn createBuffers(self: *Renderer) !void {
        const cell_size = max_cells * @sizeOf(Cell);
        try createHostBuffer(self, cell_size, c.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT, &self.cell_buffer, &self.cell_memory, &self.cell_mapping);
        const glyph_size = @sizeOf(@TypeOf(scene.glyph_bits));
        try createHostBuffer(self, glyph_size, c.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT, &self.glyph_buffer, &self.glyph_memory, &self.glyph_mapping);
        @memcpy(self.glyph_mapping.?[0..glyph_size], std.mem.sliceAsBytes(&scene.glyph_bits));
    }

    fn ensureCaptureBuffer(self: *Renderer) !void {
        const size = @as(usize, self.swapchain_extent.width) * self.swapchain_extent.height * 4;
        if (self.capture_buffer != null and self.capture_buffer_size == size) return;
        if (self.capture_mapping != null and self.capture_memory != null) c.vkUnmapMemory(self.device, self.capture_memory);
        if (self.capture_buffer != null) c.vkDestroyBuffer(self.device, self.capture_buffer, null);
        if (self.capture_memory != null) c.vkFreeMemory(self.device, self.capture_memory, null);
        self.capture_mapping = null;
        self.capture_buffer = null;
        self.capture_memory = null;
        self.capture_buffer_size = 0;
        try createHostBuffer(self, size, c.VK_BUFFER_USAGE_TRANSFER_DST_BIT, &self.capture_buffer, &self.capture_memory, &self.capture_mapping);
        self.capture_buffer_size = size;
    }

    fn createDescriptors(self: *Renderer) !void {
        const bindings = [_]c.VkDescriptorSetLayoutBinding{
            .{ .binding = 0, .descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_FRAGMENT_BIT, .pImmutableSamplers = null },
            .{ .binding = 1, .descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_FRAGMENT_BIT, .pImmutableSamplers = null },
        };
        const layout_info = c.VkDescriptorSetLayoutCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .bindingCount = bindings.len,
            .pBindings = &bindings,
        };
        try vkCheck(c.vkCreateDescriptorSetLayout(self.device, &layout_info, null, &self.descriptor_layout));

        const pool_size = c.VkDescriptorPoolSize{ .type = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = 2 };
        const pool_info = c.VkDescriptorPoolCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .maxSets = 1,
            .poolSizeCount = 1,
            .pPoolSizes = &pool_size,
        };
        try vkCheck(c.vkCreateDescriptorPool(self.device, &pool_info, null, &self.descriptor_pool));
        const layouts = [_]c.VkDescriptorSetLayout{self.descriptor_layout};
        const allocate_info = c.VkDescriptorSetAllocateInfo{
            .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
            .pNext = null,
            .descriptorPool = self.descriptor_pool,
            .descriptorSetCount = 1,
            .pSetLayouts = &layouts,
        };
        try vkCheck(c.vkAllocateDescriptorSets(self.device, &allocate_info, &self.descriptor_set));

        const buffers = [_]c.VkDescriptorBufferInfo{
            .{ .buffer = self.cell_buffer, .offset = 0, .range = max_cells * @sizeOf(Cell) },
            .{ .buffer = self.glyph_buffer, .offset = 0, .range = @sizeOf(@TypeOf(scene.glyph_bits)) },
        };
        const writes = [_]c.VkWriteDescriptorSet{
            .{ .sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .pNext = null, .dstSet = self.descriptor_set, .dstBinding = 0, .dstArrayElement = 0, .descriptorCount = 1, .descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .pImageInfo = null, .pBufferInfo = &buffers[0], .pTexelBufferView = null },
            .{ .sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .pNext = null, .dstSet = self.descriptor_set, .dstBinding = 1, .dstArrayElement = 0, .descriptorCount = 1, .descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .pImageInfo = null, .pBufferInfo = &buffers[1], .pTexelBufferView = null },
        };
        c.vkUpdateDescriptorSets(self.device, writes.len, &writes, 0, null);
    }

    fn createFrameSync(self: *Renderer) !void {
        const semaphore_info = c.VkSemaphoreCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
        };
        try vkCheck(c.vkCreateSemaphore(self.device, &semaphore_info, null, &self.image_available));
        const fence_info = c.VkFenceCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO,
            .pNext = null,
            .flags = c.VK_FENCE_CREATE_SIGNALED_BIT,
        };
        try vkCheck(c.vkCreateFence(self.device, &fence_info, null, &self.frame_fence));
    }

    fn recreateSwapchain(self: *Renderer) !void {
        if (self.requested_width == 0 or self.requested_height == 0) return;
        try vkCheck(c.vkDeviceWaitIdle(self.device));
        try self.createSwapchainResources();
    }

    fn createSwapchainResources(self: *Renderer) !void {
        var capabilities: c.VkSurfaceCapabilitiesKHR = undefined;
        try vkCheck(c.vkGetPhysicalDeviceSurfaceCapabilitiesKHR(self.physical_device, self.surface, &capabilities));
        self.capture_transfer_supported = (capabilities.supportedUsageFlags & c.VK_IMAGE_USAGE_TRANSFER_SRC_BIT) != 0;

        var format_count: u32 = 0;
        try vkCheck(c.vkGetPhysicalDeviceSurfaceFormatsKHR(self.physical_device, self.surface, &format_count, null));
        if (format_count == 0) return error.NoSurfaceFormats;
        const formats = try self.allocator.alloc(c.VkSurfaceFormatKHR, format_count);
        defer self.allocator.free(formats);
        try vkCheck(c.vkGetPhysicalDeviceSurfaceFormatsKHR(self.physical_device, self.surface, &format_count, formats.ptr));
        const chosen_format = chooseSurfaceFormat(formats);

        const extent = chooseExtent(capabilities, self.requested_width, self.requested_height);
        if (extent.width == 0 or extent.height == 0) {
            self.suspended = true;
            return;
        }
        const image_count = if (capabilities.maxImageCount == 0)
            capabilities.minImageCount + 1
        else
            @min(capabilities.minImageCount + 1, capabilities.maxImageCount);
        const queue_families = [_]u32{ self.graphics_family, self.present_family };
        const sharing_mode: c.VkSharingMode = if (self.graphics_family == self.present_family) c.VK_SHARING_MODE_EXCLUSIVE else c.VK_SHARING_MODE_CONCURRENT;
        const swapchain_info = c.VkSwapchainCreateInfoKHR{
            .sType = c.VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR,
            .pNext = null,
            .flags = 0,
            .surface = self.surface,
            .minImageCount = image_count,
            .imageFormat = chosen_format.format,
            .imageColorSpace = chosen_format.colorSpace,
            .imageExtent = extent,
            .imageArrayLayers = 1,
            .imageUsage = @as(c.VkImageUsageFlags, c.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT) | (if (self.capture_transfer_supported) @as(c.VkImageUsageFlags, c.VK_IMAGE_USAGE_TRANSFER_SRC_BIT) else 0),
            .imageSharingMode = sharing_mode,
            .queueFamilyIndexCount = if (self.graphics_family == self.present_family) 0 else 2,
            .pQueueFamilyIndices = if (self.graphics_family == self.present_family) null else &queue_families,
            .preTransform = capabilities.currentTransform,
            .compositeAlpha = chooseCompositeAlpha(capabilities.supportedCompositeAlpha),
            .presentMode = c.VK_PRESENT_MODE_FIFO_KHR,
            .clipped = c.VK_TRUE,
            .oldSwapchain = null,
        };

        self.destroySwapchainResources();
        errdefer self.destroySwapchainResources();
        try vkCheck(c.vkCreateSwapchainKHR(self.device, &swapchain_info, null, &self.swapchain));
        self.swapchain_format = chosen_format.format;
        self.swapchain_extent = extent;
        self.output_srgb = isSrgbFormat(chosen_format.format);

        var actual_count: u32 = 0;
        try vkCheck(c.vkGetSwapchainImagesKHR(self.device, self.swapchain, &actual_count, null));
        if (actual_count == 0) return error.NoSwapchainImages;
        self.swapchain_images = try self.allocator.alloc(c.VkImage, actual_count);
        try vkCheck(c.vkGetSwapchainImagesKHR(self.device, self.swapchain, &actual_count, self.swapchain_images.ptr));
        self.image_views = try self.allocator.alloc(c.VkImageView, actual_count);
        @memset(self.image_views, null);
        self.framebuffers = try self.allocator.alloc(c.VkFramebuffer, actual_count);
        @memset(self.framebuffers, null);
        self.present_semaphores = try self.allocator.alloc(c.VkSemaphore, actual_count);
        @memset(self.present_semaphores, null);

        try self.createRenderPass();
        try self.createPipeline();
        for (self.swapchain_images, 0..) |image, index| {
            try self.createImageView(image, &self.image_views[index]);
            try self.createFramebuffer(self.image_views[index], &self.framebuffers[index]);
            const semaphore_info = c.VkSemaphoreCreateInfo{
                .sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO,
                .pNext = null,
                .flags = 0,
            };
            try vkCheck(c.vkCreateSemaphore(self.device, &semaphore_info, null, &self.present_semaphores[index]));
        }
        self.suspended = false;
        self.retry_counter = 0;
    }

    fn createRenderPass(self: *Renderer) !void {
        const attachment = c.VkAttachmentDescription{
            .flags = 0,
            .format = self.swapchain_format,
            .samples = c.VK_SAMPLE_COUNT_1_BIT,
            .loadOp = c.VK_ATTACHMENT_LOAD_OP_CLEAR,
            .storeOp = c.VK_ATTACHMENT_STORE_OP_STORE,
            .stencilLoadOp = c.VK_ATTACHMENT_LOAD_OP_DONT_CARE,
            .stencilStoreOp = c.VK_ATTACHMENT_STORE_OP_DONT_CARE,
            .initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED,
            .finalLayout = c.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR,
        };
        const color_ref = c.VkAttachmentReference{ .attachment = 0, .layout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL };
        const subpass = c.VkSubpassDescription{
            .flags = 0,
            .pipelineBindPoint = c.VK_PIPELINE_BIND_POINT_GRAPHICS,
            .inputAttachmentCount = 0,
            .pInputAttachments = null,
            .colorAttachmentCount = 1,
            .pColorAttachments = &color_ref,
            .pResolveAttachments = null,
            .pDepthStencilAttachment = null,
            .preserveAttachmentCount = 0,
            .pPreserveAttachments = null,
        };
        const dependency = c.VkSubpassDependency{
            .srcSubpass = c.VK_SUBPASS_EXTERNAL,
            .dstSubpass = 0,
            .srcStageMask = c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
            .dstStageMask = c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
            .srcAccessMask = 0,
            .dstAccessMask = c.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
            .dependencyFlags = 0,
        };
        const info = c.VkRenderPassCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .attachmentCount = 1,
            .pAttachments = &attachment,
            .subpassCount = 1,
            .pSubpasses = &subpass,
            .dependencyCount = 1,
            .pDependencies = &dependency,
        };
        try vkCheck(c.vkCreateRenderPass(self.device, &info, null, &self.render_pass));
    }

    fn createPipeline(self: *Renderer) !void {
        const vertex_module = try createShaderModule(self.device, &vertex_words);
        defer c.vkDestroyShaderModule(self.device, vertex_module, null);
        const fragment_module = try createShaderModule(self.device, &fragment_words);
        defer c.vkDestroyShaderModule(self.device, fragment_module, null);

        const push_range = c.VkPushConstantRange{
            .stageFlags = c.VK_SHADER_STAGE_FRAGMENT_BIT,
            .offset = 0,
            .size = @sizeOf(GridPush),
        };
        const set_layouts = [_]c.VkDescriptorSetLayout{self.descriptor_layout};
        const layout_info = c.VkPipelineLayoutCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .setLayoutCount = 1,
            .pSetLayouts = &set_layouts,
            .pushConstantRangeCount = 1,
            .pPushConstantRanges = &push_range,
        };
        try vkCheck(c.vkCreatePipelineLayout(self.device, &layout_info, null, &self.pipeline_layout));
        errdefer {
            c.vkDestroyPipelineLayout(self.device, self.pipeline_layout, null);
            self.pipeline_layout = null;
        }

        const stages = [_]c.VkPipelineShaderStageCreateInfo{
            .{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .pNext = null, .flags = 0, .stage = c.VK_SHADER_STAGE_VERTEX_BIT, .module = vertex_module, .pName = "main", .pSpecializationInfo = null },
            .{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .pNext = null, .flags = 0, .stage = c.VK_SHADER_STAGE_FRAGMENT_BIT, .module = fragment_module, .pName = "main", .pSpecializationInfo = null },
        };
        const vertex_input = c.VkPipelineVertexInputStateCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .vertexBindingDescriptionCount = 0,
            .pVertexBindingDescriptions = null,
            .vertexAttributeDescriptionCount = 0,
            .pVertexAttributeDescriptions = null,
        };
        const input_assembly = c.VkPipelineInputAssemblyStateCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .topology = c.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,
            .primitiveRestartEnable = c.VK_FALSE,
        };
        const viewport_state = c.VkPipelineViewportStateCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .viewportCount = 1,
            .pViewports = null,
            .scissorCount = 1,
            .pScissors = null,
        };
        const raster = c.VkPipelineRasterizationStateCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .depthClampEnable = c.VK_FALSE,
            .rasterizerDiscardEnable = c.VK_FALSE,
            .polygonMode = c.VK_POLYGON_MODE_FILL,
            .cullMode = c.VK_CULL_MODE_NONE,
            .frontFace = c.VK_FRONT_FACE_COUNTER_CLOCKWISE,
            .depthBiasEnable = c.VK_FALSE,
            .depthBiasConstantFactor = 0,
            .depthBiasClamp = 0,
            .depthBiasSlopeFactor = 0,
            .lineWidth = 1,
        };
        const multisample = c.VkPipelineMultisampleStateCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .rasterizationSamples = c.VK_SAMPLE_COUNT_1_BIT,
            .sampleShadingEnable = c.VK_FALSE,
            .minSampleShading = 1,
            .pSampleMask = null,
            .alphaToCoverageEnable = c.VK_FALSE,
            .alphaToOneEnable = c.VK_FALSE,
        };
        const blend_attachment = c.VkPipelineColorBlendAttachmentState{
            .blendEnable = c.VK_FALSE,
            .srcColorBlendFactor = c.VK_BLEND_FACTOR_ONE,
            .dstColorBlendFactor = c.VK_BLEND_FACTOR_ZERO,
            .colorBlendOp = c.VK_BLEND_OP_ADD,
            .srcAlphaBlendFactor = c.VK_BLEND_FACTOR_ONE,
            .dstAlphaBlendFactor = c.VK_BLEND_FACTOR_ZERO,
            .alphaBlendOp = c.VK_BLEND_OP_ADD,
            .colorWriteMask = c.VK_COLOR_COMPONENT_R_BIT | c.VK_COLOR_COMPONENT_G_BIT | c.VK_COLOR_COMPONENT_B_BIT | c.VK_COLOR_COMPONENT_A_BIT,
        };
        const blend = c.VkPipelineColorBlendStateCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .logicOpEnable = c.VK_FALSE,
            .logicOp = c.VK_LOGIC_OP_COPY,
            .attachmentCount = 1,
            .pAttachments = &blend_attachment,
            .blendConstants = .{ 0, 0, 0, 0 },
        };
        const dynamic_states = [_]c.VkDynamicState{ c.VK_DYNAMIC_STATE_VIEWPORT, c.VK_DYNAMIC_STATE_SCISSOR };
        const dynamic = c.VkPipelineDynamicStateCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .dynamicStateCount = dynamic_states.len,
            .pDynamicStates = &dynamic_states,
        };
        const pipeline_info = c.VkGraphicsPipelineCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .stageCount = stages.len,
            .pStages = &stages,
            .pVertexInputState = &vertex_input,
            .pInputAssemblyState = &input_assembly,
            .pTessellationState = null,
            .pViewportState = &viewport_state,
            .pRasterizationState = &raster,
            .pMultisampleState = &multisample,
            .pDepthStencilState = null,
            .pColorBlendState = &blend,
            .pDynamicState = &dynamic,
            .layout = self.pipeline_layout,
            .renderPass = self.render_pass,
            .subpass = 0,
            .basePipelineHandle = null,
            .basePipelineIndex = -1,
        };
        try vkCheck(c.vkCreateGraphicsPipelines(self.device, null, 1, &pipeline_info, null, &self.pipeline));
    }

    fn createImageView(self: *Renderer, image: c.VkImage, result: *c.VkImageView) !void {
        const info = c.VkImageViewCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .image = image,
            .viewType = c.VK_IMAGE_VIEW_TYPE_2D,
            .format = self.swapchain_format,
            .components = .{ .r = c.VK_COMPONENT_SWIZZLE_IDENTITY, .g = c.VK_COMPONENT_SWIZZLE_IDENTITY, .b = c.VK_COMPONENT_SWIZZLE_IDENTITY, .a = c.VK_COMPONENT_SWIZZLE_IDENTITY },
            .subresourceRange = .{ .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT, .baseMipLevel = 0, .levelCount = 1, .baseArrayLayer = 0, .layerCount = 1 },
        };
        try vkCheck(c.vkCreateImageView(self.device, &info, null, result));
    }

    fn createFramebuffer(self: *Renderer, view: c.VkImageView, result: *c.VkFramebuffer) !void {
        const attachments = [_]c.VkImageView{view};
        const info = c.VkFramebufferCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .renderPass = self.render_pass,
            .attachmentCount = 1,
            .pAttachments = &attachments,
            .width = self.swapchain_extent.width,
            .height = self.swapchain_extent.height,
            .layers = 1,
        };
        try vkCheck(c.vkCreateFramebuffer(self.device, &info, null, result));
    }

    fn recordFrame(self: *Renderer, cells: []const Cell, cols: u32, rows: u32, image_index: u32) !void {
        _ = cells;
        try vkCheck(c.vkResetCommandBuffer(self.command_buffer, 0));
        const begin_info = c.VkCommandBufferBeginInfo{
            .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
            .pNext = null,
            .flags = c.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
            .pInheritanceInfo = null,
        };
        try vkCheck(c.vkBeginCommandBuffer(self.command_buffer, &begin_info));
        if (self.query_pool != null) {
            c.vkCmdResetQueryPool(self.command_buffer, self.query_pool, 0, 2);
            c.vkCmdWriteTimestamp(self.command_buffer, c.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, self.query_pool, 0);
        }

        const clear = c.VkClearValue{ .color = .{ .float32 = .{ 0, 0, 0, 1 } } };
        const render_begin = c.VkRenderPassBeginInfo{
            .sType = c.VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO,
            .pNext = null,
            .renderPass = self.render_pass,
            .framebuffer = self.framebuffers[image_index],
            .renderArea = .{ .offset = .{ .x = 0, .y = 0 }, .extent = self.swapchain_extent },
            .clearValueCount = 1,
            .pClearValues = &clear,
        };
        c.vkCmdBeginRenderPass(self.command_buffer, &render_begin, c.VK_SUBPASS_CONTENTS_INLINE);
        c.vkCmdBindPipeline(self.command_buffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, self.pipeline);
        const viewport = c.VkViewport{ .x = 0, .y = 0, .width = @floatFromInt(self.swapchain_extent.width), .height = @floatFromInt(self.swapchain_extent.height), .minDepth = 0, .maxDepth = 1 };
        const scissor = c.VkRect2D{ .offset = .{ .x = 0, .y = 0 }, .extent = self.swapchain_extent };
        c.vkCmdSetViewport(self.command_buffer, 0, 1, &viewport);
        c.vkCmdSetScissor(self.command_buffer, 0, 1, &scissor);
        c.vkCmdBindDescriptorSets(self.command_buffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, self.pipeline_layout, 0, 1, &self.descriptor_set, 0, null);
        const push = GridPush{ .width = self.swapchain_extent.width, .height = self.swapchain_extent.height, .cols = cols, .rows = rows, .output_srgb = @intFromBool(self.output_srgb) };
        c.vkCmdPushConstants(self.command_buffer, self.pipeline_layout, c.VK_SHADER_STAGE_FRAGMENT_BIT, 0, @sizeOf(GridPush), &push);
        c.vkCmdDraw(self.command_buffer, 3, 1, 0, 0);
        c.vkCmdEndRenderPass(self.command_buffer);

        if (self.capture_requested) self.recordCapture(image_index);

        if (self.query_pool != null) c.vkCmdWriteTimestamp(self.command_buffer, c.VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT, self.query_pool, 1);
        try vkCheck(c.vkEndCommandBuffer(self.command_buffer));
    }

    fn recordCapture(self: *Renderer, image_index: u32) void {
        const image = self.swapchain_images[image_index];
        const range = c.VkImageSubresourceRange{ .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT, .baseMipLevel = 0, .levelCount = 1, .baseArrayLayer = 0, .layerCount = 1 };
        const to_transfer = c.VkImageMemoryBarrier{
            .sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
            .pNext = null,
            .srcAccessMask = c.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
            .dstAccessMask = c.VK_ACCESS_TRANSFER_READ_BIT,
            .oldLayout = c.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR,
            .newLayout = c.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
            .srcQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED,
            .dstQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED,
            .image = image,
            .subresourceRange = range,
        };
        c.vkCmdPipelineBarrier(self.command_buffer, c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT, c.VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, null, 0, null, 1, &to_transfer);
        const copy = c.VkBufferImageCopy{
            .bufferOffset = 0,
            .bufferRowLength = 0,
            .bufferImageHeight = 0,
            .imageSubresource = .{ .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT, .mipLevel = 0, .baseArrayLayer = 0, .layerCount = 1 },
            .imageOffset = .{ .x = 0, .y = 0, .z = 0 },
            .imageExtent = .{ .width = self.swapchain_extent.width, .height = self.swapchain_extent.height, .depth = 1 },
        };
        c.vkCmdCopyImageToBuffer(self.command_buffer, image, c.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, self.capture_buffer, 1, &copy);
        const to_present = c.VkImageMemoryBarrier{
            .sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
            .pNext = null,
            .srcAccessMask = c.VK_ACCESS_TRANSFER_READ_BIT,
            .dstAccessMask = 0,
            .oldLayout = c.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
            .newLayout = c.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR,
            .srcQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED,
            .dstQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED,
            .image = image,
            .subresourceRange = range,
        };
        c.vkCmdPipelineBarrier(self.command_buffer, c.VK_PIPELINE_STAGE_TRANSFER_BIT, c.VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT, 0, 0, null, 0, null, 1, &to_present);
    }

    fn readGpuTimestamp(self: *Renderer) void {
        if (!self.timestamp_pending or self.query_pool == null) return;
        self.timestamp_pending = false;
        var values: [2]u64 = .{ 0, 0 };
        const result = c.vkGetQueryPoolResults(self.device, self.query_pool, 0, 2, @sizeOf(@TypeOf(values)), &values, @sizeOf(u64), c.VK_QUERY_RESULT_64_BIT);
        if (result != c.VK_SUCCESS) return;
        var ticks = values[1] -% values[0];
        if (self.timestamp_valid_bits < 64) ticks &= (@as(u64, 1) << @intCast(self.timestamp_valid_bits)) - 1;
        self.last_gpu_frame_ns = @intFromFloat(@as(f64, @floatFromInt(ticks)) * @as(f64, self.timestamp_period_ns));
        self.gpu_sample_count +%= 1;
    }

    fn destroySwapchainResources(self: *Renderer) void {
        if (self.pipeline != null and self.device != null) c.vkDestroyPipeline(self.device, self.pipeline, null);
        self.pipeline = null;
        if (self.pipeline_layout != null and self.device != null) c.vkDestroyPipelineLayout(self.device, self.pipeline_layout, null);
        self.pipeline_layout = null;
        for (self.framebuffers) |framebuffer| if (framebuffer != null and self.device != null) c.vkDestroyFramebuffer(self.device, framebuffer, null);
        for (self.image_views) |view| if (view != null and self.device != null) c.vkDestroyImageView(self.device, view, null);
        for (self.present_semaphores) |semaphore| if (semaphore != null and self.device != null) c.vkDestroySemaphore(self.device, semaphore, null);
        if (self.render_pass != null and self.device != null) c.vkDestroyRenderPass(self.device, self.render_pass, null);
        if (self.swapchain != null and self.device != null) c.vkDestroySwapchainKHR(self.device, self.swapchain, null);
        self.render_pass = null;
        self.swapchain = null;
        if (self.framebuffers.len > 0) self.allocator.free(self.framebuffers);
        if (self.image_views.len > 0) self.allocator.free(self.image_views);
        if (self.present_semaphores.len > 0) self.allocator.free(self.present_semaphores);
        if (self.swapchain_images.len > 0) self.allocator.free(self.swapchain_images);
        self.framebuffers = &.{};
        self.image_views = &.{};
        self.present_semaphores = &.{};
        self.swapchain_images = &.{};
        self.swapchain_extent = .{ .width = 0, .height = 0 };
        self.output_srgb = false;
    }
};

const GridPush = extern struct { width: u32, height: u32, cols: u32, rows: u32, output_srgb: u32 };

const QueueFamilies = struct { graphics: u32, present: u32, timestamp_bits: u32 };

fn spirvWords(comptime bytes: []const u8) [bytes.len / 4]u32 {
    if (bytes.len == 0 or bytes.len % 4 != 0) @compileError("invalid SPIR-V byte length");
    var words: [bytes.len / 4]u32 = undefined;
    for (0..words.len) |index| {
        const offset = index * 4;
        words[index] = @as(u32, bytes[offset]) |
            (@as(u32, bytes[offset + 1]) << 8) |
            (@as(u32, bytes[offset + 2]) << 16) |
            (@as(u32, bytes[offset + 3]) << 24);
    }
    return words;
}

fn vkCheck(result: c.VkResult) !void {
    if (result != c.VK_SUCCESS) return error.VulkanCallFailed;
}

fn createShaderModule(device: c.VkDevice, words: []const u32) !c.VkShaderModule {
    const info = c.VkShaderModuleCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .codeSize = words.len * @sizeOf(u32),
        .pCode = words.ptr,
    };
    var module: c.VkShaderModule = null;
    try vkCheck(c.vkCreateShaderModule(device, &info, null, &module));
    return module;
}

fn findQueueFamilies(allocator: std.mem.Allocator, device: c.VkPhysicalDevice, surface: c.VkSurfaceKHR) !?QueueFamilies {
    var count: u32 = 0;
    c.vkGetPhysicalDeviceQueueFamilyProperties(device, &count, null);
    if (count == 0) return null;
    const properties = try allocator.alloc(c.VkQueueFamilyProperties, count);
    defer allocator.free(properties);
    c.vkGetPhysicalDeviceQueueFamilyProperties(device, &count, properties.ptr);
    var graphics: ?u32 = null;
    var present: ?u32 = null;
    var graphics_timestamp_bits: u32 = 0;
    for (properties, 0..) |family, index| {
        if (family.queueCount == 0) continue;
        if (graphics == null and (family.queueFlags & c.VK_QUEUE_GRAPHICS_BIT) != 0) {
            graphics = @intCast(index);
            graphics_timestamp_bits = family.timestampValidBits;
        }
        var supported: c.VkBool32 = c.VK_FALSE;
        if (c.vkGetPhysicalDeviceSurfaceSupportKHR(device, @intCast(index), surface, &supported) != c.VK_SUCCESS) continue;
        if (present == null and supported == c.VK_TRUE) present = @intCast(index);
        if (graphics != null and present != null) break;
    }
    if (graphics) |graphics_index| if (present) |present_index| {
        return .{ .graphics = graphics_index, .present = present_index, .timestamp_bits = graphics_timestamp_bits };
    };
    return null;
}

fn hasDeviceExtension(allocator: std.mem.Allocator, device: c.VkPhysicalDevice, wanted: []const u8) !bool {
    var count: u32 = 0;
    try vkCheck(c.vkEnumerateDeviceExtensionProperties(device, null, &count, null));
    if (count == 0) return false;
    const extensions = try allocator.alloc(c.VkExtensionProperties, count);
    defer allocator.free(extensions);
    try vkCheck(c.vkEnumerateDeviceExtensionProperties(device, null, &count, extensions.ptr));
    for (extensions) |extension| {
        const name = std.mem.sliceTo(extension.extensionName[0..], 0);
        if (std.mem.eql(u8, name, wanted)) return true;
    }
    return false;
}

fn chooseSurfaceFormat(formats: []const c.VkSurfaceFormatKHR) c.VkSurfaceFormatKHR {
    if (formats.len == 1 and formats[0].format == c.VK_FORMAT_UNDEFINED) {
        return .{ .format = c.VK_FORMAT_B8G8R8A8_UNORM, .colorSpace = formats[0].colorSpace };
    }
    for (formats) |format| {
        if (format.format == c.VK_FORMAT_B8G8R8A8_UNORM and format.colorSpace == c.VK_COLOR_SPACE_SRGB_NONLINEAR_KHR) return format;
    }
    for (formats) |format| {
        if (format.format == c.VK_FORMAT_R8G8B8A8_UNORM and format.colorSpace == c.VK_COLOR_SPACE_SRGB_NONLINEAR_KHR) return format;
    }
    for (formats) |format| {
        if (format.format == c.VK_FORMAT_B8G8R8A8_SRGB or format.format == c.VK_FORMAT_R8G8B8A8_SRGB) return format;
    }
    return formats[0];
}

fn isSrgbFormat(format: c.VkFormat) bool {
    return format == c.VK_FORMAT_B8G8R8A8_SRGB or format == c.VK_FORMAT_R8G8B8A8_SRGB;
}

fn isCaptureFormat(format: c.VkFormat) bool {
    return format == c.VK_FORMAT_B8G8R8A8_UNORM or format == c.VK_FORMAT_B8G8R8A8_SRGB or
        format == c.VK_FORMAT_R8G8B8A8_UNORM or format == c.VK_FORMAT_R8G8B8A8_SRGB;
}

fn isCaptureBgra(format: c.VkFormat) bool {
    return format == c.VK_FORMAT_B8G8R8A8_UNORM or format == c.VK_FORMAT_B8G8R8A8_SRGB;
}

fn chooseExtent(capabilities: c.VkSurfaceCapabilitiesKHR, width: u32, height: u32) c.VkExtent2D {
    if (capabilities.currentExtent.width != std.math.maxInt(u32)) return capabilities.currentExtent;
    return .{
        .width = @max(capabilities.minImageExtent.width, @min(width, capabilities.maxImageExtent.width)),
        .height = @max(capabilities.minImageExtent.height, @min(height, capabilities.maxImageExtent.height)),
    };
}

fn chooseCompositeAlpha(supported: c.VkCompositeAlphaFlagsKHR) c.VkCompositeAlphaFlagBitsKHR {
    inline for (.{ c.VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR, c.VK_COMPOSITE_ALPHA_PRE_MULTIPLIED_BIT_KHR, c.VK_COMPOSITE_ALPHA_POST_MULTIPLIED_BIT_KHR, c.VK_COMPOSITE_ALPHA_INHERIT_BIT_KHR }) |candidate| {
        if ((supported & candidate) != 0) return candidate;
    }
    return c.VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR;
}

fn createHostBuffer(self: *Renderer, size: usize, usage: c.VkBufferUsageFlags, out_buffer: *c.VkBuffer, out_memory: *c.VkDeviceMemory, out_mapping: *?[*]u8) !void {
    const buffer_info = c.VkBufferCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .size = size,
        .usage = usage,
        .sharingMode = c.VK_SHARING_MODE_EXCLUSIVE,
        .queueFamilyIndexCount = 0,
        .pQueueFamilyIndices = null,
    };
    var buffer: c.VkBuffer = null;
    try vkCheck(c.vkCreateBuffer(self.device, &buffer_info, null, &buffer));
    errdefer c.vkDestroyBuffer(self.device, buffer, null);

    var requirements: c.VkMemoryRequirements = undefined;
    c.vkGetBufferMemoryRequirements(self.device, buffer, &requirements);
    var memory_properties: c.VkPhysicalDeviceMemoryProperties = undefined;
    c.vkGetPhysicalDeviceMemoryProperties(self.physical_device, &memory_properties);
    const wanted = c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;
    var memory_type: ?u32 = null;
    for (0..memory_properties.memoryTypeCount) |index| {
        const flags = memory_properties.memoryTypes[index].propertyFlags;
        if ((requirements.memoryTypeBits & (@as(u32, 1) << @intCast(index))) != 0 and (flags & wanted) == wanted) {
            memory_type = @intCast(index);
            break;
        }
    }
    const type_index = memory_type orelse return error.NoCoherentHostMemory;
    const allocation_info = c.VkMemoryAllocateInfo{
        .sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
        .pNext = null,
        .allocationSize = requirements.size,
        .memoryTypeIndex = type_index,
    };
    var memory: c.VkDeviceMemory = null;
    try vkCheck(c.vkAllocateMemory(self.device, &allocation_info, null, &memory));
    errdefer c.vkFreeMemory(self.device, memory, null);
    try vkCheck(c.vkBindBufferMemory(self.device, buffer, memory, 0));
    var mapped: ?*anyopaque = null;
    try vkCheck(c.vkMapMemory(self.device, memory, 0, requirements.size, 0, &mapped));

    out_buffer.* = buffer;
    out_memory.* = memory;
    out_mapping.* = @ptrCast(mapped.?);
}
