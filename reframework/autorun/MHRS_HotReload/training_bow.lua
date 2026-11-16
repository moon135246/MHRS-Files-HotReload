-- Read the local training hunter's identity and gameplay state around the
-- normal equipment rebuild. Gameplay fields are observations only.
local M={}
local stationary
local vital_fields={"_r_Vital","_vitalMax","_stamina","_staminaMax"}

local function weapon(p,field)
    local go=p:get_field(field)
    if not go or not go:call("get_Valid") then return end
    local mesh=go:call("getComponent(System.Type)",sdk.typeof("via.render.Mesh"))
    local holder=mesh and mesh:call("getMesh")
    return holder and holder:call("get_ResourcePath")
end

function M.identity(p)
    local data=p:call("get_PlayerData")
    if not data or p:get_field("_playerWeaponType")~=13 then return end
    local s={data=data:get_address(),bow=weapon(p,"_WeaponMain"),quiver=weapon(p,"_WeaponSub")}
    if not s.bow or not s.quiver then return end
    return s,data
end

function M.read(p,go)
    local s,data=M.identity(p)
    if not s then return end
    local td=data:get_type_definition()
    for _,name in ipairs(vital_fields) do
        local field=td:get_field(name)
        local v=field and field:get_data(data)
        if type(v)~="number" then return end
        s[name]=v
    end
    local tr=go:call("get_Transform")
    local pos,rot=tr:call("get_Position"),tr:call("get_Rotation")
    s.x,s.z=pos.x,pos.z
    s.rotation={rot.x,rot.y,rot.z,rot.w}
    return s
end

function M.same_hunter(a,b)
    return b and a.data==b.data and a.bow==b.bow and a.quiver==b.quiver
end

function M.difference(a,b)
    if not M.same_hunter(a,b) then return "Training hunter data or weapon changed" end
    for _,name in ipairs(vital_fields) do
        if math.abs(a[name]-b[name])>0.01 then return "Training hunter state changed: "..name end
    end
    -- Ground/animation updates can change the root height at another phase.
    local dx,dz=a.x-b.x,a.z-b.z
    local dot=0
    for i=1,4 do dot=dot+a.rotation[i]*b.rotation[i] end
    if dx*dx+dz*dz>0.0025 or math.abs(dot)<0.9999 then return "Training hunter moved or turned" end
end

function M.ready(p,go,index)
    local gui=sdk.get_managed_singleton("snow.gui.GuiManager")
    if not p:call("isMasterPlayer") or p:call("getPlayerIndex")~=index or p:call("isWeaponOn") or
            not gui or gui:call("IsPlayerAllInputDisable") then
        stationary=nil
        return
    end
    local s=M.read(p,go)
    if not s or s._stamina<0 or s._staminaMax<=0 or s._vitalMax<=0 then
        stationary=nil
        return
    end
    local now,id=os.clock(),go:get_address()
    if not stationary or stationary.id~=id or M.difference(stationary.state,s) then
        stationary={id=id,t=now,state=s}
    elseif now-stationary.t>=0.5 then
        return s
    end
end

return M
