#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <Python.h>
#include <atomic>
#include <condition_variable>
#include <cstring>
#include <filesystem>
#include <mutex>
#include <stdexcept>
#include <reframework/API.h>
extern "C" {
#include <lua.h>
#include <lauxlib.h>
}

namespace {
HMODULE module;
const REFrameworkPluginFunctions *api;
std::mutex life;
HANDLE worker;
std::condition_variable state_changed;
std::atomic<unsigned long long> generation{};
unsigned long long running_generation;
bool enabled = false;
bool finished = false;

struct Blob {
    const unsigned char *bytes;
    DWORD size;
};
Blob resource(int id) {
    auto entry = FindResourceW(module, MAKEINTRESOURCEW(id), MAKEINTRESOURCEW(10));
    if (!entry)
        throw std::runtime_error("Missing plugin resource");
    auto bytes = static_cast<const unsigned char *>(LockResource(LoadResource(module, entry)));
    const auto size = SizeofResource(module, entry);
    if (!bytes || !size)
        throw std::runtime_error("Cannot read plugin resource");
    return {bytes, size};
}
PyObject *index_bytes(PyObject *, PyObject *args) {
    const char *filename;
    if (!PyArg_ParseTuple(args, "s", &filename))
        return nullptr;
    int id = std::strcmp(filename, "rise-16.0.2-links.json.gz") == 0     ? 102
             : std::strcmp(filename, "rise-16.0.2-shaders.json.gz") == 0 ? 103
                                                                         : 0;
    if (!id) {
        PyErr_SetString(PyExc_KeyError, filename);
        return nullptr;
    }
    try {
        auto data = resource(id);
        return PyBytes_FromStringAndSize(reinterpret_cast<const char *>(data.bytes), data.size);
    } catch (const std::exception &e) {
        PyErr_SetString(PyExc_RuntimeError, e.what());
        return nullptr;
    }
}
PyObject *checkpoint(PyObject *, PyObject *) {
    if (generation.load() != running_generation) {
        PyErr_SetNone(PyExc_KeyboardInterrupt);
        return nullptr;
    }
    Py_RETURN_NONE;
}
PyObject *first_natives_loaded(PyObject *, PyObject *) {
    return PyBool_FromLong(GetModuleHandleW(L"FirstNatives.dll") != nullptr);
}
PyMethodDef methods[] = {{"index", index_bytes, METH_VARARGS, nullptr},
                         {"checkpoint", checkpoint, METH_NOARGS, nullptr},
                         {"first_natives_loaded", first_natives_loaded, METH_NOARGS, nullptr},
                         {nullptr, nullptr, 0, nullptr}};
PyModuleDef def{PyModuleDef_HEAD_INIT, "_mhrs_runtime", nullptr, -1, methods};
PyObject *make_runtime() { return PyModule_Create(&def); }

void run_python() {
    const auto *bytecode = resource(101).bytes;
    static const _frozen frozen[] = {
#include "frozen.inc"
        {nullptr, nullptr, 0, 0, nullptr}};
    static const int registered = PyImport_AppendInittab("_mhrs_runtime", make_runtime);
    if (registered != 0)
        throw std::runtime_error("Failed to register the resource reader");
    PyImport_FrozenModules = frozen;
    PyConfig config;
    PyConfig_InitIsolatedConfig(&config);
    config.module_search_paths_set = 1;
    config.site_import = config.write_bytecode = config.install_signal_handlers = config.configure_c_stdio =
        0;
    config.pathconfig_warnings = 0;
    const auto result = Py_InitializeFromConfig(&config);
    PyConfig_Clear(&config);
    if (PyStatus_Exception(result))
        throw std::runtime_error(result.err_msg ? result.err_msg : "Python initialization failed");
    while (true) {
        {
            std::unique_lock lock(life);
            state_changed.wait(lock, [] { return enabled || finished; });
            if (finished)
                break;
            running_generation = generation.load();
        }
        int status = PyRun_SimpleString("from embedded_worker import run\nrun()");
        if (status != 0 && api)
            api->log_error("[MHRS-Files-HotReload] Watcher failed; see watcher.log");
        std::lock_guard lock(life);
        if (generation.load() == running_generation)
            enabled = false;
    }
    Py_FinalizeEx();
}

DWORD WINAPI background(void *owner) {
    try {
        run_python();
    } catch (const std::exception &e) {
        if (api)
            api->log_error("[MHRS-Files-HotReload] %s", e.what());
        std::lock_guard lock(life);
        finished = true;
    }
    FreeLibraryAndExitThread(static_cast<HMODULE>(owner), 0);
}
} // namespace

extern "C" __declspec(dllexport) int mhrs_start_watcher(void *) {
    std::lock_guard lock(life);
    if (finished)
        return 0;
    enabled = true;
    if (worker) {
        state_changed.notify_one();
        return 1;
    }
    HMODULE owner;
    if (!GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS,
                            reinterpret_cast<LPCWSTR>(&mhrs_start_watcher), &owner))
        return 0;
    module = owner;
    std::error_code ec;
    std::filesystem::create_directories(L"reframework/data/MHRS-Files-HotReload", ec);
    if (!ec) {
        worker = CreateThread(nullptr, 0, background, owner, 0, nullptr);
    }
    if (!worker)
        FreeLibrary(owner);
    return worker ? 1 : 0;
}

extern "C" __declspec(dllexport) void mhrs_pause_watcher() {
    std::lock_guard lock(life);
    enabled = false;
    ++generation;
}

extern "C" __declspec(dllexport) void mhrs_shutdown_watcher() {
    HANDLE thread = nullptr;
    {
        std::lock_guard lock(life);
        finished = true;
        ++generation;
        state_changed.notify_one();
        if (worker)
            DuplicateHandle(GetCurrentProcess(), worker, GetCurrentProcess(), &thread, SYNCHRONIZE, FALSE, 0);
    }
    if (thread) {
        WaitForSingleObject(thread, INFINITE);
        CloseHandle(thread);
    }
    std::lock_guard lock(life);
    if (worker) {
        CloseHandle(worker);
        worker = nullptr;
    }
}

#define MHR_FN(name) extern "C" int mhrs_##name(void *);
#include "api.inc"
#undef MHR_FN

namespace {
void on_lua(lua_State *state) {
    const int top = lua_gettop(state);
    try {
        std::filesystem::create_directories(L"reframework/data/MHRS-Files-HotReload");
        auto script = resource(104);
        int status = luaL_loadbufferx(state, reinterpret_cast<const char *>(script.bytes), script.size,
                                      "@MHRS_Files_HotReload.lua", "t");
        if (status == LUA_OK) {
            lua_newtable(state);
            lua_pushinteger(state, GetCurrentProcessId());
            lua_setfield(state, -2, "process_id");
#define MHR_FN(name)                                                                                         \
    lua_pushcfunction(state, [](lua_State *s) { return mhrs_##name(s); });                                   \
    lua_setfield(state, -2, #name);
#include "api.inc"
#undef MHR_FN
            status = lua_pcall(state, 1, 0, 0);
        }
        if (status != LUA_OK)
            api->log_error("[MHRS-Files-HotReload] %s", lua_tostring(state, -1));
    } catch (const std::exception &e) {
        api->log_error("[MHRS-Files-HotReload] %s", e.what());
    }
    lua_settop(state, top);
}
} // namespace

extern "C" __declspec(dllexport) void reframework_plugin_required_version(REFrameworkPluginVersion *v) {
    v->major = 1;
    v->minor = 0;
    v->patch = 0;
    v->game_name = "MHRISE";
}
extern "C" __declspec(dllexport) bool
reframework_plugin_initialize(const REFrameworkPluginInitializeParam *param) {
    if (!param || !param->functions || !param->functions->on_lua_state_created)
        return false;
    api = param->functions;
    if (!GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS |
                                GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                            reinterpret_cast<LPCWSTR>(&reframework_plugin_initialize), &module))
        return false;
    return api->on_lua_state_created(on_lua);
}
