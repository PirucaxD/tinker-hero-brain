---@meta
---lib/save_select.lua - generic threat-vs-save-item selection.
---
---Given a threat (the modifier name it lands as) and the save items a hero
---currently has available, rank which saves actually counter it and pick the
---best one. This is the reusable, hero-agnostic version of the save-selection
---logic that currently lives inline in the Sniper brain (`resolve_save_order`
---/ `try_save_self`). It is provided as a standalone lib so it can be adopted
---per hero without disturbing an existing inline implementation.
---
---Pure logic: no API calls, no callbacks, no side effects (same discipline as
---`lib/threat_data.lua` and `lib/item_data.lua`). The caller decides which
---save items are available/ready and passes them in; this module only
---classifies and ranks.
---
---Bridges the two data libs:
---  - `lib/threat_data.lua`  - what counters a threat, tether ranges, the
---                             hand-tuned per-threat recommended ordering.
---  - `lib/item_data.lua`    - precise save geometry (push distance, cooldown)
---                             via `SAVE_GEOMETRY`.
---
---Naming: all save items use canonical `item_*` names (the keys of
---`threat_data.SAVE_KIND` / `RECOMMENDED_SAVES` and `item_data.SAVE_GEOMETRY`).
---
---Usage:
---```lua
---local SaveSelect = require("lib.save_select")
---local held = { "item_hurricane_pike", "item_black_king_bar", "item_cyclone" }
---local best = SaveSelect.BestSave("modifier_bane_fiends_grip", held,
---                                 { distance = dist_to_caster })
---for _, row in ipairs(SaveSelect.RankSaves(threat_mod, held, ctx)) do
---    -- row.save, row.score, row.reason
---end
---```

local ThreatData = require("lib.threat_data")
local ItemData   = require("lib.item_data")

local SaveSelect = {}

----------------------------------------------------------------------------
-- Scoring weights - heuristic, tune here.
----------------------------------------------------------------------------
local W = {
    base             = 100,  -- a save that counters the threat at all
    recommended_top  = 60,   -- bonus for being #1 in the threat's recommended list
    recommended_step = 12,   -- the bonus drops by this much per rank below #1
    tether_breaks    = 25,   -- displacement save whose push clears the tether
    tether_fails     = -70,  -- displacement save whose push is too short
    cooldown_max     = 18,   -- max bonus for a short-cooldown save
}

----------------------------------------------------------------------------
-- helpers
----------------------------------------------------------------------------

-- A cooldown in SAVE_GEOMETRY is a number, or a per-level array (Aeon Disk).
local function first_number(v)
    if type(v) == "number" then return v end
    if type(v) == "table" then return v[1] end
    return nil
end

-- Accept `available` as either a string array {"item_a", ...} or a hash set
-- {item_a = true, ...}; return a de-duplicated string array.
local function normalize(available)
    local out, seen = {}, {}
    if type(available) ~= "table" then return out end
    for k, v in pairs(available) do
        local name
        if type(k) == "number" then name = v
        elseif v then name = k end
        if type(name) == "string" and not seen[name] then
            seen[name] = true
            out[#out + 1] = name
        end
    end
    return out
end

local function is_tether(threat_mod)
    return ThreatData.THREAT_TETHER_RANGE[threat_mod or ""] ~= nil
end

----------------------------------------------------------------------------
-- public API
----------------------------------------------------------------------------

---True if `save_name` genuinely neutralises `threat_mod` - it must counter the
---threat's effect kind AND, for a tether/channel threat, its displacement must
---actually be long enough to break the tether from `ctx.distance`.
---@param save_name string       canonical item_* save name
---@param threat_mod string      the threat modifier name
---@param ctx table|nil          optional { distance = self-to-caster units }
---@return boolean
function SaveSelect.Effective(save_name, threat_mod, ctx)
    if not save_name or not threat_mod then return false end
    if not ThreatData.SaveCounters(save_name, threat_mod) then return false end
    if is_tether(threat_mod) then
        return ThreatData.WillTetherBreak(save_name, threat_mod,
                                          ctx and ctx.distance)
    end
    return true
end

---Score a single save against a threat. Returns nil when the save does not
---counter the threat at all (so it should not be offered). A save that
---counters the effect but whose push is too short for a tether scores low
---(negative-weighted) rather than nil - the caller still sees it, ranked last.
---@param save_name string
---@param threat_mod string
---@param ctx table|nil          optional { distance = self-to-caster units }
---@return number|nil score, string|nil reason
function SaveSelect.ScoreSave(save_name, threat_mod, ctx)
    if not save_name or not threat_mod then return nil end
    if not ThreatData.SaveCounters(save_name, threat_mod) then return nil end

    local score = W.base
    local reasons = { "counters" }

    -- Per-threat recommended ordering (threat_data's hand-tuned priority).
    local rec = ThreatData.RecommendedSaves(threat_mod)
    if rec then
        for i, name in ipairs(rec) do
            if name == save_name then
                local b = W.recommended_top - (i - 1) * W.recommended_step
                if b > 0 then score = score + b end
                reasons[#reasons + 1] = "recommended#" .. i
                break
            end
        end
    end

    -- Tether geometry: a displacement save only helps if the push clears the
    -- tether range from the current distance.
    if is_tether(threat_mod) then
        if ThreatData.WillTetherBreak(save_name, threat_mod,
                                      ctx and ctx.distance) then
            score = score + W.tether_breaks
            reasons[#reasons + 1] = "breaks-tether"
        else
            score = score + W.tether_fails
            reasons[#reasons + 1] = "push-too-short"
        end
    end

    -- A shorter-cooldown save is mildly preferred (cheaper to spend).
    local geo = ItemData.SaveGeometry(save_name)
    if geo and geo.cooldown then
        local cd = first_number(geo.cooldown)
        if cd and cd > 0 then
            local b = (120 - cd) / 6
            if b < 0 then b = 0 elseif b > W.cooldown_max then b = W.cooldown_max end
            score = score + b
        end
    end

    return score, table.concat(reasons, ",")
end

---Rank every available save against a threat, best first. Saves that do not
---counter the threat at all are dropped. Returns a list of
---`{ save = name, score = number, reason = string }`.
---@param threat_mod string
---@param available string[]|table<string,boolean>   save items the hero has
---@param ctx table|nil          optional { distance = self-to-caster units }
---@return table[]
function SaveSelect.RankSaves(threat_mod, available, ctx)
    local out = {}
    if not threat_mod then return out end
    for _, save in ipairs(normalize(available)) do
        local score, reason = SaveSelect.ScoreSave(save, threat_mod, ctx)
        if score ~= nil then
            out[#out + 1] = { save = save, score = score, reason = reason }
        end
    end
    table.sort(out, function(a, b)
        if a.score ~= b.score then return a.score > b.score end
        return a.save < b.save          -- stable tiebreak (sort is not stable)
    end)
    return out
end

---The single best save for a threat, or nil if nothing available counters it.
---@param threat_mod string
---@param available string[]|table<string,boolean>
---@param ctx table|nil
---@return string|nil best_save, table|nil row   (row = {save, score, reason})
function SaveSelect.BestSave(threat_mod, available, ctx)
    local ranked = SaveSelect.RankSaves(threat_mod, available, ctx)
    local top = ranked[1]
    if not top then return nil, nil end
    return top.save, top
end

---Convenience: bundle the threat_data classification a caller needs to decide
---how urgently to react. Any field is nil when threat_data has no entry.
---@param threat_mod string
---@return table  { category, severity, timing, tether_range, recommended }
function SaveSelect.ThreatBrief(threat_mod)
    return {
        category     = ThreatData.CategoryOf(threat_mod),
        severity     = ThreatData.SeverityOf(threat_mod),
        timing       = ThreatData.TimingFor(threat_mod),
        tether_range = ThreatData.THREAT_TETHER_RANGE[threat_mod or ""],
        recommended  = ThreatData.RecommendedSaves(threat_mod),
    }
end

return SaveSelect
