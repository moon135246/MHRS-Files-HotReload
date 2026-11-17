-- Test-only ScriptRunner script. It owns one otherwise empty GameObject.
local types={
    mesh={"via.render.Mesh","via.render.MeshResource","getMesh","setMesh"},
    chain={"via.motion.Chain","via.motion.ChainResource","get_ChainAsset","set_ChainAsset"},
    motbank={"via.motion.Motion","via.motion.MotionBankResource","get_MotionBankAsset","set_MotionBankAsset"},
    uvar={"via.motion.Motion","via.userdata.UserVariablesResource","get_UserVariables","set_UserVariables"},
    fbxskel={"via.motion.CustomSkeleton","via.motion.FbxSkeletonResource","get_SkeletonResourceHandle","set_SkeletonResourceHandle"},
    rtex={"via.gui.GUI","via.render.RenderTargetTextureResource","get_RenderTarget","set_RenderTarget"}
}
local dir="MHRS-Files-HotReload/"
local go,comp,kind
local function clear()
    if go then sdk.find_type_definition("via.GameObject"):get_method("destroy"):call(nil,go) end
    go,comp,kind=nil,nil,nil
end
local function handle(q)
    if q.op=="ping" then return {} end
    if q.op=="clear" then clear();return {} end
    if q.op=="attach" then
        assert(not go,"Test component already active")
        kind=assert(types[q.kind])
        local token,ext=q.path:match("^mhrs_cold/(%x+)/sample%.([a-z0-9]+)$")
        assert(token and #token==32 and ext==q.kind,"Unexpected test path")
        go=assert(sdk.find_type_definition("via.GameObject"):get_method("create(System.String)"):call(nil,"MHRS_Cold_"..token))
        go:call("set_DrawSelf",false)
        comp=assert(go:call("createComponent(System.Type)",sdk.typeof(kind[1])))
        local res=assert(sdk.create_resource(kind[2],q.path))
        local h=res:create_holder(kind[2].."Holder")
        res:release()
        comp:call(kind[4],assert(h))
        return {}
    end
    assert(q.op=="read" and comp)
    local h=assert(comp:call(kind[3]))
    return {component=tostring(comp:get_address()),resource=tostring(h:read_qword(0x10)),path=h:call("get_ResourcePath")}
end
local first=json.load_file(dir.."cold-request.json")
local last=first and first.id
re.on_application_entry("UpdateBehavior",function()
    local q=json.load_file(dir.."cold-request.json")
    if not q or q.id==last then return end
    last=q.id
    local ok,r=pcall(handle,q)
    json.dump_file(dir.."cold-reply.json",{id=last,ok=ok,result=ok and r or tostring(r)})
end)
re.on_script_reset(clear)
