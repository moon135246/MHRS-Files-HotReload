-- Exercise the actual mount state machine with controllable engine readiness.
package.path="reframework/autorun/?.lua;"..package.path
local mount=require("MHRS_HotReload.mounted_equipment")
local function replace(name,value)
    for i=1,60 do
        local n=debug.getupvalue(mount.advance,i)
        if n==name then debug.setupvalue(mount.advance,i,value);return end
    end
    error("Missing mount helper "..name)
end
local factory_ready,part_ready,released=false,false,false
replace("same_actor",function() return true end)
replace("warm",function() return factory_ready end)
replace("spawn",function() end)
replace("ready",function() return part_ready end)
replace("restore_factories",function() released=true end)
local old_alive=true
local old={call=function(_,method)
    if method=="get_DrawSelf" then return true end
    assert(method=="get_Valid")
    return old_alive
end}
local row={slot=3,old_id=1,new_id=2,old=old,new={call=function(_,method) assert(method=="get_DrawSelf");return true end}}
replace("children",function() return {[1]=old_alive and old or nil,[2]=row.new} end)
local j={rows={row},destroy={call=function(_,instance,go) assert(not instance and go==old) end},
         phase="warm",next_update=true,deadline=os.clock()+20}
local function tick(pending,fast)
    assert(mount.advance(j)==pending)
    assert((j.next_update==true)==fast,"Unexpected cadence during "..j.phase)
end
tick(true,false)                   -- factory is still loading
factory_ready=true;tick(true,true) -- native parts created, registration due
tick(true,false)                   -- async renderer/physics still pending
part_ready=true;tick(true,true)    -- first ready sample
tick(true,true)                    -- original retired, await destruction
tick(true,false)                   -- engine still owns original
old_alive=false;tick(true,true)    -- first verified handover sample
tick(false,false)
assert(released)
print("Mounted IPC cadence: four real phase transitions request the next game frame; all three asynchronous waits retain the throttle")
