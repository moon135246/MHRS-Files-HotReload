"""Exercise the plugin entry point, file lifecycle and IPC in an isolated Windows host."""
import hashlib
import json
import os
import shutil
import struct
import subprocess
import time
from pathlib import Path


def verify(work, texture=None):
    game = Path(work) / "mock-game"
    plugin = game / "reframework/plugins/mhrs_hotreload.dll"
    plugin.parent.mkdir(parents=True)
    shutil.copyfile(Path(work) / plugin.name, plugin)
    channel = game / "reframework/data/MHRS-Files-HotReload"
    log = channel / "watcher.log"
    startup_path = "player/mod/f/pl279/embedded_startup.tex"
    startup = game / "natives/stm" / (startup_path + ".28")
    startup.parent.mkdir(parents=True)
    startup.write_bytes(b"loose startup texture fixture")
    stock = b"TEX\0\x1c\0\0\0" + b"packaged texture fixture" * 8
    # A fixed Zstandard frame and filename hash keep verification independent of any local codec.
    frame = bytes.fromhex("28b52ffd24c8250100d8544558001c0000007061636b6167656420746578"
                          "747572652066690200a59d045e5bc6613c1d4a")
    header = struct.pack("<4sBBHII", b"KPKA", 4, 0, 0, 1, 0)
    entry = struct.pack("<6Q", 0xd662acec092df8c9, 64, len(frame), len(stock), 2, 0)
    (game / "re_chunk_000.pak").write_bytes(header + entry + frame)
    temp = game / "temp"
    temp.mkdir()
    env = {**os.environ, "TEMP": str(temp), "TMP": str(temp), "PYTHONHOME": "invalid"}
    process = subprocess.Popen([str(Path(work) / "test_host.exe")], cwd=game, env=env,
                               creationflags=subprocess.CREATE_NO_WINDOW,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    seen = set()
    retired_platform_paths = []

    def wait(check, label):
        deadline = time.monotonic() + 12
        while not check():
            if process.poll() is not None:
                raise RuntimeError(f"Embedded host exited {process.returncode}: {process.communicate()}")
            if time.monotonic() >= deadline:
                detail = log.read_text("utf-8") if log.is_file() else "watcher.log absent"
                raise TimeoutError(f"{label}\n{detail}")
            time.sleep(.025)

    def logged(text):
        return log.is_file() and text in log.read_text("utf-8")

    def service_until(line):
        request = channel / "request.json"
        if request.is_file():
            try:
                data = json.loads(request.read_bytes())
            except (ValueError, OSError):
                return False
            if data["id"] not in seen:
                seen.add(data["id"])
                if data["action"] == "asset_material_links":
                    result = {"links": []}
                elif data["action"] == "asset_removed":
                    retired_platform_paths.append(data["platform_files"])
                    result = {"results": [{"path": p, "state": "mock-visible"} for p in data["paths"]]}
                else:
                    raise ValueError(f"Unexpected request {data['action']}")
                reply = channel / "reply.tmp"
                reply.write_text(json.dumps({"id": data["id"], "ok": True, "result": result}), "utf-8")
                os.replace(reply, channel / "status.json")
        return logged(line)

    try:
        wait(lambda: logged("Watching 1"), "Embedded watcher startup")
        assert logged(f"In-process watcher PID {process.pid}")
        logical = "player/mod/f/pl279/embedded_fixture.tex"
        ordinary = game / "natives/stm" / (logical + ".28")
        # Staging treats TEX as opaque. Supply --verify-texture for an actual game texture.
        contents = Path(texture).read_bytes() if texture else b"opaque TEX staging fixture"
        ordinary.write_bytes(contents)
        wait(lambda: service_until(f"Added {logical}"), "First addition")
        platform = ordinary.with_suffix(".28.stm")
        assert platform.read_bytes() == contents
        records = list((channel / "platform-files").glob("*.json"))
        assert len(records) == 1
        assert json.loads(records[0].read_bytes())["owner"]["sha256"] == hashlib.sha256(contents).hexdigest()
        assert [logical] in retired_platform_paths
        ordinary.unlink()
        wait(lambda: service_until(f"Removed {logical}"), "Removal")
        assert not platform.exists() and not list((channel / "platform-files").glob("*.json"))
        # A directory rename publishes a whole costume generation at once.
        # This also exercises the worker threads inside the frozen interpreter.
        batch = ordinary.parent / "embedded_batch"
        incoming = game / "incoming"
        incoming.mkdir()
        names = [f"part{i}.tex" for i in range(8)]
        for name in names:
            (incoming / (name + ".28")).write_bytes(name.encode())
        incoming.rename(batch)
        logical_batch = ["player/mod/f/pl279/embedded_batch/" + name for name in names]
        wait(lambda: service_until("Added " + logical_batch[-1]), "Batched TEX addition")
        assert logical_batch in retired_platform_paths
        for name in names:
            ordinary_part = batch / (name + ".28")
            assert ordinary_part.with_suffix(".28.stm").samefile(ordinary_part)
            ordinary_part.unlink()
        wait(lambda: service_until("Removed " + logical_batch[-1]), "Batched TEX removal")
        assert not list(batch.iterdir())
        startup.unlink()
        wait(lambda: service_until(f"Removed {startup_path}"), "Removal of startup override")
        assert [startup_path] in retired_platform_paths
        assert startup.with_suffix(".28.stm").read_bytes() == stock
        (game / "pause.test").touch()
        wait(lambda: logged("Watcher stopped"), "Pause")
        (game / "resume.test").touch()
        wait(lambda: logged("Watching 0") and not logged("Watcher stopped"), "Resume")
        (game / "exit.test").touch()
        stdout, stderr = process.communicate(timeout=8)
        assert process.returncode == 0, (process.returncode, stdout, stderr)
        assert not list(temp.iterdir())
        print(f"Embedded host {process.pid}: cold add, parallel costume files, SHA-256, removal, Zstandard PAK rollback, "
              "Lua reset and shutdown passed")
    finally:
        if process.poll() is None:
            process.terminate()
            process.communicate()
