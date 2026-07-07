---@meta
---lib/anim.lua - animation→ability map dispatcher.
---
---Heroes register per-matchup maps (`Anim.RegisterMap`) and particle
---signatures (`Anim.RegisterParticle`). OnUnitAnimation / OnParticleCreate
---resolve the casting unit's map → fire `role` events to subscribers.
---
---Hot-path conventions:
---  • Particle matching uses integer `particleNameIndex` via
---    Utils.ResourceIdFromName (string compare is too slow at the OnParticleCreate
---    firehose rate).
---  • OnUnitAnimation tries integer activity first, then sequenceName string.
---  • Local hero animations are not dispatched (we know our own state).
---  • Stolen/invoked abilities (Rubick, Invoker) are out of scope for v1 -
---    TODO when the first such hero needs it.

local Anim = {}

local now = function() return GlobalVars.GetCurTime() end
local frame = function() return GlobalVars.GetFrameCount() end

----------------------------------------------------------------------------
-- registry
----------------------------------------------------------------------------

---@class AnimEntry
---@field ability string
---@field role    string  -- gap_close | hard_disable | ult_burst | channel_start | dispel | save

---@type table<string, table<integer|string, AnimEntry>>
local maps = {}  -- unit_name → activity_key → entry

---@type table<integer, {ability:string, role:string, on_target_field:string|nil}>
local particles = {}  -- particle_name_index → entry

---@type {substr:string, ability:string, role:string, on_target_field:string|nil}[]
local particle_patterns = {}  -- v6.15.241 (clue C2): substring-name fallback

---@type table<string, fun(event:table)[]>
local subscribers = {}  -- role → [callback]

-- per-(hero, activity) once-per-pair "unmapped" logging
local unmapped_logged = {}

-- per-frame dispatch dedup so multi-wire doesn't double-fire subscribers
local dispatched = {}  -- key → frame

local function dedup(key)
    local f = frame()
    if dispatched[key] == f then return true end
    dispatched[key] = f
    return false
end

local function reap_dispatched()
    local f = frame()
    -- cheap pass: only run every 120 frames
    if f % 120 ~= 0 then return end
    for k, v in pairs(dispatched) do
        if v + 120 < f then dispatched[k] = nil end
    end
end

----------------------------------------------------------------------------
-- public API: registration
----------------------------------------------------------------------------

---Register an animation map for a unit (typically a hero short name like
---"npc_dota_hero_slark"). Map keys are either an `Enum.GameActivity` integer
---OR a sequence name string. Values are `{ability=, role=}` tables.
---Duplicate registrations merge - later keys overwrite earlier.
---@param unit_name string
---@param map table<integer|string, AnimEntry|nil>
function Anim.RegisterMap(unit_name, map)
    local cur = maps[unit_name]
    if not cur then
        cur = {}
        maps[unit_name] = cur
    end
    for k, v in pairs(map) do
        cur[k] = v  -- v may be nil to explicitly mark "not interesting"
    end
end

---Register a particle signature. We resolve the resource path to an integer
---index once at registration time so the OnParticleCreate path is an
---integer-compare not a string-compare.
---@param particle_path  string  -- e.g. "particles/units/heroes/.../foo.vpcf"
---@param signature      {ability:string, role:string, on_target_field:string|nil}
function Anim.RegisterParticle(particle_path, signature)
    local idx = Utils.ResourceIdFromName(particle_path)
    if not idx or idx == 0 then
        Log.Write("[anim] RegisterParticle: failed to resolve " .. particle_path)
        return
    end
    particles[idx] = signature
end

---Register a particle SUBSTRING pattern -- a rot-resistant fallback for
---OnParticleCreate when the exact resource path is not registered (or a
---Valve patch versions the path). `substr` is matched lowercased + plain
---against the particle's full name; use a stable distinctive ability token
---(e.g. "black_hole", "chronosphere"). Same signature shape as
---RegisterParticle. The integer-index path stays the primary fast route;
---this fallback runs only on a miss, and only for enemy-side particles.
---@param substr     string
---@param signature  {ability:string, role:string, on_target_field:string|nil}
function Anim.RegisterParticlePattern(substr, signature)
    if type(substr) ~= "string" or substr == "" then return end
    particle_patterns[#particle_patterns + 1] = {
        substr  = substr:lower(),
        ability = signature.ability,
        role    = signature.role,
        on_target_field = signature.on_target_field,
    }
end

---Subscribe to a role. Multiple subscribers per role are allowed.
---Callback receives `{caster, ability_name, role, raw, target_self}`.
---@param role string
---@param fn   fun(event:table)
function Anim.Subscribe(role, fn)
    local arr = subscribers[role]
    if not arr then
        arr = {}
        subscribers[role] = arr
    end
    arr[#arr + 1] = fn
end

----------------------------------------------------------------------------
-- internal: target_self computation
----------------------------------------------------------------------------

-- Facing threshold for "is the caster aimed at me?" NPC.FindRotationAngle
-- returns RADIANS (established v6.15.215 in the Sniper brain: comparing the
-- raw value to a degree threshold capped |angle| at pi, so `angle > 30` was
-- never true and the gate degraded to always-pass). math.deg converts
-- before the 30-degree compare.
local DEFAULT_ANGLE_DEG = 30
local DEFAULT_RANGE = 1200

local function compute_target_self(caster, ability_range, instant_target)
    local me = Heroes.GetLocal()
    if not me or not caster or me == caster then return false end
    if Entity.IsSameTeam(me, caster) then return false end
    -- range gate
    local me_pos = Entity.GetAbsOrigin(me)
    local range = ability_range or DEFAULT_RANGE
    if not NPC.IsPositionInRange(caster, me_pos, range) then return false end
    -- v6.15.250: unit-target abilities (PA Phantom Strike, Pudge Dismember,
    -- OD Astral Imprisonment, Primal Beast Pulverize, etc.) select their
    -- target by REFERENCE, not by aim -- the caster does not face the
    -- target before casting. Per-entry `instant_target = true` skips the
    -- facing gate for these abilities. Without this flag, the v6.15.232
    -- "polish 1/4" radians fix (math.deg added below) regressed PA's
    -- gap-close detection: pre-v6.15.232 the gate accidentally always
    -- passed (raw radians ~pi never > 30 degrees), letting PA Phantom
    -- Strike fire saves. The math.deg fix is correct for aim-based
    -- projectile abilities (Pudge Hook, Lina LSA, Skywrath bolts) where
    -- the caster does face the target, so the gate stays for those.
    if instant_target then return true end
    -- facing gate (FindRotationAngle is radians - math.deg before compare)
    local angle = math.deg(math.abs(NPC.FindRotationAngle(caster, me_pos)))
    if angle > DEFAULT_ANGLE_DEG then return false end
    return true
end

local function dispatch(role, event, dedup_key)
    if dedup(dedup_key) then return end
    local arr = subscribers[role]
    if not arr then return end
    for i = 1, #arr do
        local ok, err = pcall(arr[i], event)
        if not ok then
            Log.Write("[anim] subscriber error in role '" .. tostring(role) .. "': " .. tostring(err))
        end
    end
end

----------------------------------------------------------------------------
-- callbacks
----------------------------------------------------------------------------

function Anim.OnUnitAnimation_handler(data)
    if not data or not data.unit then return end
    local caster = data.unit
    -- skip local hero's own animations
    local me = Heroes.GetLocal()
    if me and caster == me then return end

    local unit_name = NPC.GetUnitName(caster)
    local map = maps[unit_name]
    if not map then return end

    local entry = map[data.activity]
    if entry == nil and data.sequenceName then
        entry = map[data.sequenceName]
    end

    if entry == nil then
        -- once-per-(hero, activity) unmapped log
        local k = unit_name .. ":" .. tostring(data.activity)
        if not unmapped_logged[k] then
            unmapped_logged[k] = true
            -- comment in production builds; useful when extending maps
            -- Log.Write("[anim] unmapped activity " .. tostring(data.activity) .. " on " .. unit_name)
        end
        return
    end

    -- "explicitly not interesting" sentinel (registered as nil/false value)
    if entry == false then return end

    -- v6.14.1 C4: thread the entry's `range` field through to compute_target_self
    -- so short-range gap-closers don't fall back to DEFAULT_RANGE=1200 and
    -- false-positive across the map. RegisterMap entries may include
    -- `range = N` for per-ability gating.
    -- v6.15.250: also thread `instant_target` so unit-target abilities can
    -- bypass the facing gate (see compute_target_self comment).
    local target_self = compute_target_self(caster, entry.range, entry.instant_target)
    local event = {
        caster       = caster,
        ability_name = entry.ability,
        role         = entry.role,
        raw          = data,
        target_self  = target_self,
    }
    local key = "a:" .. Entity.GetIndex(caster) .. ":" .. tostring(data.activity) .. ":" .. frame()
    dispatch(entry.role, event, key)
    -- v6.14.1 low: prune dispatched-event table on the anim path too. Prior
    -- code only called reap_dispatched from OnParticleCreate_handler, so any
    -- hero with no particle subscriptions accumulated dispatched keys
    -- unbounded over the match.
    reap_dispatched()
end

-- v6.15.241 (clue C2): substring-name fallback for OnParticleCreate. The
-- integer-index lookup is the primary fast path; this runs only on a miss,
-- only when patterns are registered, and only for an enemy-side particle
-- (the team gate keeps it off the bulk of the particle firehose). Matches
-- the particle's full name -- substring-tolerant against a Valve rename.
local function match_particle_pattern(data)
    if #particle_patterns == 0 then return nil end
    local nm = data.fullName or data.name
    if type(nm) ~= "string" or nm == "" then return nil end
    local owner = data.entity or data.entityForModifiers
    if not owner then return nil end
    local me = Heroes.GetLocal()
    if not me or Entity.IsSameTeam(me, owner) then return nil end
    local low = nm:lower()
    for i = 1, #particle_patterns do
        if low:find(particle_patterns[i].substr, 1, true) then
            return particle_patterns[i]
        end
    end
    return nil
end

function Anim.OnParticleCreate_handler(data)
    if not data then return end
    local sig = particles[data.particleNameIndex]
    if not sig then
        sig = match_particle_pattern(data)
        if not sig then return end
    end

    -- v6.14.1 H5: `data.entity` is the cast SOURCE; `data.entityForModifiers`
    -- is who the spell HITS. The prior code aliased `caster` to
    -- `entityForModifiers or entity` - for an enemy ult particle on Sniper,
    -- this set ev.caster = Sniper (target), wrong. Provide both fields
    -- distinctly so subscribers can pick. `caster` now prefers entity (the
    -- source); `target` exposes entityForModifiers explicitly.
    local source = data.entity
    local target = data.entityForModifiers
    -- Fall back if one is missing.
    local owner = source or target
    if not owner then return end

    -- skip our own casts
    local me = Heroes.GetLocal()
    if me and source == me then return end

    -- legacy: `on_target_field` allows overriding `target` with a custom
    -- field name from `data` (rare; used when a particle's modifier-target
    -- field isn't entityForModifiers).
    if sig.on_target_field then
        target = data[sig.on_target_field] or target
    end

    local target_self = false
    if target and me and target == me then target_self = true end

    local event = {
        caster       = source or owner,   -- the spell SOURCE (was: entityForModifiers)
        target       = target,             -- the spell TARGET (new in v6.14.1)
        ability_name = sig.ability,
        role         = sig.role,
        raw          = data,
        target_self  = target_self,
    }
    local key = "p:" .. tostring(data.particleNameIndex) .. ":" .. tostring(data.index) .. ":" .. frame()
    dispatch(sig.role, event, key)

    reap_dispatched()
end

---@param callbacks table
function Anim.Wire(callbacks)
    local function chain(name, ours)
        local prev = callbacks[name]
        callbacks[name] = function(...)
            if prev then prev(...) end
            ours(...)
        end
    end
    chain("OnUnitAnimation",  Anim.OnUnitAnimation_handler)
    chain("OnParticleCreate", Anim.OnParticleCreate_handler)
end

----------------------------------------------------------------------------
-- init
----------------------------------------------------------------------------

local inited = false

function Anim.Init()
    if inited then return end
    inited = true
end

return Anim
