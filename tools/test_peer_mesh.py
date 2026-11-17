import struct
import unittest
from peer_mesh import vertex_edit


class PeerMeshTest(unittest.TestCase):
    def test_only_finite_vertex_positions_may_change(self):
        data = bytearray(384)
        struct.pack_into("<4sII", data, 0, b"MESH", 21091000, len(data))
        struct.pack_into("<Q", data, 80, 128)
        struct.pack_into("<4QIIHH", data, 128, 200, 224, 288, 0, 64, 0, 2, 2)
        struct.pack_into("<HHIHHI", data, 200, 0, 12, 0, 4, 16, 24)
        incoming = bytearray(data)
        struct.pack_into("<f", incoming, 224, 0.0625)
        self.assertTrue(vertex_edit(data, incoming))
        for off in (223, 248, 287, 300):
            other = incoming.copy()
            other[off] ^= 1
            self.assertFalse(vertex_edit(data, other))
        struct.pack_into("<f", incoming, 224, float("nan"))
        self.assertFalse(vertex_edit(data, incoming))
        self.assertFalse(vertex_edit(data, data[:-1]))
        struct.pack_into("<Q", data, 80, 0xdeadbeef)
        self.assertFalse(vertex_edit(data, data))


if __name__ == "__main__":
    unittest.main()
