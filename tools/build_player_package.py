"""Build the Windows x64 Fluffy package with Python 3.12 and PyInstaller 6."""
import argparse
import subprocess
import sys
import tempfile
import zipfile
from importlib.metadata import distribution
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
DATA = Path("reframework/data/MHRS-Files-HotReload")


def build(output):
    output.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run([str(ROOT / "native/build.cmd"), "request-watch"], check=True, cwd=ROOT)
    with tempfile.TemporaryDirectory() as scratch:
        work = Path(scratch)
        command = [sys.executable, "-m", "PyInstaller", "--noconfirm", "--onedir",
                   "--name", "MHRS-Watcher", "--distpath", str(work / "dist"),
                   "--workpath", str(work / "build"), "--specpath", str(work)]
        for index in ("rise-16.0.2-links.json.gz", "rise-16.0.2-shaders.json.gz"):
            command.extend(["--add-data", f"{ROOT / 'tools' / index};."])
        subprocess.run([*command, str(ROOT / "tools/player_watcher.py")], check=True, cwd=ROOT)
        watcher = work / "dist/MHRS-Watcher"
        pack_files = {
            p: p.relative_to(ROOT) for p in (ROOT / "reframework/autorun").rglob("*.lua")
        }
        for name in ("arm_material.dll", "request_watch.dll", "THIRD_PARTY_NOTICES.md",
                     "licenses/MHWS-Files-HotReload-LICENSE.txt"):
            pack_files[ROOT / DATA / name] = DATA / name
        pack_files[ROOT / "modinfo.ini"] = Path("modinfo.ini")
        for p in watcher.rglob("*"):
            if p.is_file():
                pack_files[p] = DATA / "watcher" / p.relative_to(watcher)
        pack_files[Path(sys.base_prefix) / "LICENSE.txt"] = DATA / "licenses/Python-LICENSE.txt"
        pyinstaller = distribution("PyInstaller")
        license_path = next(p for p in pyinstaller.files if p.name == "COPYING.txt" and ".dist-info" in str(p))
        pack_files[pyinstaller.locate_file(license_path)] = DATA / "licenses/PyInstaller-COPYING.txt"
        with tempfile.TemporaryDirectory(dir=output.parent) as staging:
            archive = Path(staging) / output.name
            with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as package:
                for source, entry in sorted(pack_files.items(), key=lambda pair: pair[1]):
                    package.write(source, entry.as_posix())
            with zipfile.ZipFile(archive) as package:
                if package.testzip():
                    raise ValueError("Corrupt player package")
            archive.replace(output)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    build(parser.parse_args().output.resolve())
