"""Native MDF A/B/A test on the equipped Meira arm. Changes one texture pointer."""
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
from test_arm279 import LOGICAL, replace
from watch_arm279 import command, reload_native

MATERIAL = "Meira_5_outer_Arm"
SOURCE = "player/mod/moon/20261029/moon_5.tex"
DEST = "player/mod/moon/20261029/moon_6.tex"
SLOT = "BaseDielectricMap"


def variant(raw, new_path=None):
    def name(offset):
        end = offset
        while end + 2 <= len(raw) and raw[end:end+2] != b"\0\0":
            end += 2
        if end + 2 > len(raw):
            raise ValueError("Unterminated MDF name")
        return raw[offset:end].decode("utf-16-le")

    target = donor = None
    for i in range(struct.unpack_from("<H", raw, 6)[0]):
        h = 16 + i * 80
        material = name(struct.unpack_from("<Q", raw, h)[0])
        table = struct.unpack_from("<Q", raw, h + 48)[0]
        for j in range(struct.unpack_from("<I", raw, h + 20)[0]):
            t = table + j * 32
            prop, _, tex = struct.unpack_from("<QQQ", raw, t)
            if name(prop) != SLOT:
                continue
            if material == MATERIAL and name(tex) == SOURCE:
                target = t + 16
            if name(tex) == DEST:
                donor = tex
    if target is None or (new_path is None and donor is None):
        raise ValueError("Missing target or donor base texture")
    edited = bytearray(raw)
    if new_path is not None:
        edited.extend(bytes(-len(edited) % 8))
        donor = len(edited)
        edited.extend((new_path + "\0").encode("utf-16-le"))
    struct.pack_into("<Q", edited, target, donor)
    return bytes(edited)


def main(game):
    run = Path(__file__).resolve().parents[1] / "local-tests" / ("native-" + uuid.uuid4().hex)
    run.mkdir(parents=True)
    print(run, flush=True)
    target = game / "natives/stm" / (LOGICAL + ".23")
    channel = game / "reframework/data/MHRS-Files-HotReload"
    original = target.read_bytes()
    edited = variant(original)
    (run / target.name).write_bytes(original)
    report = {"original": hashlib.sha256(original).hexdigest(), "edited": hashlib.sha256(edited).hexdigest()}

    def save():
        replace(run / "report.json", json.dumps(report, indent=2).encode())

    base = report["baseline"] = command(channel, "textures")
    assert base["path"] == LOGICAL and base["ready"]
    expected = copy.deepcopy(base["slots"])
    matches = [s for s in expected if s["name"] == MATERIAL and s["textures"].get(SLOT) == SOURCE]
    assert len(matches) == 1
    matches[0]["textures"][SLOT] = DEST
    save()

    def run_reload(label, slots):
        phase = report[label] = {}
        proc = subprocess.Popen([sys.executable, str(Path(__file__).with_name("observe_file_open.py")), str(target)],
                                stdout=subprocess.PIPE, text=True)
        try:
            phase["armed"] = json.loads(proc.stdout.readline())
            phase["start_ns"] = time.time_ns()
            result, job = reload_native(channel)
            phase["result"], phase["job"] = result, job
            save()
            phase["file_open"] = json.loads(proc.communicate(timeout=3)[0])
            assert phase["file_open"]["time_ns"] >= phase["start_ns"]
            for delay in (0.5, 3):
                time.sleep(delay)
                live = command(channel, "textures")
                phase[f"sample_{delay}"] = live
                save()
                assert live["mesh"] == base["mesh"] and live["ready"] and live["path"] == LOGICAL
                assert live["resource"] == result["resource"] != job["prior"]["resource"]
                assert live["slots"] == slots, "Unexpected live texture paths or enable switches"
            print(label, live["resource"], next(s["textures"][SLOT] for s in live["slots"] if s["name"] == MATERIAL), flush=True)
        finally:
            if proc.poll() is None:
                proc.kill()
                proc.wait()

    if target.read_bytes() != original:
        raise RuntimeError("Concurrent edit")
    replace(target, edited)
    try:
        run_reload("B", expected)
    finally:
        if target.read_bytes() != edited:
            raise RuntimeError("Concurrent edit. Original backup is in " + str(run))
        replace(target, original)
        report["restored"] = hashlib.sha256(target.read_bytes()).hexdigest()
        save()
        if "result" in report.get("B", {}):
            run_reload("A", base["slots"])


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("game", type=Path)
    main(parser.parse_args().game)
