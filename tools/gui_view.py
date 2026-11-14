"""Read scalar root View properties from Rise GUIR 430033."""
import math
import re
import struct


def view_fields(data, *, children=False):
    def pointer(offset):
        if not 0 <= offset <= len(data) - 8:
            raise ValueError("Invalid GUI offset")
        return struct.unpack_from("<Q", data, offset)[0]

    def name(offset):
        end = data.find(b"\0", offset, offset + 256)
        if end < 0:
            raise ValueError("Invalid GUI property name")
        return data[offset:end].decode("ascii")

    if len(data) < 56 or struct.unpack_from("<I4s", data) != (430033, b"GUIR"):
        raise ValueError("Expected Rise GUIR 430033")
    root = pointer(pointer(8) + 8)
    if name(pointer(root + 56)) != "via.gui.View":
        raise ValueError("Unsupported GUI root")
    fields = {}
    _properties(data, pointer, name, root, fields, "")
    if children:
        # An object record identifies its class, UTF-16 name and property table.
        # Only accept exact class strings, in-bounds aligned records and unique identities.
        classes = {m.start(): m[0][:-1].decode("ascii") for m in re.finditer(rb"via\.gui\.[A-Za-z0-9_]+\x00", data)}
        ambiguous = set()
        seen = set()
        end_of_records = pointer(16)
        if not root < end_of_records <= len(data):
            raise ValueError("Invalid GUI record section")
        for obj in range(root + 8, end_of_records - 104, 8):
            cls = classes.get(pointer(obj + 56))
            if not cls:
                continue
            start = pointer(obj + 48)
            end = start
            while end + 1 < min(len(data), start + 512) and data[end:end+2] != b"\0\0":
                end += 2
            if end == start or end + 1 >= len(data) or data[end:end+2] != b"\0\0":
                continue
            identity = data[start:end].decode("utf-16-le")
            if "|" in identity:
                continue
            prefix = f"{cls}|{identity}|"
            if prefix in seen:
                ambiguous.add(prefix)
                continue
            seen.add(prefix)
            if pointer(obj + 64):
                _properties(data, pointer, name, obj, fields, prefix)
        if ambiguous:
            fields = {k:v for k,v in fields.items() if k.rpartition("|")[0]+"|" not in ambiguous}
    return fields


def _properties(data, pointer, name, obj, fields, prefix):
    table = pointer(obj + 64)
    count = pointer(table)
    if count > 2048 or table + 8 + 32 * count > len(data):
        raise ValueError("Invalid GUI View property table")
    for i in range(count):
        record = table + 8 + i * 32
        kind, mask = struct.unpack_from("<Ii", data, record)
        key = name(pointer(record + 8))
        if mask != -1:
            continue
        offset = record + 16
        if key in {"Visible", "HitVisible", "Overlay", "DepthTest", "StencilTest",
                   "GUISortTarget", "Detonemap", "DegammaVertexColor", "UseGUIPostImage"} and kind == 1:
            value = pointer(offset)
            if value > 1:
                raise ValueError("Invalid GUI boolean")
            value = bool(value)
        elif key == "BaseFps" and kind == 10:
            value = struct.unpack_from("<d", data, offset)[0]
            if not math.isfinite(value) or value <= 0 or value > 1000:
                raise ValueError("Invalid GUI frame rate")
        elif key == "Priority" and kind == 5:
            value = pointer(offset)
            if value > 65535:
                raise ValueError("Invalid GUI priority")
        else:
            continue
        fields[prefix + key] = (offset, value)


def view_diff(previous, current):
    if len(previous) != len(current):
        raise ValueError("GUI layout changed")
    old = view_fields(previous, children=True)
    new = view_fields(current, children=True)
    if old.keys() != new.keys():
        raise ValueError("GUI View properties changed layout")
    remaining = bytearray(current)
    edits = {}
    for key, (offset, value) in new.items():
        if old[key][0] != offset:
            raise ValueError("GUI View property moved")
        if value != old[key][1]:
            edits[key] = value
            remaining[offset:offset + 8] = previous[offset:offset + 8]
    if remaining != previous:
        raise ValueError("This GUI edit includes unsupported properties or children")
    return edits
