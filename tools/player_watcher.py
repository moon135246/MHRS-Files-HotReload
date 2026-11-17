"""Standalone watcher launched with the Rise installation as its working directory."""
import argparse
import ctypes
import sys
import traceback
from ctypes import wintypes
from pathlib import Path

from watch_outfit import watch


def join_owner_job(name):
    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel.OpenJobObjectW.argtypes = (wintypes.DWORD, wintypes.BOOL, wintypes.LPCWSTR)
    kernel.OpenJobObjectW.restype = wintypes.HANDLE
    kernel.AssignProcessToJobObject.argtypes = (wintypes.HANDLE, wintypes.HANDLE)
    kernel.AssignProcessToJobObject.restype = wintypes.BOOL
    kernel.GetCurrentProcess.restype = wintypes.HANDLE
    kernel.CloseHandle.argtypes = (wintypes.HANDLE,)
    handle = kernel.OpenJobObjectW(0x0001, False, name)  # JOB_OBJECT_ASSIGN_PROCESS
    if not handle:
        raise ctypes.WinError(ctypes.get_last_error())
    try:
        if not kernel.AssignProcessToJobObject(handle, kernel.GetCurrentProcess()):
            raise ctypes.WinError(ctypes.get_last_error())
    finally:
        # Only the game keeps a handle. Closing its last handle stops the worker.
        kernel.CloseHandle(handle)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--owner-job", help="Windows job created by the hot-reload DLL")
    args = parser.parse_args()
    game = Path.cwd()
    log = game / "reframework/data/MHRS-Files-HotReload/watcher.log"
    with log.open("w", encoding="utf-8", buffering=1) as output:
        sys.stdout = sys.stderr = output
        try:
            if args.owner_job:
                join_owner_job(args.owner_job)
            watch(game)
        except Exception:
            traceback.print_exc()
            sys.exit(1)
