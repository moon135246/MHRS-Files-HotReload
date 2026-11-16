"""Own the .stm platform variants used when reopening Rise equipment resources."""
from contextlib import contextmanager
import ctypes
from ctypes import wintypes
import hashlib
import json
import msvcrt
import os
from pathlib import Path
import shutil
import stat
import uuid

from file_changes import FileChangeTimes


class PlatformFileConflict(OSError):
    """A platform path already belongs to another mod."""


_dll = ctypes.WinDLL("kernel32", use_last_error=True)
_open = _dll.CreateFileW
_open.argtypes = (wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD, wintypes.LPVOID,
                  wintypes.DWORD, wintypes.DWORD, wintypes.HANDLE)
_open.restype = wintypes.HANDLE
_set_info = _dll.SetFileInformationByHandle
_set_info.argtypes = (wintypes.HANDLE, ctypes.c_int, wintypes.LPVOID, wintypes.DWORD)
_set_info.restype = wintypes.BOOL
_invalid = ctypes.c_void_p(-1).value
_times = FileChangeTimes()


def _winerror(path):
    error = ctypes.WinError(ctypes.get_last_error())
    error.filename = str(path)
    return error


@contextmanager
def _reader(path, *, can_delete=False, allow_rename=False):
    # Deny writers and renames while checking ownership. Delete through the
    # same handle so a replacement at the path can never be deleted by mistake.
    access = 0x80000000 | (0x10000 if can_delete else 0)
    sharing = 5 if allow_rename else 1
    handle = _open(str(path), access, sharing, None, 3, 0x00200000 | 0x08000000, None)
    if handle == _invalid:
        raise _winerror(path)
    try:
        fd = msvcrt.open_osfhandle(handle, os.O_RDONLY | os.O_BINARY)
    except BaseException:
        _dll.CloseHandle(wintypes.HANDLE(handle))
        raise
    with os.fdopen(fd, "rb") as stream:
        if os.fstat(fd).st_file_attributes & 0x400:
            raise PlatformFileConflict(f"Platform path is a reparse point: {path}")
        yield stream


def _identity(stream):
    stat = os.fstat(stream.fileno())
    if not stat.st_ino:
        raise OSError("The filesystem did not return a file ID")
    return [stat.st_dev, stat.st_ino]


def _stamp(stream):
    fd = stream.fileno()
    info = os.fstat(fd)
    change = _times.read_handle(msvcrt.get_osfhandle(fd))
    return [info.st_size, info.st_mtime_ns, change] if change else None


def _digest(stream):
    stream.seek(0)
    digest = hashlib.sha256()
    while block := stream.read(1024 * 1024):
        digest.update(block)
    return digest.hexdigest()


def _dispose(stream, path):
    # Ignore the read-only attribute for this directory entry. A hard link
    # shares attributes with the original; chmod would change it.
    handle = msvcrt.get_osfhandle(stream.fileno())
    flags = wintypes.DWORD(0x11)
    if not _set_info(handle, 21, ctypes.byref(flags), ctypes.sizeof(flags)):
        delete = ctypes.c_ubyte(1)
        if not _set_info(handle, 4, ctypes.byref(delete), ctypes.sizeof(delete)):
            raise _winerror(path)


def _remove_if_owned(path, owner, source):
    if not owner:
        return
    try:
        info = path.lstat()
        if not stat.S_ISREG(info.st_mode) or info.st_file_attributes & 0x400:
            return
        with _reader(path) as probe:
            if _identity(probe) != owner["id"]:
                return
        with _reader(path, can_delete=True) as stream:
            if _identity(stream) != owner["id"]:
                return
            try:
                same_source = owner["linked"] and os.path.samestat(os.fstat(stream.fileno()), source.stat())
            except FileNotFoundError:
                same_source = False
            if not same_source and _digest(stream) != owner["sha256"]:
                return
            _dispose(stream, path)
    except FileNotFoundError:
        pass


class PlatformFiles:
    """Pass changed ordinary paths (including removals) to prepare before publishing them."""

    def __init__(self, root, state_dir):
        self.root = Path(root).resolve()
        self.state = Path(state_dir) / "platform-files"
        self.state.mkdir(parents=True, exist_ok=True)
        self.lock = (self.state / "lock").open("a+b")
        self.lock.seek(0)
        try:
            msvcrt.locking(self.lock.fileno(), msvcrt.LK_NBLCK, 1)
            self._recover()
        except BaseException:
            self.lock.close()
            raise

    def supports(self, path):
        try:
            relative = Path(path).relative_to(self.root).as_posix().lower()
        except ValueError:
            return False
        return relative.endswith((".tex.28", ".mot.495")) or (
            relative.startswith("player/mod/") and relative.endswith(
                (".mesh.2109148288", ".mdf2.23", ".chain.48", ".user.2")))

    def _source(self, key):
        path = self.root / key
        if (not self.supports(path) or ".." in Path(key).parts or Path(key).drive or Path(key).is_absolute()
                or not path.parent.resolve().is_relative_to(self.root)):
            raise ValueError(f"Invalid platform file source: {key}")
        return path

    def _journal(self, key):
        return self.state / (hashlib.sha256(key.lower().encode("utf-8")).hexdigest() + ".json")

    @staticmethod
    def _save(journal, record):
        temp = journal.with_suffix(".new")
        with temp.open("w", encoding="utf-8") as stream:
            json.dump(record, stream, ensure_ascii=False)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temp, journal)

    @staticmethod
    def _scratch(source, record):
        token = record["stage"]
        if len(token) != 32 or any(c not in "0123456789abcdef" for c in token):
            raise ValueError("Invalid platform staging directory")
        return source.parent / (".mhrs-platform-" + token)

    def _clean_stage(self, source, record):
        if "stage" not in record:
            return
        directory = self._scratch(source, record)
        if not directory.exists():
            return
        if directory.lstat().st_file_attributes & 0x400:
            raise PlatformFileConflict(f"Staging directory was replaced: {directory}")
        # This private, UUID-named directory was reserved in the journal
        # before any payload was written. Unknown entries are never removed.
        payload = directory / "payload"
        try:
            with _reader(payload, can_delete=True) as stream:
                _dispose(stream, payload)
        except FileNotFoundError:
            pass
        directory.rmdir()

    def _retire(self, journal, record):
        source = self._source(record["source"])
        if self._journal(record["source"]) != journal:
            raise ValueError(f"Invalid platform ownership journal: {journal}")
        target = Path(str(source) + ".stm")
        _remove_if_owned(target, record.get("owner"), source)
        if record.get("next"):
            # rename() consumes the staged entry. If it is still there,
            # publication did not happen and an existing target is foreign.
            if not (self._scratch(source, record) / "payload").exists():
                _remove_if_owned(target, record["next"], source)
        self._clean_stage(source, record)
        journal.unlink()

    def _recover(self):
        errors = []
        for journal in sorted(self.state.glob("*.json")):
            try:
                self._retire(journal, json.loads(journal.read_text(encoding="utf-8")))
            except (OSError, ValueError) as exc:
                errors.append(f"{journal.name}: {exc}")
        if errors:
            raise OSError("Platform-file recovery failed: " + " / ".join(errors))

    def _prepare(self, ordinary, package=None):
        key = ordinary.relative_to(self.root).as_posix()
        ordinary = self._source(key)
        target = Path(str(ordinary) + ".stm")
        journal = self._journal(key)
        record = json.loads(journal.read_text(encoding="utf-8")) if journal.exists() else {"source": key}
        if "stage" in record:
            self._retire(journal, record)
            record = {"source": key}
        packaged = package is not None and not ordinary.exists()
        source = package if packaged else ordinary
        if not packaged and not source.exists():
            if journal.exists():
                self._retire(journal, record)
            return False
        owner = record.get("owner")
        with _reader(source) as stream:
            source_id = _identity(stream)
            if owner and owner["linked"] and owner["id"] == source_id:
                try:
                    with _reader(target) as side:
                        if _identity(side) == source_id:
                            stamp = _stamp(stream)
                            if stamp is None or stamp != owner.get("stamp"):
                                owner["sha256"] = _digest(stream)
                                owner["stamp"] = stamp
                                self._save(journal, record)
                            return True
                except FileNotFoundError:
                    pass
            digest = _digest(stream)
        try:
            with _reader(target) as stream:
                target_id = _identity(stream)
                target_digest = digest if source_id == target_id else _digest(stream)
                same_content = digest == target_digest
                owned = owner is not None and target_id == owner["id"]
                if owned and not (owner["linked"] and target_id == source_id):
                    owned = target_digest == owner["sha256"]
                if not owned:
                    if journal.exists():
                        journal.unlink()
                    if not same_content:
                        raise PlatformFileConflict(f"Existing user platform file differs from {source}: {target}")
                    return True
                if (same_content and bool(owner.get("packaged")) == packaged
                        and (not owner["linked"] or source_id == target_id)):
                    if digest != owner["sha256"]:
                        owner["sha256"] = digest
                        self._save(journal, record)
                    return True
        except FileNotFoundError:
            pass

        record["stage"] = uuid.uuid4().hex
        scratch = self._scratch(ordinary, record)
        if scratch.exists():
            raise FileExistsError(scratch)
        self._save(journal, record)
        # A mod manager may remove the whole outfit's directory on uninstall.
        # The extracted copy is published exclusively under the .stm spelling.
        scratch.mkdir(parents=packaged)
        payload = scratch / "payload"
        # The private PAK extract may be reused. Keep writes made through a
        # mod-visible .stm file from mutating that original.
        linked = False
        if not packaged:
            try:
                os.link(source, payload)
                linked = True
            except OSError as exc:
                # Sharing, capacity and other transient failures should retry.
                if exc.winerror not in (1, 5, 17, 50, 1142, 1314):
                    raise
        if not linked:
            with _reader(source) as src, payload.open("xb") as dst:
                if _identity(src) != source_id:
                    raise OSError(f"Source was replaced while staging {source}")
                shutil.copyfileobj(src, dst, 1024 * 1024)
                dst.flush()
                os.fsync(dst.fileno())
        # Keep writers out across the final verification and rename. The
        # rename itself can advance NTFS ChangeTime on the hard-linked file.
        with _reader(payload, allow_rename=True) as stream:
            ident = _identity(stream)
            if (linked and ident != source_id) or _digest(stream) != digest:
                raise OSError(f"Source changed while staging {source}")
            if packaged and ordinary.exists():
                raise OSError(f"Mod was reinstalled while staging PAK data for {ordinary}")
            record["next"] = {"id": ident, "sha256": digest, "linked": linked, "packaged": packaged}
            self._save(journal, record)
            _remove_if_owned(target, owner, ordinary)
            try:
                # On Windows rename is atomic and fails if another mod occupied
                # the destination since our check. Never use os.replace here.
                os.rename(payload, target)
            except FileExistsError as exc:
                raise PlatformFileConflict(f"Another mod owns the destination {target}") from exc
            if linked:
                record["next"]["stamp"] = _stamp(stream)
        self._clean_stage(ordinary, record)
        self._save(journal, {"source": key, "owner": record["next"]})
        return True

    def prepare(self, files):
        present = set()
        for source in sorted({Path(path) for path in files}):
            if self.supports(source) and self._prepare(source):
                present.add(source)
        return present

    def prepare_from_package(self, files):
        """Stage a private PAK extract if the mod file is absent; prefer a reinstall."""
        present = set()
        for ordinary, package in sorted((Path(k), Path(v)) for k, v in files.items()):
            if self.supports(ordinary) and self._prepare(ordinary, package):
                present.add(ordinary)
        return present

    def discard(self, files):
        """Withdraw owned aliases even if the ordinary or private source still exists."""
        for ordinary in sorted({Path(path) for path in files}):
            if self.supports(ordinary):
                key = ordinary.relative_to(self.root).as_posix()
                journal = self._journal(key)
                if journal.exists():
                    self._retire(journal, json.loads(journal.read_text(encoding="utf-8")))

    def close(self):
        if not self.lock.closed:
            try:
                self._recover()
            finally:
                self.lock.close()
