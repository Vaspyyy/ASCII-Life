#!/usr/bin/env python3
"""Native GPU capture regressions. Requires the documented Wayland/Vulkan host."""
import os
import pathlib
import subprocess

root = pathlib.Path(__file__).resolve().parent.parent
subprocess.run(["zig", "build", "-Doptimize=ReleaseSmall"], cwd=root, check=True)
output = root / "artifacts/m1-checks"
output.mkdir(parents=True, exist_ok=True)
env = os.environ.copy()
layers = env.get("VK_INSTANCE_LAYERS", "").split(":")
if "VK_LAYER_KHRONOS_validation" not in layers:
    layers.append("VK_LAYER_KHRONOS_validation")
env["VK_INSTANCE_LAYERS"] = ":".join(filter(None, layers))
binary = root / "zig-out/bin/ascii-life"

def capture(name, *args):
    path = output / f"{name}.ppm"
    result = subprocess.run([str(binary), "--size", "960x540", "--hide-hud",
                             "--capture", str(path), *args], env=env, cwd="/tmp",
                            capture_output=True, text=True, timeout=90)
    (output / f"{name}.log").write_text(result.stdout + result.stderr)
    if result.returncode != 0 or "VUID-" in result.stderr or "Validation Error" in result.stderr:
        raise RuntimeError(f"{name}: {result.stderr}")
    data = path.read_bytes()
    header = b"P6\n960 540\n255\n"
    assert data.startswith(header) and len(data) == len(header) + 960*540*3
    assert len(set(data[len(header):])) > 32, "image lacks color variation"
    return data

base = capture("same-a")
assert base == capture("same-b"), "identical input changed the rendered frame"
assert base != capture("other-seed", "--seed", "72019"), "seed does not change terrain"
assert base != capture("night", "--time", "0.02"), "time does not change lighting"
assert base != capture("third-person", "--third-person"), "camera view did not change"
assert base != capture("moved", "--view", "200,-200,0.4,-0.1,20"), "viewpoint did not change"
def tour(name):
    result = subprocess.run([str(binary), "--size", "960x540", "--tour", "--frames", "120", "--metrics"],
                            env=env, cwd="/tmp", capture_output=True, text=True, timeout=90)
    (output / f"{name}.log").write_text(result.stdout + result.stderr)
    assert result.returncode == 0 and "VUID-" not in result.stderr and "Validation Error" not in result.stderr
    assert "frames=120 " in result.stderr
    pose = next(line for line in result.stderr.splitlines() if line.startswith("view="))
    assert "third_person=true" in pose, "tour did not switch views"
    return pose

assert tour("tour-a") == tour("tour-b"), "fixed-step tour ended in different states"
for args in (("--time", "nan"), ("--size", "0x0"), ("--view", "1,2,3"), ("--tour", "--capture", "/tmp/unused-m1.ppm")):
    result = subprocess.run([str(binary), *args], capture_output=True, text=True, timeout=10)
    assert result.returncode != 0, f"invalid arguments accepted: {args}"
print("PASS: repeated GPU pixels, seed/view/time variants, capture from /tmp, validation, fixed-step tours, invalid arguments")
