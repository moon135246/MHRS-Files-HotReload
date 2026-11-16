"""Read the loose armor physics and helmet settings used to verify a live reload."""
import re
import struct
from pathlib import Path

from helm_user import UnsupportedHelmLayout, decode


_armor = re.compile(r"^player/mod/[fm]/pl\d+/[fm]_(?:arm|body|helm|leg|wst)\d+\.chain$")
_helm = re.compile(r"^player/mod/[fm]/pl\d+/[fm]_helm\d+\.user$")


def is_equipment_physics(path):
    key = path.lower()
    return bool(_armor.fullmatch(key) or _helm.fullmatch(key))


def chain_groups(data, path):
    if len(data) < 104 or data[:8] != b"\x30\0\0\0chan":
        raise ValueError(f"Invalid Rise v48 chain: {path}")
    return data[72]


def chain_terminals(data, path):
    """Read the UTF-16 terminal joint of each Rise v48 group."""
    count = chain_groups(data, path)
    table, = struct.unpack_from("<Q", data, 40)
    if count and (table < 104 or table + count * 112 > len(data)):
        raise ValueError(f"Incomplete chain group table: {path}")
    names = []
    for index in range(count):
        offset, = struct.unpack_from("<Q", data, table + index * 112)
        if offset < 104 or offset % 2 or offset >= len(data):
            raise ValueError(f"Invalid chain terminal offset in group {index}: {path}")
        end = offset
        while end + 2 <= len(data) and data[end:end + 2] != b"\0\0":
            end += 2
        if offset == end or end + 2 > len(data):
            raise ValueError(f"Missing chain terminal in group {index}: {path}")
        names.append(data[offset:end].decode("utf-16-le"))
    return names


def physics_expectations(paths, current, original):
    chains, helmets, terminals = {}, {}, {}
    for file, path in paths.items():
        key = path.lower()
        if not is_equipment_physics(key):
            continue
        data = Path(file).read_bytes() if file in current else original(file)
        if key.endswith(".chain"):
            chains[key] = chain_groups(data, path) if data is not None else False
            if data is not None:
                terminals[key] = chain_terminals(data, path)
        else:
            entry = {"removed": file not in current}
            if data is not None:
                try:
                    values = decode(data)
                except UnsupportedHelmLayout as error:
                    entry["deferred"] = True
                    print("Helmet USER fields deferred until normal re-equip:", path, str(error), flush=True)
                else:
                    entry["fields"] = [
                        dict(section=s, index=i, field=f, element=j, value=v)
                        for (s, i, f, j), v in values.items()]
            helmets[key] = entry
    return {"chains": chains, "helmets": helmets, "chain_terminals": terminals}
