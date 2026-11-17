-- Read the local hunter's identity and gameplay state around the
-- normal equipment rebuild. Gameplay fields are observations only.
local M={}
local stationary
local vital_fields={"_r_Vital","_vitalMax","_stamina","_staminaMax"}

local function weapon(p,field)
    local go=p:get_field(field)
    if not go then return false end -- e.g. a single-piece great sword
    if not go:call("get_Valid") then return end
    local mesh=go:call("getComponent(System.Type)",sdk.typeof("via.render.Mesh"))
    if mesh then
        local holder=mesh:call("getMesh")
        return holder and holder:call("get_ResourcePath")
    end
    -- A weapon assembly can expose a container instead of a mesh at the root.
    -- Its equip index and container name also survive a normal rebuild.
    return go:call("get_Name")
end

function M.identity(p)
    local data=p:call("get_PlayerData")
    local weapon_type=p:get_field("_playerWeaponType")
    if not data or type(weapon_type)~="number" or weapon_type<0 or weapon_type>13 then return end
    local s={data=tostring(data:get_address()),class=p:get_type_definition():get_full_name(),weapon_type=weapon_type,
             main=weapon(p,"_WeaponMain"),sub=weapon(p,"_WeaponSub")}
    if not s.main or s.sub==nil then return end
    return s,data
end

function M.equip_indices(pm)
    local parameters=pm:call("get_PlayerParam")
    local request=parameters and parameters:get_element(pm:call("getMasterPlayerID"))
    local indices=request and request:call("get_EquipIndex")
    if not indices then return end
    local td=indices:get_type_definition()
    if td:get_full_name()~="System.Int32[]" then return end
    -- The generic REFramework array accessor returns boxed System.Int32
    -- objects. The typed array getter returns the game's actual equip indices.
    local get=td:get_method("Get(System.Int32)") or td:get_method("Get")
    if not get then return end
    local values={}
    local count=indices:get_size()
    if count<18 then return end -- EquipPack.Num in Rise, including weapon/armor data types
    for slot=0,count-1 do
        local id=get:call(indices,slot)
        if type(id)~="number" then return end
        values[#values+1]=tostring(id)
    end
    if #values==0 then return end
    return table.concat(values,",")
end

function M.equipment(pm,p)
    local s,data=M.identity(p)
    if not s then return end
    s.indices=M.equip_indices(pm)
    if not s.indices then return end
    return s,data
end

function M.read(pm,p,go)
    local s,data=M.equipment(pm,p)
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
    return b and a.data==b.data and a.class==b.class and a.weapon_type==b.weapon_type and
        a.main==b.main and a.sub==b.sub
end

function M.equipment_difference(a,b)
    if not M.same_hunter(a,b) then return "Local hunter data or weapon changed" end
    if a.indices~=b.indices then return "Local equipped item indices changed" end
end

function M.difference(a,b)
    local changed=M.equipment_difference(a,b)
    if changed then return changed end
    for _,name in ipairs(vital_fields) do
        if math.abs(a[name]-b[name])>0.01 then return "Local hunter state changed: "..name end
    end
    -- Ground/animation updates can change the root height at another phase.
    local dx,dz=a.x-b.x,a.z-b.z
    local dot=0
    for i=1,4 do dot=dot+a.rotation[i]*b.rotation[i] end
    if dx*dx+dz*dz>0.0025 or math.abs(dot)<0.9999 then return "Local hunter moved or turned" end
end

function M.rebuild_ready(pm,p,go,index,scope)
    local gui=sdk.get_managed_singleton("snow.gui.GuiManager")
    if not p:call("isMasterPlayer") or p:call("getPlayerIndex")~=index or p:call("isWeaponOn") or
            not gui or gui:call("IsPlayerAllInputDisable") then
        stationary=nil
        return
    end
    local s=M.read(pm,p,go)
    if not s or s._stamina<0 or s._staminaMax<=0 or s._vitalMax<=0 then
        stationary=nil
        return
    end
    local now,id=os.clock(),go:get_address()
    if not stationary or stationary.id~=id or stationary.scope~=scope or M.difference(stationary.state,s) then
        stationary={id=id,t=now,state=s,scope=scope}
    elseif now-stationary.t>=(scope and 1 or 0.5) then
        return s
    end
end

return M
