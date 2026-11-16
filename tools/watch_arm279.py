"""Watch the Rise arm MDF and request a refresh after a stable save."""
import argparse
import errno
import json
import msvcrt
import os
import sys
import time
import uuid
from pathlib import Path

# Embedded Python on the modding workstation omits the script's directory.
if __name__ == "__main__":
    sys.path.insert(0, str(Path(__file__).resolve().parent))
from file_changes import DirectoryChanges
from material_layout import MaterialValidator, materials
from watcher_runtime import checkpoint
LOGICAL = "player/mod/f/pl279/f_arm279.mdf2"


def replace(path, data):
    tmp = path.with_name(path.name + "." + uuid.uuid4().hex + ".tmp")
    try:
        with tmp.open("xb") as f:
            f.write(data)
        # The game's frame callback can have the destination open briefly.
        for attempt in range(12):
            try:
                os.replace(tmp, path)
                break
            except PermissionError as error:
                if error.winerror not in (5, 32, 33) or attempt == 11:
                    raise
                time.sleep(.025)
    finally:
        tmp.unlink(missing_ok=True)


def command(channel, action, **payload):
    # The Lua bridge has a single request slot. Serialize the request and its
    # acknowledgement when a test observer and the watcher run concurrently.
    with (channel / "channel.lock").open("a+b") as lock:
        lock.seek(0)
        # The CRT's blocking lock retries only once a second. Keep its timeout
        # while letting simultaneous watcher and observer requests hand off promptly.
        deadline = time.monotonic() + 10
        while True:
            checkpoint()
            try:
                msvcrt.locking(lock.fileno(), msvcrt.LK_NBLCK, 1)
                break
            except OSError as error:
                if error.errno not in (errno.EACCES, errno.EAGAIN, errno.EDEADLK) or time.monotonic() >= deadline:
                    raise
                time.sleep(.015)
        try:
            return exchange(channel, action, payload)
        finally:
            lock.seek(0)
            msvcrt.locking(lock.fileno(), msvcrt.LK_UNLCK, 1)


def exchange(channel, action, payload):
    key = uuid.uuid4().hex
    status = channel / "status.json"
    try:
        changes = DirectoryChanges(channel, recursive=False)
    except OSError:
        changes = None
    try:
        # Arm before publishing. Keep the periodic reconciliation for partial
        # writes and filesystems where directory notifications are unavailable.
        replace(channel / "request.json", json.dumps({"id": key, "action": action, **payload}).encode())
        deadline = time.monotonic() + 8
        next_read = time.monotonic() + .1
        while time.monotonic() < deadline:
            checkpoint()
            timeout = max(0, min(deadline, next_read) - time.monotonic())
            if changes:
                try:
                    paths, _, overflow = changes.poll(timeout)
                except OSError:
                    changes.close()
                    changes = None
                    continue
                if not overflow and status not in paths and time.monotonic() < next_read:
                    continue
            else:
                time.sleep(timeout)
            next_read = time.monotonic() + .1
            try:
                reply = json.loads(status.read_bytes())
            except (FileNotFoundError, PermissionError, UnicodeError, json.JSONDecodeError):
                continue
            if reply.get("id") == key:
                if not reply["ok"]:
                    raise RuntimeError(reply["result"])
                return reply["result"]
        raise TimeoutError(f"No game response to {action}")
    finally:
        if changes:
            changes.close()


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


def watch(game, native=False, baseline_root=None):
    target = game / "natives/stm" / (LOGICAL + ".23")
    channel = game / "reframework/data/MHRS-Files-HotReload"
    observed = signature(target) if target.exists() else None
    previous = {}
    validator = MaterialValidator(game / "natives/stm", baseline_root)
    if native:
        if target.exists():
            try:
                previous = {m.name: m.template.lower() for m in materials(target.read_bytes())}
            except ValueError:
                pass
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
                updated = validator.validate(target, previous)
                result, _ = reload_native(channel)
                previous = updated
                print("Bound MDF", result["resource"], flush=True)
            else:
                reply = command(channel, "refresh")
                print("Updated", reply["changed"], "values", flush=True)
            applied = current
        except FileNotFoundError:
            if observed is not None and not target.exists():
                if native:
                    try:
                        command(channel, "asset_removed", paths=[LOGICAL])
                    except (RuntimeError, TimeoutError, OSError) as error:
                        print("Removal pending", error, flush=True)
                        continue
                observed = applied = None
                print("Removed", LOGICAL, flush=True)
        except PermissionError:
            continue
        except (ValueError, RuntimeError, TimeoutError) as error:
            # Wait for the next save after an invalid file. Keep the live values.
            print(error, flush=True)
            applied = observed


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("game", type=Path)
    parser.add_argument("--native", action="store_true", help="Reload the complete MDF with the Rise 16.0.2.0 module")
    parser.add_argument("--baseline-root", type=Path, help="Patch-matched extracted natives/stm for template validation")
    try:
        args = parser.parse_args()
        watch(args.game, args.native, args.baseline_root)
    except KeyboardInterrupt:
        pass
