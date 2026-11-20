-- An engine exception during a file-worker abort must not block every future
-- equipment request or emit a warning on every UpdateBehavior.
package.path="reframework/autorun/?.lua;"..package.path
local now,frame,warnings=0,nil,{}
os.clock=function()return now end
re={on_application_entry=function(name,f)if name=="UpdateBehavior" then frame=f end end,on_script_reset=function() end}
log={warn=function(msg)warnings[#warnings+1]=msg end}
local village=require("MHRS_HotReload.village_equipment")
local function upvalue(name,value)
    for i=1,30 do
        local n,v=debug.getupvalue(village.abort,i)
        if n==name then
            if value then debug.setupvalue(village.abort,i,value) end
            return v
        end
    end
    error(name)
end
local mode,attempts,records,released="recover",0,0,0
upvalue("mounted",{
    reset_record=function()return {pid=42} end,
    rollback=function(j) attempts=attempts+1;j.step="rollback: register slot 4";error("engine exception") end,
    recover_record=function()
        records=records+1
        if mode=="fail" then error("engine exception") end
        return records==1
    end,
    release=function()released=released+1;return false end,
})
local function abort()
    village.abort({mount={phase="handover"}})
    assert(upvalue("cancelled_mount"))
end
abort()
for i=1,40 do now=now+.02;frame() end
assert(not upvalue("cancelled_mount") and attempts==1 and records==2 and released==1)
assert(#warnings==1 and warnings[1]:find("register slot 4"))
mode="fail";attempts,records=0,0;warnings={}
abort()
for i=1,600 do now=now+.01;frame() end
assert(not upvalue("cancelled_mount") and attempts==1 and records<40 and released==2)
assert(#warnings==2 and warnings[2]:find("expired"))
print("Deferred cleanup recovered from live-tree identities or released the gate at its deadline without per-frame warnings")
