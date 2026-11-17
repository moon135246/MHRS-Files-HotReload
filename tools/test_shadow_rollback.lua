-- Callback-driven recovery must finish even when the worker stops polling.
package.path="reframework/autorun/?.lua;"..package.path
local update,reset
re={on_application_entry=function(_,fn) update=fn end,on_script_reset=function(fn) reset=fn end}
local ready,why=false,"Not yet reconstructed"
local restores=0
package.loaded["MHRS_HotReload.shadow_skeleton"]={
    abort=function() restores=restores+1;return true,true end,
    verify_rollback=function() return ready,why end,
}
local armor=require("MHRS_HotReload.worn_armor")
local function batch()
    local chains={frozen=false,resumed=0}
    function chains:suspend_for_rollback() self.frozen=true end
    function chains:rollback() self.frozen=false;self.resumed=self.resumed+1 end
    return {chains=chains,chains_paused=true,shadow={},shadow_bound=true,candidates={}}
end
local b=batch()
armor.abort(b,nil)
armor.abort(b,nil)
assert(b.chains.frozen and b.chains.resumed==0 and restores==1)
-- A second file save does not touch component state while its predecessor
-- still holds frozen chains. No IPC poll is required to finish cleanup.
assert(armor.advance({candidates={}},nil,nil,nil,nil))
update();assert(b.chains.frozen)
ready=true
update();assert(not b.chains.frozen and b.chains.resumed==1)
assert(not armor.advance({candidates={}},nil,nil,nil,nil))
local cancelled=batch()
ready=nil;why="Hunter changed"
armor.abort(cancelled,nil)
update();assert(not cancelled.chains.frozen and cancelled.rollback_error=="Hunter changed")
local timed_out=batch()
ready=false;why="Rest skeleton never reconstructed"
local clock=os.clock
local now=10
os.clock=function() return now end
armor.abort(timed_out,nil)
now=14;update()
os.clock=clock
assert(not timed_out.chains.frozen and timed_out.rollback_error==why)
local shutdown=batch()
armor.abort(shutdown,nil);reset()
assert(not shutdown.chains.frozen and shutdown.chains.resumed==1)
local late=batch()
armor.abort(late,nil);assert(not late.chains.frozen and late.chains.resumed==1)
print("Shadow rollback survived cancellation, competing requests, timeout and Lua reset")
