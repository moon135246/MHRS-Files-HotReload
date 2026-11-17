"""Build the Windows x64 Fluffy package with its in-process watcher."""
import argparse
import subprocess
import sys
import tempfile
import zipfile
from importlib.metadata import distribution
from pathlib import Path
from build_embedded import build


ROOT = Path(__file__).resolve().parents[1]
DATA = Path("reframework/data/MHRS-Files-HotReload")


def build_external(output):
    zstd = distribution("zstandard")
    output.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run([str(ROOT / "native/build.cmd")], check=True, cwd=ROOT)
    with tempfile.TemporaryDirectory() as scratch:
        work = Path(scratch)
        command = [sys.executable, "-m", "PyInstaller", "--noconfirm", "--onefile",
                   "--name", "MHRS-Watcher", "--distpath", str(work / "dist"),
                   "--workpath", str(work / "build"), "--specpath", str(work)]
        for index in ("rise-16.0.2-links.json.gz", "rise-16.0.2-shaders.json.gz"):
            command.extend(["--add-data", f"{ROOT / 'tools' / index};."])
        subprocess.run([*command, str(ROOT / "tools/player_watcher.py")], check=True, cwd=ROOT)
        pack_files = {
            p: p.relative_to(ROOT) for p in (ROOT / "reframework/autorun").rglob("*.lua")
        }
        for name in ("mhrs_hotreload.dll", "THIRD_PARTY_NOTICES.md",
                     "licenses/MHWS-Files-HotReload-LICENSE.txt", "licenses/Zstandard-LICENSE.txt"):
            pack_files[ROOT / DATA / name] = DATA / name
        pack_files[ROOT / "modinfo.ini"] = Path("modinfo.ini")
        pack_files[work / "dist/MHRS-Watcher.exe"] = DATA / "MHRS-Watcher.exe"
        pack_files[Path(sys.base_prefix) / "LICENSE.txt"] = DATA / "licenses/Python-LICENSE.txt"
        pyinstaller = distribution("PyInstaller")
        license_path = next(p for p in pyinstaller.files if p.name == "COPYING.txt" and ".dist-info" in str(p))
        pack_files[pyinstaller.locate_file(license_path)] = DATA / "licenses/PyInstaller-COPYING.txt"
        zstd_license = next(p for p in zstd.files if p.name == "LICENSE" and ".dist-info" in str(p))
        pack_files[zstd.locate_file(zstd_license)] = DATA / "licenses/python-zstandard-LICENSE.txt"
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
    parser.add_argument("--external-watcher", action="store_true",
                        help="Build the development fallback using PyInstaller 6")
    parser.add_argument("--python-sdk", type=Path, help="Local extracted static Windows SDK")
    parser.add_argument("--reframework-source", type=Path, help="Local pinned REFramework checkout")
    parser.add_argument("--zstd-source", type=Path, help="Local extracted Zstandard 1.5.7 release")
    parser.add_argument("--verify", action="store_true", help="Verify the embedded watcher in an isolated host")
    parser.add_argument("--verify-texture", type=Path, help="Use this TEX in the embedded verification")
    args = parser.parse_args()
    if args.external_watcher:
        build_external(args.output.resolve())
    else:
        build(args.output, args.python_sdk, args.reframework_source,
              args.verify or bool(args.verify_texture), args.verify_texture, args.zstd_source)
