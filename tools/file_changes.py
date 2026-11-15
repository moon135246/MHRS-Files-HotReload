"""Watch the loose directory and update only paths reported by Windows."""
import ctypes
from ctypes import wintypes as w
import os
from pathlib import Path
import struct
import time


class Overlapped(ctypes.Structure):
    _fields_ = [("Internal", ctypes.c_size_t), ("InternalHigh", ctypes.c_size_t),
                ("Offset", w.DWORD), ("OffsetHigh", w.DWORD), ("event", w.HANDLE)]


class DirectoryChanges:
    def __init__(self, root, recursive=True, mask=0x1b):
        self.root = root
        self.recursive, self.mask = recursive, mask
        self.dll = ctypes.WinDLL("kernel32", use_last_error=True)

        def api(name, result, *arguments):
            func = getattr(self.dll, name)
            func.argtypes, func.restype = arguments, result
            return func

        open_dir = api("CreateFileW", w.HANDLE, w.LPCWSTR, w.DWORD, w.DWORD, w.LPVOID,
                       w.DWORD, w.DWORD, w.HANDLE)
        event = api("CreateEventW", w.HANDLE, w.LPVOID, w.BOOL, w.BOOL, w.LPCWSTR)
        self.close_handle = api("CloseHandle", w.BOOL, w.HANDLE)
        self.read = api("ReadDirectoryChangesW", w.BOOL, w.HANDLE, w.LPVOID, w.DWORD,
                        w.BOOL, w.DWORD, w.LPVOID, ctypes.POINTER(Overlapped), w.LPVOID)
        self.result = api("GetOverlappedResult", w.BOOL, w.HANDLE, ctypes.POINTER(Overlapped),
                          ctypes.POINTER(w.DWORD), w.BOOL)
        self.cancel = api("CancelIoEx", w.BOOL, w.HANDLE, ctypes.POINTER(Overlapped))
        self.wait = api("WaitForSingleObject", w.DWORD, w.HANDLE, w.DWORD)
        self.handle = open_dir(str(root), 1, 7, None, 3, 0x42000000, None)
        if self.handle == ctypes.c_void_p(-1).value:
            raise ctypes.WinError(ctypes.get_last_error())
        self.op = Overlapped(event=event(None, True, False, None))
        if not self.op.event:
            err = ctypes.get_last_error()
            self.close_handle(self.handle)
            raise ctypes.WinError(err)
        self.buffer = ctypes.create_string_buffer(65536)
        try:
            self.arm()
        except OSError:
            self.close_handle(self.op.event)
            self.close_handle(self.handle)
            raise

    def arm(self):
        # Filename, directory name, size and last write. A timestamp-preserving
        # in-place copy can leave inode, length and mtime completely unchanged.
        if not self.read(self.handle, self.buffer, len(self.buffer), self.recursive, self.mask,
                         None, ctypes.byref(self.op), None):
            raise ctypes.WinError(ctypes.get_last_error())

    def poll(self, timeout):
        state = self.wait(self.op.event, int(timeout * 1000 + .5))
        if state == 258:  # WAIT_TIMEOUT
            return set(), set(), False
        if state != 0:
            raise ctypes.WinError(ctypes.get_last_error())
        size = w.DWORD()
        if not self.result(self.handle, ctypes.byref(self.op), ctypes.byref(size), False):
            code = ctypes.get_last_error()
            if code == 996:  # ERROR_IO_INCOMPLETE
                return set(), set(), False
            if code != 1022:  # ERROR_NOTIFY_ENUM_DIR
                raise ctypes.WinError(code)
        data = ctypes.string_at(self.buffer, size.value)
        self.arm()
        paths, structural = set(), set()
        off = 0
        while off < len(data):
            step, action, length = struct.unpack_from("<III", data, off)
            name = data[off+12:off+12+length].decode("utf-16-le")
            path = self.root / Path(name)
            paths.add(path)
            if action != 3:  # Add, delete, or one side of a rename.
                structural.add(path)
            if not step:
                break
            off += step
        return paths, structural, not data

    def close(self):
        self.cancel(self.handle, ctypes.byref(self.op))
        self.result(self.handle, ctypes.byref(self.op), ctypes.byref(w.DWORD()), True)
        self.close_handle(self.op.event)
        self.close_handle(self.handle)


class LooseChanges:
    def __init__(self, root, anchor):
        self.root = root
        self.parent = root.parent
        self.tree, self.gate = None, None
        # Watch the containing directory so replacing 'stm' itself cannot leave
        # a handle attached to the old tree. The game directory only needs a
        # nonrecursive directory-name subscription for removal of 'natives'.
        if anchor != self.parent:
            if anchor != self.parent.parent:
                raise ValueError("Unexpected loose directory anchor")
            self.gate = DirectoryChanges(anchor, recursive=False, mask=2)
        try:
            self.open_tree()
        except BaseException:
            self.close()
            raise
        dll = (self.gate or self.tree).dll
        self.wait = dll.WaitForMultipleObjects
        self.wait.argtypes = w.DWORD, ctypes.POINTER(w.HANDLE), w.BOOL, w.DWORD
        self.wait.restype = w.DWORD

    def open_tree(self):
        if self.tree:
            self.tree.close()
            self.tree = None
        try:
            self.tree = DirectoryChanges(self.parent)
        except FileNotFoundError:
            if not self.gate:
                raise

    def poll(self, timeout):
        watches = [watch for watch in (self.gate, self.tree) if watch]
        handles = (w.HANDLE * len(watches))(*(watch.op.event for watch in watches))
        index = self.wait(len(handles), handles, False, int(timeout * 1000 + .5))
        if index == 258:
            return set(), set(), False
        if index >= len(handles):
            raise ctypes.WinError(ctypes.get_last_error())
        watch = watches[index]
        if watch is self.gate:
            paths, _, overflow = watch.poll(0)
            if overflow or self.parent in paths:
                self.open_tree()
                return set(), set(), True
            return set(), set(), False
        try:
            paths, structural, overflow = watch.poll(0)
        except OSError as error:
            if not self.gate or error.winerror not in (3, 5, 6):
                raise
            self.open_tree()
            return set(), set(), True
        inside = {p for p in paths if p == self.root or self.root in p.parents}
        return inside, structural & inside, overflow

    def close(self):
        for watch in (self.tree, self.gate):
            if watch:
                watch.close()


def require_closed_writers(paths):
    if os.name != "nt":
        return
    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    open_file = kernel.CreateFileW
    open_file.argtypes = (w.LPCWSTR, w.DWORD, w.DWORD, w.LPVOID, w.DWORD, w.DWORD, w.HANDLE)
    open_file.restype = w.HANDLE
    close = kernel.CloseHandle
    close.argtypes, close.restype = (w.HANDLE,), w.BOOL
    for path in paths:
        # Shared-read/delete, without shared-write, detects a copy that is
        # still open for writing despite a pause between directory events.
        handle = open_file(str(path), 0x80000000, 5, None, 3, 0x80, None)
        if handle == ctypes.c_void_p(-1).value:
            raise ctypes.WinError(ctypes.get_last_error())
        close(handle)


def snapshots(root, files, signature, suffixes, anchor=None):
    root = Path(root)
    anchor = root.parent if anchor is None else Path(anchor)
    notifications = LooseChanges(root, anchor) if os.name == "nt" else None
    sequence = 0
    directory_counts = {}

    def count_parents(file, delta):
        for directory in file.parents:
            count = directory_counts.get(directory, 0) + delta
            if count:
                directory_counts[directory] = count
            else:
                del directory_counts[directory]
            if directory == root:
                break

    def scan(directory):
        entries = {}
        for file in files(directory):
            try:
                entries[file] = (signature(file), sequence)
            except FileNotFoundError:
                pass
        return entries

    def reconcile():
        entries = scan(root)
        directory_counts.clear()
        if notifications:
            for file in entries:
                count_parents(file, 1)
        return entries

    try:
        # Arm before enumeration so copies made during the initial walk follow
        # the startup snapshot. Never mutate snapshots held by the consumer.
        current = reconcile()
        while True:
            timeout = yield current
            timeout = max(0.0, timeout or 0.0)
            if not notifications:
                time.sleep(min(timeout, .2))
                refreshed = scan(root)
                if refreshed != current:
                    current = refreshed
                continue
            paths, structural, overflow = notifications.poll(timeout)
            if not paths and not overflow:
                continue
            sequence += 1
            if overflow:
                # Windows no longer knows which timestamps may have been preserved.
                current = reconcile()
                continue
            # Moving a whole directory need not emit events for its children.
            live_dirs = {p for p in structural if p.is_dir()}
            directories = live_dirs | {p for p in structural if p in directory_counts}
            directories = {p for p in directories if not any(q in directories for q in p.parents)}
            touched = {p for p in paths if p.name.lower().endswith(suffixes)
                       and p not in live_dirs and (not directories or not directories.intersection(p.parents))}
            if not directories and not touched:
                continue
            updated = current.copy()
            affected = touched.copy()
            if directories:
                for file in current:
                    if file in directories or directories.intersection(file.parents):
                        del updated[file]
                        affected.add(file)
                for directory in directories & live_dirs:
                    entries = scan(directory)
                    updated.update(entries)
                    affected.update(entries)
            for file in touched:
                try:
                    updated[file] = (signature(file), sequence)
                except FileNotFoundError:
                    updated.pop(file, None)
            if updated != current:
                for file in affected:
                    if (file in current) != (file in updated):
                        count_parents(file, 1 if file in updated else -1)
                current = updated
    finally:
        if notifications:
            notifications.close()
