"""Build the hot-reload-compatible Rise Lua Bone System v2 from the supplied original ZIP."""
import argparse
import hashlib
from pathlib import Path
import tempfile
import zipfile


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = "reframework/autorun/LuaBoneSystem.lua"
INPUTS = {
    SCRIPT: "e637eef9298f4dbafcf8293ea418cbe1b2bc699ef465df6ff9663f4560ba10b7",
    "reframework/data/LUABoneSystem/base/f_shadow.json": "ac6ffc44b421ad4b076cc30080f91ed1be980cc62249917849c3eb7208d6ebab",
    "reframework/data/LUABoneSystem/base/m_shadow.json": "115a034b5ada416f84928e56475b8eb1cdad73da72146d7b80562c4e5b0f0129",
}


def patch_script(raw):
    if hashlib.sha256(raw).hexdigest() != INPUTS[SCRIPT]:
        raise ValueError("Expected the supplied v2 pose-fix Lua script")
    lua = raw.decode("utf-8").replace("\r\n", "\n")
    helper = (ROOT / "compat/lua-bone-system/profile_changes.lua").read_text("utf-8")

    def replace_once(before, after):
        nonlocal lua
        if lua.count(before) != 1:
            raise ValueError("Unexpected original Lua Bone System source block: " + before[:60])
        lua = lua.replace(before, after)

    replace_once("local ik_pending = {}\n", "local ik_pending = {}\n" + helper + "\n")
    replace_once('re.on_application_entry("UpdateMotion", function()\n',
                 're.on_application_entry("UpdateMotion", function()\n\treceive_profiles()\n')
    begin = lua.index("\t\tif part_changed then\n")
    end = lua.index("\t\t::continue::", begin)
    replace_once(lua[begin:end],
                 "\t\trefresh_player_profile(player_index, player_transform, player_parts, part_changed)\n")
    replace_once("if player_joint[player_index] == nil then",
                 "if not import_joint_data[player_joint[player_index]] then")
    replace_once("local newOffset = import_joint_data[player_joint[player_index]][joint:get_Name()]",
                 "local newOffset = import_joint_data[player_joint[player_index]][joint:get_Name()] or zero_position")
    return lua.replace("\n", "\r\n").encode("utf-8")


def build(source, dest):
    if source.resolve() == dest.resolve():
        raise ValueError("Keep the original ZIP and write a separate compatibility package")
    with zipfile.ZipFile(source) as original:
        files = [f.filename for f in original.infolist() if not f.is_dir()]
        if sorted(files) != sorted(INPUTS):
            raise ValueError("Unexpected v2 ZIP contents")
        contents = {name: original.read(name) for name in files}
    for name, expected in INPUTS.items():
        if hashlib.sha256(contents[name]).hexdigest() != expected:
            raise ValueError("Unexpected v2 file: " + name)
    contents[SCRIPT] = patch_script(contents[SCRIPT])
    dest.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=dest.parent) as staging:
        temp = Path(staging) / "bundle.zip"
        with zipfile.ZipFile(temp, "w") as archive:
            for name, payload in contents.items():
                entry = zipfile.ZipInfo(name, date_time=(2026, 11, 16, 0, 0, 0))
                archive.writestr(entry, payload, compress_type=zipfile.ZIP_DEFLATED, compresslevel=9)
        with zipfile.ZipFile(temp) as archive:
            if any(archive.read(name) != data for name, data in contents.items()):
                raise ValueError("Compatibility package verification failed")
        temp.replace(dest)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("original", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    build(args.original, args.output)
