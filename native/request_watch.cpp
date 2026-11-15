#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <cstddef>

namespace {
constexpr wchar_t channel[] = L"reframework/data/MHRS-Files-HotReload";
constexpr wchar_t request[] = L"request.json";
HANDLE directory = INVALID_HANDLE_VALUE;
OVERLAPPED operation{};
alignas(DWORD) unsigned char buffer[8192];
ULONGLONG next_open = 0;

void close_watch() {
    if (directory != INVALID_HANDLE_VALUE) {
        CancelIoEx(directory, &operation);
        DWORD bytes = 0;
        GetOverlappedResult(directory, &operation, &bytes, TRUE);
        CloseHandle(directory);
        directory = INVALID_HANDLE_VALUE;
    }
    if (operation.hEvent) CloseHandle(operation.hEvent);
    operation = {};
}

bool arm() {
    ResetEvent(operation.hEvent);
    return ReadDirectoryChangesW(directory, buffer, sizeof(buffer), FALSE,
        FILE_NOTIFY_CHANGE_FILE_NAME | FILE_NOTIFY_CHANGE_LAST_WRITE | FILE_NOTIFY_CHANGE_SIZE,
        nullptr, &operation, nullptr) != FALSE;
}

bool open_watch() {
    operation.hEvent = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    if (!operation.hEvent) return false;
    directory = CreateFileW(channel, FILE_LIST_DIRECTORY,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr, OPEN_EXISTING,
        FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OVERLAPPED, nullptr);
    return directory != INVALID_HANDLE_VALUE && arm();
}

bool contains_request(DWORD bytes) {
    // A buffer overflow has no names. Read the current mailbox once to reconcile.
    constexpr auto header = offsetof(FILE_NOTIFY_INFORMATION, FileName);
    DWORD offset = 0;
    while (bytes - offset >= header) {
        const auto* change = reinterpret_cast<const FILE_NOTIFY_INFORMATION*>(buffer + offset);
        if (change->FileNameLength > bytes - offset - header) return true;
        if (change->Action != FILE_ACTION_REMOVED && change->Action != FILE_ACTION_RENAMED_OLD_NAME &&
            change->FileNameLength == sizeof(request) - sizeof(wchar_t) &&
            CompareStringOrdinal(change->FileName, ARRAYSIZE(request) - 1, request, -1, TRUE) == CSTR_EQUAL)
            return true;
        if (!change->NextEntryOffset) return false;
        if (change->NextEntryOffset < header || change->NextEntryOffset > bytes - offset) return true;
        offset += change->NextEntryOffset;
    }
    return true;
}
}

// Called only from the Lua script thread. Returning one result echoes its
// argument (true). Returning no results is nil, without linking a Lua runtime.
extern "C" __declspec(dllexport) int mhrs_request_changed(void*) {
    if (directory == INVALID_HANDLE_VALUE) {
        const auto now = GetTickCount64();
        if (now >= next_open) {
            next_open = now + 1000;
            if (!open_watch()) close_watch();
        }
        return 1; // Also reconcile requests written before opening or after a failure.
    }
    const auto wait = WaitForSingleObject(operation.hEvent, 0);
    if (wait == WAIT_TIMEOUT) return 0;
    DWORD bytes = 0;
    if (wait != WAIT_OBJECT_0 || !GetOverlappedResult(directory, &operation, &bytes, FALSE)) {
        close_watch();
        return 1;
    }
    const bool dirty = contains_request(bytes);
    if (!arm()) {
        close_watch();
        return 1;
    }
    return dirty ? 1 : 0;
}

extern "C" __declspec(dllexport) int mhrs_close_request_watch(void*) {
    close_watch();
    next_open = 0;
    return 0;
}
