"""MDF v23 can omit alignment bytes after the last stored material property."""
import struct
import unittest

from material_layout import check_layout, materials


def padded_mdf():
    header, prop = 16, 96
    raw = bytearray(prop + 24)
    struct.pack_into("<4sHH", raw, 0, b"MDF\0", 1, 1)
    struct.pack_into("<III", raw, header + 12, 160, 1, 0)
    struct.pack_into("<Q", raw, header + 40, prop)
    for field, name in ((header, "Body"), (header + 72, "test/material.mmtr"), (prop, "Blend")):
        struct.pack_into("<Q", raw, field, len(raw))
        raw.extend((name + "\0").encode("utf-16-le"))
    raw.extend(bytes(-len(raw) % 16))
    struct.pack_into("<Q", raw, header + 64, len(raw))
    struct.pack_into("<II", raw, prop + 16, 148, 1)
    values = bytearray(160)
    struct.pack_into("<f", values, 148, .75)
    raw.extend(values)
    return raw


class MdfPropertyDataTest(unittest.TestCase):
    def test_unstored_alignment_keeps_values_and_shader_capacity(self):
        padded = padded_mdf()
        parsed = materials(padded[:-8])
        self.assertEqual(parsed, materials(padded))
        self.assertEqual(parsed[0].values["Blend"], struct.pack("<f", .75))
        check_layout(parsed[0], ({160}, {("Blend", 148, 4)}, set()))

    def test_truncated_parameter_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "MDF parameter data outside file"):
            materials(padded_mdf()[:-9])

    def test_excess_declared_size_is_not_alignment(self):
        raw = padded_mdf()[:-8]
        struct.pack_into("<I", raw, 16 + 12, 176)
        with self.assertRaisesRegex(ValueError, "Material table outside file"):
            materials(raw)
