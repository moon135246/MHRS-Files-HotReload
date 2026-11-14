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


def reload_native(channel):
    job = command(channel, "native_begin")
    try:
        deadline = time.monotonic() + 12
        while time.monotonic() < deadline:
            status = command(channel, "native_poll")
            if status["state"] == "ready":
                result = command(channel, "native_bind")
                return result, job
            if status["state"] != "pending":
                raise RuntimeError(status["state"])
        raise TimeoutError("MDF dependencies did not finish loading")
    except BaseException:
        command(channel, "native_abort")
        raise


def watch(game, native=False):
    target = game / "natives/stm" / (LOGICAL + ".23")
    channel = game / "reframework/data/MHRS-Files-HotReload"
    observed = signature(target)
    if native:
        print("Watching whole MDF", target, flush=True)
    else:
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
            if native:
                result, _ = reload_native(channel)
                print("Bound MDF", result["resource"], flush=True)
            else:
                reply = command(channel, "refresh")
                print("Updated", reply["changed"], "values", flush=True)
            applied = current
        except (FileNotFoundError, PermissionError):
            continue
        except (RuntimeError, TimeoutError) as error:
            # Wait for the next save after an invalid file. Keep the live values.
            print(error, flush=True)
            applied = observed


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("game", type=Path)
    parser.add_argument("--native", action="store_true", help="Reload the complete MDF with the Rise 16.0.2.0 module")
    try:
        args = parser.parse_args()
        watch(args.game, args.native)
    except KeyboardInterrupt:
        pass
