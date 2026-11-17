"""Build the single-DLL player package from pinned Windows x64 dependencies."""
import hashlib
import json
import shutil
import subprocess
import tempfile
import urllib.request
import zipfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / "native/build"
DATA = Path("reframework/data/MHRS-Files-HotReload")
PYTHON_ARCHIVE = "cpython-3.12.2%2B20240224-x86_64-pc-windows-msvc-static-noopt-full.tar.zst"
PYTHON_URL = "https://github.com/astral-sh/python-build-standalone/releases/download/20240224/" + PYTHON_ARCHIVE
PYTHON_SHA256 = "e037ede1f5f5a5c7d44a8514d63cc09f5d0e5ee61f14fce7726309a941620c2f"
REF_REVISION = "c4b1314820d20255febf7834903e8cedb669b49c"
REF_URL = "https://github.com/praydog/REFramework.git"
ZSTD_URL = "https://github.com/facebook/zstd/releases/download/v1.5.7/zstd-1.5.7.tar.gz"
ZSTD_SHA256 = "eb33e51f49a15e023950cd7825ca74a4a2b43db8354825ac24fc1b7ee09e6fa3"


def get_archive(destination, url, sha256, archive_root):
    dest = BUILD / destination
    if not dest.is_dir():
        with tempfile.TemporaryDirectory(dir=BUILD) as staging:
            stage = Path(staging)
            archive = stage / "download.tar"
            with urllib.request.urlopen(url, timeout=120) as response, archive.open("wb") as file:
                shutil.copyfileobj(response, file)
            with archive.open("rb") as file:
                if hashlib.file_digest(file, "sha256").hexdigest() != sha256:
                    raise ValueError(f"Archive checksum mismatch: {url}")
            subprocess.run(["tar", "-xf", str(archive), "-C", str(stage)], check=True)
            (stage / archive_root).rename(dest)
    return dest


def get_reframework():
    dest = BUILD / ("reframework-" + REF_REVISION[:12])
    if not dest.is_dir():
        with tempfile.TemporaryDirectory(dir=BUILD) as staging:
            stage = Path(staging) / "source"
            subprocess.run(["git", "init", "--quiet", str(stage)], check=True)
            git = ["git", "-C", str(stage)]
            subprocess.run([*git, "remote", "add", "origin", REF_URL], check=True)
            subprocess.run([*git, "sparse-checkout", "set", "dependencies/lua", "include/reframework"], check=True)
            subprocess.run([*git, "fetch", "--depth=1", "--filter=blob:none", "origin", REF_REVISION], check=True)
            subprocess.run([*git, "checkout", "--detach", "FETCH_HEAD"], check=True)
            stage.rename(dest)
    return dest


def build(output, python_sdk=None, reframework_source=None, verify=False, texture=None, zstd_source=None):
    BUILD.mkdir(exist_ok=True)
    sdk = Path(python_sdk).resolve() if python_sdk else get_archive(
        "cpython-static-20240224", PYTHON_URL, PYTHON_SHA256, "python")
    zstd = Path(zstd_source).resolve() if zstd_source else get_archive(
        "zstd-1.5.7", ZSTD_URL, ZSTD_SHA256, "zstd-1.5.7")
    ref = Path(reframework_source).resolve() if reframework_source else get_reframework()
    info = json.loads((sdk / "PYTHON.json").read_bytes())
    if (info["python_version"], info["target_triple"], info["crt_features"]) != (
            "3.12.2", "x86_64-pc-windows-msvc", ["static"]):
        raise ValueError("Expected the pinned 20240224 static CPython 3.12.2 Windows x64 SDK")
    revision = subprocess.check_output(["git", "-C", str(ref), "rev-parse", "HEAD"], text=True).strip()
    if revision != REF_REVISION:
        raise ValueError(f"Expected REFramework at {REF_REVISION}, found {revision}")

    output = Path(output).resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as scratch:
        work = Path(scratch)
        subprocess.run([str(sdk / "install/python.exe"), "-IB", str(ROOT / "tools/embedded_payload.py"),
                        str(sdk), str(work)], check=True)
        command = [str(ROOT / "native/embedded/build.cmd"), str(sdk), str(ref), str(work), str(zstd)]
        if verify:
            command.append("verify")
        subprocess.run(command, check=True)
        if verify:
            from test_embedded_player import verify as check_player
            check_player(work, texture)
        license_dir = DATA / "licenses"
        files = {
            ROOT / "modinfo.ini": Path("modinfo.ini"),
            work / "mhrs_hotreload.dll": Path("reframework/plugins/mhrs_hotreload.dll"),
            ROOT / DATA / "THIRD_PARTY_NOTICES.md": DATA / "THIRD_PARTY_NOTICES.md",
            ROOT / license_dir / "MHWS-Files-HotReload-LICENSE.txt": license_dir / "MHWS-Files-HotReload-LICENSE.txt",
            ROOT / license_dir / "Unicode-LICENSE.txt": license_dir / "Unicode-LICENSE.txt",
            ref / "LICENSE": license_dir / "REFramework-LICENSE.txt",
            zstd / "LICENSE": license_dir / "Zstandard-LICENSE.txt",
            # The Lua header carries the copyright and permission notice of this exact version.
            ref / "dependencies/lua/src/lua.h": license_dir / "Lua-5.4.3-notice.txt",
            sdk / "install/LICENSE.txt": license_dir / "Python-LICENSE.txt",
        }
        for lib in ("cpython", "libffi", "libuuid", "zlib"):
            filename = f"LICENSE.{lib}.txt"
            files[sdk / "licenses" / filename] = license_dir / filename
        with tempfile.TemporaryDirectory(dir=output.parent) as staging:
            archive = Path(staging) / output.name
            with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as package:
                for src, entry in sorted(files.items(), key=lambda pair: pair[1]):
                    package.write(src, entry.as_posix())
            with zipfile.ZipFile(archive) as package:
                if package.testzip():
                    raise ValueError("Corrupt player package")
            archive.replace(output)
