-- Copy helmet data through its managed fields in the worn mesh transaction.
local M = {}
local helm_type = "snow.player.PlayerUserDataPartsHelm"
local held,waiting = {},{}
local Physics = {}
Physics.__index = Physics

local function helm_path(root)
    if root and root:get_type_definition():get_full_name()==helm_type then
        local path=root:call("get_Path")
        return path and path:gsub("^@",""):lower()
    end
end

local function warn(message)
    if log and log.warn then log.warn("[MHRS-Files-HotReload] "..message) end
end

local function inspect(access,root,edit)
    return pcall(function()
        local get,set=access(root,edit)
        local value=get()
        assert(value~=nil,"Unreadable field")
        return get,set,value
    end)
end

local function fields(root,access)
    local edits={}
    if not root then return edits end
    local function read(section,i,name,j)
        local edit={section=section,index=i,field=name,element=j}
        local ok,_,_,value=inspect(access,root,edit)
        if ok then edit.value=value;edits[#edits+1]=edit end
    end
    -- create_userdata_global can return its managed shell before any of
    -- the face, hair or shape entries have been deserialized.
    pcall(function()
        if root:get_field("_FaceInfo") then
            read("face",-1,"FullFace",-1)
            read("face",-1,"FullBody",-1)
        end
        local hair=root:get_field("_HairInfo")
        for i=0,(hair and hair:get_size() or 0)-1 do
            local item=hair[i]
            if item then
                for _,name in ipairs({"HairDispOffParts","HairDispOff","HairChainStop"}) do read("hair",i,name,-1) end
                local shape=item:get_field("HairShapeData")
                for j=0,(shape and shape:get_size() or 0)-1 do read("hair",i,"HairShapeData",j) end
            end
        end
    end)
    return edits
end

local function get_source(path,platform)
    local ok,root=pcall(function()
        local r=sdk.create_userdata_global(helm_type,platform and "@"..path or path)
        if helm_path(r)==path then return r end
    end)
    return ok and root or nil
end

function M.new(spec, parts, access)
    local self=setmetatable({spec=spec,access=access,helmets={}},Physics)
    if not next(spec.helmets or {}) then return self end
    local ok,components=pcall(parts,"snow.player.PlayerMaterialParts")
    if ok then
        for _,comp in ipairs(components) do
            local available,root,path=pcall(function()
                local value=comp:get_field("_PlayerUserDataParts")
                return value,helm_path(value)
            end)
            if available and path and spec.helmets[path] then
                self.helmets[#self.helmets+1]={comp=comp,path=path,root=root}
            end
        end
    end
    return self
end

function Physics:request(platform,missing)
    self.users={}
    for path,spec in pairs(self.spec.helmets or {}) do
        waiting[path]=nil
        if not missing[path] or spec.removed then
            local prior=held[path]
            self.users[path]={path=path,root=not missing[path] and get_source(path,platform[path]) or nil,
                target=spec.fields,removed=spec.removed,platform=platform[path],missing=missing[path],
                deferred=spec.deferred,previous=prior and prior.originals or {},
                originals=spec.deferred and prior and prior.originals or {},retry={}}
            if spec.deferred then warn("Deferred helmet USER layout to normal equipment load: "..path) end
        end
    end
end

local function plan(entry,root,access,only)
    local edits=only or entry.target
    -- A removal without archive fields must restore each live root's own
    -- pre-edit values. Other instances can have different optional members.
    if not edits then
        local previous=entry.previous and entry.previous[root]
        edits=previous and next(previous) and previous or fields(entry.root,access)
    end
    local ops,unavailable={},{}
    if not edits or not next(edits) then return ops,nil,true end
    local before=entry.originals[root]
    if not before and not entry.removed then
        before={}
        for key,value in pairs(entry.previous[root] or {}) do before[key]=value end
        entry.originals[root]=before
    end
    for _,edit in pairs(edits) do
        local ok,get,set,value=inspect(access,root,edit)
        if not ok then
            unavailable[#unavailable+1]=edit
        else
            if before then
                local key=table.concat({edit.section,edit.index,edit.field,edit.element},"/")
                if not before[key] then
                    before[key]={section=edit.section,index=edit.index,field=edit.field,element=edit.element,value=value}
                end
            end
            if value~=edit.value then ops[#ops+1]={get=get,set=set,old=value,new=edit.value,edit=edit} end
        end
    end
    return ops,unavailable,false
end

local function rewind(applied,path)
    for i=#applied,1,-1 do
        local op=applied[i]
        local ok,err=pcall(function()
            if op.get()==op.new then op.set(op.old);assert(op.get()==op.old) end
        end)
        if not ok then warn("Helmet rollback "..path.." "..op.edit.field..": "..tostring(err)) end
    end
end

local function apply(ops,path)
    local done={}
    for _,op in ipairs(ops) do
        done[#done+1]=op
        local ok,err=pcall(function()
            op.set(op.new)
            assert(op.get()==op.new,"Field readback differs")
        end)
        if not ok then
            rewind(done,path)
            warn("Deferred helmet "..path.." "..op.edit.field.."["..op.edit.index..","..op.edit.element.."]: "..tostring(err))
            return nil
        end
    end
    return done
end

function Physics:stage()
    self.plans={}
    local seen={}
    local function stage_root(path,root,comp)
        if root and seen[root:get_address()] then return end
        if root then seen[root:get_address()]=true end
        local entry=self.users[path]
        local task={root=root,comp=comp,entry=entry,access=self.access}
        if root then
            task.ops,task.missing,task.source=plan(entry,root,self.access)
        else
            task.ops,task.source={},true
        end
        self.plans[#self.plans+1]=task
    end
    for _,row in ipairs(self.helmets) do
        local found,root=pcall(row.comp.get_field,row.comp,"_PlayerUserDataParts")
        if self.users[row.path] and not self.users[row.path].deferred and found and root==row.root then
            if self.defer_live then seen[root:get_address()]=true
            else stage_root(row.path,root,row.comp) end
        end
    end
    for path,entry in pairs(self.users) do
        if not entry.deferred and (entry.root or (not entry.missing and not self.defer_live)) then stage_root(path,entry.root) end
    end
end

function Physics:bind()
    local changed=false
    for _,task in ipairs(self.plans) do
        task.applied=apply(task.ops,task.entry.path)
        if not task.applied then task.source=true;task.missing=nil end
        if task.applied and #task.applied>0 then changed=true end
        if task.source or (task.missing and #task.missing>0) then
            task.entry.retry[#task.entry.retry+1]=task
        end
    end
    return changed
end

function Physics:verify()
    -- Verify per root. An optional managed field disappearing on the next
    -- frame must not unwind a ready mesh or another valid helmet instance.
    for _,task in ipairs(self.plans) do
        for _,op in ipairs(task.applied or {}) do
            local ok,value=pcall(op.get)
            if not ok or value~=op.new then
                rewind(task.applied,task.entry.path)
                task.applied={}
                task.source,task.missing=true,nil
                local queued=false
                for _,other in ipairs(task.entry.retry) do if other==task then queued=true;break end end
                if not queued then task.entry.retry[#task.entry.retry+1]=task end
                break
            end
        end
    end
    return true
end

local function retry(task)
    local entry=task.entry
    if task.comp and task.comp:get_field("_PlayerUserDataParts")~=task.root then return true end
    if not entry.root and not entry.missing then entry.root=get_source(entry.path,entry.platform) end
    task.root=task.root or entry.root
    if not task.root then return false end
    local ops,missing,empty=plan(entry,task.root,task.access,task.missing)
    if not apply(ops,entry.path) then return false end
    task.missing=missing
    return not empty and #missing==0
end

function M.update(now)
    for path,entry in pairs(waiting) do
        if now>=entry.next then
            for i=#entry.retry,1,-1 do
                local ok,done=pcall(retry,entry.retry[i])
                if ok and done then table.remove(entry.retry,i) end
            end
            if #entry.retry==0 or now>=entry.deadline then
                if #entry.retry>0 then
                    local task=entry.retry[1]
                    local e=task.missing and task.missing[1]
                    warn("Deferred uninitialized helmet USER to normal equipment load: "..path..
                        (e and (" "..e.section.."["..e.index.."]."..e.field.."["..e.element.."]") or ""))
                end
                entry.retry={};entry.previous=nil;waiting[path]=nil
            else entry.next=now+0.25 end
        end
    end
end

function Physics:commit()
    for path,spec in pairs(self.spec.helmets or {}) do
        if spec.removed then held[path]=nil end
    end
    for path,entry in pairs(self.users) do
        if entry.removed then held[path]=nil else held[path]=entry end
        if #entry.retry>0 then
            local now=os.clock()
            entry.next,entry.deadline=now+0.25,now+3
            waiting[path]=entry
        else entry.previous=nil end
    end
end

function Physics:abort()
    for i=#(self.plans or {}),1,-1 do
        local task=self.plans[i]
        rewind(task.applied or {},task.entry.path)
        task.applied=nil
    end
end

function M.reset() held,waiting={},{} end
return M
