---lib/towers.lua - per-tower registry: alive flag + measured hp-slope death prediction.
---Pure state-in/state-out; the hero injects samples (no engine reads here). Key = any
---stable string (the hero uses MapData name .. "@" .. team). Towers never revive, so an
---alive=false sample latches `dead` permanently. The death ETA is a MEASURED read (the
---same doctrine as the v0.1.236 wave speed): hp / EMA hp-slope while the tower is
---actively melting; an undamaged, healing, or fog-stale tower predicts math.huge =
---no behavior change anywhere. Spec: Tinker/TINKER_TOWER_DEATH_DESIGN.md.
local Towers = {}

local FLOOR   = 20    -- hp/s: below this the tower is not "melting", no prediction
local STALE_S = 6     -- s: a sample older than this decays the prediction to OFF
local EMA     = 0.5   -- slope smoothing (two-sample memory; creep waves hit steadily)

---Update the registry from one sampling pass. samples = { { key, hp, alive } ... }
---(alive == false means the spot's tower is confirmed gone). Returns the state table.
function Towers.Track(state, samples, now)
    state = state or {}
    for _, s in ipairs(samples or {}) do
        local e = state[s.key]
        if not e then e = {}; state[s.key] = e end
        if s.alive == false then
            e.dead = true
        elseif not e.dead and s.hp then
            if e.hp and e.t and now > e.t then
                local inst = (e.hp - s.hp) / (now - e.t)   -- damage taken, hp/s
                if inst < 0 then
                    e.slope = nil                          -- healing/glyph: the melt read resets
                else
                    e.slope = e.slope and (EMA * e.slope + (1 - EMA) * inst) or inst
                end
            end
            e.hp, e.t, e.seen = s.hp, now, true
        end
    end
    return state
end

---The alive flag: true / false (dead latch) / nil (never sampled).
function Towers.Alive(state, key)
    local e = state and state[key]
    if not e then return nil end
    if e.dead then return false end
    return e.seen and true or nil
end

---Seconds until predicted death from `now`: 0 when dead; hp/slope minus the sample age
---while actively melting on a fresh sample; math.huge otherwise (unknown/undamaged/
---healing/stale = conservative OFF).
function Towers.DeathEta(state, key, now, opts)
    local e = state and state[key]
    if not e then return math.huge end
    if e.dead then return 0 end
    if not (e.slope and e.hp and e.t) then return math.huge end
    if e.slope < ((opts and opts.floor) or FLOOR) then return math.huge end
    local age = now - e.t
    if age > ((opts and opts.stale_s) or STALE_S) then return math.huge end
    return math.max(0, e.hp / e.slope - age)
end

return Towers
