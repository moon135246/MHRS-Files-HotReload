"""Child process: report the first conflicting open on one existing NTFS file."""
import ctypes
from ctypes import wintypes as wt
import json
import sys
import time


class Overlapped(ctypes.Structure):
    _fields_ = [("Internal", ctypes.c_size_t), ("InternalHigh", ctypes.c_size_t),
                ("Offset", wt.DWORD), ("OffsetHigh", wt.DWORD), ("hEvent", wt.HANDLE)]


def observe(path):
    kernel = ctypes.WinDLL("kernel32", use_last_error=True)

    def api(name, result, *args):
        func = getattr(kernel, name)
        func.restype, func.argtypes = result, args
        return func

    open_file = api("CreateFileW", wt.HANDLE, wt.LPCWSTR, wt.DWORD, wt.DWORD,
                    wt.LPVOID, wt.DWORD, wt.DWORD, wt.HANDLE)
    create_event = api("CreateEventW", wt.HANDLE, wt.LPVOID, wt.BOOL, wt.BOOL, wt.LPCWSTR)
    close = api("CloseHandle", wt.BOOL, wt.HANDLE)
    request = api("DeviceIoControl", wt.BOOL, wt.HANDLE, wt.DWORD, wt.LPVOID, wt.DWORD,
                  wt.LPVOID, wt.DWORD, ctypes.POINTER(wt.DWORD), ctypes.POINTER(Overlapped))
    complete = api("GetOverlappedResult", wt.BOOL, wt.HANDLE, ctypes.POINTER(Overlapped),
                   ctypes.POINTER(wt.DWORD), wt.BOOL)
    event = create_event(None, True, False, None)
    if not event:
        raise ctypes.WinError(ctypes.get_last_error())
    handle = open_file(path, 0x80000000, 7, None, 3, 0x40000000, None)
    if handle == ctypes.c_void_p(-1).value:
        err = ctypes.get_last_error()
        close(event)
        raise ctypes.WinError(err)
    try:
        op = Overlapped(hEvent=event)
        size = wt.DWORD()
        # FSCTL_REQUEST_BATCH_OPLOCK. Pending means the filesystem granted it.
        success = request(handle, 0x90008, None, 0, None, 0, ctypes.byref(size), ctypes.byref(op))
        if success or ctypes.get_last_error() != 997:
            raise RuntimeError(f"Batch oplock not pending: {ctypes.get_last_error()}")
        print(json.dumps({"state": "armed", "time_ns": time.time_ns()}), flush=True)
        if not complete(handle, ctypes.byref(op), ctypes.byref(size), True):
            raise ctypes.WinError(ctypes.get_last_error())
        detected = time.time_ns()
    finally:
        close(handle)  # release immediately so the opener can continue
        close(event)
    print(json.dumps({"state": "break", "time_ns": detected}), flush=True)


if __name__ == "__main__":
    observe(sys.argv[1])
