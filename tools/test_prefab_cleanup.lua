package.path="reframework/autorun/?.lua;" .. package.path

local now, phases, hooks, storage = 0, {}, {}, {}
os.clock=function() return now end
re={
    on_application_entry=function(phase,callback) phases[phase]=callback end,
    on_script_reset=function() end,
}
log={info=function() end,error=error}
json={dump_file=function() end}
thread={get_hook_storage=function() return storage end}
local method={get_name=function() return "instantiate" end}
sdk={
    find_type_definition=function(name)
        return {get_methods=function() return name=="via.Prefab" and {method} or {} end,
                get_method=function() end}
    end,
    to_managed_object=function(object) return object end,
    hook=function(found,pre,post)
        if found==method then hooks.pre,hooks.post=pre,post end
    end,
}
local outfit=require("MHRS_HotReload.outfit")
local path="test/instance.pfb"
local factory={
    get_type_definition=function() return {get_full_name=function() return "via.Prefab" end} end,
    get_address=function() return 1 end,
    call=function(_,name) assert(name=="get_ResourcePath");return path end,
}
local function instantiate(address)
    local go={checks=0,draw=true}
    function go:get_address() return address end
    function go:call(name,value)
        if name=="get_Valid" then
            self.checks=self.checks+1
            if self.destroyed then error("Destroyed native handle") end
            return true
        end
        if name=="get_DrawSelf" then return self.draw end
        assert(name=="set_DrawSelf")
        self.draw=value
    end
    hooks.pre({nil,factory})
    assert(hooks.post(go)==go)
    return go
end

local stale, live=instantiate(10),instantiate(20)
stale.destroyed=true
local result=outfit.run("asset_prefab",{path=path,edits={DrawSelf=false}})
assert(result.count==1 and not live.draw and stale.checks==1)

local requests=0
require("MHRS_HotReload.game_update").register(function() requests=requests+1 end)
phases.UpdateBehavior()
assert(live.checks==2 and stale.checks==2,"A destroyed instance interrupted the cleanup slice")
assert(requests==1,"Cleanup prevented the next UpdateBehavior job")
now=6
phases.UpdateBehavior()
result=outfit.run("asset_prefab",{path=path,edits={DrawSelf=true}})
assert(result.count==1 and live.draw and stale.checks==2 and requests==2,"Kept a destroyed instance in the tracker")
print("A destroyed prefab handle is discarded and live instances remain editable")
