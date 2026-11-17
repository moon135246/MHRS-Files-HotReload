-- Paired physics publication through the real worn-armor transaction.
package.path="reframework/autorun/?.lua;"..package.path
local armor=require("MHRS_HotReload.worn_armor")
local physics=require("MHRS_HotReload.equipment_physics")
local helm="player/mod/f/pl279/f_helm279.user"
local root={FullBody=false}
function root:get_address() return 10 end
function root:get_type_definition() return {get_full_name=function() return "snow.player.PlayerUserDataPartsHelm" end} end
function root:call(method) assert(method=="get_Path");return helm end
local user={get_field=function(_,k) assert(k=="_PlayerUserDataParts");return root end}
local source
sdk={
    create_userdata_global=function(_,name) source=name;return root end}
local function prepare(entry,platform)
    local spec={helmets={[helm]=entry}}
    local tx=physics.new(spec,function() return {user} end,function(r,e)
        return function() return r[e.field] end,function(v) r[e.field]=v end
    end)
    tx:request({[helm]=platform},{})
    return {candidates={},physics=tx},{}
end
local function advance(batch,refs)
    return armor.advance(batch,function() error("No meshes should be queried") end,refs,nil,nil)
end
local function installed(value)
    return {removed=false,fields={{section="face",index=-1,field="FullBody",element=-1,value=value}}}
end
local batch,refs=prepare(installed(true),true)
assert(source=="@"..helm and not root.FullBody)
assert(advance(batch,refs) and root.FullBody)
assert(not advance(batch,refs));batch.physics:commit()

-- Two outfits with equal USER bytes do not rewrite the live fields.
batch,refs=prepare(installed(true),true)
assert(not advance(batch,refs));batch.physics:commit()

batch,refs=prepare({removed=true},false)
assert(source==helm)
assert(advance(batch,refs) and not root.FullBody)
armor.abort(batch,nil)
assert(root.FullBody)
batch,refs=prepare({removed=true},false)
assert(advance(batch,refs));assert(not advance(batch,refs));batch.physics:commit()
assert(not root.FullBody)
-- Defer every live field when a normally instantiated custom model is kept
-- on screen. This includes a newly requested USER aliasing its live root.
batch,refs=prepare(installed(true),true)
batch.physics.defer_live=true
assert(not advance(batch,refs) and not root.FullBody)
batch.physics:commit()
print("Helmet fields passed addition, equal-value replacement, abort and packaged removal")
