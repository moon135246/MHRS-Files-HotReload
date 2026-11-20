package.path="reframework/autorun/?.lua;" .. package.path

local phases, errors = {}, {}
re = {on_application_entry=function(phase, callback)
    assert(not phases[phase])
    phases[phase] = callback
end}
log = {
    error=function(message) errors[#errors + 1] = message end,
}

local tick, cleanup, interrupted = 0, 0, false
local updates = require("MHRS_HotReload.game_update")
updates.register(function()
    tick = tick + 1
    if interrupted then error("test failure") end
end)
updates.register(function()
    assert(tick == cleanup + 1)
    cleanup = cleanup + 1
end)

local primary = assert(phases.UpdateBehavior)
assert(not phases.LateUpdateBehavior)
primary()
assert(tick == 1 and cleanup == 1 and #errors == 0)
interrupted = true
primary(); primary()
assert(tick == 3 and cleanup == 3 and #errors == 2)
assert(errors[1]:find("test failure", 1, true))
interrupted = false
primary()
assert(tick == 4 and cleanup == 4 and #errors == 2)
print("A failing game update job does not skip the other jobs in UpdateBehavior")
