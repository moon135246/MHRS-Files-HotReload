"""Freeze the watcher with the same CPython that is linked into the DLL."""
import argparse
import ast
import json
import marshal
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
TOOLS = ROOT / "tools"
EXTENSIONS = {"_ctypes", "_uuid", "unicodedata"}


def watcher_sources():
    sources = {}
    pending = ["embedded_worker"]
    while pending:
        name = pending.pop()
        source = TOOLS / (name + ".py")
        if name in sources or not source.is_file():
            continue
        sources[name] = (source, False)
        for node in ast.walk(ast.parse(source.read_bytes(), filename=str(source))):
            if isinstance(node, ast.ImportFrom) and node.module:
                pending.append(node.module.split(".")[0])
            elif isinstance(node, ast.Import):
                pending.extend(alias.name.split(".")[0] for alias in node.names)
    return sources


def freeze(sdk, work):
    lib = sdk / "install/Lib"
    sources = {p.stem: (p, False) for p in lib.glob("*.py")}
    for package in ("collections", "concurrent", "ctypes", "encodings", "importlib", "json", "logging", "re", "urllib"):
        for source in (lib / package).rglob("*.py"):
            parts = list(source.relative_to(lib).with_suffix("").parts)
            if "test" in parts:
                continue
            is_package = parts[-1] == "__init__"
            if is_package:
                parts.pop()
            sources[".".join(parts)] = (source, is_package)
    sources.update(watcher_sources())
    table = []
    with (work / "bytecode.bin").open("wb") as blob:
        for name, (source, is_package) in sorted(sources.items()):
            text = source.read_bytes()
            if name == "ctypes":
                # This pinned static SDK's ctypes reopens sys.executable to
                # access the Python C API. The watcher only uses Win32 APIs.
                original = b"pythonapi = PyDLL(_sys.executable)"
                if text.count(original) != 1:
                    raise ValueError("Unexpected static SDK ctypes module")
                text = text.replace(original, b"pythonapi = None")
            code = marshal.dumps(compile(text, f"<embedded:{name}>", "exec", optimize=1))
            table.append(f'{{"{name}", bytecode + {blob.tell()}, {len(code)}, {int(is_package)}, nullptr}},')
            blob.write(code)
    (work / "frozen.inc").write_text("\n".join(table), "utf-8")


def prepare(sdk, work):
    freeze(sdk, work)
    autorun = ROOT / "reframework/autorun"
    chunks = []
    for file in sorted((autorun / "MHRS_HotReload").glob("*.lua")):
        chunks.append(f'package.preload["MHRS_HotReload.{file.stem}"] = function(...)\n'
                      + file.read_text("utf-8") + "\nend\n")
    chunks.append((autorun / "MHRS_Files_HotReload.lua").read_text("utf-8"))
    (work / "script.lua").write_text("\n".join(chunks), "utf-8")

    # Compile the SDK's core builtin table with only the extension libraries
    # used here. Linking its default table would pull in OpenSSL, SQLite, etc.
    info = json.loads((sdk / "PYTHON.json").read_bytes())["build_info"]
    excluded = {name for name, ext in info["extensions"].items()
                if not ext[0]["in_core"] and name not in EXTENSIONS}
    config = (sdk / info["inittab_source"]).read_text("utf-8")
    for name in sorted(excluded):
        init = info["extensions"][name][0]["init_fn"]
        entry = f'{{"{name}", {init}}},'
        if config.count(entry) != 1:
            raise ValueError(f"Unexpected SDK builtin entry for {name}")
        config = config.replace(entry, "")
    # Use CPython's documented freeze insertion points for our linked codec.
    for marker, line in (('/* -- ADDMODULE MARKER 1 -- */', 'extern PyObject* PyInit__mhrs_pak(void);'),
                         ('/* -- ADDMODULE MARKER 2 -- */', '{"_mhrs_pak", PyInit__mhrs_pak},')):
        if config.count(marker) != 1:
            raise ValueError(f"Expected the CPython SDK builtin module marker: {marker}")
        config = config.replace(marker, line + "\n" + marker)
    (work / "config.c").write_text(config, "utf-8")
    assets = [work / "bytecode.bin", TOOLS / "rise-16.0.2-links.json.gz",
              TOOLS / "rise-16.0.2-shaders.json.gz", work / "script.lua"]
    resources = [f'{n} RCDATA "{p.as_posix()}"' for n, p in enumerate(assets, 101)]
    (work / "payload.rc").write_text('#pragma code_page(65001)\n' + "\n".join(resources), "utf-8-sig")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("sdk", type=Path)
    parser.add_argument("work", type=Path)
    args = parser.parse_args()
    prepare(args.sdk.resolve(), args.work.resolve())
