"""Watch loose resources used by equipped parts and active Rise scene components."""
import argparse
import json
import os
import struct
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from helm_user import decode, diff
from gui_view import view_fields, view_diff
from scalar_user import scalar_layout, scalar_diff
from scene_data import camera_fields, prefab_root_diff, prefab_root_fields
from resource_links import logical_path, ResourceLinks
from watch_arm279 import command, reload_native, signature
from test_arm279 import LOGICAL

SUFFIXES = (".chain.48", ".jcns.21", ".motbank.3", ".motlist.528", ".efx.2818730", ".rcol.20",
            ".mesh.2109148288", ".tex.28", ".mdf2.23", ".user.2", ".mmtr.220427553", ".gui.430033", ".pfb.17",
            ".uvs.7", ".uvs.7.stm", ".rtex.5", ".rtex.5.stm", ".uvar.3", ".mot.495", ".fbxskel.4")


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


def update_user_fields(channel, path, before, after, edits, **schema):
    command(channel, "asset_camera_prepare", path=path, **schema)
    try:
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            sample = command(channel, "asset_camera_inspect", path=path, edits=edits)["values"]
            if all(sample[k] in (before[k], after[k]) for k in edits):
                return command(channel, "asset_camera", path=path, edits=edits)
        raise TimeoutError("USER did not reach the expected field values")
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


def reload_dependency(channel, path, owners, intermediate=None):
    result = command(channel, "asset_master_begin", path=path)
    bound = []
    try:
        deadline = time.monotonic()+12
        while command(channel, "asset_master_poll")["state"] != "ready":
            if time.monotonic() > deadline:
                raise TimeoutError("Dependency initialization timed out")
        for owner in owners:
            reload_asset(channel, owner)
            bound.append(owner)
        for uv, effects in (intermediate or {}).items():
            reload_dependency(channel, uv, effects)
            bound.append(uv)
        command(channel, "asset_master_commit")
    except BaseException:
        command(channel, "asset_master_abort")
        for owner in bound:
            if intermediate and owner in intermediate:
                reload_dependency(channel, owner, intermediate[owner])
            else:
                reload_asset(channel, owner)
        raise
    print("Bound template" if path.lower().endswith(".mmtr") else "Bound dependency", path, result["resource"], "via", ", ".join(bound), flush=True)


def watch(game, baseline_root=None, schema=None):
    root = game / "natives/stm"
    channel = game / "reframework/data/MHRS-Files-HotReload"
    if not root.is_dir() or not channel.is_dir():
        raise ValueError("Missing loose resources or plugin data directory")
    observed, applied, users = {}, {}, {}
    gui_files = {}
    markers, cameras, scalars = {}, {}, {}
    links = ResourceLinks()
    def original(file):
        if baseline_root is not None:
            baseline = baseline_root / file.relative_to(root)
            if baseline.is_file():
                return baseline.read_bytes()
        return None
    for file in files(root):
        applied[file] = observed[file] = signature(file)
        if file.name.lower().endswith(".gui.430033"):
            gui_files[file] = file.read_bytes()
        if file.name.lower().endswith(".pfb.17"):
            markers[file] = file.read_bytes()
        if file.name.lower().endswith(".user.2"):
            try:
                raw = file.read_bytes()
                camera = camera_fields(raw)
                if camera is not None:
                    cameras[file] = camera
                elif schema and scalar_layout(raw, schema):
                    scalars[file] = raw
                else:
                    users[file] = decode(raw)
            except (ValueError, struct.error):
                pass
    print("Watching", len(applied), "outfit files in", root, flush=True)
    while True:
        time.sleep(.25)
        present = set(files(root))
        for removed in observed.keys()-present:
            if removed in markers:
                try:
                    command(channel, "asset_prefab_forget", path=logical_path(root, removed))
                except (RuntimeError, TimeoutError, OSError) as error:
                    print("Prefab cleanup pending", removed.name, str(error), flush=True)
                    continue
            observed.pop(removed)
            applied.pop(removed, None)
            users.pop(removed, None)
            gui_files.pop(removed, None)
            markers.pop(removed, None)
            cameras.pop(removed, None)
            scalars.pop(removed, None)
        for file in sorted(present):
            try:
                current = signature(file)
                if observed.get(file) != current:
                    observed[file] = current
                    continue
                if applied.get(file) == current:
                    continue
                path = logical_path(root, file)
                if path.lower().endswith(".pfb"):
                    content = file.read_bytes()
                    if file not in markers and (raw_base := original(file)) is not None:
                        markers[file] = raw_base
                    if file not in markers:
                        prefab_root_fields(content)
                        print("Recorded PFB baseline", path, flush=True)
                    else:
                        edits = prefab_root_diff(markers[file], content)
                        if edits:
                            result = command(channel, "asset_prefab", path=path, edits=edits)
                            print("Updated PFB", path, result["count"], "instances; future factory instances tracked", flush=True)
                    markers[file] = content
                elif path.lower().endswith(".gui"):
                    content = file.read_bytes()
                    if file not in gui_files and (raw_base := original(file)) is not None:
                        gui_files[file] = raw_base
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
                        if file not in cameras and (raw_base := original(file)) is not None:
                            first = camera_fields(raw_base)
                            if first is None:
                                raise ValueError("Original USER schema differs from loose override")
                            cameras[file] = first
                        if file not in cameras:
                            print("Recorded camera USER baseline", path, flush=True)
                        else:
                            edits = {k:v for k,v in camera.items() if cameras[file][k] != v}
                            if edits:
                                result = update_user_fields(channel, path, cameras[file], camera, edits)
                                print("Updated camera USER", path, len(result["values"]), "fields", flush=True)
                        cameras[file] = camera
                        applied[file] = current
                        continue
                    layout = scalar_layout(raw, schema) if schema else None
                    if layout:
                        previous = scalars.get(file)
                        if previous is None:
                            previous = original(file)
                        if previous is None:
                            print("Recorded scalar USER baseline", path, flush=True)
                        else:
                            edits = scalar_diff(previous, raw, schema)
                            if edits:
                                before = scalar_layout(previous, schema)[1]
                                update_user_fields(channel, path, {k:before[k][3] for k in edits}, edits, edits,
                                              user_type=layout[0], fields={k:layout[1][k][2] for k in edits})
                                print("Updated scalar USER", path, layout[0], len(edits), "fields", flush=True)
                        scalars[file] = raw
                        applied[file] = current
                        continue
                    updated = decode(raw)
                    if file not in users and (raw_base := original(file)) is not None:
                        users[file] = decode(raw_base)
                    if file not in users:
                        users[file] = updated
                        print("Recorded new helm USER baseline", path, flush=True)
                    else:
                        edits = diff(users[file], updated)
                        if edits:
                            result = command(channel, "asset_user", path=path, edits=edits)
                            print("Updated USER", path, len(edits), "fields in", result["roots"], "roots", flush=True)
                        users[file] = updated
                elif path == LOGICAL:
                    result, _ = reload_native(channel)
                    print("Bound MDF", result["resource"], flush=True)
                else:
                    ext = path.lower().rsplit(".", 1)[-1]
                    owners, intermediate = [], {}
                    if ext in {"tex", "rtex", "uvs", "mot", "uvar", "mesh", "mdf2", "mmtr"}:
                        candidates, via_uv = links.owners(root, present, path)
                        for uv, effects in via_uv.items():
                            active = [effect for effect in effects if command(channel, "asset_inspect", path=effect).get("bindings")]
                            if active:
                                intermediate[uv] = active
                        if ext == "mmtr":
                            candidates += [logical_path(root, f) for f in sorted(present)
                                           if f.name.lower().endswith(".mdf2.23") and path.lower() in templates(f)]
                        owners = [p for p in dict.fromkeys(candidates)
                                  if command(channel, "asset_inspect", path=p).get("bindings")]
                    direct = ext != "mmtr"
                    if direct and ((not owners and not intermediate) or command(channel, "asset_inspect", path=path).get("bindings")):
                        checks = joint_checks(file) if ext == "jcns" else {}
                        result = reload_asset(channel, path, **checks)
                        for owner in owners:
                            reload_asset(channel, owner)
                        for uv, effects in intermediate.items():
                            reload_dependency(channel, uv, effects)
                        print("Bound", path, result["resource"], result["bindings"], *owners, flush=True)
                    elif owners or intermediate:
                        reload_dependency(channel, path, owners, intermediate)
                    else:
                        raise ValueError("No active dependent loose resource")
                applied[file] = current
            except (FileNotFoundError, PermissionError):
                continue
            except (ValueError, struct.error, RuntimeError, TimeoutError) as error:
                print("Skipped", file.name, str(error), flush=True)
                applied[file] = current


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("game", type=Path)
    parser.add_argument("--baseline-root", type=Path, help="Unmodified, patch-matched extracted natives/stm directory for first-save GUI/PFB/USER diffs")
    parser.add_argument("--rsz-schema", type=Path, help="Rise RSZ JSON type database for single-root scalar USER edits")
    try:
        args = parser.parse_args()
        if args.baseline_root and (not args.baseline_root.is_dir() or args.baseline_root.resolve() == (args.game / "natives/stm").resolve()):
            parser.error("--baseline-root must be a separate directory containing original resources")
        watch(args.game, args.baseline_root, json.loads(args.rsz_schema.read_bytes()) if args.rsz_schema else None)
    except KeyboardInterrupt:
        pass
