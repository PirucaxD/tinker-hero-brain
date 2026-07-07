---@meta
---lib/signal.lua - cross-hero coordination registry.
---
---Each hero brain that loads calls `Signal.Register(name, api)` to publish
---its public surface. Other heroes call `Signal.Get(name)` to look up an
---ally hero's brain and call into its API. The registry lives on this
---module's table (a Lua module is a singleton across `require` calls in the
---same Lua state) - so all hero scripts that `require("lib.signal")` share
---the same `_registry`. Note v6.15.3: UCZone's sandbox doesn't expose `_G`,
---so we cannot store the registry as a true global; the module-singleton
---pattern is the workaround.
---
---Use cases:
---  - Sniper saving an ally: `Signal.Broadcast("save_request", { ally = e })`
---    and Wisp/Oracle/Dazzle/Disruptor brains subscribe.
---  - Multi-Sniper R coordination: each Sniper publishes "I am firing R on
---    target X at time T", others suppress redundant R commits.
---  - Item-coordination: brain A publishes "I will give Lotus on tick T",
---    brain B knows not to also give Lotus.
---
---API surface intentionally small. Subscribers are responsible for nil-safety;
---publishers must not depend on subscribers being present.
---
---NOT a replacement for OnUpdateEx polling. Use signals for sparse,
---intent-level coordination; use polling for state queries.

local Signal = {}

-- v6.15.3 hotfix: UCZone's Lua sandbox doesn't expose `_G` as a global
-- table (`attempt to index a nil value (global '_G')` at module load).
-- Cross-hero state lives on the module table itself; Lua's `require` cache
-- ensures all hero files that `require("lib.signal")` see the same table.
-- This works as long as all heroes share a single Lua state - the standard
-- UCZone case. If the framework ever isolates hero scripts in separate
-- states, a different bridge would be needed (e.g., writes through db.json).
local _registry = {
    api      = {},   -- name → api-table
    subs     = {},   -- channel → { tokens → fn }
    last     = {},   -- channel → last-payload (cache)
    next_tok = 0,    -- v6.15.2 H5: monotonic counter
}
-- Re-export on the module table so callers can introspect if they want.
Signal._registry = _registry

---Register a hero's public API.
---@param name string  Hero identifier ("Sniper", "Pudge", etc.)
---@param api  table   Table of functions the hero exposes.
function Signal.Register(name, api)
    -- v6.15.2 H6: nil-name would raise "table index is nil" on the next line.
    if name == nil then return end
    _registry.api[name] = api
end

---Look up another hero's API.
---@param name string
---@return table|nil
function Signal.Get(name)
    return _registry.api[name]
end

---Subscribe to a channel. The callback fires with the payload published
---via Broadcast. Subscribers are scoped to the current Lua state - if the
---hero file reloads, prior subscriptions are dropped (the calling code is
---responsible for re-subscribing on init).
---
---Returns a token that can be passed to Unsubscribe.
---@param channel  string
---@param callback fun(payload: table)
---@return integer token
-- v6.15.2 H5: monotonic global counter, NOT array length. Using `#arr + 1`
-- on a sparse table (with holes from Unsubscribe) returns the last non-nil
-- index - re-uses an in-use token, silently overwriting a still-live
-- subscriber. The counter avoids reuse forever.
function Signal.Subscribe(channel, callback)
    local arr = _registry.subs[channel]
    if not arr then
        arr = {}
        _registry.subs[channel] = arr
    end
    _registry.next_tok = _registry.next_tok + 1
    local tok = _registry.next_tok
    arr[tok] = callback
    return tok
end

function Signal.Unsubscribe(channel, token)
    local arr = _registry.subs[channel]
    if arr and arr[token] then arr[token] = nil end
end

---Publish a payload to all subscribers of a channel. Subscriber errors are
---logged (via the Log subsystem if available) and swallowed so one bad
---hero brain doesn't break the chain.
---@param channel string
---@param payload table|nil
-- v6.15.2 H5: iterate via `pairs` since the subs table is now keyed by
-- monotonic token (sparse). #arr + numeric-for iteration no longer applies.
function Signal.Broadcast(channel, payload)
    _registry.last[channel] = payload
    local arr = _registry.subs[channel]
    if not arr then return end
    for _, cb in pairs(arr) do
        local ok, err = pcall(cb, payload)
        if not ok then
            -- Diagnostic: prefer Log.Write (UCZone) then fall back to print
            -- so subscriber errors aren't silently dropped when Log is nil.
            if Log and Log.Write then
                Log.Write("[signal] subscriber error on '" .. channel .. "': " .. tostring(err))
            elseif print then
                print("[signal] subscriber error on '" .. channel .. "': " .. tostring(err))
            end
        end
    end
end

---Fetch the last-broadcast payload on a channel without subscribing. Useful
---for one-shot queries like "did any ally hero publish R-on-target X
---recently?".
---@param channel string
---@return table|nil
function Signal.Last(channel) return _registry.last[channel] end

---Drop the cached last-payload for a channel (or all channels if nil).
---v6.15.2 low: previously `last[channel]` grew forever - large per-tick
---broadcasts held references to old payloads indefinitely. Hero brains
---should call this when shutting down or hot-reloading.
---@param channel string|nil
function Signal.Clear(channel)
    if channel == nil then
        _registry.last = {}
    else
        _registry.last[channel] = nil
    end
end

return Signal
