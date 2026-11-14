"""Watch loose resources used by equipped parts and active Rise scene components."""
import argparse
import os
import struct
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from helm_user import decode, diff
from gui_view import view_fields, view_diff
from scene_data import PLAYER_MARKER, camera_fields, marker_diff, marker_time
from watch_arm279 import command, reload_native, signature
from test_arm279 import LOGICAL

SUFFIXES = (".chain.48", ".jcns.21", ".motbank.3", ".motlist.528", ".efx.2818730", ".rcol.20",
            ".mesh.2109148288", ".tex.28", ".mdf2.23", ".user.2", ".mmtr.220427553", ".gui.430033", ".pfb.17")


def reload_asset(channel, path, **checks):
    job = command(channel, "asset_begin", path=path, **checks)
    try:
        deadline = time.monotonic()+12
        while time.monotonic() < deadline:
            state = command(channel, "asset_poll")["state"]
            if state == "ready":
                result = command(channel, "asset_bind")
                if result["state"] != "pending":
                    return result
            elif state != "pending":
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


def update_camera(channel, path, before, after, edits):
    command(channel, "asset_camera_prepare", path=path)
    try:
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            sample = command(channel, "asset_camera_inspect", path=path, edits=after)["values"]
            if all(sample[k] in (before[k], after[k]) for k in after):
                return command(channel, "asset_camera", path=path, edits=edits)
        raise TimeoutError("Camera USER did not reach the expected field values")
    finally:
        command(channel, "asset_camera_release", path=path)


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
    gui_files = {}
    markers, cameras = {}, {}
    for file in files(root):
        applied[file] = observed[file] = signature(file)
        if file.name.lower().endswith(".gui.430033"):
            gui_files[file] = file.read_bytes()
        if file.relative_to(root).as_posix().lower() == PLAYER_MARKER + ".17":
            markers[file] = file.read_bytes()
        if file.name.lower().endswith(".user.2"):
            try:
                raw = file.read_bytes()
                camera = camera_fields(raw)
                if camera is not None:
                    cameras[file] = camera
                else:
                    users[file] = decode(raw)
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
            gui_files.pop(removed, None)
            markers.pop(removed, None)
            cameras.pop(removed, None)
        for file in sorted(present):
            try:
                current = signature(file)
                if observed.get(file) != current:
                    observed[file] = current
                    continue
                if applied.get(file) == current:
                    continue
                path = file.relative_to(root).as_posix().rsplit(".", 1)[0]
                if path.lower().endswith(".pfb"):
                    if path.lower() != PLAYER_MARKER:
                        raise ValueError("Unsupported prefab path")
                    content = file.read_bytes()
                    if file not in markers:
                        marker_time(content)
                        print("Recorded PFB baseline", path, flush=True)
                    else:
                        edits = marker_diff(markers[file], content)
                        if edits:
                            result = command(channel, "asset_marker", path=path, edits=edits)
                            print("Updated PFB", path, result["count"], "instances", flush=True)
                    markers[file] = content
                elif path.lower().endswith(".gui"):
                    content = file.read_bytes()
                    if file not in gui_files:
                        view_fields(content)
                        print("Recorded GUI baseline", path, flush=True)
                    else:
                        edits = view_diff(gui_files[file], content)
                        if edits:
                            result = command(channel, "asset_gui", path=path, edits=edits)
                            print("Updated GUI", path, result["views"], "views", flush=True)
                    gui_files[file] = content
                elif path.lower().endswith(".user"):
                    raw = file.read_bytes()
                    camera = camera_fields(raw)
                    if camera is not None:
                        if file not in cameras:
                            print("Recorded camera USER baseline", path, flush=True)
                        else:
                            edits = {k:v for k,v in camera.items() if cameras[file][k] != v}
                            if edits:
                                result = update_camera(channel, path, cameras[file], camera, edits)
                                print("Updated camera USER", path, len(result["values"]), "fields", flush=True)
                        cameras[file] = camera
                        applied[file] = current
                        continue
                    updated = decode(raw)
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
