"""Watch loose resources used by equipped parts and active Rise scene components."""
import argparse
from contextlib import ExitStack
import json
import os
import re
import struct
import sys
import time
from pathlib import Path

if __name__ == "__main__":
    sys.path.insert(0, str(Path(__file__).resolve().parent))
from material_layout import IncompatibleMaterial, MaterialValidator, check_layout, materials, mesh_materials, unchanged_bindings
from file_changes import DirectoryChanges, require_closed_writers, snapshots
from platform_files import PlatformFiles
from rise_pak import RisePak
from equipment_sources import EquipmentSources
from peer_mesh import vertex_edit
from equipment_physics import chain_groups, physics_expectations
from helm_user import decode, diff
from gui_view import view_diff
from scalar_user import scalar_layout, scalar_diff
from scene_data import camera_fields, prefab_root_diff
from resource_links import consumers, logical_path, ResourceLinks
from watch_arm279 import LOGICAL, command, signature
from watcher_runtime import checkpoint
from bone_profiles import BoneProfiles
from rise_shadow import shadow_path, shadow_targets

SUFFIXES = (".chain.48", ".jcns.21", ".motbank.3", ".motlist.528", ".efx.2818730", ".rcol.20",
            ".mesh.2109148288", ".tex.28", ".mdf2.23", ".user.2", ".mmtr.220427553", ".gui.430033", ".pfb.17",
            ".mmtr.220427553.stm", ".uvs.7", ".uvs.7.stm", ".rtex.5", ".rtex.5.stm", ".uvar.3", ".mot.495", ".fbxskel.4")
# EquipmentSources also creates platform texture copies. Observe their changes
# to wake pending MDFs without publishing our own writes as new texture edits.
DEPENDENCY_VARIANTS = (".tex.28.stm",)
WATCHED_SUFFIXES = (*SUFFIXES, *DEPENDENCY_VARIANTS)


class MissingMaterialDependencies(TimeoutError):
    def __init__(self, root, dependencies):
        self.files = {file for pair in dependencies for file in pair}
        templates = {shader for _, shader in dependencies}
        self.files.update(Path(str(f) + ".stm") for f in templates)
        label = "Missing MMTR" if all(p.name.lower().endswith(".mmtr.220427553") for p in templates) else "Missing material dependency"
        super().__init__(label + ": " + ", ".join(sorted(
            "natives/stm/" + path.relative_to(root).as_posix() for path in templates)))

    def watch_files(self, batch, current):
        print(str(self), "Waiting for the dependency or outfit files to change.", flush=True)
        return {f: current.get(f) for f in batch | self.files}


def missing_material_dependencies(root, waiting, archives, validator):
    # Only park copies for a dependency the engine actually reported waiting on.
    # Built-in shaders, mounted PAKs and present loose files retain normal readiness retries.
    missing = set()
    reported = set()
    for row in waiting.splitlines():
        fields = row.replace("\\", "/").split("\t")
        if len(fields) != 3 or not fields[0].lower().endswith(".mdf2"):
            continue
        child = fields[2].removeprefix("@")
        version = {".mmtr": ".220427553", ".tex": ".28"}.get(Path(child).suffix.lower())
        if not version:
            continue
        owner, shader = Path(fields[0] + ".23"), Path(child + version)
        if any(p.anchor or ".." in p.parts or ":" in str(p) for p in (owner, shader)):
            continue
        if child.lower() not in validator.packaged_shaders:
            reported.add((root / owner, root / shader))
    for shader in {shader for _, shader in reported}:
        variants = (shader, Path(str(shader) + ".stm"))
        if any(validator.source(f) for f in variants):
            continue
        try:
            if all(archives.read(f.relative_to(root)) is None for f in variants):
                missing.add(shader)
        except (OSError, ValueError, RuntimeError):
            continue  # An unreadable archive cannot establish that a template is missing.
    return {(owner, shader) for owner, shader in reported if shader in missing}


class GuiReadyNotice:
    def __init__(self, channel):
        self.path = channel / "gui-ready.json"
        self.watch = None
        self.registered = {}
        self.renew_at = 0

    def close(self):
        if self.watch:
            self.watch.close()
            self.watch = None

    def due(self, owners):
        if not owners:
            if not self.registered:
                self.close()
            return bool(self.registered)
        now = time.monotonic()
        if not self.watch and now >= self.renew_at:
            try:
                self.watch = DirectoryChanges(self.path.parent, recursive=False)
            except OSError:
                pass
        if self.watch:
            try:
                paths, _, overflow = self.watch.poll(0)
                if overflow or self.path in paths:
                    self.renew_at = 0
            except OSError:
                self.close()
                self.renew_at = 0
        if owners != self.registered or now >= self.renew_at:
            self.renew_at = 0  # keep a failed exchange eligible for retry
            return True
        return False

    def acknowledge(self, owners, ready, notifications):
        self.registered = {path: names for path, names in owners.items() if path not in ready}
        if not self.registered:
            self.close()
            self.renew_at = 0
        else:
            self.renew_at = time.monotonic() + (60 if self.watch and notifications else 1)


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


def equipment_command(channel, action, **payload):
    try:
        return command(channel, action, **payload)
    except RuntimeError as error:
        reason = str(error)
        # This can fail during initial discovery, before freezing a Chain,
        # or in a later game update that checks the new Mesh's joints.
        if "Incompatible CHAIN terminal " in reason or "[live equipment rejected]" in reason:
            raise ValueError(reason) from error
        raise


def files(root):
    for directory, _, names in os.walk(root):
        for name in names:
            if name.lower().endswith(WATCHED_SUFFIXES):
                yield Path(directory) / name


def recovery_files(root, state, current):
    versions = {"mesh": "2109148288", "mdf2": "23", "chain": "48", "user": "2"}
    wanted = state["paths"]
    if not isinstance(wanted, dict) or not 1 <= len(wanted) <= 17:
        raise ValueError("Unexpected worn recovery paths")
    result = set()
    for path in (*wanted, state.get("suit")):
        if not path:
            continue
        if not re.fullmatch(r"player/mod/([fm])/(?:bone|pl[0-9]+)/\1_(?:(?:body|arm|wst|leg|helm)[0-9]+|shadow)\.(mesh|mdf2|chain|user)", path):
            raise ValueError("Unexpected worn recovery resource")
        file = root / (path + "." + versions[path.rsplit(".", 1)[1]])
        if path in wanted or file in current:
            result.add(file)
    return result


def worn_source(path, meshes):
    base, _, ext = path.rpartition(".")
    if ext in {"mesh", "mdf2", "chain", "user", "jcns"} and base + ".mesh" in meshes:
        return True
    scope = shadow_path(path)
    return bool(scope and any(mesh.split("/")[2] == scope[0] and scope[1] in ("bone", mesh.split("/")[3])
                              for mesh in meshes))


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
    return {material.template for material in materials(file.read_bytes())}


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


def reload_dependency(channel, path, owners, intermediate=None, verify_sources=None, platform=False):
    master = command(channel, "asset_master_begin", path=path, platform=platform)
    bound, committed = [], []
    try:
        deadline = time.monotonic()+12
        while command(channel, "asset_master_poll")["state"] != "ready":
            if time.monotonic() > deadline:
                raise TimeoutError("Dependency initialization timed out")
        for owner in dict.fromkeys(owners):
            if verify_sources:
                verify_sources()
            result = reload_asset(channel, owner)
            if result["state"] != "staged":
                committed.append(owner)
            bound.append(owner)
        for uv, effects in (intermediate or {}).items():
            reload_dependency(channel, uv, effects)
            bound.append(uv)
            committed.append(uv)
        if verify_sources:
            verify_sources()
        command(channel, "asset_master_commit")
    except BaseException:
        command(channel, "asset_master_abort")
        for owner in committed:
            if intermediate and owner in intermediate:
                reload_dependency(channel, owner, intermediate[owner])
            else:
                reload_asset(channel, owner)
        raise
    print("Bound template" if path.lower().endswith(".mmtr") else "Bound dependency", path, master["resource"], "via", ", ".join(bound), flush=True)


def watch(game, baseline_root=None, schema=None):
    root = game / "natives/stm"
    channel = game / "reframework/data/MHRS-Files-HotReload"
    if not channel.is_dir():
        raise ValueError("Missing plugin data directory")
    contents, mdf_templates = {}, {}
    links = ResourceLinks(baseline_root)
    validator = MaterialValidator(root, baseline_root)
    sleeping = False
    physical_paths = {}
    pending_views = {}
    # Local mesh -> old resource identity and files needed to validate its next
    # generation. Never retain a game object, a resource, or an old mod's bytes.
    waiting_worn = {}
    full_wait = None
    rejected_worn = None
    gui_notice = GuiReadyNotice(channel)
    bone_profiles = BoneProfiles(game, channel)
    try:
        from _mhrs_runtime import first_natives_loaded
        first_natives = first_natives_loaded()
    except ImportError:
        config = game / "re2_fw_config.txt"
        first_natives = ((game / "reframework/plugins/FirstNatives.dll").is_file() and config.is_file() and
                         "LooseFileLoader_Enabled=false" in config.read_text(encoding="utf-8-sig").splitlines())
    if first_natives:
        print("Using FirstNatives for equipment loose files", flush=True)

    def retire_paths(paths, aliases, live_reentry, missing, expected_materials, platform_files, physics, provenance, shadows, worn_retry,
                     peer_meshes, stock_meshes, reset_replay=None, worn_guard=None):
        nonlocal sleeping
        paths = sorted(set(paths))
        if not paths:
            return {}, {}, {}, None
        receipt = equipment_command(channel, "asset_removed", paths=paths, aliases=aliases, live_reentry=live_reentry,
                          missing=missing, expected_materials=expected_materials, platform_files=platform_files,
                          physics=physics, startup_equipment=provenance[0], loose_equipment=provenance[1],
                          shadow_skeletons=shadows, peer_meshes=peer_meshes, stock_meshes=stock_meshes,
                          **({"worn_retry": worn_retry} if worn_retry else {}), **({"reset_replay": reset_replay} if reset_replay else {}),
                          **({"worn_guard": worn_guard} if worn_guard else {}))
        worn_mount = receipt.get("worn_mount")
        rows = receipt.get("results") or []
        if [row["path"] for row in rows] != paths:
            raise RuntimeError("Incomplete cache invalidation receipt")
        sleeping = bool(receipt.get("sleeping"))
        for peer in receipt.get("peer_equipment") or []:
            print("Peer equipment", peer["index"], peer["slot"], peer["status"], peer["path"], flush=True)
        if receipt.get("shadow_deferred"):
            print("Deferred shadow skeleton:", receipt["shadow_deferred"], flush=True)
        if receipt.get("waiting_equipment"):
            print("Queued worn equipment until the local hunter is ready:", ", ".join(receipt["waiting_equipment"]), flush=True)
        elif receipt.get("deferred_equipment") and not worn_mount:
            print("Deferred worn equipment until normal re-equip (change the part and change back):",
                  ", ".join(receipt["deferred_equipment"]), flush=True)
        if receipt.get("factories") or receipt.get("equipment"):
            deadline = time.monotonic() + 12
            while True:
                progress = equipment_command(channel, "asset_factories_ready")
                worn_mount = progress.get("worn_mount") or worn_mount
                if progress.get("source_mismatch"):
                    raise IncompatibleMaterial(progress["source_mismatch"])
                if not progress["pending"]:
                    break
                if time.monotonic() >= deadline:
                    detail = channel / "equipment-wait.txt"
                    waiting = detail.read_text(encoding="utf-8", errors="replace").strip() if detail.is_file() else ""
                    if receipt.get("equipment_bindings") or receipt.get("deferred_equipment") or (platform_files and receipt.get("equipment")):
                        command(channel, "asset_equipment_abort")
                        if progress.get("equipment_pending"):
                            absent = missing_material_dependencies(root, waiting, sources.archives, validator)
                            if absent:
                                raise MissingMaterialDependencies(root, absent)
                        raise TimeoutError(f"Equipment is not ready: {waiting or 'waiting for resources'}")
                    print("Next use: game factory is still initializing", waiting or "prefab", flush=True)
                    break
                # A request is consumed at most once per UpdateBehavior. Advance
                # a ready local part on the next frame, while asynchronous resource
                # initialization and older plugin versions keep their normal cadence.
                if progress.get("next_update") is not True:
                    time.sleep(.05)
        return ({row["path"]: row["state"] for row in rows}, receipt.get("preview_targets") or {},
                receipt.get("waiting_equipment") or {}, worn_mount)

    def bind_asset(file, active_material_links=None, platform=False, **options):
        path = logical_path(root, file)
        ext = path.lower().rsplit(".", 1)[-1]
        platform = platform or file.name.lower().endswith(".stm")
        if ext == "uvs":
            options["gui_owners"] = links.gui_owners(path)
        if ext in {"mesh", "mdf2"}:
            bound = command(channel, "asset_inspect", path=path).get("bindings") or []
            source = validator.source(file)
            if not source:
                raise ValueError("A live mesh/material pair needs its layout for validation")
            slots = mesh_materials(source) if ext == "mesh" else {m.name for m in materials(source.read_bytes())}
            for row in bound:
                current = set(row.get("material_names") or [])
                if ext == "mesh":
                    compatible = slots <= current
                else:
                    model = validator.source(root / (row["mesh_path"] + ".2109148288")) if row.get("mesh_path") else None
                    required = mesh_materials(model) if model else current
                    compatible = bool(required) and required <= slots
                if not compatible:
                    raise ValueError("Mesh and material slots changed; waiting for owner recreation")
        owners, intermediate = [], {}
        if ext in {"tex", "rtex", "uvs", "mot", "uvar", "mesh", "mdf2", "mmtr"}:
            candidates, via_uv = links.owners(path)
            possible = set(candidates)
            for effects in via_uv.values():
                possible.update(effects)
            active = set()
            if possible:
                reply = command(channel, "asset_active_consumers", paths=sorted(possible))
                active.update(reply.get("paths") or [])
            for uv, effects in via_uv.items():
                running = [p for p in effects if p in active]
                if running:
                    intermediate[uv] = running
            if ext == "mmtr":
                shader = validator.source(file)
                packaged_layout = validator.packaged_shaders.get(path.lower())
                shader_layout = validator.layout(shader) if shader else packaged_layout
                if shader_layout is None:
                    raise ValueError("No MMTR source available for validation")
                sources = {file: (shader, signature(shader) if shader else None)}
                stock_compatible = packaged_layout == shader_layout
                template_owners = {}
                runtime_links = active_material_links
                if runtime_links is None:
                    runtime_links = command(channel, "asset_material_links", paths=[path]).get("links") or []
                referenced = {r["owner"].lower(): r["child"] for r in runtime_links if r["child"].lower() == path.lower()}
                for owner in command(channel, "asset_material_paths").get("paths") or []:
                    owner_path = root / (owner + ".23")
                    owner_file = validator.source(owner_path)
                    if owner_file is None:
                        name = referenced.get(owner.lower())
                        if not name and owner.lower() in links.stock_parents.get(path.lower(), ()):
                            name = next((n for n in links.stock_aliases[path.lower()] if n != path), path)
                        if name:
                            if not stock_compatible:
                                raise ValueError(f"Shared MMTR needs a matching interface for packaged MDF {owner}")
                            template_owners.setdefault(name, set()).add(owner)
                        continue
                    owner_signature = signature(owner_file)
                    slots = materials(owner_file.read_bytes())
                    matches = {m.template for m in slots if m.template.lower() == path.lower()}
                    if matches:
                        try:
                            validator.validate(owner_file, mdf_templates.get(owner_path))
                            if shader is None:
                                for slot in slots:
                                    if slot.template in matches:
                                        check_layout(slot, shader_layout)
                        except ValueError as error:
                            raise IncompatibleMaterial(f"{owner}: {error}") from error
                        sources[owner_path] = (owner_file, owner_signature)
                        for name in matches:
                            template_owners.setdefault(name, set()).add(owner)

                def verify_sources():
                    for live_path, (checked, sig) in sources.items():
                        if validator.source(live_path) != checked or (checked and signature(checked) != sig):
                            raise RuntimeError(f"File changed during MMTR reload: {live_path.name}")

                if template_owners:
                    # One physical save must not publish a subset of the meshes
                    # when references use different spellings of the same path.
                    name = path if path in template_owners else min(template_owners)
                    owners = set().union(*template_owners.values())
                    verify_sources()
                    reload_dependency(channel, name, sorted(owners), verify_sources=verify_sources,
                                      platform=shader is not None and shader.name.lower().endswith(".stm"))
                    return {path.lower(), *(owner.lower() for owner in owners)}
            owners = [p for p in candidates if p in active]
        direct = ext != "mmtr"
        if direct and ((not owners and not intermediate) or command(channel, "asset_inspect", path=path).get("bindings")):
            checks = joint_checks(file) if ext == "jcns" and file.is_file() else {}
            result = reload_asset(channel, path, platform=platform, **checks, **options)
            for owner in owners:
                view_options = {"gui_owners": links.gui_owners(owner)} if owner.endswith(".uvs") else {}
                reload_asset(channel, owner, **view_options)
            for uv, effects in intermediate.items():
                reload_dependency(channel, uv, effects)
            if path.lower() == LOGICAL.lower():
                print("Bound MDF", result["resource"], path, flush=True)
            else:
                print("Bound", path, result["resource"], result["bindings"], *owners, flush=True)
        elif owners or intermediate:
            reload_dependency(channel, path, owners, intermediate, platform=platform)
        else:
            raise ValueError("No active dependent loose resource")
        published = {path.lower(), *(owner.lower() for owner in owners)}
        for uv, effects in intermediate.items():
            published.add(uv.lower())
            published.update(effect.lower() for effect in effects)
        return published

    def refresh_awake():
        nonlocal sleeping
        reply = command(channel, "asset_awake")
        sleeping = reply["pending"]
        done = {}
        for path in reply.get("paths") or {}:
            ext = path.rpartition(".")[2]
            suffix = next((s for s in SUFFIXES if s.startswith("." + ext + ".")), None)
            if not suffix:
                continue
            file = physical_paths.get(path, root / (path + suffix[len(ext)+1:]))
            try:
                bind_asset(file)
                print("Reactivated", path, flush=True)
            except (ValueError, struct.error) as error:
                print("Next creation", path, str(error), flush=True)
            done[path] = True
        if done:
            sleeping = command(channel, "asset_awake", done=done)["pending"]
    def needs_contents(file):
        return file.name.lower().endswith((".user.2", ".pfb.17", ".gui.430033", ".mdf2.23"))

    def remember(file, data):
        if data is None:
            contents.pop(file, None)
            mdf_templates.pop(file, None)
            return
        contents[file] = data
        if file.name.lower().endswith(".mdf2.23"):
            mdf_templates[file] = {m.name: m.template.lower() for m in materials(data)}

    def update_managed(path, before, after):
        if before is None:
            return
        if path.lower().endswith(".pfb"):
            edits = prefab_root_diff(before, after)
            if edits:
                result = command(channel, "asset_prefab", path=path, edits=edits)
                print("Updated PFB", path, result["count"], "instances", flush=True)
            return
        if path.lower().endswith(".gui"):
            edits = view_diff(before, after)
            if edits:
                result = command(channel, "asset_gui", path=path, edits=edits)
                print("Updated GUI", path, result["views"], "views", flush=True)
            return
        camera = camera_fields(after)
        if camera is not None:
            prior = camera_fields(before)
            if prior is None:
                raise ValueError("Changed camera USER layout")
            edits = {k: v for k, v in camera.items() if prior[k] != v}
            if edits:
                update_user_fields(channel, path, prior, camera, edits)
                print("Updated camera USER", path, len(edits), "fields", flush=True)
            return
        layout = scalar_layout(after, schema) if schema else None
        if layout:
            edits = scalar_diff(before, after, schema)
            if edits:
                prior = scalar_layout(before, schema)[1]
                update_user_fields(channel, path, {k: prior[k][3] for k in edits}, edits, edits,
                                   user_type=layout[0], fields={k: layout[1][k][2] for k in edits})
                print("Updated scalar USER", path, layout[0], len(edits), "fields", flush=True)
            return
        edits = diff(decode(before), decode(after))
        if edits:
            result = command(channel, "asset_user", path=path, edits=edits)
            print("Updated USER", path, len(edits), "fields in", result["roots"], "roots", flush=True)

    def apply_batch(changed, current, applied, removed_files, worn_retry=None, reset_replay=None, worn_guard=None):
        nonlocal full_wait
        previous_wait = full_wait
        replacing = previous_wait and any(worn_source(logical_path(root, f).lower(), previous_wait["worn"]) for f in changed)
        if previous_wait and not replacing and not reset_replay and not worn_guard:
            pending_sets = {p.split("/")[2] for p in previous_wait["worn"] if p.startswith("player/mod/")}
            replacing = any(name.startswith("player/mod/") and name.endswith(".mesh") and name.split("/")[2] in pending_sets
                            for name in (logical_path(root, f).lower() for f in changed))
        if replacing:
            changed = changed | previous_wait["files"]
        require_closed_writers(f for f in changed if f in current)
        paths = {f: logical_path(root, f).lower() for f in changed}
        previous = links.index
        disk = {f: (f.read_bytes() if f in current else None) for f in changed if needs_contents(f)}
        links.update(root, current, changed, disk)
        targets = set(paths.values())
        # Streamed mips are the companion of the ordinary TEX holder.
        targets.update(p[len("streaming/"):] for p in paths.values() if p.startswith("streaming/") and p.endswith(".tex"))
        live_graph, live_names, material_links = {}, {}, []
        material_sources = sorted(p for p in targets if p.endswith((".mmtr", ".tex")) and not p.startswith("streaming/"))
        if material_sources:
            reply = command(channel, "asset_material_links", paths=material_sources)
            material_links = reply.get("links") or []
            for entry in material_links:
                owner, child = entry["owner"], entry["child"]
                live_graph.setdefault(owner.lower(), set()).add(child.lower())
                for name in (owner, child):
                    live_names.setdefault(name.lower(), set()).add(name)
        affected = consumers(targets, previous, links.index, live_graph, packaged=links.stock_parents,
                             overrides=lambda owner: owner in previous.graph and owner in links.graph)
        sequences = sorted(p for p in affected if p.endswith(".uvs"))
        gui_sequences = {}
        if sequences:
            for entry in command(channel, "asset_gui_links", paths=sequences, active_only=True).get("links") or []:
                owner, child = entry["owner"], entry["child"]
                gui_sequences.setdefault(child.lower(), set()).add(owner.lower())
                for name in (owner, child):
                    live_names.setdefault(name.lower(), set()).add(name)
        for file in changed:
            validator.shaders.pop(file, None)
        for file in changed:
            path = paths[file]
            if file in current and path.endswith(".mdf2"):
                validator.validate(file)
            if path.endswith(".mmtr"):
                shader = validator.source(file)
                if shader:
                    validator.layout(shader)
                    for owner in affected:
                        if owner.endswith(".mdf2"):
                            mdf = validator.source(root / (owner + ".23"))
                            if mdf:
                                validator.validate(mdf, mdf_templates.get(root / (owner + ".23")))
        for file in changed:
            if (file in current and signature(file) != current[file][0]) or (file not in current and file.exists()):
                raise OSError(f"Copy in progress: {file.name}")
        platform_sources, ready, platform_paths = sources.prepare(
            paths, current, affected, targets, links, previous, live_graph, physical_paths)
        physics = physics_expectations(paths, current, sources.original)
        shadows = shadow_targets(root, changed, current, sources.archives, first_natives)
        changed_meshes = {path: file for file, path in paths.items()
                          if path.startswith("player/mod/") and path.endswith(".mesh") and not shadow_path(path)}
        peer_paths = set(changed_meshes)
        if len(changed) == 1:
            peer_paths.update(path.removesuffix(".mdf2") + ".mesh" for path in targets
                              if path.startswith("player/mod/") and path.endswith(".mdf2"))
        worn_meshes = command(channel, "asset_peer_meshes", paths=sorted(peer_paths)) if peer_paths else {}
        online_parts = worn_meshes.get("paths") or {}
        vertex_paths = set(online_parts)
        # Lua can commit a local vertex update only for a single live_reentry
        # path. A complete outfit uses the game's ordinary equipment assembly.
        if len(targets) == 1:
            vertex_paths.update(targets.intersection(worn_meshes.get("master") or {}))
        # A single edit can also refresh an already running consumer. Mixed
        # additions, overwrites and removals are one factory generation: never
        # apply a new mesh to an old MDF while a costume directory is changing.
        published = set()
        armor_batch = len(changed) > 1 and any(
            path.startswith("player/mod/") and path.endswith((".mesh", ".mdf2", ".chain", ".user", ".jcns"))
            for path in targets)
        # Resolve dependencies before their consumers when both are saved. The
        # worn-equipment path below prepares the entire mesh/material/CHAIN set.
        order = {ext: i for i, ext in enumerate(("mmtr", "tex", "rtex", "uvs", "mdf2", "mesh",
                                                  "mot", "uvar", "motlist", "motbank", "efx"))}
        for file in sorted(changed, key=lambda f: (order.get(paths[f].rsplit(".", 1)[-1], len(order)), f)):
            path = paths[file]
            coordinated = armor_batch and (path in platform_paths or
                (path.startswith("player/mod/") and path.endswith((".mesh", ".mdf2", ".chain", ".jcns"))) or
                path in physics["helmets"])
            if path in published or coordinated:
                continue
            managed = path.endswith((".gui", ".pfb", ".user"))
            new_armor = (not path.endswith(".mot") and file in platform_sources
                         and (file not in applied or file not in current or path.endswith(".tex")))
            if path.startswith("player/mod/") and path.endswith(".mesh"):
                new_armor = True
            if path.startswith("player/mod/") and path.endswith(".mdf2"):
                prior_slots = tuple(mdf_templates.get(file, ()))
                if (file not in current or path.removesuffix(".mdf2") + ".mesh" in online_parts
                        or tuple(m.name for m in materials(disk[file])) != prior_slots):
                    new_armor = True
            try:
                before = contents.get(file)
                if file in current and before is None and needs_contents(file):
                    before = sources.original(file)
                if path in physics["chains"] or path in physics["helmets"]:
                    pass  # Validate on the active part in the same transaction as a whole wardrobe change.
                elif managed and file in current:
                    update_managed(path, before, disk[file])
                elif managed and file not in current and before is not None:
                    after = sources.original(file)
                    if after is not None:
                        update_managed(path, before, after)
                elif (not managed and not new_armor and not path.startswith("streaming/")
                      and (file in current or ((file in ready or path in links.stock_aliases or validator.source(file))
                           and path.endswith((".mot", ".uvs", ".tex", ".rtex", ".mmtr"))))):
                    options = {}
                    if path.endswith(".chain") and file in current:
                        options["expected_groups"] = chain_groups(file.read_bytes(), path)
                    if path.endswith(".mdf2"):
                        validator.validate(file, mdf_templates.get(file))
                        options["preserve"] = unchanged_bindings(before, disk[file])
                    updated = bind_asset(file, active_material_links=material_links, platform=file in ready, **options)
                    published.update(updated)
                    # The current binding now owns the newly published key.
                    # Parents not rebound by the live path still need retirement.
                    affected.difference_update(updated)
                    if file not in current:
                        print("Restored packaged", path, flush=True)
            except IncompatibleMaterial:
                raise
            except TimeoutError:
                raise
            except (ValueError, struct.error, RuntimeError) as error:
                if isinstance(error, RuntimeError) and any(reason in str(error) for reason in (
                        "Equipped binding changed", "MDF users changed", "MDF holder changed",
                        "Preview target changed or is not ready", "File changed during MMTR reload", "Resource not ready")):
                    raise
                print("Next use", path, str(error), flush=True)
        aliases = {p: set(previous.aliases.get(p, ())) | set(links.aliases.get(p, ())) |
                      links.stock_aliases.get(p, set()) | live_names.get(p, set())
                   for p in affected}
        for file in changed:
            if paths[file] in aliases:
                aliases[paths[file]].add(logical_path(root, file))
        missing = {paths[f]: True for f in changed if f not in current and f not in sources.packaged
                   and paths[f] not in links.stock_aliases and validator.source(f) is None}
        expected_materials = {}
        with ExitStack() as vertex_sources:
            peer_meshes = {}
            stock_sources = {}
            for path in changed_meshes.keys() & (worn_meshes.get("master") or {}).keys():
                file = changed_meshes[path]
                if file in current or (file not in applied and file not in sources.packaged):
                    continue
                held = vertex_sources.enter_context(sources.stock_mesh_source(file))
                if held:
                    stock_sources[path] = held
                    missing.pop(path, None)
                    if path not in platform_paths:
                        platform_paths.append(path)
            if changed_meshes:
                for path in changed_meshes.keys() & vertex_paths:
                    file = changed_meshes[path]
                    sex = path.split("/")[2]
                    if any((scope := shadow_path(logical_path(root, f))) and scope[0] == sex
                           for f in current.keys() | sources.startup):
                        continue
                    if path in stock_sources:
                        stock = stock_sources[path].read()
                        if vertex_edit(stock, stock):
                            peer_meshes[path] = True
                        continue
                    stock = sources.archives.read(file.relative_to(root))
                    fresh = file.read_bytes() if file in current else stock
                    if vertex_edit(stock, fresh):
                        held = vertex_sources.enter_context(sources.vertex_source(file, stock, file in current))
                        if held and vertex_edit(stock, held.read()):
                            peer_meshes[path] = True
                        if held and path not in platform_paths:
                            platform_paths.append(path)
            for file, path in paths.items():
                if path in affected and path.startswith("player/mod/") and path.endswith(".mdf2"):
                    raw = disk[file] if file in current else sources.original(file)
                    if raw is not None:
                        expected_materials[path] = [m.name for m in materials(raw)]
            rows, preview_targets, waiting, mount_outcome = retire_paths(affected, {p: sorted(names) for p, names in aliases.items()},
                                                 sorted(targets), missing, expected_materials,
                                                 [p for p in platform_paths if p.lower() not in published],
                                                 physics, sources.provenance(affected, current), shadows, worn_retry, peer_meshes,
                                                 dict.fromkeys(stock_sources, True), reset_replay, worn_guard)
        if replacing:
            full_wait = None
        if mount_outcome:
            worn = mount_outcome.get("worn") or {}
            if mount_outcome.get("retry") and worn:
                files_to_retry = {f for f, name in paths.items() if worn_source(name, worn)}
                targets_to_retry = {p: old for p, old in worn.items()
                                    if p in targets or p.removesuffix(".mesh") + ".mdf2" in targets}
                if files_to_retry and targets_to_retry:
                    delay = min(10, 2 * previous_wait["delay"]) if worn_guard and previous_wait else 1
                    full_wait = dict(mount_outcome, files=files_to_retry, targets=targets_to_retry,
                                     delay=delay, due=time.monotonic() + delay)
                    if not previous_wait or mount_outcome.get("reason") != previous_wait.get("reason"):
                        print("Queued worn equipment on the existing hunter:", mount_outcome.get("reason"), flush=True)
            else:
                print("Complete outfit deferred to natural equipment assembly:", mount_outcome.get("reason"), flush=True)
        physical_paths.update((path,file) for file,path in paths.items())
        # A manager slot survives closing the menu. Publish its retired RTEX
        # before any UVS in the same copy requests it for the next preview.
        for path, name in preview_targets.items():
            if path not in missing:
                file = physical_paths.get(path)
                reload_asset(channel, name, platform=bool(file and file.name.lower().endswith(".stm")))
        for path in sequences:
            pending_views.pop(path, None)
            if (path in published and path in gui_sequences) or path in missing or not (path in gui_sequences or links.gui_owners(path)):
                continue
            file = physical_paths.get(path, root / (path + ".7"))
            # Reopen after any textures in the same copy have been retired.
            # When a view is still under construction, retry at its next use.
            if path in gui_sequences:
                try:
                    bind_asset(file)
                    continue
                except (ValueError, RuntimeError, TimeoutError) as error:
                    print("Next use", path, str(error), flush=True)
            owners = set(links.gui_owners(path)) | gui_sequences.get(path, set())
            pending_views[path] = file, sorted(owners)
        for file in sorted(changed):
            path = paths[file]
            if file in disk:
                remember(file, disk[file])
            if file not in current:
                removed_files.add(file)
                verb = "Removed"
            elif file in removed_files:
                removed_files.discard(file)
                verb = "Restored"
            else:
                verb = "Replaced" if file in applied else "Added"
            print(verb, path, rows.get(path, "live"), flush=True)

        # Carry material/physics/skeleton edits for the same worn item across
        # successive copies while a menu owns input. Textures are already in
        # the canonical cache; unrelated owners need no second retirement.
        for mesh in waiting_worn.keys() | waiting.keys():
            if mesh in targets and mesh not in waiting:
                waiting_worn.pop(mesh, None)
                continue
            old, files_to_retry = waiting_worn.get(mesh, (None, set()))
            base = mesh.rsplit(".", 1)[0]
            sex_scope = mesh.split("/")[2:4]
            for file, name in paths.items():
                shadow = shadow_path(name)
                if ((name.rsplit(".", 1)[0] == base and name.endswith((".mesh", ".mdf2", ".chain", ".user", ".jcns")))
                        or (shadow and len(sex_scope) == 2 and shadow[0] == sex_scope[0] and
                            shadow[1] in ("bone", sex_scope[1]))):
                    files_to_retry.add(file)
            waiting_worn[mesh] = waiting.get(mesh, old), files_to_retry

    platforms = PlatformFiles(root, channel)
    stream = snapshots(root, files, signature, WATCHED_SUFFIXES, anchor=game, known_link_change=platforms.known_link_change)
    current = next(stream)
    sources = EquipmentSources(root, platforms, RisePak(game), current, baseline_root)
    physical_paths.update((logical_path(root, file).lower(), file) for file in current
                          if not file.name.lower().endswith(DEPENDENCY_VARIANTS))
    applied = current.copy()
    for file in current:
        if needs_contents(file):
            try:
                remember(file, file.read_bytes())
            except (ValueError, OSError, struct.error):
                pass
    links.update(root, current, contents=contents)
    removed_files = set()
    due = {}
    groups = []
    retries = {}
    next_awake = 0
    changed = set()
    material_waits = []
    rejected_groups = {}
    deferred_material_waits = {}

    def groups_for(files, wakeups):
        # The old and incoming reference graphs both matter on removal and when
        # a file in this copy introduces a dependency for the first time.
        if len(files) < 2:
            return [frozenset(files)] if files else []
        old_index, old_records = links.index, links.records
        try:
            links.update(root, current, files)
            incoming = links.index
        finally:
            links.index, links.records = old_index, old_records

        parents = {f: f for f in files}
        def leader(f):
            while parents[f] != f:
                parents[f] = parents[parents[f]]
                f = parents[f]
            return f

        uses = {}
        for file in sorted(files):
            name = logical_path(root, file).lower()
            targets = {name, name.removeprefix("streaming/")}
            owners = consumers(targets, old_index, incoming, packaged=links.stock_parents,
                               overrides=lambda owner: owner in old_index.graph and owner in incoming.graph)
            for owner in tuple(owners):
                suit = re.match(r"^(player/mod/[fm]/pl[0-9]+)/", owner)
                if suit:
                    owners.add(suit[1])
                # Rise registers the armor slots together. Keep indirect MDF
                # dependencies and mixed-ID layered parts in that same handover.
                if owner.startswith("player/mod/") and owner.endswith((".mesh", ".mdf2", ".chain", ".user", ".jcns")):
                    owners.add("/".join(owner.split("/")[:3]))
            for owner in owners:
                if owner in uses:
                    parents[leader(file)] = leader(uses[owner])
                else:
                    uses[owner] = file
        for related in wakeups:
            members = sorted(files.intersection(related))
            for file in members[1:]:
                parents[leader(file)] = leader(members[0])
        groups = {}
        for file in sorted(files):
            groups.setdefault(leader(file), set()).add(file)
        return [frozenset(group) for group in groups.values()]

    def retry_equipment(queue, batch, **options):
        previous = deferred_material_waits.get(queue)
        if previous:
            previous_batch, previous_options, watched = previous
            if previous_batch == batch and previous_options == options and all(current.get(f) == s for f, s in watched.items()):
                return False
        old_index, old_records = links.index, links.records
        try:
            apply_batch(batch, current, applied, removed_files, **options)
        except MissingMaterialDependencies as error:
            links.index, links.records = old_index, old_records
            deferred_material_waits[queue] = frozenset(batch), options, error.watch_files(batch, current)
            return False
        except (ValueError, struct.error, RuntimeError, OSError):
            links.index, links.records = old_index, old_records
            raise
        deferred_material_waits.pop(queue, None)
        return True
    # Only a worker started after a Lua reset can inherit an interrupted
    # shadow mount. Lua validates the process, root and every registered slot.
    recover_shadow = first_natives and (channel / "part-recovery.json").is_file()
    print("Watching", len(applied), "loose files in", root, flush=True)
    try:
        while True:
            checkpoint()
            bone_profiles.poll()
            now = time.monotonic()
            deferred = full_wait or recover_shadow or sleeping or pending_views or gui_notice.registered or (waiting_worn and rejected_worn is not current)
            wait = 1.0  # also lets an idle Windows console handle Ctrl+C
            if groups:
                wait = min(wait, max(0., min(max(due[f] for f in group) for group in groups) - now))
            if deferred:
                wait = min(wait, max(0., next_awake - now))
            snapshot = stream.send(wait)
            now = time.monotonic()
            if snapshot is not current:
                previous, current = current, snapshot
                changed = {f for f in applied.keys() | current.keys()
                           if applied.get(f) != current.get(f) and not f.name.lower().endswith(DEPENDENCY_VARIANTS)}
                wakeups = []
                for batch, watched in material_waits:
                    if any(current.get(f) != stamp for f, stamp in watched.items()):
                        changed.update(batch)
                        wakeups.append(watched.keys())
                    else:
                        changed.difference_update(batch)
                due = {f: now + .55 if f not in due or current.get(f) != previous.get(f) else due[f] for f in changed}
                try:
                    groups = groups_for(changed, wakeups)
                except OSError:
                    # A file may have been replaced between notification and indexing.
                    groups = [frozenset(changed)] if changed else []
                groups = [group for group in groups if not any(
                    group <= batch and all(current.get(f) == stamp for f, stamp in watched.items())
                    for batch, watched in rejected_groups.items())]
                for group in groups:
                    if group not in retries and any(f not in previous or current.get(f) != previous.get(f) for f in group):
                        for f in group:
                            due[f] = min(due[f], now + .55)
                retries = {group: delay for group, delay in retries.items()
                           if group in groups and all(previous.get(f) == current.get(f) for f in group)}
            for group in groups.copy():
                if max(due[f] for f in group) > now:
                    continue
                old_index, old_records = links.index, links.records
                try:
                    apply_batch(group, current, applied, removed_files)
                except MissingMaterialDependencies as error:
                    links.index, links.records = old_index, old_records
                    material_waits = [entry for entry in material_waits if entry[0].isdisjoint(group)]
                    material_waits.append((group, error.watch_files(group, current)))
                except (IncompatibleMaterial, UnicodeError, ValueError, struct.error) as error:
                    links.index, links.records = old_index, old_records
                    print("Rejected copy", str(error), flush=True)
                    rejected_groups = {batch: watched for batch, watched in rejected_groups.items() if batch.isdisjoint(group)}
                    rejected_groups[group] = {f: current.get(f) for f in group}
                except (RuntimeError, TimeoutError, OSError) as error:
                    links.index, links.records = old_index, old_records
                    print("Reload pending", str(error), flush=True)
                    retries[group] = min(10, max(1, retries.get(group, 0) * 2))
                    for f in group:
                        due[f] = time.monotonic() + retries[group]
                    continue
                else:
                    rejected_groups = {batch: watched for batch, watched in rejected_groups.items() if batch.isdisjoint(group)}
                    for f in group:
                        if f in current:
                            applied[f] = current[f]
                        else:
                            applied.pop(f, None)
                    material_waits = [entry for entry in material_waits if entry[0].isdisjoint(group)]
                groups.remove(group)
                for f in group:
                    due.pop(f, None)
                retries.pop(group, None)
            if deferred and time.monotonic() >= next_awake:
                try:
                    pending_files = set().union(*groups)
                    pending_paths = {logical_path(root, f).lower() for f in pending_files}
                    def pending_worn(meshes):
                        return any(worn_source(path, meshes) for path in pending_paths)

                    if full_wait and not pending_worn(full_wait["worn"]) and time.monotonic() >= full_wait["due"]:
                        q = full_wait
                        q["due"] = time.monotonic() + q["delay"]
                        state = command(channel, "asset_worn_state", paths=q["worn"], wait_factory=q.get("wait_factory", False))
                        if state.get("ready") and state.get("root") and state.get("scope"):
                            observed = state.get("observed") or {}
                            new_owner = (state["root"], state["scope"]) != (q.get("root"), q.get("scope"))
                            if (q.get("discover") or new_owner) and state.get("slots_known") is False:
                                state["available"] = {}
                            elif q.get("discover") or new_owner:
                                observed = {path: value for path, value in observed.items() if path in q["targets"]}
                                if not observed or (not q.get("partial") and not state.get("complete_outfit")):
                                    full_wait = None
                                else:
                                    q.update(root=state["root"], scope=state["scope"], worn=observed,
                                             targets=observed, discover=False, wait_factory=False)
                                    q["files"] = {f for f in q["files"] if worn_source(logical_path(root, f).lower(), observed)}
                            if full_wait and state.get("slots_known") is not False and observed != q["worn"]:
                                full_wait = None
                            if full_wait and not q.get("discover") and observed == q["worn"] and all((state.get("available") or {}).get(p) for p in q["targets"]):
                                try:
                                    retry_equipment("outfit", q["files"], worn_retry=q["targets"],
                                                    worn_guard={"root": q["root"], "scope": q["scope"]})
                                except (ValueError, struct.error) as error:
                                    full_wait = None
                                    print("Rejected queued complete outfit", str(error), flush=True)
                                except (RuntimeError, OSError, TimeoutError):
                                    q["delay"] = min(10, q["delay"] * 2)
                                    q["due"] = time.monotonic() + q["delay"]
                                    raise
                    if recover_shadow:
                        state = command(channel, "asset_part_recovery")
                        recover_shadow = bool(state.get("pending") or state.get("id"))
                        if state.get("id"):
                            recovered = retry_equipment("recovery", recovery_files(root, state, current),
                                                        worn_retry=state["worn"], reset_replay=state["id"])
                            if recovered:
                                recover_shadow = False
                                print("Recovered interrupted FirstNatives assembly on the existing local hunter", flush=True)
                    if waiting_worn and rejected_worn is not current and not pending_worn(waiting_worn):
                        wanted = {mesh: row[0] for mesh, row in waiting_worn.items()}
                        state = command(channel, "asset_worn_state", paths=wanted)
                        if state.get("ready"):
                            observed = state.get("observed") or {}
                            for mesh, old in wanted.items():
                                if observed.get(mesh) != old and (mesh in observed or state.get("slots_known") is not False):
                                    del waiting_worn[mesh]
                                    if mesh in observed:
                                        print("Queued worn mesh already recreated by the game:", mesh, flush=True)
                                    else:
                                        print("Queued mesh is no longer worn by the local hunter:", mesh, flush=True)
                            available = state.get("available") or {}
                            retry = {mesh: row[0] for mesh, row in waiting_worn.items() if available.get(mesh)}
                            if retry:
                                files_to_retry = set().union(*(waiting_worn[mesh][1] for mesh in retry))
                                try:
                                    complete = retry_equipment("parts", files_to_retry, worn_retry=retry)
                                except (ValueError, struct.error) as error:
                                    rejected_worn = current
                                    print("Rejected queued equipment", str(error), flush=True)
                                else:
                                    if complete:
                                        print("Reactivated worn equipment", ", ".join(retry), flush=True)
                    if sleeping:
                        refresh_awake()
                    owners = {path: names for path, (_, names) in pending_views.items()}
                    if gui_notice.due(owners):
                        reply = command(channel, "asset_gui_ready", owners=owners, notify=gui_notice.watch is not None)
                        ready = reply.get("paths") or []
                        gui_notice.acknowledge(owners, ready, reply.get("notifications"))
                        for path in ready:
                            bind_asset(pending_views[path][0])
                            del pending_views[path]
                            print("Reactivated", path, flush=True)
                except (ValueError, struct.error, RuntimeError, TimeoutError, OSError) as error:
                    print("Reactivation pending", str(error), flush=True)
                next_awake = time.monotonic() + 1
    finally:
        gui_notice.close()
        stream.close()
        platforms.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("game", type=Path)
    parser.add_argument("--baseline-root", type=Path, help="Unmodified, patch-matched extracted natives/stm directory for field diffs and active single-file packaged fallback")
    parser.add_argument("--rsz-schema", type=Path, help="Rise RSZ JSON type database for single-root scalar USER edits")
    try:
        args = parser.parse_args()
        if args.baseline_root and (not args.baseline_root.is_dir() or args.baseline_root.resolve() == (args.game / "natives/stm").resolve()):
            parser.error("--baseline-root must be a separate directory containing original resources")
        watch(args.game, args.baseline_root, json.loads(args.rsz_schema.read_bytes()) if args.rsz_schema else None)
    except KeyboardInterrupt:
        pass
