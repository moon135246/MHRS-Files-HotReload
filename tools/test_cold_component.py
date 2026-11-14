"""Round-trip a previously unused Rise resource on a disposable scene component."""
import argparse
import json
import sys
import time
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_arm279 import replace


SUFFIX = {"mesh": ".mesh.2109148288", "chain": ".chain.48", "motbank": ".motbank.3",
          "uvar": ".uvar.3", "fbxskel": ".fbxskel.4", "rtex": ".rtex.5"}


def request(channel, operation, **arguments):
    token = uuid.uuid4().hex
    replace(channel / "cold-request.json", json.dumps(dict(id=token, op=operation, **arguments)).encode())
    deadline = time.monotonic() + 8
    while time.monotonic() < deadline:
        time.sleep(0.1)
        try:
            reply = json.loads((channel / "cold-reply.json").read_bytes())
        except (OSError, ValueError):
            continue
        if reply.get("id") == token:
            if not reply["ok"]:
                raise RuntimeError(reply["result"])
            return reply["result"]
    raise TimeoutError("No reply from cold_component_probe.lua")


def run(game, log, kind, source, alternate):
    suffix = SUFFIX[kind]
    if not all(p.name.lower().endswith(suffix) for p in (source, alternate)):
        raise ValueError("Expected two compatible " + suffix + " inputs")
    a, b = source.read_bytes(), alternate.read_bytes()
    if a == b:
        raise ValueError("The original and alternate files have identical content")
    token = uuid.uuid4().hex
    path = f"mhrs_cold/{token}/sample.{kind}"
    target = game / "natives/stm" / (path + suffix[suffix.rindex("."):])
    channel = game / "reframework/data/MHRS-Files-HotReload"
    output = Path("local-tests") / ("component-" + token + ".json")
    report = {"path": path, "kind": kind}
    request(channel, "ping")
    target.parent.mkdir(parents=True, exist_ok=False)
    output.parent.mkdir(exist_ok=True)
    try:
        with target.open("xb") as stream:
            stream.write(a)
        time.sleep(1.5)
        request(channel, "attach", path=path, kind=kind)
        time.sleep(0.8)
        first = report["first"] = request(channel, "read")
        if first["path"].lower() != path:
            raise RuntimeError("Initial holder did not take the new path")
        previous = first
        for phase, data in (("changed", b), ("restored", a)):
            pos = log.stat().st_size
            replace(target, data)
            deadline = time.monotonic() + 20
            while time.monotonic() < deadline:
                time.sleep(0.15)
                with log.open("rb") as stream:
                    stream.seek(pos)
                    lines = stream.read().decode(errors="replace").splitlines()
                if any(line.startswith("Bound " + path + " ") for line in lines):
                    break
            else:
                raise TimeoutError(f"No binding receipt for {path}: {lines}")
            row = report[phase] = request(channel, "read")
            if row["component"] != first["component"] or row["path"].lower() != path or row["resource"] == previous["resource"]:
                raise RuntimeError("Binding readback failed")
            previous = row
    finally:
        try:
            request(channel, "clear")
        finally:
            if target.is_file() and target.read_bytes() in (a, b):
                target.unlink()
            if not any(target.parent.iterdir()):
                target.parent.rmdir()
            output.write_text(json.dumps(report, indent=2), encoding="utf-8")
            print(output)


if __name__ == "__main__":
    cli = argparse.ArgumentParser(description=__doc__)
    cli.add_argument("game", type=Path)
    cli.add_argument("watch_log", type=Path)
    cli.add_argument("kind", choices=SUFFIX)
    cli.add_argument("original", type=Path)
    cli.add_argument("alternate", type=Path)
    args = cli.parse_args()
    run(args.game, args.watch_log, args.kind, args.original, args.alternate)
