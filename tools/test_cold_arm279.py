"""Exercise the running native watcher with a new, solid-magenta BC7 texture."""
import argparse
import copy
import hashlib
import json
import struct
import subprocess
import sys
import time
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_native_arm279 import LOGICAL, MATERIAL, SLOT, SOURCE, command, replace, variant


def magenta_tex(template):
    data = bytearray(template)
    if data[:8] != b"TEX\0\x1c\0\0\0" or data[14] != 1 or data[15] % 16 or struct.unpack_from("<I", data, 16)[0] != 99:
        raise ValueError("Expected single-image BC7 sRGB TEX.28")
    # BC7 mode 6: equal endpoints, opaque magenta, both endpoint p-bits set.
    bits = 1 << 6
    for index, component in enumerate((127, 127, 0, 0, 127, 127, 127, 127)):
        bits |= component << (7 + 7 * index)
    block = (bits | (3 << 63)).to_bytes(16, "little")
    for offset in range(40, 40 + data[15], 16):
        start, pitch, size = struct.unpack_from("<QII", data, offset)
        if start < 40 + data[15] or not pitch or not size or size % 16 or start + size > len(data):
            raise ValueError("Invalid TEX mip span")
        data[start:start + size] = block * (size // 16)
    return bytes(data)


def main(game, log, hold, token):
    root = Path(__file__).resolve().parents[1]
    run = root / "local-tests" / ("cold-" + token)
    run.mkdir(parents=True)
    steam = game / "natives/stm"
    target = steam / (LOGICAL + ".23")
    new_path = SOURCE.rsplit("/", 1)[0] + "/cold_" + token + ".tex"
    test_tex = steam / (new_path + ".28")
    channel = game / "reframework/data/MHRS-Files-HotReload"
    original = target.read_bytes()
    edited = variant(original, new_path)
    (run / target.name).write_bytes(original)
    base = command(channel, "textures")
    expected = copy.deepcopy(base["slots"])
    matches = [s for s in expected if s["name"] == MATERIAL and s["enabled"] and s["textures"].get(SLOT) == SOURCE]
    if base["path"] != LOGICAL or not base["ready"] or len(matches) != 1:
        raise RuntimeError("Target arm or baseline texture unavailable")
    matches[0]["textures"][SLOT] = new_path
    tex = magenta_tex((steam / (SOURCE + ".28")).read_bytes())
    def digest(data):
        return hashlib.sha256(data).hexdigest()

    report = dict(baseline=base, new_path=new_path, original=digest(original), edited=digest(edited), texture=digest(tex))

    def save():
        replace(run / "report.json", json.dumps(report, indent=2).encode())

    def apply(label, previous, data, slots):
        if target.read_bytes() != previous:
            raise RuntimeError("Concurrent MDF edit; backup in " + str(run))
        pos = log.stat().st_size
        started = time.monotonic()
        phase = report[label] = {"save_ns": time.time_ns()}
        replace(target, data)
        save()
        while time.monotonic() - started < 25:
            with log.open("rb") as stream:
                stream.seek(pos)
                lines = [line for line in stream.read().splitlines()
                         if line.startswith(b"Bound MDF ") or b"f_arm279.mdf2" in line
                         or line.startswith(b"MDF dependencies")]
            if lines:
                phase["watcher"] = lines[0].decode(errors="replace")
                phase["ack_ns"] = time.time_ns()
                phase["seconds"] = round(time.monotonic() - started, 3)
                save()
                if not lines[0].startswith(b"Bound MDF "):
                    raise RuntimeError(phase["watcher"])
                break
            time.sleep(.05)
        else:
            raise TimeoutError("No watcher acknowledgement")
        for delay in (0, 2):
            time.sleep(delay)
            live = command(channel, "textures")
            phase[f"sample_{delay}"] = live
            save()
            prior_resource = base["resource"] if label == "B" else report["B"].get("sample_0", base)["resource"]
            if not (live["ready"] and live["path"] == LOGICAL and live["mesh"] == base["mesh"]
                    and live["resource"] != prior_resource
                    and live["slots"] == slots and phase["watcher"] == "Bound MDF " + live["resource"]):
                raise RuntimeError("Live material bindings differ from expectation")
        print(label, phase["watcher"], phase["seconds"], flush=True)

    print(run, new_path, flush=True)
    save()
    with test_tex.open("xb") as stream:
        stream.write(tex)
    try:
        with subprocess.Popen([sys.executable, str(root / "tools/observe_file_open.py"), str(test_tex)],
                              stdout=subprocess.PIPE, text=True) as observer:
            try:
                report["armed"] = json.loads(observer.stdout.readline())
                apply("B", original, edited, expected)
                report["first_open"] = json.loads(observer.communicate(timeout=3)[0])
                if not report["B"]["save_ns"] <= report["first_open"]["time_ns"] <= report["B"]["ack_ns"]:
                    raise RuntimeError("Texture file open outside the reload interval")
                save()
                time.sleep(hold)
            finally:
                if observer.poll() is None:
                    observer.kill()
                current = target.read_bytes()
                if current == edited:
                    apply("A", edited, original, base["slots"])
                elif current != original:
                    raise RuntimeError("Concurrent MDF edit; backup in " + str(run))
                report["restored"] = digest(target.read_bytes())
                save()
    finally:
        if target.read_bytes() == original and test_tex.read_bytes() == tex:
            test_tex.unlink()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("game", type=Path)
    parser.add_argument("watch_log", type=Path)
    parser.add_argument("--hold", type=float, default=8)
    parser.add_argument("--token", type=uuid.UUID, default=uuid.uuid4())
    args = parser.parse_args()
    main(args.game, args.watch_log, args.hold, args.token.hex)
