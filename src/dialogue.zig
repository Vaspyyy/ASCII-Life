const std = @import("std");
const scene = @import("scene.zig");
const people = @import("people.zig");
const sim_mod = @import("village_sim.zig");
const ecology_mod = @import("ecology.zig");
const life_mod = @import("life.zig");
const village_mod = @import("village.zig");

pub const input_capacity = 96;
pub const reply_capacity = 192;
pub const max_history = 8;
pub const max_journal_entries = 16;
pub const journal_text_capacity = reply_capacity;
pub const name_capacity = 24;
pub const journal_page_size = 3;

pub const Intent = enum(u8) {
    greeting,
    ask_name,
    ask_work,
    ask_family,
    ask_news,
    ask_goals,
    ask_about,
    thanks,
    insult,
    apologize,
    goodbye,
    offer_help,
    unknown,
    ask_employment,
    buy_food,
    rent_home,
};

/// Parse the small, explicit set of conversational phrases understood by the
/// current milestone. Punctuation and ASCII letter case do not matter.
pub fn parseIntent(input: []const u8) Intent {
    const phrase = normalized(input) orelse return .unknown;
    if (oneOf(phrase, &.{ "hello", "hi", "hey", "greetings", "good morning", "good evening" })) return .greeting;
    if (oneOf(phrase, &.{ "name", "what is your name", "what's your name", "who are you", "what do people call you" })) return .ask_name;
    if (oneOf(phrase, &.{ "hire me", "paid work", "i need paid work", "can you hire me", "can i work for you", "i want a job" })) return .ask_employment;
    if (oneOf(phrase, &.{ "buy food", "i want to buy food", "can i buy food", "buy provisions" })) return .buy_food;
    if (oneOf(phrase, &.{ "home", "rent a room", "rent room", "can i rent a room", "i need a home", "i need a room" })) return .rent_home;
    if (oneOf(phrase, &.{ "work", "job", "what do you do", "what is your job", "what's your job", "what is your work", "what's your work", "where do you work", "what is your profession" })) return .ask_work;
    if (oneOf(phrase, &.{ "family", "tell me about your family", "do you have family", "who is in your family", "how is your family" })) return .ask_family;
    if (oneOf(phrase, &.{ "news", "what's new", "what is new", "any news", "what happened", "what have you heard", "heard anything", "what's happening", "what is happening" })) return .ask_news;
    if (oneOf(phrase, &.{ "plans", "goal", "goals", "ambitions", "what do you want", "what are your plans", "what is your goal", "what are your goals", "what are your ambitions", "what are you hoping for" })) return .ask_goals;
    if (oneOf(phrase, &.{ "thanks", "thank you", "thanks a lot" })) return .thanks;
    if (oneOf(phrase, &.{ "sorry", "i am sorry", "i'm sorry", "forgive me", "i apologize" })) return .apologize;
    if (oneOf(phrase, &.{ "goodbye", "bye", "see you", "farewell" })) return .goodbye;
    if (oneOf(phrase, &.{ "you fool", "you are a fool", "you are rude", "i hate you", "shut up" })) return .insult;
    if (oneOf(phrase, &.{ "help", "can i help", "can i help you", "do you need help", "i can help", "let me help", "need any help" })) return .offer_help;
    if (oneOf(phrase, &.{ "livestock", "wolves", "sheep" })) return .ask_about;
    if (std.mem.startsWith(u8, phraseSlice(&phrase), "ask about ") and topicIntent(input, "ask about ")) return .ask_about;
    if (std.mem.startsWith(u8, phraseSlice(&phrase), "tell me about ") and topicIntent(input, "tell me about ")) return .ask_about;
    return .unknown;
}

fn topicIntent(input: []const u8, prefix: []const u8) bool {
    const phrase = trimEdgeMarks(input);
    if (phrase.len < prefix.len) return false;
    return std.mem.trim(u8, phrase[prefix.len..], " \t\r\n").len != 0;
}

fn topicText(input: []const u8, prefix_a: []const u8, prefix_b: []const u8) []const u8 {
    const phrase = trimEdgeMarks(input);
    const prefix = if (asciiStartsWithIgnoreCase(phrase, prefix_a)) prefix_a else prefix_b;
    return std.mem.trim(u8, phrase[prefix.len..], " \t\r\n.,?!;:");
}

fn trimEdgeMarks(input: []const u8) []const u8 {
    var start: usize = 0;
    var end = input.len;
    while (start < end and (std.ascii.isWhitespace(input[start]) or isEdgePunctuation(input[start]))) : (start += 1) {}
    while (end > start and (std.ascii.isWhitespace(input[end - 1]) or isEdgePunctuation(input[end - 1]))) : (end -= 1) {}
    return input[start..end];
}

fn normalized(input: []const u8) ?[input_capacity]u8 {
    if (input.len > input_capacity) return null;
    var out = [_]u8{0} ** input_capacity;
    var len: usize = 0;
    for (input) |ch| {
        if (len == out.len) return null;
        out[len] = std.ascii.toLower(ch);
        len += 1;
    }
    var start: usize = 0;
    var end = len;
    while (start < end and (std.ascii.isWhitespace(out[start]) or isEdgePunctuation(out[start]))) : (start += 1) {}
    while (end > start and (std.ascii.isWhitespace(out[end - 1]) or isEdgePunctuation(out[end - 1]))) : (end -= 1) {}
    const compact = out[start..end];
    std.mem.copyForwards(u8, out[0..compact.len], compact);
    if (compact.len < out.len) out[compact.len] = 0;
    return out;
}

fn isEdgePunctuation(ch: u8) bool {
    return switch (ch) {
        '.', ',', '?', '!', ';', ':', '"', '\'', '(', ')', '[', ']', '{', '}' => true,
        else => false,
    };
}

fn oneOf(phrase: [input_capacity]u8, options: []const []const u8) bool {
    const end = std.mem.indexOfScalar(u8, &phrase, 0) orelse phrase.len;
    for (options) |option| if (std.mem.eql(u8, phrase[0..end], option)) return true;
    return false;
}

fn phraseSlice(phrase: *const [input_capacity]u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, phrase, 0) orelse phrase.len;
    return phrase[0..end];
}

pub const TranscriptEntry = struct {
    speaker_id: usize = 0,
    speaker: [name_capacity]u8 = [_]u8{0} ** name_capacity,
    speaker_len: u8 = 0,
    player_line: [input_capacity]u8 = [_]u8{0} ** input_capacity,
    player_len: u8 = 0,
    reply: [reply_capacity]u8 = [_]u8{0} ** reply_capacity,
    reply_len: u8 = 0,
};

pub const JournalEntry = struct {
    text: [journal_text_capacity]u8 = [_]u8{0} ** journal_text_capacity,
    text_len: u8 = 0,
    source_name: [name_capacity]u8 = [_]u8{0} ** name_capacity,
    source_name_len: u8 = 0,
    underlying_source_name: [name_capacity]u8 = [_]u8{0} ** name_capacity,
    underlying_source_name_len: u8 = 0,
    source_id: usize = 0,
    underlying_source_id: u8 = 0,
    provenance: JournalProvenance = .direct_disclosure,
    learned_day: u32 = 0,
};

pub const JournalProvenance = enum(u8) { direct_disclosure, witnessed, told, inferred, notice, read_notice };

/// Session-bounded conversation and learned-information state. It owns no
/// generated simulation facts: Social supplies every factual disclosure.
pub const Dialogue = struct {
    active: bool = false,
    journal_open: bool = false,
    speaker_id: usize = 0,
    speaker_name: [name_capacity]u8 = [_]u8{0} ** name_capacity,
    speaker_name_len: u8 = 0,
    speaker_name_known: bool = false,
    input: [input_capacity]u8 = [_]u8{0} ** input_capacity,
    input_len: u8 = 0,
    reply: [reply_capacity]u8 = [_]u8{0} ** reply_capacity,
    reply_len: u8 = 0,
    last_intent: Intent = .unknown,
    history: [max_history]TranscriptEntry = [_]TranscriptEntry{.{}} ** max_history,
    history_start: usize = 0,
    history_count: usize = 0,
    journal: [max_journal_entries]JournalEntry = [_]JournalEntry{.{}} ** max_journal_entries,
    journal_start: usize = 0,
    journal_count: usize = 0,
    journal_offset: usize = 0,
    known_ids: [people.max_people]usize = [_]usize{0} ** people.max_people,
    known_names: [people.max_people][name_capacity]u8 = [_][name_capacity]u8{[_]u8{0} ** name_capacity} ** people.max_people,
    known_name_lens: [people.max_people]u8 = [_]u8{0} ** people.max_people,
    known_count: usize = 0,
    ask_topic: [input_capacity]u8 = [_]u8{0} ** input_capacity,
    ask_topic_len: u8 = 0,

    pub fn open(self: *Dialogue, speaker_id: usize, social: *people.Social, sim: *sim_mod.Sim) void {
        if (speaker_id >= sim.resident_count or speaker_id >= @as(usize, social.count) or speaker_id > std.math.maxInt(u8)) return;
        self.active = true;
        self.journal_open = false;
        self.speaker_id = speaker_id;
        self.input_len = 0;
        self.input[0] = 0;
        self.reply_len = 0;
        self.reply[0] = 0;
        self.history_start = 0;
        self.history_count = 0;
        self.ask_topic_len = 0;
        self.ask_topic[0] = 0;
        self.speaker_name_known = false;
        self.speaker_name_len = 0;
        self.speaker_name = [_]u8{0} ** name_capacity;
        self.restoreKnownName();
        social.meet(@intCast(speaker_id), sim.elapsed_seconds);
        if (!self.speaker_name_known) self.setReply("You are speaking with a villager.");
    }

    pub fn close(self: *Dialogue) void {
        self.active = false;
        self.input_len = 0;
        self.input[0] = 0;
    }

    pub fn addChar(self: *Dialogue, ch: u8) void {
        if (!self.active or self.journal_open or self.input_len == input_capacity) return;
        if (ch < 0x20 or ch > 0x7e) return;
        self.input[self.input_len] = ch;
        self.input_len += 1;
        if (self.input_len < self.input.len) self.input[self.input_len] = 0;
    }

    pub fn backspace(self: *Dialogue) void {
        if (!self.active or self.journal_open or self.input_len == 0) return;
        self.input_len -= 1;
        self.input[self.input_len] = 0;
    }

    pub fn toggleJournal(self: *Dialogue) void {
        self.journal_open = !self.journal_open;
    }

    /// Reading a physical public notice is a disclosure, not a conversation
    /// with an absent resident or permission to perform work on their behalf.
    pub fn openNotice(self: *Dialogue, ecology: *const ecology_mod.Ecology, social: *const people.Social, sim: *const sim_mod.Sim) void {
        const knowledge = ecology.noticeKnowledge() orelse return;
        const owner = social.person(knowledge.subject_id) orelse return;
        const day: u32 = @intCast(@min(sim.day(), std.math.maxInt(u32)));
        var text: [reply_capacity]u8 = undefined;
        const posted_day = knowledge.observed_at / sim_mod.seconds_per_day + 1;
        const fact = std.fmt.bufPrint(&text, "Posted day {d}: Wolves threaten my sheep. {d} remain; {d} lost. Help protecting the pen is welcome. Signed {s}.", .{ posted_day, knowledge.evidence_count, knowledge.evidence_losses, owner.nameSlice() }) catch return;
        self.recordLearnedWithContext(knowledge.subject_id, "Public notice", fact, day, .read_notice, knowledge.subject_id, owner.nameSlice());
        self.learnName(knowledge.subject_id, owner.nameSlice());
        const guidance = std.fmt.bufPrint(&text, "The pen is {s} of the well, beside the field. Ask {s} 'help' to volunteer; then close the panel and hold G at the pen to repair and guard it.", .{ penDirection(ecology), owner.nameSlice() }) catch return;
        self.recordLearnedWithContext(knowledge.subject_id, "Public notice", guidance, day, .read_notice, knowledge.subject_id, owner.nameSlice());
        self.close();
        self.journal_open = true;
        self.journal_offset = ((self.journal_count -| 2) / journal_page_size) * journal_page_size;
    }

    /// Move through the bounded journal three entries at a time. `delta` is
    /// normally +1 for N and -1 for P.
    pub fn pageJournal(self: *Dialogue, delta: i32) void {
        const page_count = (self.journal_count + journal_page_size - 1) / journal_page_size;
        const current: i32 = @intCast(self.journal_offset / journal_page_size);
        const last_page: i32 = if (page_count == 0) 0 else @intCast(page_count - 1);
        self.journal_offset = @as(usize, @intCast(std.math.clamp(current + delta, 0, last_page))) * journal_page_size;
    }

    pub fn submit(self: *Dialogue, social: *people.Social, sim: *sim_mod.Sim) void {
        if (!self.active or self.journal_open) return;
        self.submitText(self.input[0..self.input_len], social, sim);
    }

    pub fn submitWithEcology(self: *Dialogue, social: *people.Social, sim: *sim_mod.Sim, ecology: *ecology_mod.Ecology) void {
        if (!self.active or self.journal_open) return;
        self.submitTextWithEcology(self.input[0..self.input_len], social, sim, ecology);
    }

    pub fn submitWithLife(self: *Dialogue, social: *people.Social, sim: *sim_mod.Sim, ecology: *ecology_mod.Ecology, life: *life_mod.Life, village: *const village_mod.Village) void {
        if (!self.active or self.journal_open) return;
        self.submitTextWithLife(self.input[0..self.input_len], social, sim, ecology, life, village);
    }

    /// QA and scripted callers can submit the same text path as keyboard input.
    pub fn submitText(self: *Dialogue, line: []const u8, social: *people.Social, sim: *sim_mod.Sim) void {
        self.submitCommon(line, social, sim, null, null, null);
    }

    pub fn submitTextWithEcology(self: *Dialogue, line: []const u8, social: *people.Social, sim: *sim_mod.Sim, ecology: *ecology_mod.Ecology) void {
        self.submitCommon(line, social, sim, ecology, null, null);
    }

    pub fn submitTextWithLife(self: *Dialogue, line: []const u8, social: *people.Social, sim: *sim_mod.Sim, ecology: *ecology_mod.Ecology, life: *life_mod.Life, village: *const village_mod.Village) void {
        self.submitCommon(line, social, sim, ecology, life, village);
    }

    fn submitCommon(self: *Dialogue, line: []const u8, social: *people.Social, sim: *sim_mod.Sim, ecology: ?*ecology_mod.Ecology, life: ?*life_mod.Life, village: ?*const village_mod.Village) void {
        if (!self.active or self.journal_open) return;
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0) return;
        self.last_intent = parseIntent(trimmed);
        self.ask_topic_len = 0;
        self.ask_topic[0] = 0;
        if (self.last_intent == .ask_about) {
            const topic = if (asciiStartsWithIgnoreCase(trimmed, "ask about ") or asciiStartsWithIgnoreCase(trimmed, "tell me about ")) topicText(trimmed, "ask about ", "tell me about ") else trimEdgeMarks(trimmed);
            self.ask_topic_len = @intCast(copyLowerBounded(&self.ask_topic, topic));
        }
        self.respond(social, sim, ecology, life, village);
        self.rememberTurn(trimmed);
        self.input_len = 0;
        self.input[0] = 0;
    }

    fn respond(self: *Dialogue, social: *people.Social, sim: *sim_mod.Sim, ecology: ?*ecology_mod.Ecology, life: ?*life_mod.Life, village: ?*const village_mod.Village) void {
        const id: u8 = @intCast(self.speaker_id);
        const person_value = social.person(id) orelse {
            self.setReply("I don't understand. Try hello, name, work, family, news, plans, help, ask about supplies, or goodbye.");
            return;
        };
        switch (self.last_intent) {
            .greeting => {
                const trust = social.trust(id);
                if (trust < 0) {
                    self.setReply("Hello. After what you said, I need time to trust you.");
                } else if (trust >= 16 and person_value.player.meaningful_actions >= 2) {
                    self.setReply("Hello, my friend. It's good to see you again.");
                } else if (trust > 0) {
                    self.setReply("Hello again. It's good to see you.");
                } else {
                    self.setReply("Hello.");
                }
            },
            .ask_name => {
                const name = person_value.nameSlice();
                self.learnName(self.speaker_id, name);
                self.setReplyFmt("My name is {s}.", .{name});
                self.recordReply(social, sim, .direct_disclosure, 0);
            },
            .ask_work => {
                const occupation = jobName(person_value.job);
                self.setReplyFmt("I work as {s}.", .{occupation});
                self.recordReply(social, sim, .direct_disclosure, 0);
            },
            .ask_employment, .buy_food, .rent_home => self.answerLife(social, sim, life, village),
            .ask_family => self.answerFamily(social, sim, person_value),
            .ask_news => self.answerNews(social, sim, id),
            .ask_goals => self.answerGoal(social, sim, person_value),
            .ask_about => self.answerTopic(social, sim, id),
            .thanks => self.setReply("You're welcome."),
            .insult => {
                social.recordPlayerAction(id, .insult, sim.elapsed_seconds);
                self.setReply(if (social.trust(id) < 0) "That was unkind. I won't forget it." else "Please speak respectfully.");
            },
            .apologize => self.setReply(if (social.trust(id) < 0) "I hear your apology. Trust takes time to mend." else "I hear you."),
            .goodbye => {
                self.setReply("Goodbye. Take care.");
                self.active = false;
            },
            .offer_help => {
                if (ecology) |state| {
                    const knowledge = social.knowledgeAbout(id, .livestock);
                    if (knowledge != null and social.canDisclose(id, knowledge.?.privacy) and state.volunteer(id)) {
                        self.setReplyFmt("You can help protect the sheep. The pen is {s} of the well, beside the field. Close this panel and hold G at the pen to repair and guard it.", .{penDirection(state)});
                        self.recordReply(social, sim, .direct_disclosure, 0);
                        return;
                    }
                }
                self.setReplyFmt("I work as {s}. You can ask how work is going.", .{jobName(person_value.job)});
                self.recordReply(social, sim, .direct_disclosure, 0);
            },
            .unknown => self.setReply("Try hello; name, work, family, news, plans; hire me; buy food; rent a room; ask about supplies or sheep; help; thanks; sorry; or goodbye."),
        }
    }

    fn answerLife(self: *Dialogue, social: *people.Social, sim: *sim_mod.Sim, life: ?*life_mod.Life, village: ?*const village_mod.Village) void {
        const state = life orelse {
            self.setReply("I can tell you about my work. Try 'work'.");
            return;
        };
        const place = village orelse return;
        const id: u8 = @intCast(self.speaker_id);
        if (self.speaker_id >= sim.resident_count) return;
        const resident = sim.residents[self.speaker_id];
        switch (self.last_intent) {
            .ask_employment => {
                if (resident.job != .farmer or !resident.employed) {
                    self.setReply("I cannot offer paid field work. Ask a working farmer 'hire me'.");
                    self.recordReply(social, sim, .direct_disclosure, 0);
                } else if (state.employer_id != null and state.employer_id.? != id) {
                    self.setReply("You already have a farmer to work with. Keep that arrangement for now.");
                } else if (!state.hire(id, sim, social)) {
                    self.setReply("After how you treated me, I cannot offer you work yet.");
                } else {
                    self.learnName(id, resident.nameSlice());
                    const field = place.buildingsSlice()[resident.workplace];
                    self.setReplyFmt("I'm {s}. My field is {s} of the well: hold G at its entrance in working hours. Pay: 2 coins/hour, up to six hours/day, plus a quarter ration if stores allow.", .{ resident.nameSlice(), placeDirection(place, field.x, field.z) });
                    self.recordReply(social, sim, .direct_disclosure, 0);
                }
            },
            .buy_food => {
                if (resident.job != .keeper or !resident.employed) {
                    self.setReply("I do not sell provisions. Ask the keeper of the village stores 'buy food'.");
                } else if (state.buyFood(id, sim, social)) {
                    self.setReply("Here are two daily rations for 3 coins. Keep some coins for your room. Your food is eaten as you live and work.");
                } else if (social.trust(id) < -20) {
                    self.setReply("After how you treated me, I will not trade with you yet.");
                } else if (state.coins < 3) {
                    self.setReply("Two daily rations cost 3 coins. You do not have enough coins yet.");
                } else {
                    self.setReply("I cannot spare two rations from the village stores today.");
                }
                self.recordReply(social, sim, .direct_disclosure, 0);
            },
            .rent_home => {
                if (state.home_household) |home| {
                    if (home == resident.household) {
                        const door = place.doorPoint(sim.households[home].home_building);
                        self.setReplyFmt("Your room is with us, {s} of the well. Upkeep is 1 coin a day after the first week. Near our door you can sleep or live your routine; K shows your life.", .{placeDirection(place, door.x, door.z)});
                        self.recordReply(social, sim, .direct_disclosure, 0);
                    } else self.setReply("You already have a room with another household.");
                } else if (resident.job == .child) {
                    self.setReply("Ask an adult in the household about a room.");
                } else if (state.rentHome(id, sim, social)) {
                    self.learnName(id, resident.nameSlice());
                    const door = place.doorPoint(resident.home_building);
                    self.setReplyFmt("I'm {s}. Your room is {s} of the well. The 7 coins cover the first week, then 1 coin/day. Come to our door to sleep or live your work routine. K shows your life.", .{ resident.nameSlice(), placeDirection(place, door.x, door.z) });
                    self.recordReply(social, sim, .direct_disclosure, 0);
                } else if (social.trust(id) < 0) {
                    self.setReply("I cannot invite you into our home after how you treated me. Trust will need time and real help to mend.");
                } else if (state.coins < 7) {
                    self.setReply("A room costs 7 coins for the first week, then 1 coin a day. Save enough for the first payment.");
                    self.recordReply(social, sim, .direct_disclosure, 0);
                } else {
                    self.setReply("A room costs 7 coins, then 1 a day. First work four paid hours for our household, or let us get to know you through real help.");
                    self.recordReply(social, sim, .direct_disclosure, 0);
                }
            },
            else => unreachable,
        }
    }

    fn answerFamily(self: *Dialogue, social: *people.Social, sim: *sim_mod.Sim, person_value: *const people.Person) void {
        const id: u8 = @intCast(self.speaker_id);
        if (!social.canDisclose(id, .personal)) {
            self.setReply("I'd rather keep family matters to myself for now.");
            return;
        }
        if (person_value.family_count == 0) {
            self.setReply("I have no close family here.");
            self.recordReply(social, sim, .direct_disclosure, 0);
            return;
        }
        var response: [reply_capacity]u8 = undefined;
        var used = copyBounded(&response, "My family includes ");
        for (person_value.family[0..person_value.family_count], 0..) |link, i| {
            const relative = social.person(link.other_id) orelse continue;
            const separator = if (i == 0) "" else if (i + 1 == person_value.family_count) ", and " else ", ";
            used = appendFormat(&response, used, "{s}{s} ({s})", .{ separator, relative.nameSlice(), familyName(link.kind) });
        }
        if (used == "My family includes ".len) {
            self.setReply("I'd rather not discuss family details.");
            return;
        }
        self.setReply(response[0..used]);
        self.recordReply(social, sim, .direct_disclosure, 0);
    }

    fn answerGoal(self: *Dialogue, social: *people.Social, sim: *sim_mod.Sim, person_value: *const people.Person) void {
        const id: u8 = @intCast(self.speaker_id);
        if (!social.canDisclose(id, .private)) {
            self.setReply("Those are personal plans. I don't share them with just anyone.");
            return;
        }
        const goal = goalDescription(person_value.goal.kind);
        const progress = person_value.goal.progress_hours;
        const target = person_value.goal.target_hours;
        if (person_value.goal.completed) {
            self.setReplyFmt("I wanted to {s}; I've managed it now.", .{goal});
        } else {
            self.setReplyFmt("I want to {s}. I've made progress, but there's more to do.", .{goal});
        }
        // Progress is a real simulated counter; include it only when useful.
        if (!person_value.goal.completed and target != 0 and progress != 0) {
            self.setReplyFmt("I want to {s}. I've put in {d} of {d} hours so far.", .{ goal, progress, target });
        }
        self.recordReply(social, sim, .direct_disclosure, 0);
    }

    fn answerNews(self: *Dialogue, social: *people.Social, sim: *sim_mod.Sim, id: u8) void {
        var newest: ?people.Knowledge = null;
        for ([_]people.Topic{ .food_reserves, .harvest, .work, .livestock }) |topic| {
            const knowledge = social.knowledgeAbout(id, topic) orelse continue;
            if (!social.canDisclose(id, knowledge.privacy)) continue;
            if (newest == null or knowledge.observed_at > newest.?.observed_at or (topic == .livestock and knowledge.observed_at == newest.?.observed_at)) newest = knowledge;
        }
        if (newest) |knowledge| {
            self.answerKnowledge(social, sim, knowledge);
        } else {
            self.setReply("I haven't heard anything in particular that I can report.");
        }
    }

    fn answerTopic(self: *Dialogue, social: *people.Social, sim: *sim_mod.Sim, id: u8) void {
        const topic_name = self.ask_topic[0..self.ask_topic_len];
        const topic: ?people.Topic = if (topicMatches(topic_name, &.{ "food", "supplies", "food supplies", "food stores", "food reserves", "provisions", "stores" }))
            .food_reserves
        else if (topicMatches(topic_name, &.{ "harvest", "crops", "fields" }))
            .harvest
        else if (topicMatches(topic_name, &.{ "work", "jobs", "workplaces" }))
            .work
        else if (topicMatches(topic_name, &.{ "livestock", "wolves", "sheep", "animals", "pen" }))
            .livestock
        else
            null;
        const selected = topic orelse {
            self.setReply("I don't know anything I can tell you about that.");
            return;
        };
        const knowledge = social.knowledgeAbout(id, selected) orelse {
            self.setReply("I don't know enough about that to answer.");
            return;
        };
        if (!social.canDisclose(id, knowledge.privacy)) {
            self.setReply("I can't share that with you yet.");
            return;
        }
        self.answerKnowledge(social, sim, knowledge);
    }

    fn answerKnowledge(self: *Dialogue, social: *people.Social, sim: *sim_mod.Sim, knowledge: people.Knowledge) void {
        self.setReply("I don't know enough about that to answer.");
        const stale = sim.elapsed_seconds -| knowledge.observed_at >= sim_mod.seconds_per_day;
        var opening_buffer: [64]u8 = undefined;
        const opening = knowledgeOpening(&opening_buffer, social, knowledge, stale);
        switch (knowledge.topic) {
            .food_reserves => switch (knowledge.belief) {
                .well_stocked => self.setReplyFmt("{s}the stores {s}food for about {d} days per resident.", .{ opening, if (stale) "held " else "hold ", knowledge.evidence_days }),
                .thin_stock => self.setReplyFmt("{s}there {s}about {d} days of food per resident, but some must stay for seed.", .{ opening, if (stale) "were " else "are ", knowledge.evidence_days }),
                .critical => {
                    const days = @as(u16, knowledge.evidence_days) + 1;
                    self.setReplyFmt("{s}food supplies {s}critically low, with less than {d} {s} per resident.", .{ opening, if (stale) "were " else "are ", days, if (days == 1) "day" else "days" });
                },
                else => return,
            },
            .harvest => switch (knowledge.belief) {
                .harvest_started => self.setReplyFmt("{s}the harvest {s}started.", .{ opening, if (stale) "had " else "has " }),
                .harvest_modest => self.setReplyFmt("{s}the harvest {s}modest so far.", .{ opening, if (stale) "looked " else "looks " }),
                else => return,
            },
            .work => switch (knowledge.belief) {
                .work_steady => self.setReplyFmt("{s}work around the village {s}steady.", .{ opening, if (stale) "was " else "is " }),
                .work_sparse => self.setReplyFmt("{s}there {s}much work around the village lately.", .{ opening, if (stale) "wasn't " else "hasn't been " }),
                else => return,
            },
            .livestock => switch (knowledge.belief) {
                .livestock_taken => self.setReplyFmt("{s}wolves took sheep. At that time {d} remained, with {d} lost in all.", .{ opening, knowledge.evidence_count, knowledge.evidence_losses }),
                .livestock_threatened => self.setReplyFmt("{s}wolves threatened the sheep pen. At that time {d} sheep remained; protection was needed.", .{ opening, knowledge.evidence_count }),
                .livestock_protected => self.setReplyFmt("{s}the sheep pen was protected. At that time {d} sheep remained, with {d} lost in all.", .{ opening, knowledge.evidence_count, knowledge.evidence_losses }),
                .livestock_lost_all => self.setReplyFmt("{s}the household had lost all its sheep, {d} in all.", .{ opening, knowledge.evidence_losses }),
                else => {
                    self.setReply("I don't know enough about that to answer.");
                    return;
                },
            },
        }
        const provenance: JournalProvenance = switch (knowledge.provenance) {
            .witnessed => .witnessed,
            .told => .told,
            .inferred => .inferred,
            .notice => .notice,
        };
        self.recordReply(social, sim, provenance, knowledge.source_id);
    }

    fn recordReply(self: *Dialogue, social: *people.Social, sim: *sim_mod.Sim, provenance: JournalProvenance, underlying_source_id: u8) void {
        const id: u8 = @intCast(self.speaker_id);
        const name = if (self.speaker_name_known) self.currentSpeakerName() else "Villager";
        const day: u32 = @intCast(@min(sim.day(), std.math.maxInt(u32)));
        if (social.person(id) == null) return;
        const source_id = if (provenance == .told or provenance == .notice) underlying_source_id else id;
        const underlying_name = if (provenance == .told or provenance == .notice) blk: {
            const source = social.person(source_id) orelse break :blk "";
            break :blk source.nameSlice();
        } else "";
        self.recordLearnedWithContext(id, name, self.reply[0..self.reply_len], day, provenance, source_id, underlying_name);
    }

    fn setReplyFmt(self: *Dialogue, comptime fmt: []const u8, args: anytype) void {
        self.reply = [_]u8{0} ** reply_capacity;
        const text = std.fmt.bufPrint(&self.reply, fmt, args) catch self.reply[0..0];
        self.reply_len = @intCast(text.len);
    }

    pub fn speakerName(self: *const Dialogue) []const u8 {
        return self.currentSpeakerName();
    }

    pub fn knownName(self: *const Dialogue, person_id: usize) ?[]const u8 {
        for (0..self.known_count) |i| if (self.known_ids[i] == person_id and self.known_name_lens[i] != 0) return self.known_names[i][0..self.known_name_lens[i]];
        return null;
    }

    /// Add a fact only after Social explicitly disclosed it to the player.
    pub fn recordLearned(self: *Dialogue, source_id: usize, source_name: []const u8, fact: []const u8, day: u32) void {
        self.recordLearnedWithProvenance(source_id, source_name, fact, day, .direct_disclosure, 0);
    }

    pub fn recordLearnedWithProvenance(self: *Dialogue, source_id: usize, source_name: []const u8, fact: []const u8, day: u32, provenance: JournalProvenance, underlying_source_id: u8) void {
        self.recordLearnedWithContext(source_id, source_name, fact, day, provenance, underlying_source_id, "");
    }

    pub fn recordLearnedWithContext(self: *Dialogue, source_id: usize, source_name: []const u8, fact: []const u8, day: u32, provenance: JournalProvenance, underlying_source_id: u8, underlying_source_name: []const u8) void {
        const text = std.mem.trim(u8, fact, " \t\r\n");
        if (text.len == 0) return;
        for (0..self.journal_count) |i| {
            const entry = self.journal[(self.journal_start + i) % max_journal_entries];
            if (entry.source_id == source_id and std.mem.eql(u8, entry.text[0..entry.text_len], text)) return;
        }
        const index = if (self.journal_count < max_journal_entries) blk: {
            const at = (self.journal_start + self.journal_count) % max_journal_entries;
            self.journal_count += 1;
            break :blk at;
        } else blk: {
            const at = self.journal_start;
            self.journal_start = (self.journal_start + 1) % max_journal_entries;
            break :blk at;
        };
        var entry = JournalEntry{ .source_id = source_id, .learned_day = day, .provenance = provenance, .underlying_source_id = underlying_source_id };
        entry.text_len = @intCast(copyBounded(&entry.text, text));
        entry.source_name_len = @intCast(copyBounded(&entry.source_name, source_name));
        entry.underlying_source_name_len = @intCast(copyBounded(&entry.underlying_source_name, underlying_source_name));
        self.journal[index] = entry;
    }

    /// Make a name known only after the conversation has introduced it.
    pub fn learnName(self: *Dialogue, person_id: usize, name: []const u8) void {
        const n = std.mem.trim(u8, name, " \t\r\n");
        if (n.len == 0) return;
        var index: usize = self.known_count;
        for (0..self.known_count) |i| if (self.known_ids[i] == person_id) {
            index = i;
            break;
        };
        if (index == self.known_count) {
            if (self.known_count < self.known_ids.len) {
                self.known_count += 1;
            } else {
                // Reuse the lowest identifier only if a future population
                // larger than the village limit reaches this table.
                index = 0;
                for (1..self.known_count) |i| if (self.known_ids[i] < self.known_ids[index]) {
                    index = i;
                };
            }
            self.known_ids[index] = person_id;
        }
        @memset(&self.known_names[index], 0);
        self.known_name_lens[index] = @intCast(copyBounded(&self.known_names[index], n));
        if (self.active and self.speaker_id == person_id) self.restoreKnownName();
    }

    pub fn paint(self: *const Dialogue, cells: []scene.Cell) void {
        if (self.journal_open) return self.paintJournal(cells);
        if (!self.active) return;
        self.beginPanel(cells, "Conversation");
        const bounds = panelBounds();
        if (bounds.width < 4 or bounds.height < 5) return;
        var title: [name_capacity + 24]u8 = [_]u8{0} ** (name_capacity + 24);
        const who = self.currentSpeakerName();
        const head = std.fmt.bufPrint(&title, "Conversation with {s}", .{who}) catch "Conversation";
        drawText(cells, bounds.x + 2, bounds.y + 1, bounds.width - 4, head, color_heading);
        drawText(cells, bounds.x + 2, bounds.y + 2, bounds.width - 4, "name | work | hire me | buy food | rent a room | family | news | plans | help | bye", color_hint);
        const prompt_y = bounds.y + bounds.height - 2;
        drawHLine(cells, bounds.x + 1, prompt_y - 1, bounds.width - 2, color_border);
        self.paintHistory(cells, bounds.x + 2, bounds.y + 3, bounds.width - 4, prompt_y - 1 - (bounds.y + 3));
        var prompt: [input_capacity + 4]u8 = [_]u8{0} ** (input_capacity + 4);
        const prompt_width = bounds.width - 4;
        const prompt_text = if (self.input_len + 3 <= prompt_width)
            std.fmt.bufPrint(&prompt, "> {s}_", .{self.input[0..self.input_len]}) catch ">"
        else blk: {
            const visible = prompt_width -| 6;
            const tail = self.input[self.input_len -| visible..self.input_len];
            break :blk std.fmt.bufPrint(&prompt, "> ...{s}_", .{tail}) catch ">";
        };
        drawText(cells, bounds.x + 2, prompt_y, prompt_width, prompt_text, color_prompt);
        drawText(cells, bounds.x + 2, bounds.y + bounds.height - 1, bounds.width - 4, "Enter speak / Esc leave / time paused", color_hint);
    }

    pub fn paintJournal(self: *const Dialogue, cells: []scene.Cell) void {
        const bounds = panelBounds();
        if (bounds.width == 0 or bounds.height == 0) return;
        self.beginPanel(cells, "Journal - information you learned");
        drawText(cells, bounds.x + 2, bounds.y + 1, bounds.width - 24, "J / Esc close / time paused", color_hint);
        drawHLine(cells, bounds.x + 1, bounds.y + 2, bounds.width - 2, color_border);
        var row = bounds.y + 3;
        const end_y = bounds.y + bounds.height - 1;
        if (self.journal_count == 0) {
            drawText(cells, bounds.x + 2, row, bounds.width - 4, "Nothing learned yet.", color_text);
            return;
        }
        const page_end = @min(self.journal_count, self.journal_offset + journal_page_size);
        for (self.journal_offset..page_end) |i| {
            const entry = self.journal[(self.journal_start + i) % max_journal_entries];
            var line: [journal_text_capacity + name_capacity + 64]u8 = undefined;
            const source = if (entry.source_name_len == 0) "A villager" else entry.source_name[0..entry.source_name_len];
            const attribution = switch (entry.provenance) {
                .direct_disclosure => " told you: ",
                .witnessed => if (entry.source_id == people.player_id) " observed: " else " told you from direct observation: ",
                .told => if (entry.underlying_source_name_len != 0) " told you they heard from " else " passed on what they heard: ",
                .inferred => " suspects: ",
                .notice => " disclosed a posted notice: ",
                .read_notice => " states: ",
            };
            const content = if (entry.provenance == .told and entry.underlying_source_name_len != 0)
                std.fmt.bufPrint(&line, "Day {d}: {s}{s}{s}: {s}", .{ @as(u64, entry.learned_day) + 1, source, attribution, entry.underlying_source_name[0..entry.underlying_source_name_len], entry.text[0..entry.text_len] }) catch continue
            else
                std.fmt.bufPrint(&line, "Day {d}: {s}{s}{s}", .{ @as(u64, entry.learned_day) + 1, source, attribution, entry.text[0..entry.text_len] }) catch continue;
            const used = drawWrapped(cells, bounds.x + 2, row, bounds.width - 4, end_y - row, content, color_text);
            row += used;
            if (row >= end_y) break;
        }
        var page_note: [28]u8 = undefined;
        const page_count = @max(1, (self.journal_count + journal_page_size - 1) / journal_page_size);
        const page_text = std.fmt.bufPrint(&page_note, "N/P page {d}/{d}", .{ self.journal_offset / journal_page_size + 1, page_count }) catch "N/P";
        drawText(cells, bounds.x + bounds.width - @min(bounds.width - 2, page_text.len) - 1, bounds.y + 1, page_text.len, page_text, color_heading);
    }

    fn currentSpeakerName(self: *const Dialogue) []const u8 {
        if (self.speaker_name_known and self.speaker_name_len != 0) return self.speaker_name[0..self.speaker_name_len];
        return "Villager";
    }

    fn restoreKnownName(self: *Dialogue) void {
        for (0..self.known_count) |i| if (self.known_ids[i] == self.speaker_id and self.known_name_lens[i] != 0) {
            self.speaker_name = self.known_names[i];
            self.speaker_name_len = self.known_name_lens[i];
            self.speaker_name_known = true;
            return;
        };
    }

    fn setReply(self: *Dialogue, text: []const u8) void {
        @memset(&self.reply, 0);
        self.reply_len = @intCast(copyBounded(&self.reply, text));
    }

    fn rememberTurn(self: *Dialogue, line: []const u8) void {
        const index = if (self.history_count < max_history) blk: {
            const at = (self.history_start + self.history_count) % max_history;
            self.history_count += 1;
            break :blk at;
        } else blk: {
            const at = self.history_start;
            self.history_start = (self.history_start + 1) % max_history;
            break :blk at;
        };
        var entry = TranscriptEntry{ .speaker_id = self.speaker_id };
        const who = self.currentSpeakerName();
        entry.speaker_len = @intCast(copyBounded(&entry.speaker, who));
        entry.player_len = @intCast(copyBounded(&entry.player_line, line));
        entry.reply_len = @intCast(copyBounded(&entry.reply, self.reply[0..self.reply_len]));
        self.history[index] = entry;
    }

    fn paintHistory(self: *const Dialogue, cells: []scene.Cell, x: usize, y: usize, width: usize, height: usize) void {
        if (width == 0 or height == 0) return;
        var row = y;
        const end = y + height;
        const first = self.visibleHistoryStart(width, height);
        for (first..self.history_count) |i| {
            const entry = self.history[(self.history_start + i) % max_history];
            var text: [input_capacity + 8]u8 = undefined;
            const player = std.fmt.bufPrint(&text, "You: {s}", .{entry.player_line[0..entry.player_len]}) catch continue;
            row += drawWrapped(cells, x, row, width, end - row, player, color_player);
            if (row >= end) break;
            var answer: [reply_capacity + name_capacity + 4]u8 = undefined;
            const npc = std.fmt.bufPrint(&answer, "{s}: {s}", .{ entry.speaker[0..entry.speaker_len], entry.reply[0..entry.reply_len] }) catch continue;
            row += drawWrapped(cells, x, row, width, end - row, npc, color_text);
            if (row >= end) break;
        }
        if (self.history_count == 0 and self.reply_len != 0) {
            var reply_line: [reply_capacity + name_capacity + 4]u8 = undefined;
            const who = self.currentSpeakerName();
            const text = std.fmt.bufPrint(&reply_line, "{s}: {s}", .{ who, self.reply[0..self.reply_len] }) catch return;
            _ = drawWrapped(cells, x, row, width, end - row, text, color_text);
        }
    }

    fn visibleHistoryStart(self: *const Dialogue, width: usize, height: usize) usize {
        var first = self.history_count;
        var rows_used: usize = 0;
        while (first > 0) {
            const entry = self.history[(self.history_start + first - 1) % max_history];
            var player_buffer: [input_capacity + 8]u8 = undefined;
            const player_line = std.fmt.bufPrint(&player_buffer, "You: {s}", .{entry.player_line[0..entry.player_len]}) catch "You:";
            var reply_buffer: [reply_capacity + name_capacity + 4]u8 = undefined;
            const npc_line = std.fmt.bufPrint(&reply_buffer, "{s}: {s}", .{ entry.speaker[0..entry.speaker_len], entry.reply[0..entry.reply_len] }) catch "Villager:";
            const needed = wrappedRows(player_line, width) + wrappedRows(npc_line, width);
            if (rows_used != 0 and rows_used + needed > height) break;
            rows_used += needed;
            first -= 1;
            if (rows_used >= height) break;
        }
        return first;
    }

    fn beginPanel(self: *const Dialogue, cells: []scene.Cell, heading: []const u8) void {
        _ = self;
        const bounds = panelBounds();
        if (bounds.width == 0 or bounds.height == 0) return;
        for (bounds.y..bounds.y + bounds.height) |row| {
            const begin = row * scene.cols + bounds.x;
            const finish = @min(cells.len, begin + bounds.width);
            if (begin >= finish) continue;
            for (cells[begin..finish]) |*cell| {
                cell.glyph = ' ';
                cell.foreground = color_text;
                cell.background = color_background;
            }
        }
        if (bounds.width < 2 or bounds.height < 2) return;
        drawHLine(cells, bounds.x, bounds.y, bounds.width, color_border);
        drawHLine(cells, bounds.x, bounds.y + bounds.height - 1, bounds.width, color_border);
        for (bounds.y..bounds.y + bounds.height) |row| {
            putCell(cells, bounds.x, row, '|', color_border, color_background);
            putCell(cells, bounds.x + bounds.width - 1, row, '|', color_border, color_background);
        }
        drawText(cells, bounds.x + 2, bounds.y, bounds.width - 4, heading, color_heading);
    }
};

const PanelBounds = struct { x: usize, y: usize, width: usize, height: usize };
const panel_width: usize = 100;
const panel_height: usize = 16;
const color_background: u32 = scene.rgb(8, 12, 19);
const color_border: u32 = scene.rgb(81, 112, 140);
const color_heading: u32 = scene.rgb(196, 220, 238);
const color_text: u32 = scene.rgb(221, 228, 231);
const color_player: u32 = scene.rgb(149, 200, 168);
const color_prompt: u32 = scene.rgb(255, 220, 147);
const color_hint: u32 = scene.rgb(139, 163, 182);

fn panelBounds() PanelBounds {
    const cols: usize = scene.cols;
    const rows: usize = scene.rows;
    const width = @min(panel_width, cols);
    const height = @min(panel_height, rows);
    // Leave room for the desktop's window placement and decoration in a
    // monitor-sized window, as well as a visual inset in fullscreen.
    const bottom_margin = @min(6, rows - height);
    return .{ .x = (cols - width) / 2, .y = rows - height - bottom_margin, .width = width, .height = height };
}

fn copyBounded(dest: []u8, source: []const u8) usize {
    const count = @min(dest.len, source.len);
    @memcpy(dest[0..count], source[0..count]);
    return count;
}

fn copyLowerBounded(dest: []u8, source: []const u8) usize {
    const count = @min(dest.len, source.len);
    for (source[0..count], 0..) |ch, i| dest[i] = std.ascii.toLower(ch);
    return count;
}

fn appendFormat(dest: *[reply_capacity]u8, used: usize, comptime fmt: []const u8, args: anytype) usize {
    if (used >= dest.len) return dest.len;
    const text = std.fmt.bufPrint(dest[used..], fmt, args) catch return dest.len;
    return used + text.len;
}

fn asciiStartsWithIgnoreCase(text: []const u8, prefix: []const u8) bool {
    if (text.len < prefix.len) return false;
    for (text[0..prefix.len], prefix) |a, b| if (std.ascii.toLower(a) != std.ascii.toLower(b)) return false;
    return true;
}

fn asciiEqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| if (std.ascii.toLower(ca) != std.ascii.toLower(cb)) return false;
    return true;
}

fn topicMatches(topic: []const u8, choices: []const []const u8) bool {
    for (choices) |choice| if (asciiEqlIgnoreCase(topic, choice)) return true;
    return false;
}

fn knowledgeOpening(buffer: []u8, social: *const people.Social, knowledge: people.Knowledge, stale: bool) []const u8 {
    return switch (knowledge.provenance) {
        .witnessed => if (stale) "At my last look, " else "",
        .inferred => if (stale) "At my last count, I suspect that " else "I suspect that ",
        .notice => if (social.person(knowledge.source_id)) |source|
            std.fmt.bufPrint(buffer, "I read {s}'s notice saying that ", .{source.nameSlice()}) catch "I read a notice saying that "
        else
            "I read a notice saying that ",
        .told => if (social.person(knowledge.source_id)) |source| blk: {
            if (stale) break :blk std.fmt.bufPrint(buffer, "The last I heard from {s}, ", .{source.nameSlice()}) catch "The last I heard, ";
            break :blk std.fmt.bufPrint(buffer, "I heard from {s} that ", .{source.nameSlice()}) catch "I heard that ";
        } else if (stale) "The last I heard, " else "I heard that ",
    };
}

/// The established village coordinate convention is +X east and -Z north.
fn penDirection(ecology: *const ecology_mod.Ecology) []const u8 {
    const dx = ecology.pen.x - ecology.well.x;
    const dz = ecology.pen.z - ecology.well.z;
    if (@abs(dx) > @abs(dz) * 2) return if (dx >= 0) "east" else "west";
    if (@abs(dz) > @abs(dx) * 2) return if (dz >= 0) "south" else "north";
    if (dz >= 0) return if (dx >= 0) "southeast" else "southwest";
    return if (dx >= 0) "northeast" else "northwest";
}

fn placeDirection(village: *const village_mod.Village, x: f32, z: f32) []const u8 {
    var well = village.center;
    for (village.buildingsSlice()) |building| if (building.kind == .well) {
        well = .{ .x = building.x, .z = building.z };
        break;
    };
    const dx = x - well.x;
    const dz = z - well.z;
    if (@abs(dx) > @abs(dz) * 2) return if (dx >= 0) "east" else "west";
    if (@abs(dz) > @abs(dx) * 2) return if (dz >= 0) "south" else "north";
    if (dz >= 0) return if (dx >= 0) "southeast" else "southwest";
    return if (dx >= 0) "northeast" else "northwest";
}

fn jobName(job: sim_mod.Job) []const u8 {
    return switch (job) {
        .child => "a child helping at home",
        .farmer => "a farmer",
        .craftsperson => "a craftsperson",
        .keeper => "a keeper of the village stores",
        .water_carrier => "a water carrier",
    };
}

fn familyName(kind: people.FamilyKind) []const u8 {
    return switch (kind) {
        .partner => "partner",
        .parent => "parent",
        .child => "child",
        .sibling => "sibling",
    };
}

fn goalDescription(kind: people.GoalKind) []const u8 {
    return switch (kind) {
        .tend_fields => "tend the fields well",
        .maintain_supplies => "keep the village supplied",
        .craft_better_tools => "craft better tools",
        .carry_water => "carry water to village homes",
        .learn_village_trades => "learn the trades practiced here",
    };
}

fn wrappedRows(text: []const u8, width: usize) usize {
    if (width == 0) return 1;
    var rows: usize = 1;
    var col: usize = 0;
    var words = std.mem.tokenizeScalar(u8, text, ' ');
    while (words.next()) |word| {
        if (col != 0 and col + 1 + word.len > width) {
            rows += 1;
            col = 0;
        }
        if (col != 0) col += 1;
        for (word) |_| {
            if (col == width) {
                rows += 1;
                col = 0;
            }
            col += 1;
        }
    }
    return rows;
}

fn putCell(cells: []scene.Cell, x: usize, y: usize, ch: u8, fg: u32, bg: u32) void {
    if (x >= scene.cols or y >= scene.rows) return;
    const index = y * scene.cols + x;
    if (index >= cells.len) return;
    cells[index].glyph = if (ch < 128) ch else '?';
    cells[index].foreground = fg;
    cells[index].background = bg;
}

fn drawText(cells: []scene.Cell, x: usize, y: usize, width: usize, text: []const u8, color: u32) void {
    if (y >= scene.rows) return;
    for (text, 0..) |ch, i| {
        if (i >= width or x + i >= scene.cols) break;
        putCell(cells, x + i, y, ch, color, color_background);
    }
}

fn drawHLine(cells: []scene.Cell, x: usize, y: usize, width: usize, color: u32) void {
    if (y >= scene.rows) return;
    for (0..width) |i| putCell(cells, x + i, y, '-', color, color_background);
}

fn drawWrapped(cells: []scene.Cell, x: usize, y: usize, width: usize, max_rows: usize, text: []const u8, color: u32) usize {
    if (width == 0 or max_rows == 0) return 0;
    var row: usize = 0;
    var col: usize = 0;
    var words = std.mem.tokenizeScalar(u8, text, ' ');
    while (words.next()) |word| {
        if (col != 0 and col + 1 + word.len > width) {
            row += 1;
            col = 0;
            if (row >= max_rows) return max_rows;
        }
        if (col != 0) {
            putCell(cells, x + col, y + row, ' ', color, color_background);
            col += 1;
        }
        for (word) |ch| {
            if (col == width) {
                row += 1;
                col = 0;
                if (row >= max_rows) return max_rows;
            }
            putCell(cells, x + col, y + row, ch, color, color_background);
            col += 1;
        }
    }
    return @min(max_rows, row + 1);
}

test "typed phrase parsing is case insensitive and tolerates basic punctuation" {
    try std.testing.expectEqual(Intent.greeting, parseIntent(" HELLO! "));
    try std.testing.expectEqual(Intent.ask_name, parseIntent("What's your name?"));
    try std.testing.expectEqual(Intent.ask_work, parseIntent("WORK"));
    try std.testing.expectEqual(Intent.ask_employment, parseIntent("Hire me!"));
    try std.testing.expectEqual(Intent.ask_employment, parseIntent("paid work"));
    try std.testing.expectEqual(Intent.buy_food, parseIntent("Buy food."));
    try std.testing.expectEqual(Intent.rent_home, parseIntent("rent a room"));
    try std.testing.expectEqual(Intent.rent_home, parseIntent("home"));
    try std.testing.expectEqual(Intent.ask_family, parseIntent("family"));
    try std.testing.expectEqual(Intent.ask_about, parseIntent("Tell me about supplies."));
    try std.testing.expectEqual(Intent.unknown, parseIntent("Tell me about ."));
    try std.testing.expectEqual(Intent.unknown, parseIntent("I heard a thing"));
    try std.testing.expectEqual(Intent.unknown, parseIntent("hello" ** 30));
}

test "input stays bounded and wraps transcript in the bottom panel" {
    var dialogue = Dialogue{};
    dialogue.active = true;
    for (0..input_capacity + 8) |_| dialogue.addChar('x');
    try std.testing.expectEqual(@as(usize, input_capacity), dialogue.input_len);
    dialogue.backspace();
    try std.testing.expectEqual(@as(usize, input_capacity - 1), dialogue.input_len);
    dialogue.input_len = 0;
    dialogue.setReply("Hello.");
    dialogue.rememberTurn("hello");
    var cells = [_]scene.Cell{.{ .glyph = 0, .foreground = 0, .background = 0 }} ** (scene.cols * scene.rows);
    dialogue.paint(&cells);
    const bounds = panelBounds();
    try std.testing.expectEqual(@as(u32, '|'), cells[bounds.y * scene.cols + bounds.x].glyph);
    try std.testing.expect(dialogue.history_count == 1);
    try std.testing.expectEqualStrings("hello", dialogue.history[0].player_line[0..dialogue.history[0].player_len]);
}

test "journal stores only explicit learned facts with a source" {
    var dialogue = Dialogue{};
    dialogue.recordLearned(3, "Mara", "The well is beside the granary.", 4);
    dialogue.recordLearned(3, "Mara", "The well is beside the granary.", 4);
    try std.testing.expectEqual(@as(usize, 1), dialogue.journal_count);
    try std.testing.expectEqualStrings("Mara", dialogue.journal[0].source_name[0..dialogue.journal[0].source_name_len]);
    try std.testing.expectEqualStrings("The well is beside the granary.", dialogue.journal[0].text[0..dialogue.journal[0].text_len]);
}

test "life conversation executes real trades and learns only disclosed arrangements" {
    const terrain_mod = @import("terrain.zig");
    var terrain = try terrain_mod.Terrain.init(std.testing.allocator, terrain_mod.default_seed);
    defer terrain.deinit();
    const village = try village_mod.Village.init(&terrain);
    var sim = sim_mod.Sim.init(&village, terrain.seed);
    var social = people.Social.init(&sim, terrain.seed);
    var ecology = ecology_mod.Ecology.init(&village, &sim, terrain.seed);
    var life = life_mod.Life.init(&sim);
    var dialogue = Dialogue{};
    var farmer: ?u8 = null;
    var keeper: ?u8 = null;
    for (sim.residents[0..sim.resident_count]) |resident| {
        if (resident.job == .farmer and farmer == null) farmer = resident.id;
        if (resident.job == .keeper) keeper = resident.id;
    }
    try std.testing.expect(farmer != null and keeper != null);
    dialogue.open(farmer.?, &social, &sim);
    dialogue.submitTextWithLife("work", &social, &sim, &ecology, &life, &village);
    try std.testing.expectEqual(@as(?u8, null), life.employer_id);
    dialogue.submitTextWithLife("hire me", &social, &sim, &ecology, &life, &village);
    try std.testing.expectEqual(farmer, life.employer_id);
    try std.testing.expectEqual(@as(usize, 1), dialogue.known_count);
    try std.testing.expect(std.mem.indexOf(u8, dialogue.reply[0..dialogue.reply_len], "hold G") != null);
    const stock_before = sim.economy.food_stock_milli;
    dialogue.submitTextWithLife("buy food", &social, &sim, &ecology, &life, &village);
    try std.testing.expectEqual(stock_before, sim.economy.food_stock_milli);
    try std.testing.expect(std.mem.indexOf(u8, dialogue.reply[0..dialogue.reply_len], "keeper") != null);

    dialogue.open(keeper.?, &social, &sim);
    sim.economy.food_stock_milli = 1_999;
    const coins_before = life.coins;
    const food_before = life.food_milli;
    dialogue.submitTextWithLife("buy food", &social, &sim, &ecology, &life, &village);
    try std.testing.expectEqual(coins_before, life.coins);
    try std.testing.expectEqual(food_before, life.food_milli);
    sim.economy.food_stock_milli = 4_000;
    dialogue.submitTextWithLife("buy food", &social, &sim, &ecology, &life, &village);
    try std.testing.expectEqual(coins_before - 3, life.coins);
    try std.testing.expectEqual(food_before + 2_000, life.food_milli);
    try std.testing.expectEqual(@as(u64, 2_000), sim.economy.food_stock_milli);

    dialogue.open(farmer.?, &social, &sim);
    dialogue.submitTextWithLife("rent a room", &social, &sim, &ecology, &life, &village);
    try std.testing.expectEqual(@as(?u8, null), life.home_household);
    social.recordPlayerAction(farmer.?, .helpful_work, sim.elapsed_seconds);
    dialogue.submitTextWithLife("rent a room", &social, &sim, &ecology, &life, &village);
    try std.testing.expectEqual(@as(?u8, sim.residents[farmer.?].household), life.home_household);
    try std.testing.expect(std.mem.indexOf(u8, dialogue.reply[0..dialogue.reply_len], "first week") != null);
    try std.testing.expectEqual(@as(usize, 1), dialogue.known_count);
    const newest = dialogue.journal[(dialogue.journal_start + dialogue.journal_count - 1) % max_journal_entries];
    try std.testing.expectEqual(JournalProvenance.direct_disclosure, newest.provenance);
    try std.testing.expectEqualStrings(sim.residents[farmer.?].nameSlice(), newest.source_name[0..newest.source_name_len]);
}

fn testFixture() struct { sim: sim_mod.Sim, social: people.Social } {
    var sim = sim_mod.Sim{ .resident_count = 2 };
    var social = people.Social{ .count = 2 };
    var speaker = people.Person{ .id = 0, .job = .farmer, .traits = .{ .caution = 0 }, .goal = .{ .kind = .tend_fields, .progress_hours = 2, .target_hours = 10 } };
    speaker.name_len = @intCast(copyBounded(&speaker.name, "Mara"));
    speaker.family[0] = .{ .other_id = 1, .kind = .child };
    speaker.family_count = 1;
    var relative = people.Person{ .id = 1, .job = .child, .traits = .{ .caution = 0 } };
    relative.name_len = @intCast(copyBounded(&relative.name, "Finn"));
    social.persons[0] = speaker;
    social.persons[1] = relative;
    sim.elapsed_seconds = 0;
    return .{ .sim = sim, .social = social };
}

test "private family and goals stay hidden until trust permits disclosure" {
    var fixture = testFixture();
    var dialogue = Dialogue{};
    dialogue.open(0, &fixture.social, &fixture.sim);
    try std.testing.expectEqualStrings("Villager", dialogue.speakerName());
    dialogue.submitText("family", &fixture.social, &fixture.sim);
    try std.testing.expect(std.mem.indexOf(u8, dialogue.reply[0..dialogue.reply_len], "keep family") != null);
    dialogue.submitText("plans", &fixture.social, &fixture.sim);
    try std.testing.expect(std.mem.indexOf(u8, dialogue.reply[0..dialogue.reply_len], "personal plans") != null);
    try std.testing.expectEqual(@as(usize, 0), dialogue.journal_count);

    fixture.social.persons[0].player.trust = 40;
    fixture.social.persons[0].player.meaningful_actions = 2;
    dialogue.submitText("family", &fixture.social, &fixture.sim);
    try std.testing.expect(std.mem.indexOf(u8, dialogue.reply[0..dialogue.reply_len], "Finn (child)") != null);
    dialogue.submitText("plans", &fixture.social, &fixture.sim);
    try std.testing.expect(std.mem.indexOf(u8, dialogue.reply[0..dialogue.reply_len], "tend the fields") != null);
    try std.testing.expectEqual(@as(usize, 2), dialogue.journal_count);
}

test "learned name persists and insults change the next greeting" {
    var fixture = testFixture();
    var dialogue = Dialogue{};
    dialogue.open(0, &fixture.social, &fixture.sim);
    dialogue.submitText("name", &fixture.social, &fixture.sim);
    try std.testing.expectEqualStrings("Mara", dialogue.speakerName());
    dialogue.close();
    dialogue.open(0, &fixture.social, &fixture.sim);
    try std.testing.expectEqualStrings("Mara", dialogue.speakerName());
    dialogue.submitText("you are rude", &fixture.social, &fixture.sim);
    try std.testing.expectEqual(@as(i8, -8), fixture.social.trust(0));
    dialogue.close();
    dialogue.open(0, &fixture.social, &fixture.sim);
    dialogue.submitText("hello", &fixture.social, &fixture.sim);
    try std.testing.expect(std.mem.indexOf(u8, dialogue.reply[0..dialogue.reply_len], "need time to trust") != null);
    dialogue.submitText("goodbye", &fixture.social, &fixture.sim);
    try std.testing.expect(!dialogue.active);
}

test "public rumors keep their immediate teller in the reply and journal" {
    var fixture = testFixture();
    fixture.social.persons[0].knowledge[0] = .{
        .topic = .food_reserves,
        .belief = .thin_stock,
        .provenance = .told,
        .confidence = 70,
        .source_id = 1,
        .witness_id = 0,
        .event_id = 9,
        .observed_at = 0,
        .evidence_days = 4,
        .privacy = .public,
    };
    fixture.social.persons[0].knowledge_count = 1;
    var dialogue = Dialogue{};
    dialogue.open(0, &fixture.social, &fixture.sim);
    dialogue.submitText("ask about supplies", &fixture.social, &fixture.sim);
    const answer = dialogue.reply[0..dialogue.reply_len];
    try std.testing.expect(std.mem.indexOf(u8, answer, "from Finn") != null);
    try std.testing.expect(std.mem.indexOf(u8, answer, "seed") != null);
    try std.testing.expectEqual(@as(usize, 1), dialogue.journal_count);
    try std.testing.expectEqual(JournalProvenance.told, dialogue.journal[0].provenance);
    try std.testing.expectEqual(@as(u8, 1), dialogue.journal[0].underlying_source_id);
    try std.testing.expectEqualStrings("Finn", dialogue.journal[0].underlying_source_name[0..dialogue.journal[0].underlying_source_name_len]);
}

test "journal paging is clamped and a full input keeps its caret visible" {
    var dialogue = Dialogue{ .active = true };
    for (0..10) |i| {
        var fact: [24]u8 = undefined;
        const text = std.fmt.bufPrint(&fact, "Learned fact {d}.", .{i}) catch unreachable;
        dialogue.recordLearned(i, "Villager", text, 0);
    }
    dialogue.pageJournal(1);
    try std.testing.expectEqual(@as(usize, 3), dialogue.journal_offset);
    dialogue.pageJournal(100);
    try std.testing.expectEqual(@as(usize, 9), dialogue.journal_offset);
    dialogue.pageJournal(-100);
    try std.testing.expectEqual(@as(usize, 0), dialogue.journal_offset);

    for (0..input_capacity) |_| dialogue.addChar('x');
    var cells = [_]scene.Cell{.{ .glyph = 0, .foreground = 0, .background = 0 }} ** (scene.cols * scene.rows);
    dialogue.paint(&cells);
    const bounds = panelBounds();
    const prompt_y = bounds.y + bounds.height - 2;
    try std.testing.expectEqual(@as(u32, '_'), cells[prompt_y * scene.cols + bounds.x + bounds.width - 3].glyph);
}

fn testLivestockKnowledge(provenance: people.Provenance) people.Knowledge {
    return .{
        .topic = .livestock,
        .belief = .livestock_taken,
        .provenance = provenance,
        .confidence = 70,
        .source_id = 1,
        .witness_id = 1,
        .subject_id = 0,
        .event_id = 12,
        .observed_at = 0,
        .evidence_count = 5,
        .evidence_losses = 1,
        .privacy = .public,
    };
}

test "livestock rumor reports the speaker's dated evidence and immediate source" {
    var fixture = testFixture();
    fixture.social.persons[0].knowledge[0] = testLivestockKnowledge(.told);
    fixture.social.persons[0].knowledge_count = 1;
    fixture.sim.elapsed_seconds = sim_mod.seconds_per_day * 2;
    var dialogue = Dialogue{};
    dialogue.open(0, &fixture.social, &fixture.sim);
    dialogue.submitText("wolves", &fixture.social, &fixture.sim);
    const reply = dialogue.reply[0..dialogue.reply_len];
    try std.testing.expect(std.mem.indexOf(u8, reply, "last I heard from Finn") != null);
    try std.testing.expect(std.mem.indexOf(u8, reply, "5 remained") != null);
    try std.testing.expect(std.mem.indexOf(u8, reply, "1 lost") != null);
    try std.testing.expectEqual(@as(u32, 2), dialogue.journal[0].learned_day);
    try std.testing.expectEqual(JournalProvenance.told, dialogue.journal[0].provenance);
    try std.testing.expectEqual(@as(u8, 1), dialogue.journal[0].underlying_source_id);
}

test "unknown and withheld livestock knowledge create no learned facts" {
    var fixture = testFixture();
    var dialogue = Dialogue{};
    dialogue.open(0, &fixture.social, &fixture.sim);
    dialogue.submitText("ask about livestock", &fixture.social, &fixture.sim);
    try std.testing.expectEqual(@as(usize, 0), dialogue.journal_count);
    fixture.social.persons[0].knowledge[0] = testLivestockKnowledge(.witnessed);
    fixture.social.persons[0].knowledge[0].privacy = .private;
    fixture.social.persons[0].knowledge_count = 1;
    dialogue.submitText("wolves", &fixture.social, &fixture.sim);
    try std.testing.expectEqualStrings("I can't share that with you yet.", dialogue.reply[0..dialogue.reply_len]);
    try std.testing.expectEqual(@as(usize, 0), dialogue.journal_count);
    dialogue.submitText("news", &fixture.social, &fixture.sim);
    try std.testing.expectEqual(@as(usize, 0), dialogue.journal_count);
    dialogue.submitText("ask about the wolf pack's coordinates", &fixture.social, &fixture.sim);
    try std.testing.expectEqual(@as(usize, 0), dialogue.journal_count);
}

test "an invalid topic belief pair never repeats a previous factual answer" {
    var fixture = testFixture();
    fixture.social.persons[0].knowledge[0] = testLivestockKnowledge(.witnessed);
    fixture.social.persons[0].knowledge[0].belief = .well_stocked;
    fixture.social.persons[0].knowledge_count = 1;
    var dialogue = Dialogue{};
    dialogue.open(0, &fixture.social, &fixture.sim);
    dialogue.submitText("work", &fixture.social, &fixture.sim);
    const learned_before = dialogue.journal_count;
    dialogue.submitText("ask about livestock", &fixture.social, &fixture.sim);
    try std.testing.expectEqualStrings("I don't know enough about that to answer.", dialogue.reply[0..dialogue.reply_len]);
    try std.testing.expectEqual(learned_before, dialogue.journal_count);
}

test "help enables local labor only through informed disclosure and grants no trust" {
    var fixture = testFixture();
    var ecology = ecology_mod.Ecology{
        .owner_id = 0,
        .animals = 5,
        .initial_animals = 6,
        .losses = 1,
        .attacks = 1,
        .notice = true,
        .pen = .{ .x = 20, .z = -20 },
    };
    var dialogue = Dialogue{};
    dialogue.open(0, &fixture.social, &fixture.sim);
    dialogue.submitTextWithEcology("help", &fixture.social, &fixture.sim, &ecology);
    try std.testing.expect(!ecology.player_volunteered);
    fixture.social.persons[0].knowledge[0] = testLivestockKnowledge(.witnessed);
    fixture.social.persons[0].knowledge_count = 1;
    fixture.social.persons[0].knowledge[0].privacy = .private;
    dialogue.submitTextWithEcology("help", &fixture.social, &fixture.sim, &ecology);
    try std.testing.expect(!ecology.player_volunteered);
    fixture.social.persons[0].knowledge[0].privacy = .public;
    dialogue.submitTextWithEcology("help", &fixture.social, &fixture.sim, &ecology);
    try std.testing.expect(ecology.player_volunteered);
    try std.testing.expect(std.mem.indexOf(u8, dialogue.reply[0..dialogue.reply_len], "hold G at the pen") != null);
    try std.testing.expect(std.mem.indexOf(u8, dialogue.reply[0..dialogue.reply_len], "northeast of the well") != null);
    try std.testing.expectEqual(@as(i8, 0), fixture.social.trust(0));
    try std.testing.expectEqual(@as(u16, 0), fixture.social.persons[0].player.meaningful_actions);
    try std.testing.expectEqual(@as(u32, 0), ecology.repaired);
    try std.testing.expectEqual(@as(u8, 5), ecology.animals);
}

test "reading a published notice learns only its snapshot and never invents a conversation" {
    var fixture = testFixture();
    fixture.sim.elapsed_seconds = sim_mod.seconds_per_day * 3;
    var ecology = ecology_mod.Ecology{
        .owner_id = 0,
        .animals = 2,
        .losses = 4,
        .notice = false,
        .pen = .{ .x = -30, .z = 0 },
    };
    var posted = testLivestockKnowledge(.notice);
    posted.belief = .livestock_threatened;
    posted.observed_at = sim_mod.seconds_per_day;
    ecology.posted_knowledge = posted;
    var dialogue = Dialogue{};
    dialogue.openNotice(&ecology, &fixture.social, &fixture.sim);
    try std.testing.expectEqual(@as(usize, 0), dialogue.journal_count);
    try std.testing.expect(!dialogue.journal_open);
    const social_before = fixture.social.fingerprint();
    ecology.notice = true;
    dialogue.openNotice(&ecology, &fixture.social, &fixture.sim);
    try std.testing.expect(dialogue.journal_open);
    try std.testing.expect(!dialogue.active);
    try std.testing.expectEqual(@as(usize, 0), dialogue.history_count);
    try std.testing.expectEqual(social_before, fixture.social.fingerprint());
    try std.testing.expect(!ecology.player_volunteered);
    try std.testing.expectEqual(@as(usize, 2), dialogue.journal_count);
    const entry = dialogue.journal[0];
    try std.testing.expectEqual(JournalProvenance.read_notice, entry.provenance);
    try std.testing.expectEqualStrings("Public notice", entry.source_name[0..entry.source_name_len]);
    try std.testing.expectEqual(@as(u32, 3), entry.learned_day);
    try std.testing.expect(std.mem.indexOf(u8, entry.text[0..entry.text_len], "Posted day 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, entry.text[0..entry.text_len], "5 remain; 1 lost") != null);
    try std.testing.expect(std.mem.indexOf(u8, entry.text[0..entry.text_len], "Signed Mara") != null);
    const instructions = dialogue.journal[1];
    try std.testing.expect(std.mem.indexOf(u8, instructions.text[0..instructions.text_len], "west of the well") != null);
    try std.testing.expect(std.mem.indexOf(u8, instructions.text[0..instructions.text_len], "Ask Mara 'help'") != null);
}
