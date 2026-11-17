"""Publish stable Lua Bone System profile changes from the in-process watcher."""
import hashlib
import json
import math
import os
from pathlib import Path
import re
import time
import uuid

from file_changes import FileChangeTimes, require_closed_writers


PROFILE = re.compile(r"[fm]_(?:helm|body|arm|wst|leg)[a-z0-9_-]+\.json", re.IGNORECASE | re.ASCII)


def valid_profile(value):
    return isinstance(value, dict) and bool(value) and all(
        isinstance(row, dict) and all(type(row.get(axis)) in (int, float) and math.isfinite(row[axis])
                                      for axis in ("x", "y", "z")) for row in value.values()
    )


class BoneProfiles:
    def __init__(self, game, channel):
        self.root = Path(game) / "reframework/data/LUABoneSystem/custom"
        self.notice = Path(channel) / "bone-profiles.json"
        self.data = Path(channel) / "bone-profile-data.json"
        self.session = uuid.uuid4().hex
        self.times = FileChangeTimes() if os.name == "nt" else None
        self.observed = None
        self.applied = {}
        self.hashes = {}
        self.values = {}
        self.published = None
        self.next_scan = 0.0

    def _stamp(self, path):
        stat = path.stat()
        return (stat.st_ino, stat.st_size, stat.st_mtime_ns, self.times.read(path) if self.times else stat.st_ctime_ns)

    def _scan(self):
        try:
            files = list(self.root.iterdir())
        except FileNotFoundError:
            return {}
        return {f: self._stamp(f) for f in files if PROFILE.fullmatch(f.name) and f.is_file()}

    def poll(self):
        now = time.monotonic()
        if now < self.next_scan:
            return
        self.next_scan = now + 0.55
        try:
            observed = self._scan()
            earlier = self.observed
            self.observed = observed
            if earlier is None:
                return
            for file in observed.keys() | self.applied.keys():
                stamp = observed.get(file)
                if stamp != earlier.get(file) or stamp == self.applied.get(file):
                    continue
                name = file.stem.lower()
                if stamp is None:
                    self.hashes.pop(name, None)
                    self.applied.pop(file)
                    continue
                try:
                    require_closed_writers([file])
                    raw = file.read_bytes()
                    if self._stamp(file) != stamp:
                        continue
                except OSError:
                    continue
                try:
                    profile = json.loads(raw)
                    if not valid_profile(profile):
                        raise ValueError("Expected joint names with finite x, y, z offsets")
                except (ValueError, UnicodeError, OverflowError, RecursionError) as error:
                    print("Kept previous bone profile", file.name, str(error), flush=True)
                else:
                    digest = hashlib.sha256(raw).hexdigest()
                    self.hashes[name] = digest
                    self.values[digest] = {joint: {axis: row[axis] for axis in ("x", "y", "z")}
                                           for joint, row in profile.items()}
                self.applied[file] = stamp
            if self.hashes != self.published:
                # Publish the already validated offsets, not a request for the game
                # thread to reopen loose files which may already be changing again.
                self.values = {digest: self.values[digest] for digest in set(self.hashes.values())}
                head = {"version": 1, "pid": os.getpid(), "session": self.session, "profiles": self.hashes}
                data_temp = self.data.with_suffix(".new")
                data_temp.write_text(json.dumps({**head, "values": self.values}, separators=(",", ":"),
                                                allow_nan=False), "utf-8")
                os.replace(data_temp, self.data)
                temp = self.notice.with_suffix(".new")
                temp.write_text(json.dumps(head, sort_keys=True), "utf-8")
                os.replace(temp, self.notice)
                self.published = self.hashes.copy()
        except OSError:
            # Keep the last complete manifest through directory swaps or a
            # concurrent reader that temporarily prevents replacing the file.
            return
