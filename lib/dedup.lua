---@meta
---lib/dedup.lua - generic event-dedup helpers (state-container design).
---
---Two independent dedup concerns:
---  - anim-log dedup    - "did I just log this anim event?" (per-caster, per-ability)
---  - threat dedup      - "did I already respond to this threat instance?" (per-caster, per-modifier)
---
---**State-container design (v6.15.115 redesign).** An earlier draft kept
---module-private dedup tables. That broke the consuming brain's external
---readers - Sniper has 5+ sites that iterate / clear / GC its
---`state.responded_threats` and `state.anim_log_dedup` tables directly.
---
---Fix: every function takes the caller-owned table as its FIRST argument.
---The caller still owns the data (its iterators / GC passes keep working);
---this module just provides the read/write API + the window constants.
---
---Usage:
---```lua
---local Dedup = require("lib.dedup")
---
----- threat dedup against a caller-owned table:
---if not Dedup.threat_already_responded(state.responded_threats, caster, mod) then
---    -- fire the save
---    Dedup.threat_mark_responded(state.responded_threats, caster, mod)
---end
---
----- anim-log throttle (throttle-and-mark in one call):
---if not Dedup.anim_throttled(state.anim_log_dedup, caster, ability_name) then
---    tlog(...)  -- log the anim event
---end
---
----- periodic GC, once per ~5s:
---Dedup.gc(state.responded_threats, state.anim_log_dedup, GlobalVars.GetCurTime())
---```

local Dedup = {}

---Window in seconds: an identical anim event from the same caster/ability
---within this window is duplicate (suppress the log entry, but still
---process the event). 1.0s covers OnUnitAnimation's multiple-emit pattern.
Dedup.ANIM_WINDOW = 1.0

---A single threat instance (one Bane casting one Nightmare) should produce
---at most one save action. Multiple observation paths (anim event,
---modifier-create) can see the same threat. Window: 2.0s - large enough to
---cover slow-cast → modifier-landing windows (Fiend Grip 0.2s cast etc.)
---but short enough that re-casts within normal CD (Nightmare 12s) aren't
---conflated.
Dedup.THREAT_WINDOW = 2.0

---@param caster userdata|nil
---@param mod_name string|nil
---@return string|nil
local function threat_key(caster, mod_name)
    if not caster or not mod_name then return nil end
    if not Entity.IsEntity(caster) then return nil end
    return tostring(Entity.GetIndex(caster)) .. ":" .. mod_name
end

---Anim-log throttle. Returns true if an identical anim event was logged in
---the last ANIM_WINDOW (caller should still PROCESS the event, just skip
---the log). Stamps `tbl` on every call - "throttle-and-mark" in one.
---@param tbl table caller-owned dedup table ("<caster_idx>:<ability>" → time)
---@param caster userdata|nil
---@param ability_name string|nil
---@return boolean
function Dedup.anim_throttled(tbl, caster, ability_name)
    if not tbl or not caster then return false end
    local key = tostring(Entity.GetIndex(caster)) .. ":" .. (ability_name or "?")
    local t = GlobalVars.GetCurTime()
    local last = tbl[key]
    if last and (t - last) < Dedup.ANIM_WINDOW then return true end
    tbl[key] = t
    return false
end

---Threat-response already-responded check. Read-only - does NOT mark.
---@param tbl table caller-owned dedup table ("<caster_idx>:<mod>" → time)
---@param caster userdata|nil
---@param mod_name string|nil
---@return boolean
function Dedup.threat_already_responded(tbl, caster, mod_name)
    if not tbl then return false end
    local key = threat_key(caster, mod_name)
    if not key then return false end
    local last = tbl[key]
    if last and (GlobalVars.GetCurTime() - last) < Dedup.THREAT_WINDOW then
        return true
    end
    return false
end

---Most-recent threat-mark timestamp across ALL consumers of this module.
---Updated inside threat_mark_responded; exposed via Dedup.last_mark_t() so
---hot-path callers can ask "was ANY threat marked in the last N seconds?"
---in O(1) instead of iterating their responded_threats table every tick.
---Per-hero state is unaffected, this scalar piggybacks on the existing
---mark write site and is only useful as a recency floor; consumers that
---need per-caster/per-mod fidelity continue to call threat_already_responded.
local _last_mark_t = nil

---Mark a threat instance as responded. Call AFTER taking the save action
---so future observations of the same threat dedupe.
---@param tbl table caller-owned dedup table
---@param caster userdata|nil
---@param mod_name string|nil
function Dedup.threat_mark_responded(tbl, caster, mod_name)
    if not tbl then return end
    local key = threat_key(caster, mod_name)
    if not key then return end
    local t = GlobalVars.GetCurTime()
    tbl[key] = t
    -- v0.5.37 PERF-06: stamp the global most-recent-mark scalar so consumers
    -- (e.g. Lina ww_recent_threat) can do an O(1) recency query without
    -- iterating the caller's responded_threats table on every tick.
    _last_mark_t = t
end

---Returns the timestamp of the most-recent threat mark across ALL consumers
---of this module, or nil if no mark has ever been recorded this session.
---Stable, O(1). Used by hot-path "was anything marked recently?" gates that
---would otherwise iterate a multi-entry dedup table every frame.
---@return number|nil
function Dedup.last_mark_t()
    return _last_mark_t
end

---Clear a threat instance's responded mark, so the NEXT observation of the
---same (caster, mod) is treated as a fresh occurrence and not deduped. Call
---when a genuinely new instance of the threat is detected - e.g. a repeated
---instant-blink cast: each cast deserves its own save, and the flat
---THREAT_WINDOW dedup would otherwise swallow the second one.
---@param tbl table caller-owned dedup table
---@param caster userdata|nil
---@param mod_name string|nil
function Dedup.threat_clear_responded(tbl, caster, mod_name)
    if not tbl then return end
    local key = threat_key(caster, mod_name)
    if not key then return end
    tbl[key] = nil
end

---Periodic GC over both caller-owned tables. Drops threat entries older
---than 5× THREAT_WINDOW and anim entries older than 30s. Caller invokes
---this periodically (e.g., every ~5s in OnUpdateEx).
---@param responded_tbl table|nil caller-owned threat dedup table
---@param anim_tbl table|nil caller-owned anim dedup table
---@param now_t number current game time
function Dedup.gc(responded_tbl, anim_tbl, now_t)
    if responded_tbl then
        for k, t in pairs(responded_tbl) do
            if (now_t - t) > (Dedup.THREAT_WINDOW * 5) then
                responded_tbl[k] = nil
            end
        end
    end
    if anim_tbl then
        for k, t in pairs(anim_tbl) do
            if (now_t - t) > 30 then anim_tbl[k] = nil end
        end
    end
end

return Dedup
