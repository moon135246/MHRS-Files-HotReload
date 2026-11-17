"""Recognize renderer-only edits to a stock Rise player mesh."""
import struct
import math


def vertex_edit(stock, incoming):
    """Allow changes inside stock vertex positions only; keep skinning, index
    data, material slots, submeshes and all other metadata byte-identical."""
    if not stock or not incoming or len(stock) != len(incoming) or stock[:4] != b"MESH":
        return False
    try:
        version, size = struct.unpack_from("<II", stock, 4)
        if version not in (21061800, 21091000) or size != len(stock):
            return False
        header, = struct.unpack_from("<Q", stock, 80)
        elements, vertices, faces, _, buf_size, _, _, count = struct.unpack_from("<4QIIHH", stock, header)
        if not (128 <= header < elements < vertices < faces <= size and 2 <= count <= 32
                and elements + count * 8 <= vertices and vertices + buf_size <= faces):
            return False
        attrs = [struct.unpack_from("<HHI", stock, elements + i * 8) for i in range(count)]
        if attrs[0] != (0, 12, 0) or any(attrs[i][2] <= attrs[i-1][2] for i in range(1, count)):
            return False
        end = attrs[1][2]
        if not (0 < end <= buf_size and end % 12 == 0 and attrs[-1][2] < buf_size):
            return False
        a, b = memoryview(stock), memoryview(incoming)
        if a[:vertices] != b[:vertices] or a[vertices + end:] != b[vertices + end:]:
            return False
        return all(math.isfinite(v) for (v,) in struct.iter_unpack("<f", b[vertices:vertices + end]))
    except (ValueError, struct.error):
        return False
