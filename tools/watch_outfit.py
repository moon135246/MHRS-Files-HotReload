"""Watch loose Rise outfit resources used by the local hunter."""
import argparse
import os
import struct
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from helm_user import decode, diff
from watch_arm279 import command, reload_native, signature
from test_arm279 import LOGICAL

SUFFIXES = (".chain.48", ".jcns.21", ".motbank.3", ".mesh.2109148288", ".tex.28", ".mdf2.23", ".user.2", ".mmtr.220427553")


def reload_asset(channel, path, **checks):
    job = command(channel, "asset_begin", path=path, **checks)
    try:
        deadline = time.monotonic()+12
        while time.monotonic() < deadline:
            state = command(channel, "asset_poll")["state"]
            if state == "ready":
                return command(channel, "asset_bind")
            if state != "pending":
                raise RuntimeError(state)
        raise TimeoutError("Asset did not finish loading: " + job["address"])
    except BaseException:
        command(channel, "asset_abort")
        raise


def files(root):
    for directory, _, names in os.walk(root):
        for name in names:
            if name.lower().endswith(SUFFIXES):
                yield Path(directory) / name


def templates(file):
    raw = file.read_bytes()
    if raw[:4] != b"MDF\0":
        raise ValueError("Invalid MDF header")
    paths = set()
    for i in range(struct.unpack_from("<H", raw, 6)[0]):
        start = struct.unpack_from("<Q", raw, 16+80*i+72)[0]
        end = start
        while end+2 <= len(raw) and raw[end:end+2] != b"\0\0":
            end += 2
        if end+2 > len(raw):
            raise ValueError("Invalid MDF template path")
        paths.add(raw[start:end].decode("utf-16-le").lower())
    return paths


def joint_checks(file):
    raw = file.read_bytes()
    if len(raw) < 48 or raw[:8] != b"\x15\0\0\0jcns":
        raise ValueError("Invalid JCNS v21 header")
    if struct.unpack_from("<I", raw, 40)[0] != 1:
        return {}
    table = struct.unpack_from("<Q", raw, 32)[0]
    if table > len(raw)-8:
        raise ValueError("Invalid JCNS group table")
    group = struct.unpack_from("<Q", raw, table)[0]
    if group > len(raw)-78:
        raise ValueError("Invalid JCNS group offset")
    return {"expected_outputs": struct.unpack_from("<H", raw, group+76)[0]}


def reload_template(channel, root, path, present):
    owners = []
    for file in sorted(present):
        if file.name.lower().endswith(".mdf2.23") and path.lower() in templates(file):
            mdf = file.relative_to(root).as_posix().rsplit(".", 1)[0]
            if command(channel, "asset_inspect", path=mdf).get("bindings"):
                owners.append(mdf)
    if not owners:
        raise ValueError("No equipped loose MDF references this template")
    result = command(channel, "asset_master_begin", path=path)
    bound = []
    try:
        deadline = time.monotonic()+12
        while command(channel, "asset_master_poll")["state"] != "ready":
            if time.monotonic() > deadline:
                raise TimeoutError("Template initialization timed out")
        for mdf in owners:
            reload_asset(channel, mdf)
            bound.append(mdf)
        command(channel, "asset_master_commit")
    except BaseException:
        command(channel, "asset_master_abort")
        for mdf in bound:
            reload_asset(channel, mdf)
        raise
    print("Bound template", path, result["resource"], "via", ", ".join(bound), flush=True)


def watch(game):
    root = game / "natives/stm"
    channel = game / "reframework/data/MHRS-Files-HotReload"
    if not root.is_dir() or not channel.is_dir():
        raise ValueError("Missing loose resources or plugin data directory")
    observed, applied, users = {}, {}, {}
    for file in files(root):
        applied[file] = observed[file] = signature(file)
        if file.name.lower().endswith(".user.2"):
            try:
                users[file] = decode(file.read_bytes())
            except (ValueError, struct.error):
                pass
    print("Watching", len(applied), "outfit files in", root, flush=True)
    while True:
        time.sleep(.25)
        present = set(files(root))
        for removed in observed.keys()-present:
            observed.pop(removed)
            applied.pop(removed, None)
            users.pop(removed, None)
        for file in sorted(present):
            try:
                current = signature(file)
                if observed.get(file) != current:
                    observed[file] = current
                    continue
                if applied.get(file) == current:
                    continue
                path = file.relative_to(root).as_posix().rsplit(".", 1)[0]
                if path.endswith(".user"):
                    updated = decode(file.read_bytes())
                    if file not in users:
                        users[file] = updated
                        print("Recorded new helm USER baseline", path, flush=True)
                    else:
                        edits = diff(users[file], updated)
                        if edits:
                            result = command(channel, "asset_user", path=path, edits=edits)
                            print("Updated USER", path, len(edits), "fields in", result["roots"], "roots", flush=True)
                        users[file] = updated
                elif path.lower().endswith(".mmtr"):
                    reload_template(channel, root, path, present)
                elif path == LOGICAL:
                    result, _ = reload_native(channel)
                    print("Bound MDF", result["resource"], flush=True)
                else:
                    checks = joint_checks(file) if path.endswith(".jcns") else {}
                    result = reload_asset(channel, path, **checks)
                    print("Bound", path, result["resource"], result["bindings"], flush=True)
                applied[file] = current
            except (FileNotFoundError, PermissionError):
                continue
            except (ValueError, struct.error, RuntimeError, TimeoutError) as error:
                print("Skipped", file.name, str(error), flush=True)
                applied[file] = current


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("game", type=Path)
    try:
        watch(parser.parse_args().game)
    except KeyboardInterrupt:
        pass
