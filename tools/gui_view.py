"""Read scalar root View properties from Rise GUIR 430033."""
import math
import struct


def view_fields(data):
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
    table = pointer(root + 64)
    count = pointer(table)
    if count > 2048 or table + 8 + 32 * count > len(data):
        raise ValueError("Invalid GUI View property table")
    fields = {}
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
        fields[key] = (offset, value)
    return fields


def view_diff(previous, current):
    if len(previous) != len(current):
        raise ValueError("GUI layout changed")
    old = view_fields(previous)
    new = view_fields(current)
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
