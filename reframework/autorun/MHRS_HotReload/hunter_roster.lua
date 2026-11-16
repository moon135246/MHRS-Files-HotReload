-- Read the local client's scene and lobby/quest membership. A PlayerList
-- index is reused; it alone never authorizes changing a render component.
local M = {}
local function items(list)
    if type(list)=="table" and not list.call then return list end
    local ok,count=pcall(function() return list:call("get_Count") end)
    if not ok or type(count)~="number" then
        if list.get_elements then return list:get_elements() end
        count=list:call("get_Length")
        local getter=list:get_type_definition():get_method("Get(System.Int32)")
        local result={}
        for i=0,count-1 do result[#result+1]=getter:call(list,i) end
        return result
    end
    local result={}
    local getter
    for i=0,count-1 do
        local found,value=pcall(function() return list:call("get_Item",i) end)
        if not found then
            getter=getter or list:get_type_definition():get_method("get_Item")
            if getter then found,value=pcall(getter.call,getter,list,i) end
        end
        if found and value then result[#result+1]=value end
    end
    return result
end
local function members(status)
    local map = {}
    if status~=1 and status~=2 then return map end
    local lobby = sdk.get_managed_singleton("snow.LobbyManager")
    local list = lobby and lobby:get_field(status==2 and "_questHunterInfo" or "_hunterInfo")
    if not list then return map end
    for _,info in pairs(items(list)) do
        if info then
            local index=info:get_field("_memberIndex")
            local id=info:get_field("_HunterUniqueId")
            local guid=id and id:call("ToString()")
            if type(index)=="number" and type(guid)=="string" and #guid==36
                    and guid:match("^[%x%-]+$") and guid:gsub("[-0]","")~="" then
                if map[index]~=nil then map[index]=false else map[index]=guid end
            end
        end
    end
    return map
end

local function scene_scope(status)
    if status==1 then
        local v=sdk.get_managed_singleton("snow.VillageAreaManager")
        return v and "village/"..v:call("getCurrentAreaNo")
    elseif status==2 then
        local q=sdk.get_managed_singleton("snow.QuestManager")
        local a=q and q:call("getActiveQuestData")
        return a and table.concat({"quest",q:call("getQuestNo"),q:call("getMapNo"),a:get_address()},"/")
    end
end
local function scan(out)
    local pm=sdk.get_managed_singleton("snow.player.PlayerManager")
    local gm=sdk.get_managed_singleton("snow.SnowGameManager")
    local ok,status=pcall(function() return gm:call("getStatus") end)
    local has_members,known=pcall(members,ok and status)
    if not has_members then known={} end
    out.members,out.status=known,ok and status or nil
    if not pm then return end
    local has_scope,scope=pcall(scene_scope,out.status)
    out.scope=has_scope and scope or nil
    local master=pm:call("findMasterPlayer")
    local local_index=pm:call("getMasterPlayerID")
    local owner=master and master:call("get_GameObject")
    local active=master and owner and owner:call("get_Valid") and master:call("isMasterPlayer")
        and master:call("getPlayerIndex")==local_index
    local function register(p)
        local root=p and p:call("get_GameObject")
        if not root or not root:call("get_Valid") then return end
        local index=p:call("getPlayerIndex")
        local role="unconfirmed"
        if active and p==master and root==owner then role="master"
        elseif p:call("isServant") then role="follower"
        elseif active and out.scope and pm:call("getPlayer",local_index)==master
                and index~=local_index and root~=owner and not p:call("isMasterPlayer")
                and pm:call("getPlayer",index)==p and known[index] and pm:call("isReadyPlayer",index) then role="peer" end
        local entry={player=p,root=root,index=index,role=role,guid=known[index],slots={},scope=out.scope}
        out.entries[#out.entries+1]=entry
        out.roots[root:get_address()]=entry
        if role=="peer" then out.by_index[index]=entry end
        for slot=0,4 do
            local ok,go=pcall(function()
                local g=p:call("getPartsGameObject",slot)
                if g and g:call("get_Valid") then return g end
            end)
            if ok and go then
                entry.slots[slot]=go
                local address=go:get_address()
                local previous=out.parts[address]
                if previous and (previous.entry~=entry or previous.slot~=slot) then out.parts[address]={ambiguous=true}
                else out.parts[address]={entry=entry,slot=slot,go=go} end
            end
        end
    end
    -- PlayerList is empty or partial during equipment/area transitions. The
    -- validated local actor and its own slots remain independently available.
    if master then pcall(register,master) end
    local list=pm:get_field("PlayerList")
    for _,p in pairs(list and items(list) or {}) do
        if p~=master then pcall(register,p) end
    end
end

function M.read()
    local out={parts={},roots={},by_index={},entries={},members={},owners={}}
    pcall(scan,out)
    return out
end

-- A missing list row is not evidence that a loose armor part is a preview.
-- Accept an actual NPC/preview component or a known hunter hierarchy.
local unknown={role="unconfirmed"}
local outside={role="outside"}
local function attached(go,class)
    local t=sdk.typeof(class)
    return t and go:call("getComponent(System.Type)",t)
end
local function identify(out,go)
    local tr=go:call("get_Transform")
    local seen,external={},nil
    while tr do
        local obj=tr:call("get_GameObject")
        local a=obj:get_address()
        if seen[a] then return unknown end
        seen[a]=true
        local slot=out.parts[a]
        if slot then return slot.entry or unknown end
        if out.roots[a] then return out.roots[a] end
        if attached(obj,"snow.player.PlayerPreview") or attached(obj,"snow.npc.NpcBase") then
            external={role="scene",root=obj}
        elseif attached(obj,"snow.player.PlayerBase") then
            return unknown
        end
        tr=tr:call("get_Parent")
    end
    return external or outside
end
function M.owner(out,go)
    if not go then return unknown end
    local a=go:get_address()
    local slot=out.parts[a]
    if slot then return slot.entry or unknown end
    if not out.owners[a] then
        local ok,r=pcall(identify,out,go)
        out.owners[a]=ok and r or unknown
    end
    return out.owners[a]
end

-- A retained component can be reparented while a resource is loading.
-- Keep only scalar identity across engine updates.
function M.guard(owner)
    local role,root,scope,guid=owner.role,owner.root:get_address(),owner.scope,owner.guid
    return function(go)
        local current=M.owner(M.read(),go)
        return current.role==role and current.root and current.root:get_address()==root
            and current.scope==scope and (role~="peer" or current.guid==guid)
    end
end

function M.same(roster,owner,slot,go)
    local now=roster.by_index[owner.index]
    return now and now.scope==owner.scope and now.guid==owner.guid and now.player==owner.player and now.root==owner.root
        and now.slots[slot]==go
end

function M.render_part(go)
    local mesh=go:call("getComponent(System.Type)",sdk.typeof("via.render.Mesh"))
    local mh=mesh and mesh:call("getMesh")
    local dh=mesh and mesh:call("get_Material")
    if not mh or not dh then return end
    return mesh,mh,dh
end

function M.mesh_paths(wanted)
    local peers,master={},{}
    for _,e in ipairs(M.read().entries) do
        local found=e.role=="master" and master or (e.role=="peer" and peers)
        if found then
            for _,go in pairs(e.slots) do
                pcall(function()
                    local _,mh=M.render_part(go)
                    local path=mh and mh:call("get_ResourcePath"):lower():gsub("^@",""):gsub("\\","/")
                    if path and wanted[path] then found[path]=true end
                end)
            end
        end
    end
    return peers,master
end

function M.describe(roster)
    local result={}
    for _,e in ipairs(roster.entries) do
        local row={index=e.index,role=e.role,root=tostring(e.root:get_address()),parts={}}
        result[#result+1]=row
        pcall(function()
            row.class=e.player:get_type_definition():get_full_name()
            local tr=e.root:call("get_Transform")
            for _,j in pairs(tr:call("get_Joints")) do
                if j:call("get_Name")=="Head_00" then
                    row.head_base_y=j:call("get_BaseLocalPosition").y
                    row.head_local_y=j:call("get_LocalPosition").y
                    break
                end
            end
        end)
        for slot,go in pairs(e.slots) do
            pcall(function()
                local comp,mh,dh=M.render_part(go)
                if comp then
                    local part={slot=slot,go=tostring(go:get_address()),
                        mesh=mh:call("get_ResourcePath"),mesh_resource=tostring(mh:read_qword(0x10)),
                        material=dh:call("get_ResourcePath"),material_resource=tostring(dh:read_qword(0x10)),
                        ready=comp:call("get_MeshReady") and comp:call("get_MaterialReady")}
                    row.parts[#row.parts+1]=part
                    if comp:call("get_MaterialReady") then
                        part.material_names={}
                        for i=0,comp:call("get_MaterialNum")-1 do part.material_names[#part.material_names+1]=comp:call("getMaterialName",i) end
                    end
                    local chain=go:call("getComponent(System.Type)",sdk.typeof("via.motion.Chain"))
                    local h=chain and chain:call("get_ChainAsset")
                    if h then
                        part.chain={path=h:call("get_ResourcePath"),resource=tostring(h:read_qword(0x10)),
                            resource_groups=chain:call("get_ResourceGroupCount")}
                        if chain:call("get_Setuped") then part.chain.running_groups=chain:call("getGroupCount") end
                    end
                end
            end)
        end
    end
    return result
end
return M
