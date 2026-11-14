"""Read plain managed scalar fields from a single-root Rise RSZ v16 USER."""
import math
import struct


FORMATS = {
    "Bool": ("B", "System.Boolean"), "F32": ("f", "System.Single"), "F64": ("d", "System.Double"),
    "S8": ("b", "System.SByte"), "U8": ("B", "System.Byte"),
    "S16": ("h", "System.Int16"), "U16": ("H", "System.UInt16"),
    "S32": ("i", "System.Int32"), "U32": ("I", "System.UInt32"),
}


def scalar_layout(raw, schema):
    if len(raw) < 48 or raw[:4] != b"USR\0" or any(raw[4:16]):
        return None
    start = struct.unpack_from("<Q", raw, 32)[0]
    if raw[start:start+4] != b"RSZ\0" or start + 52 > len(raw):
        return None
    if struct.unpack_from("<4I", raw, start+4) != (16, 1, 2, 0) or struct.unpack_from("<I", raw, start+48)[0] != 1:
        return None
    info, data = struct.unpack_from("<QQ", raw, start+24)
    if not 52 <= info <= data - 16 or start + data > len(raw):
        raise ValueError("Invalid scalar USER table")
    kind, crc = struct.unpack_from("<II", raw, start+info+8)
    row = schema.get(format(kind, "x"))
    if not row or int(row["crc"], 16) != crc:
        return None
    cursor = start + data
    values = {}
    for field in row["fields"]:
        align, size, name = field["align"], field["size"], field["name"]
        if field["array"] or align not in (1, 2, 4, 8, 16) or size <= 0:
            return None
        # Unknown and reference fields can be variable-length. Never guess their stride.
        fmt = FORMATS.get(field["type"])
        if not fmt or struct.calcsize("<" + fmt[0]) != size:
            return None
        cursor = (cursor + align - 1) & -align
        if cursor + size > len(raw):
            raise ValueError("Truncated scalar USER")
        if not field["native"] and fmt[1] == field["original_type"] and not name.startswith("STRUCT__"):
            if name in values:
                return None
            value = struct.unpack_from("<" + fmt[0], raw, cursor)[0]
            if not math.isfinite(value) or (field["type"] == "Bool" and value not in (0, 1)):
                raise ValueError("Invalid scalar USER field")
            values[name] = (cursor, size, fmt[1], bool(value) if field["type"] == "Bool" else value)
        cursor += size
    return (row["name"], values) if cursor == len(raw) and values else None


def scalar_diff(previous, current, schema):
    old, new = scalar_layout(previous, schema), scalar_layout(current, schema)
    if not old or not new or old[0] != new[0] or old[1].keys() != new[1].keys():
        raise ValueError("Scalar USER schema changed")
    remaining = bytearray(current)
    edits = {}
    for name, (offset, size, typ, value) in new[1].items():
        if old[1][name][:3] != (offset, size, typ):
            raise ValueError("Scalar USER layout changed")
        if old[1][name][3] != value:
            remaining[offset:offset+size] = previous[offset:offset+size]
            edits[name] = value
    if remaining != previous:
        raise ValueError("Edit includes bytes outside supported scalar USER fields")
    return edits
