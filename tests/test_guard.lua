-- mock environment
package.loaded["logger"] = { warn=function(...) print("WARN", ...) end, info=function(...) print("INFO", ...) end, dbg=function() end }
local registered = {}
local INVENTORY_TIMEOUTS = {10, 30}
package.loaded["userpatch"] = {
  registerPatchPluginFunc = function(n, f) registered[n] = f end,
  getUpValue = function(fn, name) local i=1 while true do local k,v=debug.getupvalue(fn,i) if not k then return end if k==name then return v end i=i+1 end end,
}
local to = {}
package.loaded["socketutil"] = { set_timeout=function(_,a,b) to[#to+1]=a..","..b end, reset_timeout=function() to[#to+1]="reset" end }
local fail_with = nil
local calls = 0
local Client = {}
function Client:report_inventory(u,p,d,id,inv,f,t,cb) local _=INVENTORY_TIMEOUTS calls=calls+1 if fail_with then cb(false,nil,fail_with) else cb(true,{}) end end
function Client:get_progress(u,p,doc,dev,id,cb) calls=calls+1 if fail_with then cb(false,nil,fail_with) else cb(true,{}) end end
function Client:authorize(u,p) calls=calls+1 if fail_with then return false,nil,fail_with end return true,{} end
function Client:pull_annotations(u,p,doc,d,id,cb) calls=calls+1 cb(true,{}) end
package.loaded["CWNGSyncClient"] = Client
local fakeT = 1000; os.time = function() return fakeT end
dofile(arg[1])
local plugin = { _onNetworkConnected=function() end, onCWNGSyncSyncNow=function() end }
registered["cwngsync"](plugin)
assert(INVENTORY_TIMEOUTS[1]==5 and INVENTORY_TIMEOUTS[2]==15, "inventory cap")
local got
Client:get_progress("u","p","d","x","y", function(ok,b,r) got={ok,r} end); assert(got[1]==true and calls==1)
fail_with = "common/Spore/Protocols.lua:85: wantread"
Client:get_progress("u","p","d","x","y", function(ok,b,r) got={ok,r} end); assert(got[1]==false and calls==2)
-- now open: must be skipped, callback still called
Client:report_inventory("u","p","d","i",{},1,2, function(ok,b,r) got={ok,r} end); assert(calls==2 and got[1]==false and got[2]:find("unreachable"))
local ok,_,r = Client:authorize("u","p"); assert(ok==false and calls==2)
fakeT = fakeT + 181 -- cooldown 3 min elapsed: half-open
fail_with = "502 not expected"
Client:get_progress("u","p","d","x","y", function() end); assert(calls==3)
Client:get_progress("u","p","d","x","y", function() end); assert(calls==3, "reopened with doubled cooldown")
fakeT = fakeT + 200; Client:get_progress("u","p","d","x","y", function() end); assert(calls==3, "6 min cooldown still active")
plugin._onNetworkConnected(plugin) -- reset
fail_with = nil
Client:get_progress("u","p","d","x","y", function() end); assert(calls==4)
-- 4xx must not trip
fail_with = "HTTP 401"
Client:get_progress("u","p","d","x","y", function() end); Client:get_progress("u","p","d","x","y", function() end); assert(calls==6)
-- sync-return failure trips
fail_with = "timeout"; Client:authorize("u","p"); Client:authorize("u","p"); assert(calls==7)
-- timeout wrapping for methods without own timeouts
fakeT = fakeT + 4000; fail_with=nil; to = {}
Client:pull_annotations("u","p","d","x","y", function() end); assert(to[1]=="3,10" and to[2]=="reset")
print("ALL GUARD TESTS PASSED")
