"""Watch the Rise arm MDF and request a refresh after a stable save."""
import argparse
import json
import sys
import time
import uuid
from pathlib import Path

# Embedded Python on the modding workstation omits the script's directory.
sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_arm279 import LOGICAL, replace


def command(channel, action):
    key = uuid.uuid4().hex
    replace(channel / "request.json", json.dumps({"id": key, "action": action}).encode())
    deadline = time.monotonic() + 8
    while time.monotonic() < deadline:
        time.sleep(0.1)
        try:
            reply = json.loads((channel / "status.json").read_bytes())
        except (FileNotFoundError, PermissionError, json.JSONDecodeError):
            continue
        if reply.get("id") == key:
            if not reply["ok"]:
                raise RuntimeError(reply["result"])
            return reply["result"]
    raise TimeoutError(f"No game response to {action}")


def signature(path):
    st = path.stat()
    return st.st_ino, st.st_size, st.st_mtime_ns


def watch(game):
    target = game / "natives/stm" / (LOGICAL + ".23")
    channel = game / "reframework/data/MHRS-Files-HotReload"
    observed = signature(target)
    print("Captured", command(channel, "capture")["bindings"], "bindings; watching", target, flush=True)
    applied = observed
    while True:
        time.sleep(0.15)
        try:
            current = signature(target)
            if current == applied:
                continue
            if current != observed:
                observed = current
                continue
            reply = command(channel, "refresh")
            print("Updated", reply["changed"], "values", flush=True)
            applied = current
        except (FileNotFoundError, PermissionError):
            continue
        except RuntimeError as error:
            # Wait for the next save after an invalid file. Keep the live values.
            print(error, flush=True)
            applied = observed


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("game", type=Path)
    try:
        watch(parser.parse_args().game)
    except KeyboardInterrupt:
        pass
