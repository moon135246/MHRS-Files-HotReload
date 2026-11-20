"""Own the .stm platform variants used when reopening Rise equipment resources."""
from concurrent.futures import ThreadPoolExecutor
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
from typing import NamedTuple
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


@contextmanager
def _publication_source(source, ordinary):
    # Hard-link publication needs FILE_SHARE_DELETE. An installer can rename
    # the old ordinary file away, then put another file under its original name.
    with _reader(source, allow_rename=True) as protected:
        yield protected
        if not os.path.samestat(os.fstat(protected.fileno()), source.stat()):
            raise OSError(f"Source was replaced while staging {source}")
        if source != ordinary and ordinary.exists():
            raise OSError(f"Mod was reinstalled while staging PAK data for {ordinary}")


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
    return hashlib.file_digest(stream, "sha256").hexdigest()


class SourceDigest(NamedTuple):
    sha256: str
    identity: tuple[int, int]
    stamp: tuple[int, int, int] | None

    def matches(self, stream, identity):
        if self.stamp is None or self.identity != tuple(identity):
            return False
        stamp = _stamp(stream)
        return stamp is not None and self.stamp == tuple(stamp)


def read_source_digest(path, signature):
    # Hash while denying writers. Use the same file ID and Windows ChangeTime
    # when staging the alias, including if a save restores the old mtime.
    with _publication_source(path, path) as stream:
        info = os.fstat(stream.fileno())
        if (info.st_ino, info.st_size, info.st_mtime_ns) != signature:
            return None
        stamp = _stamp(stream)
        return SourceDigest(_digest(stream), (info.st_dev, info.st_ino), tuple(stamp) if stamp else None)


def _dispose(stream, path):
    # Ignore the read-only attribute for this directory entry. A hard link
    # shares attributes with the original; chmod would change it.
    handle = msvcrt.get_osfhandle(stream.fileno())
    flags = wintypes.DWORD(0x11)
    if not _set_info(handle, 21, ctypes.byref(flags), ctypes.sizeof(flags)):
        delete = ctypes.c_ubyte(1)
        if not _set_info(handle, 4, ctypes.byref(delete), ctypes.sizeof(delete)):
            raise _winerror(path)


def _remove_if_owned(path, owner):
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
            if not owner["linked"] and _digest(stream) != owner["sha256"]:
                return
            _dispose(stream, path)
    except FileNotFoundError:
        pass


class PlatformFiles:
    """Pass changed ordinary paths (including removals) to prepare before publishing them."""

    def __init__(self, root, state_dir):
        self.root = Path(root).resolve()
        self._link_changes = {}
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
        self._link_changes.pop(source, None)
        if self._journal(record["source"]) != journal:
            raise ValueError(f"Invalid platform ownership journal: {journal}")
        target = Path(str(source) + ".stm")
        _remove_if_owned(target, record.get("owner"))
        if record.get("next"):
            # rename() consumes the staged entry. If it is still there,
            # publication did not happen and an existing target is foreign.
            if not (self._scratch(source, record) / "payload").exists():
                _remove_if_owned(target, record["next"])
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

    def _prepare(self, ordinary, package=None, *, detached=False, transfer_package=False, checked=None):
        key = ordinary.relative_to(self.root).as_posix()
        ordinary = self._source(key)
        target = Path(str(ordinary) + ".stm")
        journal = self._journal(key)
        record = json.loads(journal.read_text(encoding="utf-8")) if journal.exists() else {"source": key}
        if "stage" in record:
            self._retire(journal, record)
            record = {"source": key}
        packaged = package is not None and not ordinary.exists()
        if transfer_package and not packaged:
            return False
        source = package if packaged else ordinary
        if not packaged and not source.exists():
            if journal.exists():
                self._retire(journal, record)
            return False
        owner = record.get("owner")
        with _publication_source(source, ordinary) as protected:
            source_id = _identity(protected)
            digest = checked.sha256 if checked and checked.matches(protected, source_id) else None
            if not detached and owner and owner["linked"] and owner["id"] == source_id:
                try:
                    with _reader(target) as side:
                        if _identity(side) == source_id:
                            stamp = _stamp(protected)
                            if stamp is None or stamp != owner.get("stamp"):
                                owner["sha256"] = digest or _digest(protected)
                                owner["stamp"] = stamp
                                self._save(journal, record)
                            return True
                except FileNotFoundError:
                    pass
            digest = digest or _digest(protected)
            try:
                with _reader(target) as stream:
                    target_id = _identity(stream)
                    # Writes to the ordinary file also change the bytes of our
                    # hard link. If the installer then replaces the ordinary
                    # name, the recorded ID still identifies our old entry.
                    # A detached copy can only change through another writer.
                    if not (owner and owner["linked"] and target_id == owner["id"]):
                        target_digest = digest if source_id == target_id else _digest(stream)
                        owned_copy = owner and target_id == owner["id"] and target_digest == owner["sha256"]
                        if not owned_copy:
                            if journal.exists():
                                journal.unlink()
                            if digest != target_digest:
                                raise PlatformFileConflict(f"Existing user platform file differs from {source}: {target}")
                            return True
                        if digest == target_digest and bool(owner.get("packaged")) == packaged:
                            return True
            except FileNotFoundError:
                pass

            record["stage"] = uuid.uuid4().hex
            before_link = _stamp(protected) if not packaged else None
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
            # A freshly extracted temporary PAK payload can hand its sole
            # directory entry to the platform file without copying the bytes.
            if (not packaged and not detached) or transfer_package:
                try:
                    os.link(source, payload)
                    linked = True
                except OSError as exc:
                    # Sharing, capacity and other transient failures should retry.
                    if exc.winerror not in (1, 5, 17, 50, 1142, 1314):
                        raise
            if not linked:
                with payload.open("xb") as dst:
                    protected.seek(0)
                    shutil.copyfileobj(protected, dst, 1024 * 1024)
                    dst.flush()
                    os.fsync(dst.fileno())
            # Keep writers out across the final verification and rename. The
            # rename itself can advance NTFS ChangeTime on the hard-linked file.
            with _reader(payload, allow_rename=True) as stream:
                ident = _identity(stream)
                # The source handle has denied all writers since its first SHA-256.
                # The same file ID proves a staged hard link has those exact bytes.
                if not os.path.samestat(os.fstat(protected.fileno()), source.stat()):
                    raise OSError(f"Source was replaced while staging {source}")
                same_content = ident == source_id if linked else _digest(stream) == digest
                if not same_content:
                    raise OSError(f"Source changed while staging {source}")
                if packaged and ordinary.exists():
                    raise OSError(f"Mod was reinstalled while staging PAK data for {ordinary}")
                record["next"] = {"id": ident, "sha256": digest, "linked": linked and not packaged, "packaged": packaged}
                self._save(journal, record)
                _remove_if_owned(target, owner)
                try:
                    # On Windows rename is atomic and fails if another mod occupied
                    # the destination since our check. Never use os.replace here.
                    os.rename(payload, target)
                except FileExistsError as exc:
                    raise PlatformFileConflict(f"Another mod owns the destination {target}") from exc
                after_link = _stamp(protected) if before_link else None
                if linked and not packaged:
                    record["next"]["stamp"] = after_link
                replacing_link = owner and owner["linked"] and owner["id"] == source_id
                if (linked or replacing_link) and before_link and after_link and before_link[2] != after_link[2]:
                    # Creating a hard link and later detaching it may both
                    # advance ChangeTime before the watcher next polls. Both
                    # transitions were covered by a handle that denied writers.
                    previous = self._link_changes.get(ordinary)
                    original = (previous[1] if previous and previous[0] == source_id[1]
                                and previous[3] == before_link[2] else before_link[2])
                    self._link_changes[ordinary] = (source_id[1], original, before_link[2], after_link[2])
            self._clean_stage(ordinary, record)
            self._save(journal, {"source": key, "owner": record["next"]})
            return True

    @contextmanager
    def pin_copy(self, ordinary, package=None):
        """Hold the exact platform entry used by the renderer. Leave ordinary installs writable."""
        key = ordinary.relative_to(self.root).as_posix()
        source = self._source(key)
        target = Path(str(source) + ".stm")
        journal = self._journal(key)
        if target.exists():
            record = json.loads(journal.read_text(encoding="utf-8")) if journal.exists() else {}
            owner = record.get("owner")
            info = target.stat()
            if not owner or [info.st_dev, info.st_ino] != owner["id"]:
                yield None
                return
        if self._prepare(source, package, detached=True) and journal.exists():
            owner = json.loads(journal.read_text(encoding="utf-8")).get("owner")
            if owner and not owner["linked"]:
                with _reader(target) as stream:
                    if _identity(stream) == owner["id"] and os.fstat(stream.fileno()).st_nlink == 1:
                        yield stream
                        return
        yield None

    @contextmanager
    def pin_package(self, ordinary):
        """Prove the existing private PAK payload still owns the requested platform name."""
        key = ordinary.relative_to(self.root).as_posix()
        target = Path(str(self._source(key)) + ".stm")
        journal = self._journal(key)
        record = json.loads(journal.read_text(encoding="utf-8")) if journal.exists() else {}
        owner = record.get("owner")
        if owner and owner.get("packaged") and not owner["linked"] and target.is_file():
            info = target.stat()
            if [info.st_dev, info.st_ino] != owner["id"]:
                yield None
                return
            with _reader(target) as stream:
                if (_identity(stream) == owner["id"] and os.fstat(stream.fileno()).st_nlink == 1
                        and _digest(stream) == owner["sha256"]):
                    stream.seek(0)
                    yield stream
                    return
        yield None

    def known_link_change(self, path, signature, before, after):
        receipt = self._link_changes.get(path)
        return bool(receipt and receipt[0] == signature[0] and before in receipt[1:3] and after == receipt[3])

    def prepare(self, files, *, digests=None):
        sources = sorted({Path(path) for path in files if self.supports(path)})
        digests = digests or {}
        if len(sources) < 8:
            return {source for source in sources if self._prepare(source, checked=digests.get(source))}
        # Each path has its own ownership journal and scratch directory. Wait
        # for every publisher before the game can see the batch or we can retry.
        with ThreadPoolExecutor(max_workers=4, thread_name_prefix="MHRS assets") as workers:
            results = {source: workers.submit(self._prepare, source, checked=digests.get(source)) for source in sources}
        present = set()
        for source, result in results.items():
            try:
                ready = result.result()
            except OSError as error:
                # An installer may hard-link two source paths to the same file.
                # Overlapping verification handles can temporarily deny rename.
                if error.winerror not in (32, 33):
                    raise
                ready = self._prepare(source, checked=digests.get(source))
            if ready:
                present.add(source)
        return present

    def prepare_from_package(self, files, *, transfer=False):
        """Stage a private PAK extract if the mod file is absent; prefer a reinstall."""
        present = set()
        for ordinary, package in sorted((Path(k), Path(v)) for k, v in files.items()):
            if self.supports(ordinary) and self._prepare(ordinary, package, transfer_package=transfer):
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
