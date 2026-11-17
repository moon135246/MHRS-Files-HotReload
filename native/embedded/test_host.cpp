#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <filesystem>
#include <cstdio>
#include <cstdarg>
#include <reframework/API.h>
extern "C" {
#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>
}
static REFLuaStateCreatedCb created;
static bool had_error = false;
bool capture(REFLuaStateCreatedCb cb) {
    created = cb;
    return true;
}
void log_error(const char *fmt, ...) {
    had_error = true;
    va_list args;
    va_start(args, fmt);
    vfprintf(stderr, fmt, args);
    va_end(args);
    fputc('\n', stderr);
}
bool open_state() {
    lua_State *L = luaL_newstate();
    luaL_openlibs(L);
    const char *init = R"lua(
local function noop() end
sdk={typeof=noop,find_type_definition=function() return {get_method=noop,get_methods=function() return {} end} end, hook=noop}
re={on_application_entry=function(_,fn) assert(type(fn)=="function") end,
    on_pre_application_entry=function(_,fn) assert(type(fn)=="function") end,
    on_frame=function(fn) assert(type(fn)=="function") end,
    on_script_reset=function(fn) assert(type(fn)=="function") end}
json={load_file=noop,dump_file=function(_,v) assert(v.state=="loaded"); entered=true end}
log={warn=noop}
)lua";
    if (luaL_dostring(L, init) != 0)
        return false;
    created(L);
    lua_getglobal(L, "entered");
    bool ok = lua_toboolean(L, -1);
    lua_close(L);
    return ok && !had_error;
}
int main() {
    auto dll = LoadLibraryW(L"reframework/plugins/mhrs_hotreload.dll");
    if (!dll)
        return 1;
    REFrameworkPluginFunctions f{};
    f.on_lua_state_created = capture;
    f.log_error = log_error;
    REFrameworkPluginInitializeParam p{};
    p.functions = &f;
    auto init = reinterpret_cast<REFPluginInitializeFn>(GetProcAddress(dll, "reframework_plugin_initialize"));
    if (!init || !init(&p) || !created || !open_state() || !open_state())
        return 2;
    puts("two Lua states registered, one shared watcher");
    fflush(stdout);
    while (!std::filesystem::exists("pause.test"))
        Sleep(15);
    reinterpret_cast<void (*)()>(GetProcAddress(dll, "mhrs_pause_watcher"))();
    while (!std::filesystem::exists("resume.test"))
        Sleep(15);
    if (!open_state())
        return 3;
    while (!std::filesystem::exists("exit.test"))
        Sleep(15);
    reinterpret_cast<void (*)()>(GetProcAddress(dll, "mhrs_shutdown_watcher"))();
    FreeLibrary(dll);
    return had_error ? 4 : 0;
}
