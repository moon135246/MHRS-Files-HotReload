"""Run the live MDF2.23 experiment using a loaded REFramework probe."""
import argparse
import hashlib
import json
import os
import struct
import time
import uuid
from pathlib import Path


RIM = (1.0, 0.0, 1.0, 1.0)
COL = (0.0, 1.0, 0.0, 1.0)
LOGICAL = "player/mod/f/pl279/f_arm279.mdf2"


def test_variant(original):
    data = bytearray(original)
    if data[:4] != b"MDF\0":
        raise ValueError("Expected an MDF file")

    def name_at(offset):
        end = offset
        while data[end:end + 2] != b"\0\0":
            end += 2
            if end >= len(data):
                raise ValueError("Invalid MDF string offset")
        return data[offset:end].decode("utf-16-le")

    changes = []
    for i in range(struct.unpack_from("<H", data, 6)[0]):
        header = 16 + 80 * i  # Rise MDF2.23
        name = name_at(struct.unpack_from("<Q", data, header)[0])
        count = struct.unpack_from("<I", data, header + 16)[0]
        table = struct.unpack_from("<Q", data, header + 40)[0]
        block = struct.unpack_from("<Q", data, header + 64)[0]
        found = set()
        for j in range(count):
            prop = table + j * 24
            key = name_at(struct.unpack_from("<Q", data, prop)[0])
            if key not in ("S_col_R", "moon_RimColor"):
                continue
            relative, size = struct.unpack_from("<II", data, prop + 16)
            if size != 4 or key in found:
                raise ValueError(f"Unexpected {name}/{key} layout")
            offset = block + relative
            changes.append((name, key, struct.unpack_from("<4f", data, offset)))
            struct.pack_into("<4f", data, offset, *(RIM if key == "moon_RimColor" else COL))
            found.add(key)
        if len(found) != 2:
            raise ValueError(f"Missing marker properties in {name}")
    if not changes or data == original:
        raise ValueError("No testable differences")
    return bytes(data), changes


def replace(path, data):
    tmp = path.with_name(path.name + "." + uuid.uuid4().hex + ".tmp")
    try:
        with tmp.open("xb") as f:
            f.write(data)
        os.replace(tmp, path)
    finally:
        tmp.unlink(missing_ok=True)


def main(game):
    run = Path(__file__).resolve().parents[1] / "local-tests" / uuid.uuid4().hex
    run.mkdir(parents=True)
    channel = game / "reframework/data/MHRS-Files-HotReload"
    target = game / "natives/stm" / (LOGICAL + ".23")
    original = target.read_bytes()
    edited, changes = test_variant(original)
    (run / target.name).write_bytes(original)
    report = {"original_sha256": hashlib.sha256(original).hexdigest(),
              "test_sha256": hashlib.sha256(edited).hexdigest(), "changes": changes, "samples": {}}

    def save():
        replace(run / "report.json", json.dumps(report, indent=2).encode())

    def command(label, action):
        key = uuid.uuid4().hex
        replace(channel / "request.json", json.dumps({"id": key, "action": action}).encode())
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            time.sleep(0.1)
            try:
                reply = json.loads((channel / "status.json").read_bytes())
            except (FileNotFoundError, json.JSONDecodeError, PermissionError):
                continue
            if reply.get("id") == key:
                report["samples"][label] = reply
                save()
                if not reply["ok"]:
                    raise RuntimeError(reply["result"])
                return reply["result"]
        raise TimeoutError(label + ": no game response")

    def sample(label):
        time.sleep(1.5)
        obj = command(label, "inspect")
        if not obj["ready"] or obj["mesh"] != baseline["mesh"]:
            raise RuntimeError("Arm changed or material not ready")
        if obj["path"] != baseline["path"] or [s["name"] for s in obj["slots"]] != slot_names:
            raise RuntimeError("Material path or slots changed")
        values = [s["moon_RimColor"] for s in obj["slots"]]
        hits = sum(tuple(v) == RIM for v in values)
        report.setdefault("observations", {})[label] = {
            "marker_slots": hits, "total_slots": len(values), "matches_baseline": values == old_values}
        save()
        print(label, obj["path"], f"{hits}/{len(values)} marker slots", flush=True)
        if label == "restored" and values != old_values:
            raise RuntimeError("Restored material values differ from baseline")
        return obj

    print(run, flush=True)
    baseline = command("baseline", "inspect")
    if baseline["path"].lower() != LOGICAL or not baseline["ready"]:
        raise RuntimeError("Unexpected starting material")
    if not baseline["slots"] or any("moon_RimColor" not in s for s in baseline["slots"]):
        raise RuntimeError("Runtime marker unavailable")
    if any(tuple(s["moon_RimColor"]) == RIM for s in baseline["slots"]):
        raise RuntimeError("Test marker already present on equipped arm")
    slot_names = [s["name"] for s in baseline["slots"]]
    old_values = [s["moon_RimColor"] for s in baseline["slots"]]
    changed = rebound = False
    try:
        if target.read_bytes() != original:
            raise RuntimeError("Original file changed during setup")
        replace(target, edited)
        changed = True
        sample("overwrite_only")
        rebound = True
        command("bind_same", "same")
        sample("after_same")
    finally:
        if changed:
            if target.read_bytes() != edited:
                raise RuntimeError("Concurrent edit; original backup in " + str(run))
            replace(target, original)
            report["restored_sha256"] = hashlib.sha256(target.read_bytes()).hexdigest()
            save()
        if rebound:
            command("restore", "restore")
            sample("restored")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("game", type=Path, help="MonsterHunterRise installation directory")
    main(parser.parse_args().game)
