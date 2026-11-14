// Rise Steam 16.0.2.0. Called on the game thread by REFramework package.loadlib.
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <cwchar>
#include <limits>

namespace {
using Ptr = uintptr_t;
struct Kind { const wchar_t* ext; uint32_t id; const char* name; };
constexpr Kind kinds[] = {
    {L".mdf2",0xb16b241e,"via.render.MeshMaterialResource"},
    {L".mesh",0x5da4e5c8,"via.render.MeshResource"},
    {L".chain",0x5b53b1ab,"via.motion.ChainResource"},
    {L".tex",0x3590e544,"via.render.TextureResource"},
    {L".mmtr",0x9c0da5c7,"via.render.MasterMaterialResource"},
    {L".jcns",0x8a7d4b14,"via.motion.JointConstraintsResource"},
    {L".motbank",0xbc91e6b4,"via.motion.MotionBankResource"},
    {L".efx",0,"via.effect.EffectResource"},
    {L".motlist",0,"via.motion.MotionListResource"},
    {L".rcol",0,"via.physics.RequestSetColliderResource"},
    {L".uvs",0,"via.uvsequence.UVSequenceResource"},
    {L".rtex",0,"via.render.RenderTargetTextureResource"},
    {L".uvar",0,"via.userdata.UserVariablesResource"},
    {L".fbxskel",0,"via.motion.FbxSkeletonResource"},
    {L".mot",0,"via.motion.MotionResource"}
};
constexpr char result_path[] = "reframework/data/MHRS-Files-HotReload/native-state.txt";
const Ptr base = reinterpret_cast<Ptr>(GetModuleHandleW(nullptr));
struct Transaction { Ptr manager{}, old{}, fresh{}, key{}, parking{}; const Kind* kind{}; } tx, masters[2];
size_t master_count{};
template<class T> T& field(Ptr p, size_t offset) { return *reinterpret_cast<T*>(p + offset); }
template<class Fn> Fn function(size_t rva) { return reinterpret_cast<Fn>(base+rva); }
void write_state(const char* message, Ptr value = 0) {
    FILE* f{};
    if (fopen_s(&f, result_path, "wb") == 0) {
        fprintf(f, "%s\n%llu\n", message, static_cast<unsigned long long>(value));
        fclose(f);
    }
}
bool supported() {
    wchar_t exe[MAX_PATH]{};
    GetModuleFileNameW(nullptr, exe, MAX_PATH);
    const auto name = wcsrchr(exe, L'\\');
    if (!name || _wcsicmp(name+1, L"MonsterHunterRise.exe") != 0) return false;
    auto dos = reinterpret_cast<const IMAGE_DOS_HEADER*>(base);
    auto nt = reinterpret_cast<const IMAGE_NT_HEADERS64*>(base+dos->e_lfanew);
    if (nt->OptionalHeader.SizeOfImage <= 0xf621630) return false;
    return memcmp((void*)(base+0x416ef40), "\x40\x53\x57\x41\x55\x48\x83\xec\x50", 9)==0 &&
           memcmp((void*)(base+0x416f0e9), "\x49\x8d\x8d\x10\x04\x00\x00", 7)==0 &&
           memcmp((void*)(base+0x416f0fb), "\x49\x8b\x95\x48\x0c\x00\x00", 7)==0 &&
           memcmp((void*)(base+0x41718e9), "\x48\x8d\x8f\x48\x0c\x00\x00\xe8\xfb\x8e\xff\xff", 12)==0 &&
           memcmp((void*)(base+0x416d9d0), "\x48\x8b\xd1\x48\x8b\x0d\x56\x3c\x4b\x0b", 10)==0;
}
struct Lock {
    CRITICAL_SECTION* cs;
    explicit Lock(Ptr rm) : cs(reinterpret_cast<CRITICAL_SECTION*>(rm+0x410)) { EnterCriticalSection(cs); }
    ~Lock() { LeaveCriticalSection(cs); }
};
template<class Key> Ptr lookup(Ptr map, Key key) {
    const auto head = field<Ptr>(map, 0);
    auto node = field<Ptr>(head, 8);
    for (int depth = 0; depth < 96 && node != head && !field<uint8_t>(node, 0x19); ++depth) {
        auto candidate = field<Key>(node, 0x20);
        if (candidate == key) return node;
        node = field<Ptr>(node, key < candidate ? 0 : 0x10);
    }
    return 0;
}
void retain(Ptr resource) { function<void(*)(Ptr)>(0x416d820)(resource); }
// The extension registry is small. Resolve new families by registered class name.
Ptr registered_type(Ptr node, const char* name, unsigned depth=0) {
    if (!node || depth>=96 || field<uint8_t>(node,0x19)) return 0;
    const Ptr type=field<Ptr>(node,0x28);
    if (type && field<const char*>(type,0x20) && !strcmp(field<const char*>(type,0x20),name)) return node;
    const Ptr left=registered_type(field<Ptr>(node,0),name,depth+1);
    return left ? left : registered_type(field<Ptr>(node,0x10),name,depth+1);
}
void release(Ptr resource) { function<void(*)(Ptr)>(0x416d9d0)(resource); }
void erase(Ptr map, Ptr node) {
    auto detached = function<Ptr(*)(Ptr,Ptr)>(0x416a7f0)(map, node);
    function<void(*)(Ptr)>(0x421f0e0)(detached);
}
// Keep retired resources registered for their ordinary reference-count teardown.
// The native tree routines use Rise's own allocator and maintain its ordering.
void relocate(Ptr map, Ptr node, Ptr resource, Ptr new_key) {
    auto slot = function<Ptr*(*)(Ptr,const Ptr*)>(0x416e8f0)(map, &new_key);
    *slot = resource;
    field<Ptr>(resource, 0x30) = new_key;
    erase(map, node);
}
Ptr unused_key(Ptr map) {
    Ptr k = std::numeric_limits<Ptr>::max();
    while (lookup(map,k)) --k;
    return k;
}
bool finish_resource(Ptr r);
bool deps_ready(Ptr r);
const char* begin(const wchar_t* path, const Kind& kind) {
    if (tx.old) return "transaction already active";
    if (!supported()) return "unsupported Rise build";
    const Ptr rm = field<Ptr>(base, 0x416d9da+0xb4b3c56);
    if (!rm) return "manager unavailable";
    const Ptr key = function<Ptr(*)(const wchar_t*)>(0x4171030)(path);
    Lock lock(rm);
    const Ptr map = rm + 0xc48, node = lookup(map,key);
    const Ptr registry=rm+0xc58;
    const Ptr type_node = kind.id ? lookup<uint32_t>(registry,kind.id)
                                  : registered_type(field<Ptr>(field<Ptr>(registry,0),8),kind.name);
    if (!node || !type_node) return "equipped resource not in cache";
    const Ptr type = field<Ptr>(type_node,0x28), old = field<Ptr>(node,0x28);
    if (!old || !type || strcmp(field<const char*>(type,0x20),kind.name) ||
        field<Ptr>(old,0x30)!=key || _wcsicmp(field<const wchar_t*>(old,8),path))
        return "unexpected cached resource identity";
    if (field<uint16_t>(old,0x38)!=0x101) {
        // A first-use holder can precede the engine's second initialization stage.
        const bool ready = &kind == &kinds[0] ? deps_ready(old) : finish_resource(old);
        if (!ready) return "cached resource not initialized";
    }
    retain(old);
    const Ptr parking = unused_key(map);
    relocate(map,node,old,parking);
    const Ptr fresh = function<Ptr(*)(Ptr,Ptr,const wchar_t*)>(0x416ef40)(rm,type,path);
    if (!fresh) {
        relocate(map,lookup(map,parking),old,key);
        release(old);
        return "native resource creation failed";
    }
    tx = {rm,old,fresh,key,parking,&kind};
    return "pending";
}
const char* begin_asset() {
    FILE* f{};
    if (fopen_s(&f,"reframework/data/MHRS-Files-HotReload/asset-path.txt","rb")!=0) return "missing resource path";
    char bytes[2048]{};
    const auto n=fread(bytes,1,sizeof(bytes),f);
    fclose(f);
    wchar_t path[2048]{};
    if (!n || n==sizeof(bytes) || memchr(bytes,0,n) ||
        !MultiByteToWideChar(CP_UTF8,MB_ERR_INVALID_CHARS,bytes,static_cast<int>(n),path,2047) ||
        *path==L'/' || wcspbrk(path,L"\\:\r\n") || wcsstr(path,L"..")) return "invalid resource path";
    const auto ext=wcsrchr(path,L'.');
    for (const auto& kind:kinds) if (ext && !_wcsicmp(ext,kind.ext)) return begin(path,kind);
    return "unsupported resource extension";
}
// A newly requested texture can stay CPU-ready until a consumer runs Rise's
// second-stage resource finalizer. Poll is called on the game thread.
bool finish_resource(Ptr r) {
    if (!r || field<uint8_t>(r,0x38)!=1) return false;
    if (!field<uint8_t>(r,0x39)) function<bool(*)(Ptr)>(0x416db60)(r);
    return field<uint8_t>(r,0x39)==1;
}
bool deps_ready(Ptr r) {
    if (!field<uint8_t>(r,0x38)) return false;
    const Ptr raw=field<Ptr>(r,0x50), mats=field<Ptr>(r,0x58);
    if (!raw || !mats || field<uint32_t>(raw,0)!=0x46444d) return false;
    const auto count=field<uint16_t>(raw,6);
    if (!count || count>256) return false;
    for (unsigned i=0;i<count;i++) {
        const Ptr m=mats+i*0x110, h=raw+16+i*80;
        if (field<Ptr>(m,0x30)!=h) return false;
        const Ptr mmtr=field<Ptr>(m,0x38), entries=field<Ptr>(m,0x40);
        const auto n=field<uint32_t>(m,0x48);
        if (!mmtr || field<uint16_t>(mmtr,0x38)!=0x101 ||
            n!=field<uint32_t>(h,20) || n>1024 || (n && !entries)) return false;
        for (unsigned j=0;j<n;j++) {
            const Ptr tex=field<Ptr>(entries+j*16,8);
            if (!finish_resource(tex)) return false;
        }
    }
    // Invoke the same second-stage resource finalizer used by Rise's Mesh
    // setter, before exposing the fresh resource to an equipped mesh.
    return finish_resource(r);
}
const char* finish(bool commit) {
    if (!tx.old) return "no active transaction";
    {
        Lock lock(tx.manager);
        const auto map=tx.manager+0xc48, live=lookup(map,tx.key), parked=lookup(map,tx.parking);
        if (!live || !parked || field<Ptr>(live,0x28)!=tx.fresh || field<Ptr>(parked,0x28)!=tx.old)
            return "cache changed during transaction";
        if (!commit) {
            relocate(map,live,tx.fresh,unused_key(map));
            relocate(map,parked,tx.old,tx.key);
        }
    }
    release(tx.old);
    release(tx.fresh);
    tx={};
    return commit ? "committed" : "rolled back";
}
}
// No Lua ABI dependency: these lua_CFunctions take no arguments and return zero
// Lua values. The calling script reads the status immediately after each call.
extern "C" __declspec(dllexport) int mhrs_begin(void*) {
    auto msg=begin(L"player/mod/f/pl279/f_arm279.mdf2",kinds[0]); write_state(msg,tx.fresh); return 0;
}
extern "C" __declspec(dllexport) int mhrs_asset(void*) { auto msg=begin_asset(); write_state(msg,tx.fresh); return 0; }
// Rise JCNS v21 relocates the group table and its group pointers on load.
// Check the pending resource before publishing it to any layer.
extern "C" __declspec(dllexport) int mhrs_joint_outputs(void*) {
    if (!tx.fresh || tx.kind!=&kinds[5] || field<uint16_t>(tx.fresh,0x38)!=0x101) {
        write_state("JCNS resource not ready"); return 0;
    }
    const auto raw=field<Ptr>(tx.fresh,0x58);
    if (!raw || field<uint32_t>(raw,0)!=21 || field<uint32_t>(raw,4)!=0x736e636a ||
        field<uint32_t>(raw,40)!=1) {
        write_state("unexpected JCNS group layout"); return 0;
    }
    const auto table=field<Ptr>(raw,32);
    const auto group=table ? field<Ptr>(table,0) : 0;
    if (group) write_state("outputs",field<uint16_t>(group,76));
    else write_state("missing JCNS group");
    return 0;
}
// Keep the dependency and its old cache entry alive while its users rebind.
extern "C" __declspec(dllexport) int mhrs_hold_master(void*) {
    if (master_count < sizeof(masters)/sizeof(masters[0]) && tx.old && field<uint16_t>(tx.fresh,0x38)==0x101) {
        masters[master_count++]=tx; write_state("held",tx.fresh); tx={};
    } else write_state("template not ready");
    return 0;
}
extern "C" __declspec(dllexport) int mhrs_resume_master(void*) {
    if (master_count && !tx.old) { tx=masters[--master_count]; masters[master_count]={}; write_state("resumed",tx.fresh); }
    else write_state("template cannot resume");
    return 0;
}
extern "C" __declspec(dllexport) int mhrs_poll(void*) {
    const bool ready=tx.fresh && (tx.kind==&kinds[0] ? deps_ready(tx.fresh) : finish_resource(tx.fresh));
    write_state(!tx.fresh ? "no active transaction" : ready ? "ready" : "pending",tx.fresh);
    return 0;
}
extern "C" __declspec(dllexport) int mhrs_commit(void*) { write_state(finish(true)); return 0; }
extern "C" __declspec(dllexport) int mhrs_abort(void*) { write_state(finish(false)); return 0; }
