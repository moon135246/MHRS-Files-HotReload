"""Drive the existing local Rise acceptance fixtures. Player packages do not include this tool."""
import argparse
import csv
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import time
from uuid import uuid4

from platform_files import _reader, _dispose

TOOLS = Path(__file__).resolve().parent
FIXTURES = TOOLS.parent / "local-tests" / "mount-live"
GAME = Path("F:/SteamLibrary/steamapps/common/MonsterHunterRise")
DATA = Path("data/MHRS-Files-HotReload")
RUNS = FIXTURES / "qa-runs"
SCRIPTS = {
    "MHRS_mount_session.lua": FIXTURES / "session.lua",
    "MHRS_mount_identity.lua": FIXTURES / "identity.lua",
    "MHRS_mount_dye.lua": FIXTURES / "material-colors.lua",
    "MHRS_mount_weapon_qa.lua": FIXTURES / "MHRS_mount_weapon_qa.lua",
    "MHRS_visit_current.lua": FIXTURES.parent / "direct-live/visit-current.lua",
    "MHRS_test_quest_flow.lua": TOOLS / "rise_quest_flow.lua",
}
CHANNELS = ("quest-observe", "area-travel", "mount-state", "mount-identity", "mount-dye",
            "facility-visit", "mount-training-box-open", "mount-weapon-proof", "training-weapons-v3",
            "qa-quest-flow")
READY = ("mount-session-ready", "mount-dye-ready", "mount-weapon-qa-ready", "direct-visit-ready")


def channels():
    """Names reserved for this run. The timing recorder uses separate start/end receipts."""
    names = [f"{ch}-{suffix}.json" for ch in CHANNELS for suffix in ("request", "reply")]
    names += [name + ".json" for name in READY]
    names += [f"direct-timing-{suffix}.json" for suffix in ("request", "start", "end")]
    return names


def require_closed():
    output = subprocess.check_output(["tasklist", "/FI", "IMAGENAME eq MonsterHunterRise.exe",
                                      "/FO", "CSV", "/NH"], creationflags=subprocess.CREATE_NO_WINDOW)
    if any(row and row[0].casefold() == "monsterhunterrise.exe" for row in csv.reader(output.decode("mbcs").splitlines())):
        raise RuntimeError("Save and close MonsterHunterRise before staging or removing its autorun scripts.")


def checked(path):
    if path.resolve() != path.absolute() or path.is_symlink():
        raise RuntimeError(f"Unexpected redirected path: {path}")
    return path


def write_new(path, raw):
    with checked(path).open("xb") as handle:
        handle.write(raw)


def as_json(value):
    return json.dumps(value, ensure_ascii=False, indent=2).encode("utf8")


def stage(root, runs):
    require_closed()
    if checked(runs / "active.json").exists():
        raise FileExistsError("A QA session already exists. Resume that session or run clean after closing Rise.")
    if not (root / "autorun").is_dir() or not (root / DATA).is_dir() or not (root / "plugins/mhrs_hotreload.dll").is_file():
        raise RuntimeError("Expected an installed Rise REFramework and hot-reload player DLL.")
    inputs = {name: source.read_bytes() for name, source in SCRIPTS.items()}
    # This historical training bundle also bundled an older copy of identity.lua.
    # Leave identity ownership to the separately staged version with head/face checks.
    name = "MHRS_mount_weapon_qa.lua"
    bundle = inputs[name].decode("utf8").replace("\r\n", "\n")
    marker = ";(function()\n-- Sample one frame only when exchange.py sends a fresh mount-identity request."
    footer = 'json.dump_file("MHRS-Files-HotReload/mount-weapon-qa-ready.json",{ready=true})'
    if bundle.count(marker) != 1 or not bundle.rstrip().endswith(footer):
        raise RuntimeError("Review the changed equipment-box QA bundle before staging.")
    inputs[name] = (bundle.partition(marker)[0] + footer + "\n").encode("utf8")
    paths = [root / "autorun" / n for n in inputs]
    paths += [root / DATA / n for n in channels() + ["direct-stop.txt", "direct-visit-stop.txt"]]
    for path in paths:
        if checked(path).exists():
            raise FileExistsError(f"Existing QA file retained: {path}")
    token = uuid4().hex
    run = checked(runs / token)
    run.mkdir(parents=True)
    manifest = {"game": str(root), "run": token,
                "scripts": {n: hashlib.sha256(raw).hexdigest() for n, raw in inputs.items()}}
    write_new(run / "manifest.json", as_json(manifest))
    try:
        write_new(runs / "active.json", as_json(manifest))
    except FileExistsError:
        (run / "manifest.json").unlink()
        run.rmdir()
        raise
    # Stage the initially empty request slots before autorun can poll them.
    for n in channels():
        if n.endswith("-request.json"):
            write_new(root / DATA / n, b"{}")
    for n, raw in inputs.items():
        write_new(root / "autorun" / n, raw)
    print(f"Staged {len(inputs)} QA scripts. Start Rise normally. Run evidence: {run}")


def active(root, runs):
    m = json.loads(checked(runs / "active.json").read_bytes())
    if (m["game"] != str(root) or not re.fullmatch("[0-9a-f]{32}", m["run"]) or
            set(m["scripts"]) != set(SCRIPTS)):
        raise RuntimeError("Active QA session does not match this installation.")
    run = checked(runs / m["run"])
    if json.loads((run / "manifest.json").read_bytes()) != m:
        raise RuntimeError("QA session manifest changed.")
    return m, run


def legacy_records(folder, evidence, since):
    """Tie legacy runners' receipts to the current request and its original reply."""
    approved = {}
    if not evidence:
        return approved
    samples = []
    for directory in evidence:
        if not directory.is_dir():
            raise ValueError(f"Missing evidence directory: {directory}")
        for path in directory.rglob("*.json"):
            if path.is_symlink() or not path.is_file():
                continue
            stat = path.stat()
            if stat.st_mtime < since or stat.st_size > 5_000_000:
                continue
            try:
                samples.append((path, json.loads(path.read_bytes())))
            except (UnicodeError, ValueError):
                continue
    for ch in (*CHANNELS, "direct-timing"):
        req = f"{ch}-request.json"
        rep = f"{ch}-{'end' if ch == 'direct-timing' else 'reply'}.json"
        try:
            body = json.loads((folder / req).read_bytes())
            reply = json.loads((folder / rep).read_bytes())
        except (FileNotFoundError, UnicodeError, ValueError):
            continue
        if not isinstance(body, dict) or not isinstance(reply, dict):
            continue
        nonce = str(body.get("id", ""))
        if not re.fullmatch("[0-9a-f]{32}", nonce) or reply.get("id") != nonce:
            continue
        extra = {"file_operations_seconds", "elapsed_host_seconds", "post_copy_seconds", "post_publish_seconds"}
        matched = any(isinstance(v, dict) and v.get("id") == nonce and
                      (v == reply or (ch == "direct-timing" and {k:x for k,x in v.items() if k not in extra} == reply))
                      for _, v in samples)
        if not matched and ch == "training-weapons-v3":
            # training-box.py prints only response.data. The real grid selection
            # must match both the archived menu decision and a physical box item.
            before = body.get("before")
            choice = reply.get("data")
            if body.get("action") == "select-grid" and reply.get("ok") is True and isinstance(before, dict) and isinstance(choice, dict):
                target = before.get("target")
                idx = body.get("index")
                matches_choice = (choice == {"index": idx, "equipped": target} or
                                  choice == {"already_equipped": True, "state": before})
                menu = any(p.name.endswith("-menu.json") and v == choice for p,v in samples)
                inventory = [v.get("data", {}) for p,v in samples if p.name.endswith("-inventory.json") and isinstance(v, dict)]
                matched = (isinstance(target, dict) and idx == before.get("index") and matches_choice and menu and any(
                    row.get("box") == before.get("box") and row.get("target", {}).get("index") == idx and
                    row.get("target", {}).get("equipped") and row.get("target", {}).get("same") and
                    all(row["target"].get(k) == target.get(k) for k in ("id", "object", "label")) for row in inventory))
        if matched:
            approved[req], approved[rep] = body, reply
            if ch == "direct-timing":
                approved["direct-timing-start.json"] = {"id": nonce, "ok": True}
    return approved


def clean(root, runs, evidence=()):
    require_closed()
    m, run = active(root, runs)
    archive = checked(run / "retired")
    archive.mkdir(exist_ok=True)
    entries = [(root / "autorun" / n, h) for n, h in m["scripts"].items()]
    entries += [(root / DATA / n, None) for n in channels()]
    external = legacy_records(root / DATA, evidence, (run / "manifest.json").stat().st_mtime)
    retained = []
    for path, digest in entries:
        if not checked(path).exists():
            continue
        with _reader(path, can_delete=True) as handle:
            raw = handle.read()
            if digest and hashlib.sha256(raw).hexdigest() != digest:
                retained.append(path)
                continue
            if not digest:
                try:
                    record = json.loads(raw)
                except (UnicodeError, ValueError):
                    record = None
                if not owned_record(path, record, run) and (record is None or external.get(path.name) != record):
                    retained.append(path)
                    continue
            copy = archive / path.name
            if not copy.exists():
                write_new(copy, raw)
            if copy.read_bytes() != raw:
                raise RuntimeError(f"Archive verification failed: {copy}")
            _dispose(handle, path)
    print(f"Archived this session's autorun files and exchanges: {archive}")
    if retained:
        raise RuntimeError("Retained unverified files. Compare with your trace or matrix records:\n" +
                           "\n".join(str(path) for path in retained))
    (runs / "active.json").unlink()


def owned_record(path, record, run):
    if path.name.endswith("-request.json") and record == {}:
        return True
    if path.stem in READY:
        expected = {"ready": True, "version": 2} if path.stem == "mount-dye-ready" else {"ready": True}
        return record == expected
    if not isinstance(record, dict) or not re.fullmatch("[0-9a-f]{32}", str(record.get("id", ""))):
        return False
    channel, _, suffix = path.stem.rpartition("-")
    saved = run / f"{channel}-{record['id']}-{suffix}.json"
    return saved.is_file() and json.loads(saved.read_bytes()) == record


def exchange(root, run, channel, payload):
    body = {**payload, "id": uuid4().hex}
    folder = root / DATA
    slot = checked(folder / (channel + "-request.json"))
    temp = checked(folder / (body["id"] + ".tmp"))
    encoded = as_json(body)
    write_new(run / f"{channel}-{body['id']}-request.json", encoded)
    write_new(temp, encoded)
    try:
        deadline = time.monotonic() + 5
        while True:
            try:
                os.replace(temp, slot)
                break
            except PermissionError:
                if time.monotonic() >= deadline:
                    raise
                time.sleep(.05)
    finally:
        temp.unlink(missing_ok=True)
    deadline = time.monotonic() + 65
    while time.monotonic() < deadline:
        try:
            reply = json.loads((folder / (channel + "-reply.json")).read_bytes())
        except (FileNotFoundError, PermissionError, ValueError):
            reply = {}
        if isinstance(reply, dict) and reply.get("id") == body["id"] and reply.get("state") != "submitted":
            output = run / f"{channel}-{body['id']}-reply.json"
            write_new(output, as_json(reply))
            if reply.get("ok") is False or reply.get("state") in ("rejected", "timeout"):
                raise RuntimeError(f"{reply.get('error') or reply.get('reason') or reply} ({output})")
            print(output)
            return reply
        time.sleep(.1)
    raise RuntimeError(f"No matching {channel} receipt. Check the game screen and the REFramework log.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("stage", help="install the test scripts with Rise closed",
                   description="Close Rise before installing the local test scripts.")
    cleanup = sub.add_parser("clean", help="close Rise first; archive this session's verified scripts and records",
                             description="Save and close Rise first. Preserve unverified files and archive this session's verified records.")
    cleanup.add_argument("--records", type=Path, nargs="+", default=[], help="this run's legacy evidence directories, searched recursively")
    sub.add_parser("sample", help="capture the current local hunter and equipment")
    for name, help_text in (("counter", "approach Hinoa's village counter in area 0"),
                            ("box", "approach the training equipment box in area 5")):
        sub.add_parser(name, help=help_text, description=help_text)
    proof = sub.add_parser("weapon-proof", help="read the physical inventory slot and weapon objects in training")
    proof.add_argument("index", type=int, help="owned slot to inspect, e.g. 215 (original bow), 56 or 31")
    grid = sub.add_parser("select-grid", help="select one verified item in the already visible training equipment grid")
    grid.add_argument("index", type=int, help="owned slot in the current category; e.g. 31 for insect glaive or 215 for the original bow")
    travel = sub.add_parser("travel")
    for name in ("origin", "destination"):
        travel.add_argument(name, type=int, choices=range(6))
    for action in ("depart", "return"):
        sub.add_parser(action).add_argument("quest", type=int, choices=(101, 308))
    args = parser.parse_args()
    root = checked(GAME / "reframework")
    cmd = args.command
    if cmd == "stage":
        return stage(root, RUNS)
    if cmd == "clean":
        return clean(root, RUNS, args.records)
    _, run = active(root, RUNS)
    if cmd == "sample":
        result = exchange(root, run, "quest-observe", {"action": "sample"})["data"]
        print({k: result.get(k) for k in ("game_status", "area", "quest", "class", "hunter", "input", "wearer_roles", "member_count")})
    elif cmd == "travel":
        print(exchange(root, run, "area-travel", {"from": args.origin, "point": f"v01a0{args.destination}_00"}))
    elif cmd in ("counter", "box"):
        channel = "facility-visit" if cmd == "counter" else "mount-training-box-open"
        print(exchange(root, run, channel, {"action": cmd}))
    elif cmd == "weapon-proof":
        result = exchange(root, run, "mount-weapon-proof", {"index": args.index})["data"]
        print(json.dumps({k: result[k] for k in ("class", "kind", "root", "target", "original", "duplicate", "weapons")},
                         ensure_ascii=False, indent=2))
    elif cmd == "select-grid":
        # The same two requests used by quest-live/training-box.py, retaining both nonces.
        inventory = json.loads((FIXTURES.parent / "quest-live/owned-weapons-confirmed.json").read_bytes())
        expected = next((w for w in inventory["weapons"] if w["index"] == args.index), None)
        if expected is None:
            raise ValueError(f"No verified weapon fixture for slot {args.index}.")
        payload = {"action": "observe", "index": args.index, "before": None}
        before = exchange(root, run, "training-weapons-v3", payload)["data"]
        if any(before["target"][k] != expected[k] for k in ("id", "label")):
            raise ValueError(f"The contents of slot {args.index} have changed.")
        result = exchange(root, run, "training-weapons-v3", {**payload, "action": "select-grid", "before": before})
        print(result["data"])
    else:
        current = exchange(root, run, "qa-quest-flow", {"action": "inspect"})["data"]
        if current["quest"] != args.quest:
            raise ValueError(f"Requested quest {args.quest}, game reports {current}")
        result = exchange(root, run, "qa-quest-flow", {**current, "action": cmd})
        print(result["data"], "Continue through the game's confirmation or results screen.")


if __name__ == "__main__":
    main()
