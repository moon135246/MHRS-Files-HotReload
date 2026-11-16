"""Watch loose resources used by equipped parts and active Rise scene components."""
import argparse
import json
import os
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
            ".uvs.7", ".uvs.7.stm", ".rtex.5", ".rtex.5.stm", ".uvar.3", ".mot.495", ".fbxskel.4")


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
                     peer_meshes):
        nonlocal sleeping
        paths = sorted(set(paths))
        if not paths:
            return {}, {}, {}
        receipt = equipment_command(channel, "asset_removed", paths=paths, aliases=aliases, live_reentry=live_reentry,
                          missing=missing, expected_materials=expected_materials, platform_files=platform_files,
                          physics=physics, startup_equipment=provenance[0], loose_equipment=provenance[1],
                          shadow_skeletons=shadows, peer_meshes=peer_meshes, **({"worn_retry": worn_retry} if worn_retry else {}))
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
        elif receipt.get("deferred_equipment"):
            print("Deferred worn equipment until normal re-equip (change the part and change back):",
                  ", ".join(receipt["deferred_equipment"]), flush=True)
        if receipt.get("factories") or receipt.get("equipment"):
            deadline = time.monotonic() + 12
            while True:
                progress = equipment_command(channel, "asset_factories_ready")
                if progress.get("source_mismatch"):
                    raise IncompatibleMaterial(progress["source_mismatch"])
                if not progress["pending"]:
                    break
                if time.monotonic() >= deadline:
                    detail = channel / "equipment-wait.txt"
                    waiting = detail.read_text(errors="replace").strip() if detail.is_file() else ""
                    if receipt.get("equipment_bindings") or receipt.get("deferred_equipment") or (platform_files and receipt.get("equipment")):
                        command(channel, "asset_equipment_abort")
                        raise TimeoutError(f"Equipment is not ready: {waiting or 'waiting for resources'}")
                    print("Next use: game factory is still initializing", waiting or "prefab", flush=True)
                    break
                time.sleep(.05)
        return ({row["path"]: row["state"] for row in rows}, receipt.get("preview_targets") or {},
                receipt.get("waiting_equipment") or {})

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
                    reload_dependency(channel, name, sorted(owners), verify_sources=verify_sources)
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

    def apply_batch(changed, current, applied, removed_files, worn_retry=None):
        require_closed_writers(f for f in changed if f in current)
        previous = links.index
        disk = {f: (f.read_bytes() if f in current else None) for f in changed if needs_contents(f)}
        links.update(root, current, changed, disk)
        paths = {f: logical_path(root, f).lower() for f in changed}
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
        online_parts = (command(channel, "asset_peer_meshes", paths=sorted(peer_paths)).get("paths") or {}
                        if peer_paths else {})
        # A single edit can also refresh an already running consumer. Mixed
        # additions, overwrites and removals are one factory generation: never
        # apply a new mesh to an old MDF while a costume directory is changing.
        published = set()
        if len(changed) == 1:
            file = next(iter(changed))
            path = paths[file]
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
                    published = bind_asset(file, active_material_links=material_links, platform=file in ready, **options)
                    # The current binding now owns the newly published key.
                    # Parents not rebound by the live path still need retirement.
                    affected.difference_update(published)
                    if file not in current:
                        print("Restored packaged", path, flush=True)
            except IncompatibleMaterial:
                raise
            except (ValueError, struct.error, RuntimeError, TimeoutError) as error:
                print("Next use", path, str(error), flush=True)
        if len(changed) > 1:
            # Each currently playing standalone clip owns a Motion layer. A
            # multi-file install also needs to rebind those existing layers.
            for file in sorted(changed):
                path = paths[file]
                if not path.endswith(".mot") or not (file in current or file in ready or path in links.stock_aliases):
                    continue
                if not command(channel, "asset_inspect", path=path).get("bindings"):
                    continue
                try:
                    result = reload_asset(channel, path, platform=file in ready)
                except (RuntimeError, TimeoutError) as error:
                    print("Next use", path, str(error), flush=True)
                else:
                    published.add(path)
                    affected.discard(path)
                    print("Bound", path, result["resource"], result["bindings"], flush=True)
        aliases = {p: set(previous.aliases.get(p, ())) | set(links.aliases.get(p, ())) |
                      links.stock_aliases.get(p, set()) | live_names.get(p, set())
                   for p in affected}
        for file in changed:
            if paths[file] in aliases:
                aliases[paths[file]].add(logical_path(root, file))
        missing = {paths[f]: True for f in changed if f not in current and f not in sources.packaged
                   and paths[f] not in links.stock_aliases and validator.source(f) is None}
        expected_materials = {}
        peer_meshes = {}
        if changed_meshes:
            for path in online_parts:
                file = changed_meshes.get(path)
                if file is None:
                    continue
                sex = path.split("/")[2]
                if any((scope := shadow_path(logical_path(root, f))) and scope[0] == sex
                       for f in current.keys() | sources.startup):
                    continue
                stock = sources.archives.read(file.relative_to(root))
                fresh = file.read_bytes() if file in current else stock
                if vertex_edit(stock, fresh):
                    peer_meshes[path] = True
        for file, path in paths.items():
            if path in affected and path.startswith("player/mod/") and path.endswith(".mdf2"):
                raw = disk[file] if file in current else sources.original(file)
                if raw is not None:
                    expected_materials[path] = [m.name for m in materials(raw)]
        rows, preview_targets, waiting = retire_paths(affected, {p: sorted(names) for p, names in aliases.items()},
                                             sorted(targets), missing, expected_materials,
                                             [p for p in platform_paths if p.lower() not in published],
                                             physics, sources.provenance(affected, current), shadows, worn_retry, peer_meshes)
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
    stream = snapshots(root, files, signature, SUFFIXES, anchor=game)
    current = next(stream)
    sources = EquipmentSources(root, platforms, RisePak(game), current, baseline_root)
    physical_paths.update((logical_path(root, file).lower(), file) for file in current)
    applied = current.copy()
    for file in current:
        if needs_contents(file):
            try:
                remember(file, file.read_bytes())
            except (ValueError, OSError, struct.error):
                pass
    links.update(root, current, contents=contents)
    removed_files = set()
    last_change = time.monotonic()
    rejected = None
    retry_delay = 0
    next_awake = 0
    changed = set()
    print("Watching", len(applied), "loose files in", root, flush=True)
    try:
        while True:
            checkpoint()
            bone_profiles.poll()
            now = time.monotonic()
            deferred = sleeping or pending_views or gui_notice.registered or (waiting_worn and rejected_worn is not current)
            wait = 1.0  # also lets an idle Windows console handle Ctrl+C
            if changed and rejected is not current:
                wait = max(0.0, last_change + .55 + retry_delay - now)
            elif not changed and deferred:
                wait = max(0.0, min(wait, next_awake - now))
            snapshot = stream.send(wait)
            if snapshot is not current:
                current = snapshot
                last_change = time.monotonic()
                retry_delay = 0
                changed = {f for f in applied.keys() | current.keys() if applied.get(f) != current.get(f)}
            if changed and rejected is not current and time.monotonic() - last_change >= .55 + retry_delay:
                old_index, old_records = links.index, links.records
                try:
                    apply_batch(changed, current, applied, removed_files)
                    applied = current
                    changed.clear()
                    rejected = None
                    retry_delay = 0
                except (IncompatibleMaterial, UnicodeError, ValueError, struct.error) as error:
                    # Preserve old owners. A corrected generation is retried even
                    # if only one of the previously rejected group changes again.
                    links.index, links.records = old_index, old_records
                    if rejected is not current:
                        print("Rejected copy", str(error), flush=True)
                    rejected = current
                except (RuntimeError, TimeoutError, OSError) as error:
                    links.index, links.records = old_index, old_records
                    print("Reload pending", str(error), flush=True)
                    retry_delay = min(10, max(1, retry_delay * 2))
                    last_change = time.monotonic()
            elif not changed and deferred and time.monotonic() >= next_awake:
                try:
                    if waiting_worn and rejected_worn is not current:
                        wanted = {mesh: row[0] for mesh, row in waiting_worn.items()}
                        state = command(channel, "asset_worn_state", paths=wanted)
                        if state.get("ready"):
                            observed = state.get("observed") or {}
                            for mesh, old in wanted.items():
                                if observed.get(mesh) != old:
                                    del waiting_worn[mesh]
                                    if mesh in observed:
                                        print("Queued worn mesh already recreated by the game:", mesh, flush=True)
                                    else:
                                        print("Queued mesh is no longer worn by the local hunter:", mesh, flush=True)
                            available = state.get("available") or {}
                            retry = {mesh: row[0] for mesh, row in waiting_worn.items() if available.get(mesh)}
                            if retry:
                                files_to_retry = set().union(*(waiting_worn[mesh][1] for mesh in retry))
                                old_index, old_records = links.index, links.records
                                try:
                                    apply_batch(files_to_retry, current, applied, removed_files, worn_retry=retry)
                                except (ValueError, struct.error) as error:
                                    links.index, links.records = old_index, old_records
                                    rejected_worn = current
                                    print("Rejected queued equipment", str(error), flush=True)
                                except (RuntimeError, TimeoutError, OSError):
                                    links.index, links.records = old_index, old_records
                                    raise
                                else:
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
