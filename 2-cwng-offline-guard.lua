--[[
User patch (2026-11-21): CWNG sync offline guard + gesture pass-through on the CWNG Library.

Why: every CWNG sync call is a blocking HTTP request on KOReader's UI thread
(DUSE_TURBO_LIB=false, so the plugin's AsyncHTTP path is inactive). When the
server is unreachable (server asleep -> HTTP 502, no internet, flaky router
hiccup -> "wantread"), each screen change re-tried and froze the UI; the
annotation and sleep-screen calls set no timeout at all and inherited
KOReader's 60 s block timeout.

What it does:
  1. Circuit breaker: after a network-type failure (timeout, unreachable,
     refused, DNS, TLS wantread, HTTP 5xx) all CWNG calls are skipped for a
     cool-down (3 min, doubling up to 30 min). Skipped calls report
     "Network is unreachable", which CWNG already treats as "try later", so
     progress is queued, not lost. Reset on Wi-Fi (re)connect and on a manual
     "Sync now".
  2. Timeouts: calls without their own timeout get 3 s connect / 10 s total;
     the 10/30 s inventory timeout is capped to 5/15 s.
  3. CWNG Library home: gestures assigned in the file browser's gesture
     manager (corner taps, holds, multiswipes...) are handed to the Gestures
     plugin first; unassigned gestures behave as before.

Remove this file (and restart KOReader) to undo everything.
]]
local userpatch = require("userpatch")
local logger = require("logger")
local unpack = unpack or table.unpack
local function pack(...) return { n = select("#", ...), ... } end

local COOLDOWN_START = 3 * 60
local COOLDOWN_MAX = 30 * 60
local guard = { open_until = 0, cooldown = 0 }

local function now() return os.time() end

local function isNetworkFailure(reason)
    if type(reason) ~= "string" then return reason == nil end
    local l = reason:lower()
    for _, needle in ipairs({ "timeout", "timed out", "wantread", "wantwrite", "unreachable",
            "no route", "refused", "name resolution", "host not found", "name or service",
            "closed", "no response", "network_unavailable", "download_failed" }) do
        if l:find(needle, 1, true) then return true end
    end
    local status = tonumber(l:match("^http (%d%d%d)$") or l:match("^(%d%d%d) not expected"))
    return status ~= nil and status >= 500
end

local function trip(label, reason)
    guard.cooldown = guard.cooldown == 0 and COOLDOWN_START or math.min(guard.cooldown * 2, COOLDOWN_MAX)
    guard.open_until = now() + guard.cooldown
    logger.warn("CWNG offline guard:", label, "failed (", tostring(reason),
        ") - pausing CWNG sync for", guard.cooldown, "s")
end

local function succeed()
    if guard.cooldown ~= 0 then logger.info("CWNG offline guard: server reachable again") end
    guard.cooldown = 0
    guard.open_until = 0
end

local function reset(why)
    if guard.open_until ~= 0 then logger.info("CWNG offline guard: reset by", why) end
    guard.open_until = 0 -- next call may try; cooldown keeps growing if it fails again
end

local SKIP_REASON = "Network is unreachable (CWNG offline guard)"

-- methods that do not set their own socket timeout
local NO_OWN_TIMEOUT = {
    _sleep_screen_request = true, pull_annotations = true, push_annotations = true,
    claim_deletion = true, complete_deletion = true, get_collections = true,
    complete_collections = true, refuse_delivery = true,
}

local METHODS = {
    "authorize", "update_progress", "get_progress", "report_inventory", "claim_delivery",
    "refuse_delivery", "claim_deletion", "complete_deletion", "get_collections",
    "complete_collections", "complete_delivery", "download_delivery", "get_library",
    "update_read_status", "download_file", "_sleep_screen_request",
    "pull_annotations", "push_annotations",
}

local function patchClient(Client)
    if Client._offline_guard_patched then return end
    Client._offline_guard_patched = true
    local socketutil = require("socketutil")

    -- cap the inventory timeout table in place (a local upvalue of report_inventory)
    local inv = userpatch.getUpValue(Client.report_inventory, "INVENTORY_TIMEOUTS")
    if type(inv) == "table" then inv[1], inv[2] = 5, 15 end

    for _, name in ipairs(METHODS) do
        local orig = Client[name]
        if type(orig) == "function" then
            Client[name] = function(self, ...)
                local args = pack(...)
                local cb_index
                for i = args.n, 1, -1 do
                    if type(args[i]) == "function" then cb_index = i; break end
                end
                if now() < guard.open_until then
                    logger.dbg("CWNG offline guard: skipped", name)
                    if cb_index then args[cb_index](false, nil, SKIP_REASON) end
                    return false, nil, SKIP_REASON
                end
                local observed = false
                if cb_index then
                    local cb = args[cb_index]
                    args[cb_index] = function(ok, body, reason, ...)
                        observed = true
                        if ok then succeed()
                        elseif isNetworkFailure(reason) then trip(name, reason) end
                        return cb(ok, body, reason, ...)
                    end
                end
                if NO_OWN_TIMEOUT[name] then socketutil:set_timeout(3, 10) end
                local r = pack(pcall(orig, self, unpack(args, 1, args.n)))
                if NO_OWN_TIMEOUT[name] then socketutil:reset_timeout() end
                if not r[1] then error(r[2], 0) end
                if not observed and r.n >= 2 and type(r[2]) == "boolean" then
                    if r[2] then succeed()
                    elseif isNetworkFailure(r[4]) then trip(name, r[4]) end
                end
                return unpack(r, 2, r.n)
            end
        end
    end
    logger.info("CWNG offline guard: client patched")
end

local function patchHome(Home)
    if not Home or Home._gesture_patch then return end
    Home._gesture_patch = true
    -- KOReader hands a gesture to a widget's children (book tiles, page
    -- buttons) before the widget's own onGesture, so the forwarding has to
    -- sit in handleEvent, ahead of that propagation.
    local orig_handleEvent = Home.handleEvent
    local logged = false
    Home.handleEvent = function(self, event)
        -- While a forwarded gesture runs, the Dispatcher sends its action
        -- (e.g. ToggleFrontlight) to the top widget, which is this Home.
        -- Hand anything Home does not handle to the file browser below.
        if self._forwarding_gesture and event and event.handler ~= "onGesture"
                and event.handler ~= "onBatchedUpdate" and event.handler ~= "onBatchedUpdateDone" then
            if orig_handleEvent(self, event) then return true end
            return self.ui and self.ui:handleEvent(event)
        end
        if event and event.handler == "onGesture" then
            local ev = event.args and event.args[1]
            local ui = self.ui
            local g = ev and ui and not ui.document and ui.gestures -- file browser only (no open document)
            if g and g.gestures and ui._ordered_touch_zones then
                for _, tz in ipairs(ui._ordered_touch_zones) do
                    local id = tz.def and tz.def.id
                    if id and (id == "multiswipe" or g.gestures[id] ~= nil)
                            and tz.gs_range:match(ev) then
                        self._forwarding_gesture = true
                        local ok, handled = pcall(tz.handler, ev)
                        self._forwarding_gesture = nil
                        if not ok then logger.warn("CWNG home gesture patch: action failed", id, handled) end
                        if ok and handled then
                        logger.dbg("CWNG home: gesture forwarded to file browser gestures", id)
                        return true
                        end
                    end
                end
            elseif not logged then
                logged = true
                logger.warn("CWNG home gesture patch: no file browser gestures found",
                    ui and ui.document ~= nil, ui and ui.gestures ~= nil, ui and ui._ordered_touch_zones ~= nil)
            end
        end
        return orig_handleEvent(self, event)
    end
    logger.info("CWNG home gesture patch: installed")
end

userpatch.registerPatchPluginFunc("cwngsync", function(plugin)
    local ok, Client = pcall(require, "CWNGSyncClient")
    if ok and type(Client) == "table" then patchClient(Client)
    else logger.warn("CWNG offline guard: CWNGSyncClient not found", Client) end

    if package.loaded["cwng_home"] then patchHome(package.loaded["cwng_home"])
    else logger.warn("CWNG home gesture patch: cwng_home module not loaded") end

    if not plugin._offline_guard_hooks then
        plugin._offline_guard_hooks = true
        local orig_net = plugin._onNetworkConnected
        if orig_net then
            plugin._onNetworkConnected = function(self, ...)
                reset("network connected")
                return orig_net(self, ...)
            end
        end
        local orig_now = plugin.onCWNGSyncSyncNow
        if orig_now then
            plugin.onCWNGSyncSyncNow = function(self, ...)
                reset("manual sync")
                return orig_now(self, ...)
            end
        end
    end
end)
