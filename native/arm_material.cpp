// Rise Steam 16.0.2.0. Called on the game thread by REFramework package.loadlib.
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <cwchar>
#include <limits>
#include <set>
#include <string>
#include <vector>

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
    {L".mot",0,"via.motion.MotionResource"},
    {L".pfb",0,"via.PrefabResource"},
    {L".user",0,"via.UserDataResource"},
    {L".gui",0,"via.gui.GUIResource"}
};
constexpr char result_path[] = "reframework/data/MHRS-Files-HotReload/native-state.txt";
const Ptr base = reinterpret_cast<Ptr>(GetModuleHandleW(nullptr));
struct Transaction { Ptr manager{}, old{}, fresh{}, key{}, parking{}; const Kind* kind{}; bool require_platform{}; } tx, masters[2];
size_t master_count{};
std::vector<Transaction> staged_mdfs;
std::set<Ptr> platform_keys;
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
const char* begin(const wchar_t* path, const Kind& kind, bool platform=false) {
    if (tx.fresh) return "transaction already active";
    if (!supported()) return "unsupported Rise build";
    const Ptr rm = field<Ptr>(base, 0x416d9da+0xb4b3c56);
    if (!rm) return "manager unavailable";
    const Ptr key = function<Ptr(*)(const wchar_t*)>(0x4171030)(path);
    Lock lock(rm);
    const Ptr map = rm + 0xc48, node = lookup(map,key);
    const Ptr registry=rm+0xc58;
    const Ptr type_node = kind.id ? lookup<uint32_t>(registry,kind.id)
                                  : registered_type(field<Ptr>(field<Ptr>(registry,0),8),kind.name);
    if (!type_node) return "resource type unavailable";
    const Ptr type = field<Ptr>(type_node,0x28);
    if (!type || strcmp(field<const char*>(type,0x20),kind.name)) return "unexpected registered resource type";
    if (!node) {
        // An active component may still own the previous generation after
        // a grouped change vacated this key.
        const std::wstring request_path=(platform || platform_keys.count(key)) ? std::wstring(L"@")+path : path;
        const Ptr fresh=function<Ptr(*)(Ptr,Ptr,const wchar_t*)>(0x416ef40)(rm,type,request_path.c_str());
        if (!fresh) return "native resource creation failed";
        tx={rm,0,fresh,key,0,&kind,platform};
        return "pending";
    }
    const Ptr old=field<Ptr>(node,0x28);
    if (!old ||
        field<Ptr>(old,0x30)!=key || _wcsicmp(field<const wchar_t*>(old,8),path))
        return "unexpected cached resource identity";
    if (field<uint16_t>(old,0x38)!=0x101) {
        // A first-use holder can precede the engine's second initialization stage.
        const bool ready = &kind == &kinds[0] ? deps_ready(old) : finish_resource(old);
        if (!ready) return "cached resource not initialized";
    }
    // Rise strips '@' from the cache key and stored path, but keeps the
    // platform-file flag on the resource. Preserve it when reopening .stm.
    const std::wstring request_path = (platform || field<uint8_t>(old,0x3a)) ? std::wstring(L"@") + path : path;
    retain(old);
    const Ptr parking = unused_key(map);
    relocate(map,node,old,parking);
    const Ptr fresh = function<Ptr(*)(Ptr,Ptr,const wchar_t*)>(0x416ef40)(rm,type,request_path.c_str());
    if (!fresh) {
        relocate(map,lookup(map,parking),old,key);
        release(old);
        return "native resource creation failed";
    }
    tx = {rm,old,fresh,key,parking,&kind,platform};
    return "pending";
}
// A file can disappear while meshes, prefab instances or motion layers still own
// the old version. Leave their references alive and free only the original key.
// On next use the ordinary factory picks the PAK entry (or reports a missing asset).
const char* forget(const wchar_t* path, const Kind& kind) {
    if (tx.fresh || master_count) return "resource transaction active";
    if (!supported()) return "unsupported Rise build";
    const Ptr rm = field<Ptr>(base, 0x416d9da+0xb4b3c56);
    if (!rm) return "manager unavailable";
    const Ptr key = function<Ptr(*)(const wchar_t*)>(0x4171030)(path);
    Lock lock(rm);
    const Ptr map = rm + 0xc48, node = lookup(map,key);
    if (!node) return "not cached";
    const Ptr old = field<Ptr>(node,0x28);
    if (!old || field<Ptr>(old,0x30)!=key || !field<const wchar_t*>(old,8) ||
        _wcsicmp(field<const wchar_t*>(old,8),path)) return "unexpected cached resource identity";
    const auto ext = wcsrchr(field<const wchar_t*>(old,8),L'.');
    if (!ext || _wcsicmp(ext,kind.ext)) return "unexpected resource extension";
    if (field<uint8_t>(old,0x3a)) platform_keys.insert(key); else platform_keys.erase(key);
    relocate(map,node,old,unused_key(map));
    return "retired";
}

// Collect aliases from engine holders and asset references in Lua/Python.
// Look up only the requested keys. Unrelated cache entries can have different
// layouts and must never be interpreted as path-bearing resources.
const char* forget_batch() {
    if (tx.fresh || master_count) return "resource transaction active";
    if (!supported()) return "unsupported Rise build";
    FILE* input{};
    if (fopen_s(&input, "reframework/data/MHRS-Files-HotReload/asset-paths.txt", "rb"))
        return "missing resource paths";
    std::vector<std::wstring> paths;
    char line[8192];
    bool valid = true;
    while (fgets(line, sizeof(line), input)) {
        const size_t length = strcspn(line, "\r\n");
        if (!length || line[length] != '\n') { valid = false; break; }
        wchar_t path[2048]{};
        if (!MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, line, static_cast<int>(length), path, 2047)
                || *path == L'/' || wcspbrk(path, L"\\:") || wcsstr(path, L"..")) {
            valid = false; break;
        }
        const wchar_t* ext = wcsrchr(path, L'.');
        bool known = false;
        for (const auto& kind : kinds) if (ext && !_wcsicmp(ext, kind.ext)) { known = true; break; }
        if (!known) { valid = false; break; }
        paths.emplace_back(path);
    }
    valid = valid && !ferror(input);
    fclose(input);
    if (!valid || paths.empty()) return "invalid resource paths";
    const Ptr rm = field<Ptr>(base, 0x416d9da+0xb4b3c56);
    if (!rm) return "manager unavailable";
    std::vector<unsigned> counts(paths.size());
    {
        Lock lock(rm);
        const Ptr map = rm + 0xc48;
        struct Match { Ptr key, resource; size_t index; };
        std::vector<Match> matches;
        std::set<Ptr> seen;
        for (size_t i=0; i<paths.size(); ++i) {
            const auto* path = paths[i].c_str();
            const Ptr key = function<Ptr(*)(const wchar_t*)>(0x4171030)(path);
            if (!seen.insert(key).second) continue;
            const Ptr node = lookup(map, key);
            if (!node) continue;
            const Ptr resource = field<Ptr>(node, 0x28);
            if (!resource || field<Ptr>(resource, 0x30) != key || !field<const wchar_t*>(resource, 8)
                    || _wcsicmp(field<const wchar_t*>(resource, 8), path)) return "unexpected cached resource identity";
            matches.push_back({key,resource,i});
        }
        Ptr parking = std::numeric_limits<Ptr>::max();
        // Remember the engine's platform spelling for active holders that
        // outlive this cache generation and later need an explicit live bind.
        for (const auto& match : matches) {
            if (field<uint8_t>(match.resource,0x3a)) platform_keys.insert(match.key);
            else platform_keys.erase(match.key);
        }
        for (const auto& match : matches) {
            // Tree erase/rebalance may move another node. A key is stable
            // across the preceding removals, an address into the tree is not.
            const Ptr node = lookup(map, match.key);
            if (!node || field<Ptr>(node, 0x28)!=match.resource) return "cache changed during retirement";
            while (lookup(map, parking)) --parking;
            relocate(map, node, match.resource, parking--);
            ++counts[match.index];
        }
    }
    FILE* receipt{};
    if (fopen_s(&receipt, "reframework/data/MHRS-Files-HotReload/retired-counts.txt", "wb"))
        return "cannot write retirement receipt";
    for (const auto count : counts) fprintf(receipt, "%u\n", count);
    return fclose(receipt) == 0 ? "retired batch" : "cannot finish retirement receipt";
}
const char* dispatch_asset(bool removed) {
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
    for (const auto& kind:kinds) if (ext && !_wcsicmp(ext,kind.ext)) {
        if (removed) return forget(path,kind);
        if (!_wcsicmp(ext,L".pfb") || !_wcsicmp(ext,L".user") || !_wcsicmp(ext,L".gui"))
            return "use managed resource factory";
        const bool platform=path[0]==L'@';
        return begin(platform ? path+1 : path,kind,platform);
    }
    return "unsupported resource extension";
}

struct PathLess {
    bool operator()(const std::wstring& a, const std::wstring& b) const { return _wcsicmp(a.c_str(),b.c_str())<0; }
};
// The scene supplies exact MDF paths. Only inspect textures and templates of
// those initialized materials, using the same v23 tables as deps_ready().
const char* material_links() {
    if (!supported()) return "unsupported Rise build";
    FILE* input{};
    if (fopen_s(&input,"reframework/data/MHRS-Files-HotReload/material-paths.txt","rb")) return "missing material paths";
    std::vector<std::wstring> owners;
    std::set<std::wstring,PathLess> wanted;
    char line[8192];
    bool valid=true;
    while (fgets(line,sizeof(line),input)) {
        size_t n=strcspn(line,"\r\n");
        wchar_t path[2048]{};
        if (!n || line[n]!='\n' || !MultiByteToWideChar(CP_UTF8,MB_ERR_INVALID_CHARS,line,static_cast<int>(n),path,2047)) { valid=false; break; }
        const wchar_t* ext=wcsrchr(path,L'.');
        if (ext && !_wcsicmp(ext,L".mdf2")) owners.emplace_back(path);
        else if (ext && (!_wcsicmp(ext,L".tex") || !_wcsicmp(ext,L".mmtr"))) wanted.emplace(path);
        else { valid=false; break; }
    }
    valid=valid && !ferror(input);
    fclose(input);
    if (!valid) return "invalid material paths";
    const Ptr rm=field<Ptr>(base,0x416d9da+0xb4b3c56);
    if (!rm) return "manager unavailable";
    std::set<std::pair<std::wstring,std::wstring>> pairs;
    {
        Lock lock(rm);
        for (const auto& path:owners) {
            const Ptr key=function<Ptr(*)(const wchar_t*)>(0x4171030)(path.c_str());
            const Ptr node=lookup(rm+0xc48,key);
            const Ptr mdf=node ? field<Ptr>(node,0x28) : 0;
            if (!mdf || field<uint16_t>(mdf,0x38)!=0x101 || field<Ptr>(mdf,0x30)!=key) continue;
            const auto name=field<const wchar_t*>(mdf,8);
            if (!name || _wcsicmp(name,path.c_str())) continue;
            const Ptr raw=field<Ptr>(mdf,0x50), slots=field<Ptr>(mdf,0x58);
            if (!raw || !slots || field<uint32_t>(raw,0)!=0x46444d) continue;
            const auto count=field<uint16_t>(raw,6);
            if (count>256) continue;
            auto add=[&](Ptr resource) {
                if (!resource || field<uint8_t>(resource,0x38)!=1) return;
                const auto child=field<const wchar_t*>(resource,8);
                if (child && wanted.count(child)) pairs.emplace(path,child);
            };
            for (unsigned i=0;i<count;++i) {
                const Ptr slot=slots+i*0x110, header=raw+16+i*80;
                if (field<Ptr>(slot,0x30)!=header) continue;
                add(field<Ptr>(slot,0x38));
                const Ptr textures=field<Ptr>(slot,0x40);
                const auto n=field<uint32_t>(slot,0x48);
                if (!textures || n!=field<uint32_t>(header,20) || n>1024) continue;
                for (unsigned j=0;j<n;++j) add(field<Ptr>(textures+j*16,8));
            }
        }
    }
    FILE* out{};
    if (fopen_s(&out,"reframework/data/MHRS-Files-HotReload/material-links.txt","wb")) return "cannot write material links";
    for (const auto& pair:pairs) {
        const auto row=pair.first+L"\t"+pair.second+L"\n";
        const int length=WideCharToMultiByte(CP_UTF8,0,row.c_str(),static_cast<int>(row.size()),nullptr,0,nullptr,nullptr);
        std::string utf8(length,'\0');
        if (!length || !WideCharToMultiByte(CP_UTF8,0,row.c_str(),static_cast<int>(row.size()),utf8.data(),length,nullptr,nullptr)
                || fwrite(utf8.data(),1,length,out)!=static_cast<size_t>(length)) { fclose(out);return "cannot write material link"; }
    }
    return fclose(out)==0 ? "material links" : "cannot finish material links";
}
// A newly requested texture can stay CPU-ready until a consumer runs Rise's
// second-stage resource finalizer. Poll is called on the game thread.
bool finish_resource(Ptr r) {
    if (!r || field<uint8_t>(r,0x38)!=1) return false;
    if (!field<uint8_t>(r,0x39)) function<bool(*)(Ptr)>(0x416db60)(r);
    return field<uint8_t>(r,0x39)==1;
}
bool deps_ready_detail(Ptr r, const wchar_t** waiting) {
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
        if (!mmtr || !finish_resource(mmtr)) {
            if (waiting && mmtr) *waiting=field<const wchar_t*>(mmtr,8);
            return false;
        }
        if (n!=field<uint32_t>(h,20) || n>1024 || (n && !entries)) return false;
        for (unsigned j=0;j<n;j++) {
            const Ptr tex=field<Ptr>(entries+j*16,8);
            if (!finish_resource(tex)) {
                if (waiting && tex) *waiting=field<const wchar_t*>(tex,8);
                return false;
            }
        }
    }
    // Invoke the same second-stage resource finalizer used by Rise's Mesh
    // setter, before exposing the fresh resource to an equipped mesh.
    return finish_resource(r);
}
bool deps_ready(Ptr r) { return deps_ready_detail(r,nullptr); }

// A resource may already have been requested normally by a prefab or loader.
// Verify that the first request for every companion actually won the ordinary
// key, and wait for standalone textures before the watcher removes its copy.
const char* equipment_platform_ready(Ptr rm, FILE* waiting) {
    FILE* input{};
    if (fopen_s(&input,"reframework/data/MHRS-Files-HotReload/equipment-platform.txt","rb"))
        return "missing equipment platform list";
    const char* result="ready";
    char line[8192];
    while (fgets(line,sizeof(line),input)) {
        char* tab=strchr(line,'\t');
        unsigned long long address{};
        char ending{};
        if (!tab || sscanf_s(tab+1,"%llu%c",&address,&ending,1u)!=2 || ending!='\n') {
            result="invalid equipment platform list"; break;
        }
        *tab='\0';
        wchar_t path[2048]{};
        if (!MultiByteToWideChar(CP_UTF8,MB_ERR_INVALID_CHARS,line,-1,path,2048)) {
            result="invalid equipment platform path"; break;
        }
        const auto ext=wcsrchr(path,L'.');
        const bool texture=ext && !_wcsicmp(ext,L".tex");
        if (!ext || (!texture && _wcsicmp(ext,L".mesh") && _wcsicmp(ext,L".mdf2") && _wcsicmp(ext,L".chain") && _wcsicmp(ext,L".mot"))) {
            result="invalid equipment platform resource"; break;
        }
        const Ptr key=function<Ptr(*)(const wchar_t*)>(0x4171030)(path);
        Ptr resource{};
        {
            Lock lock(rm);
            const Ptr node=lookup(rm+0xc48,key);
            resource=node ? field<Ptr>(node,0x28) : 0;
            if (!resource || resource!=address || field<Ptr>(resource,0x30)!=key
                    || !field<const wchar_t*>(resource,8) || _wcsicmp(path,field<const wchar_t*>(resource,8))
                    || !field<uint8_t>(resource,0x3a)) {
                if (waiting) fprintf(waiting,"%s expected platform request @%s, loaded %s\n",line,line,
                    resource && resource==address ? "ordinary source" : "different cache resource");
                result="equipment platform source mismatch"; break;
            }
            retain(resource);
        }
        if (texture && !finish_resource(resource)) {
            result="pending";
            if (waiting) fprintf(waiting,"%s\t%04x\n",line,unsigned(field<uint16_t>(resource,0x38)));
        }
        release(resource);
    }
    if (ferror(input)) result="cannot read equipment platform list";
    fclose(input);
    return result;
}

// Rise v23 MDF stores the UTF-16 material name in the same raw buffer as the
// 80-byte slot header. The loader can fix a file offset into an absolute
// pointer. Bound either representation before reading the string.
bool write_material_slots(FILE* out, Ptr resource, const char* path) {
    const Ptr raw=field<Ptr>(resource,0x50), slots=field<Ptr>(resource,0x58);
    if (!raw || !slots || field<uint32_t>(raw,0)!=0x46444d) return false;
    const unsigned count=field<uint16_t>(raw,6);
    if (!count || count>256) return false;
    const size_t header_end=16+count*80;
    for (unsigned i=0;i<count;++i) {
        const Ptr header=raw+16+i*80;
        if (field<Ptr>(slots+i*0x110,0x30)!=header) return false;
        const Ptr value=field<Ptr>(header,0);
        const Ptr offset=value>=raw ? value-raw : value;
        if (offset<header_end || offset>=16*1024*1024 || (offset&1)) return false;
        const Ptr location=raw+offset;
        MEMORY_BASIC_INFORMATION region{};
        if (!VirtualQuery(reinterpret_cast<void*>(location),&region,sizeof(region))
                || region.State!=MEM_COMMIT || (region.Protect&(PAGE_NOACCESS|PAGE_GUARD))) return false;
        const auto* name=reinterpret_cast<const wchar_t*>(location);
        const auto remaining=(reinterpret_cast<Ptr>(region.BaseAddress)+region.RegionSize-location)/sizeof(wchar_t);
        const size_t limit=remaining<1024 ? remaining : 1024;
        const size_t length=wcsnlen_s(name,limit);
        if (!length || length==limit || wcspbrk(name,L"\t\r\n")) return false;
        char utf8[4096]{};
        const int size=WideCharToMultiByte(CP_UTF8,WC_ERR_INVALID_CHARS,name,static_cast<int>(length),
                                           utf8,sizeof(utf8)-1,nullptr,nullptr);
        if (size<=0 || fprintf(out,"%s\t%llu\t%s\n",path,static_cast<unsigned long long>(resource),utf8)<0) return false;
    }
    return true;
}
bool owns_cache_entries(const Transaction& t) {
    const Ptr map=t.manager+0xc48, live=lookup(map,t.key);
    if (!live || field<Ptr>(live,0x28)!=t.fresh) return false;
    if (!t.old) return true;
    const Ptr parked=lookup(map,t.parking);
    return parked && field<Ptr>(parked,0x28)==t.old;
}
void restore_entries(const Transaction& t) {
    const Ptr map=t.manager+0xc48;
    relocate(map,lookup(map,t.key),t.fresh,unused_key(map));
    if (t.old) relocate(map,lookup(map,t.parking),t.old,t.key);
}
void release_transaction(const Transaction& t) {
    if (t.old) release(t.old);
    release(t.fresh);
}
const char* finish(bool commit) {
    if (!tx.fresh) return "no active transaction";
    {
        Lock lock(tx.manager);
        if (!owns_cache_entries(tx)) return "cache changed during transaction";
        if (!commit) restore_entries(tx);
    }
    release_transaction(tx);
    tx={};
    return commit ? "committed" : "rolled back";
}
// All owner cache entries and the template stay pinned until every holder has
// been checked. A failed second owner leaves the first one's original key intact.
bool uses_staged_template(const Transaction& mdf, const Transaction& shader) {
    const Ptr raw=field<Ptr>(mdf.fresh,0x50), mats=field<Ptr>(mdf.fresh,0x58);
    const wchar_t* path=field<const wchar_t*>(shader.fresh,8);
    if (!raw || !mats || !path) return false;
    bool found=false;
    for (unsigned i=0;i<field<uint16_t>(raw,6);++i) {
        const Ptr material_shader=field<Ptr>(mats+i*0x110,0x38);
        if (material_shader==shader.fresh) found=true;
        else if (material_shader) {
            const wchar_t* used=field<const wchar_t*>(material_shader,8);
            if (used && !_wcsicmp(used,path)) return false;
        }
    }
    return found;
}
const char* finish_material_group(bool commit) {
    if (tx.fresh || master_count!=1 || masters[0].kind!=&kinds[4]) return "no held MMTR group";
    const Transaction shader=masters[0];
    {
        Lock lock(shader.manager);
        if (!owns_cache_entries(shader)) return "template cache changed during transaction";
        for (const auto& t:staged_mdfs)
            if (!owns_cache_entries(t)) return "MDF cache changed during transaction";
        if (!commit) {
            for (const auto& t:staged_mdfs) restore_entries(t);
            restore_entries(shader);
        }
    }
    for (const auto& t:staged_mdfs) release_transaction(t);
    staged_mdfs.clear();
    release_transaction(shader);
    masters[0]={};
    master_count=0;
    return commit ? "committed" : "rolled back";
}
}
// No Lua ABI dependency: these lua_CFunctions take no arguments and return zero
// Lua values. The calling script reads the status immediately after each call.
extern "C" __declspec(dllexport) int mhrs_begin(void*) {
    auto msg=begin(L"player/mod/f/pl279/f_arm279.mdf2",kinds[0]); write_state(msg,tx.fresh); return 0;
}
extern "C" __declspec(dllexport) int mhrs_asset(void*) { auto msg=dispatch_asset(false); write_state(msg,tx.fresh); return 0; }
extern "C" __declspec(dllexport) int mhrs_forget(void*) { write_state(dispatch_asset(true)); return 0; }
extern "C" __declspec(dllexport) int mhrs_material_links(void*) {
    try { write_state(material_links()); }
    catch (const std::bad_alloc&) { write_state("unable to collect material links"); }
    return 0;
}
// Lua holds both halves of each model. Check their ordinary lookup keys and
// completed dependencies before changing a renderer.
extern "C" __declspec(dllexport) int mhrs_equipment_ready(void*) {
    if (!supported()) { write_state("unsupported Rise build"); return 0; }
    const Ptr rm=field<Ptr>(base,0x416d9da+0xb4b3c56);
    FILE* f{};
    if (!rm || fopen_s(&f,"reframework/data/MHRS-Files-HotReload/equipment-paths.txt","rb")) {
        write_state("missing equipment paths"); return 0;
    }
    const char* result="ready";
    FILE* pending{};
    fopen_s(&pending,"reframework/data/MHRS-Files-HotReload/equipment-wait.txt","wb");
    result=equipment_platform_ready(rm,pending);
    if (strcmp(result,"ready") && strcmp(result,"pending")) {
        if (pending) fclose(pending);
        fclose(f); write_state(result); return 0;
    }
    FILE* slot_names{};
    if (fopen_s(&slot_names,"reframework/data/MHRS-Files-HotReload/equipment-slots.txt","wb")) {
        if (pending) fclose(pending);
        fclose(f); write_state("cannot write equipment slots"); return 0;
    }
    char line[8192];
    while (fgets(line,sizeof(line),f)) {
        wchar_t path[2048]{};
        const size_t n=strcspn(line,"\r\n");
        if (!n || line[n]!='\n' || !MultiByteToWideChar(CP_UTF8,MB_ERR_INVALID_CHARS,line,static_cast<int>(n),path,2047)) {
            result="invalid equipment path"; break;
        }
        const wchar_t* ext=wcsrchr(path,L'.');
        const bool material=ext && !_wcsicmp(ext,L".mdf2");
        if (!ext || (!material && _wcsicmp(ext,L".mesh") && _wcsicmp(ext,L".chain") && _wcsicmp(ext,L".mot"))) {
            result="invalid equipment resource"; break;
        }
        const Ptr key=function<Ptr(*)(const wchar_t*)>(0x4171030)(path);
        Ptr resource{};
        {
            Lock lock(rm);
            const Ptr node=lookup(rm+0xc48,key);
            resource=node ? field<Ptr>(node,0x28) : 0;
            if (!resource || field<Ptr>(resource,0x30)!=key || !field<const wchar_t*>(resource,8)
                    || _wcsicmp(path,field<const wchar_t*>(resource,8))) { result="equipment resource changed"; break; }
            retain(resource);
        }
        const wchar_t* dependency=nullptr;
        if (!(material ? deps_ready_detail(resource,&dependency) : finish_resource(resource))) {
            result="pending";
            if (pending) {
                char child[8192]{};
                if (dependency && !WideCharToMultiByte(CP_UTF8,0,dependency,-1,child,sizeof(child),nullptr,nullptr))
                    child[0]='\0';
                fprintf(pending,"%.*s\t%04x\t%s\n",static_cast<int>(n),line,unsigned(field<uint16_t>(resource,0x38)),child);
            }
        } else if (material) {
            line[n]='\0';
            if (!write_material_slots(slot_names,resource,line)) {
                result="invalid equipment material slots";
                release(resource);
                break;
            }
        }
        release(resource);
    }
    if (ferror(f)) result="cannot read equipment paths";
    fclose(f);
    if (fclose(slot_names)) result="cannot write equipment slots";
    if (pending) fclose(pending);
    write_state(result);
    return 0;
}
extern "C" __declspec(dllexport) int mhrs_preview_size(void*) {
    if (!supported()) { write_state("unsupported Rise build"); return 0; }
    const Ptr rm=field<Ptr>(base,0x416d9da+0xb4b3c56);
    FILE* f{};
    if (!rm || fopen_s(&f,"reframework/data/MHRS-Files-HotReload/asset-path.txt","rb")) {
        write_state("missing RTEX path"); return 0;
    }
    char bytes[2048]{};
    const size_t n=fread(bytes,1,sizeof(bytes),f);
    fclose(f);
    wchar_t path[2048]{};
    if (!n || n==sizeof(bytes) || !MultiByteToWideChar(CP_UTF8,MB_ERR_INVALID_CHARS,bytes,static_cast<int>(n),path,2047)
            || !wcsrchr(path,L'.') || _wcsicmp(wcsrchr(path,L'.'),L".rtex")) { write_state("invalid RTEX path"); return 0; }
    const Ptr key=function<Ptr(*)(const wchar_t*)>(0x4171030)(path);
    Lock lock(rm);
    const Ptr node=lookup(rm+0xc48,key), r=node ? field<Ptr>(node,0x28) : 0;
    if (!r || field<Ptr>(r,0x30)!=key || field<uint16_t>(r,0x38)!=0x101 || !field<const wchar_t*>(r,8)
            || _wcsicmp(field<const wchar_t*>(r,8),path)) { write_state("RTEX is not resident"); return 0; }
    char dimensions[48]{};
    sprintf_s(dimensions,"%u %u",field<uint32_t>(r,0x60),field<uint32_t>(r,0x64));
    write_state(dimensions,r);
    return 0;
}
extern "C" __declspec(dllexport) int mhrs_forget_batch(void*) {
    try { write_state(forget_batch()); }
    catch (const std::bad_alloc&) { write_state("unable to stage resource paths"); }
    return 0;
}
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
    if (master_count < sizeof(masters)/sizeof(masters[0]) && tx.fresh && field<uint16_t>(tx.fresh,0x38)==0x101) {
        masters[master_count++]=tx; write_state("held",tx.fresh); tx={};
    } else write_state("template not ready");
    return 0;
}
extern "C" __declspec(dllexport) int mhrs_stage_mdf(void*) {
    if (master_count==1 && masters[0].kind==&kinds[4] && tx.kind==&kinds[0] &&
            tx.fresh && field<uint16_t>(tx.fresh,0x38)==0x101) {
        if (!uses_staged_template(tx,masters[0])) {
            write_state("MDF did not load the staged MMTR"); return 0;
        }
        try {
            staged_mdfs.push_back(tx);
            write_state("staged",tx.fresh);
            tx={};
        } catch (const std::bad_alloc&) { write_state("unable to stage MDF"); }
    } else write_state("no ready MDF for held MMTR");
    return 0;
}
extern "C" __declspec(dllexport) int mhrs_commit_materials(void*) { write_state(finish_material_group(true)); return 0; }
extern "C" __declspec(dllexport) int mhrs_abort_materials(void*) { write_state(finish_material_group(false)); return 0; }
extern "C" __declspec(dllexport) int mhrs_resume_master(void*) {
    if (master_count && !tx.fresh) { tx=masters[--master_count]; masters[master_count]={}; write_state("resumed",tx.fresh); }
    else write_state("template cannot resume");
    return 0;
}
extern "C" __declspec(dllexport) int mhrs_poll(void*) {
    if (tx.fresh && tx.require_platform && !field<uint8_t>(tx.fresh,0x3a)) {
        write_state("expected platform resource, received ordinary source",tx.fresh); return 0;
    }
    const bool ready=tx.fresh && (tx.kind==&kinds[0] ? deps_ready(tx.fresh) : finish_resource(tx.fresh));
    write_state(!tx.fresh ? "no active transaction" : ready ? "ready" : "pending",tx.fresh);
    return 0;
}
extern "C" __declspec(dllexport) int mhrs_commit(void*) { write_state(finish(true)); return 0; }
extern "C" __declspec(dllexport) int mhrs_abort(void*) { write_state(finish(false)); return 0; }
