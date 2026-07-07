---@meta
---lib/damage.lua - damage feed normalizer.
---
---Hero brains call `Damage.GetRecentDamage(npc, window)` without caring
---whether Stage 2 (typed OnEntityHurt feed) is active or we're polling.
---
---Stage 2 detection: we wire OnEntityHurt and OnUpdateEx unconditionally.
---On the first OnEntityHurt firing we flip `stage2_active` to true and the
---polling path stops recording (to avoid double-counting). If a damage event
---is observed via Hero.GetLastHurtTime polling first, we record it; if
---OnEntityHurt later fires we'll prefer it from then on.
---
---Wiring: hero/bootstrap script calls `Damage.Wire(callbacks)` once.

local Damage = {}

local BUF_MAX = 64           -- entries per entity
local BUF_AGE = 3.0          -- seconds, hard-GC older entries

local now = function() return GlobalVars.GetCurTime() end
local frame = function() return GlobalVars.GetFrameCount() end

----------------------------------------------------------------------------
-- ring buffers
----------------------------------------------------------------------------

---@class DmgEntry
---@field time     number
---@field source   userdata|nil
---@field ability  userdata|nil
---@field damage   number

---@type table<integer, {entries: DmgEntry[], head: integer, last_hurt_t: number}>
local buffers = {}        -- keyed by Entity.GetIndex(npc)
local entity_handle = {}  -- index → CEntity, for IsAlive checks during GC

local function buf_for(npc)
    local idx = Entity.GetIndex(npc)
    local b = buffers[idx]
    if not b then
        -- last_hurt_t (wall time, now()) is for OnEntityHurt path bookkeeping
        -- last_hurt_framework (framework time base) is the dedup cursor for
        -- the poll path against Hero.GetLastHurtTime. The two bases may not
        -- match, so keep them separate.
        b = { entries = {}, head = 0, last_hurt_t = 0, last_hurt_framework = 0 }
        buffers[idx] = b
        entity_handle[idx] = npc
    end
    return b
end

local function push(npc, t, source, ability, damage)
    if not npc or damage <= 0 then return end
    local b = buf_for(npc)
    b.head = (b.head % BUF_MAX) + 1
    b.entries[b.head] = { time = t, source = source, ability = ability, damage = damage }
end

-- Ring-buffer entries are sparse after stale-removal - index N may be nil
-- while index N+1 is not. `for i = 1, #b.entries` produces undefined
-- behaviour on sparse tables (`#` returns *any* boundary), so we iterate
-- with `pairs` and defensively guard against nil entries. Stale-removal
-- is deferred to OnUpdateEx_handler's GC pass so this read path never
-- mutates while iterating.
local function sum_window(b, since, source_filter)
    if not b or not b.entries then return 0 end
    local total = 0
    for _, e in pairs(b.entries) do
        if e and e.time >= since then
            if source_filter == nil or e.source == source_filter then
                total = total + e.damage
            end
        end
    end
    return total
end

----------------------------------------------------------------------------
-- Stage 2 state
----------------------------------------------------------------------------

local stage2_active = false
local first_callback_logged = false

---@return boolean
function Damage.IsStage2Active() return stage2_active end

----------------------------------------------------------------------------
-- public read API
----------------------------------------------------------------------------

---Total damage taken in the last `window_seconds` (default 1.5).
---@param npc            userdata
---@param window_seconds number|nil
---@return number
function Damage.GetRecentDamage(npc, window_seconds)
    if not npc or not Entity.IsEntity(npc) then return 0 end
    local w = window_seconds or 1.5
    return sum_window(buffers[Entity.GetIndex(npc)], now() - w, nil)
end

---Damage from a specific source in the window. Stage 2 OFF returns 0.
---@param npc            userdata
---@param source_npc     userdata
---@param window_seconds number|nil
---@return number
function Damage.GetRecentDamageBySource(npc, source_npc, window_seconds)
    if not npc or not source_npc then return 0 end
    if not Entity.IsEntity(npc) or not Entity.IsEntity(source_npc) then return 0 end
    if not stage2_active then return 0 end
    local w = window_seconds or 1.5
    return sum_window(buffers[Entity.GetIndex(npc)], now() - w, source_npc)
end

---Damage rate (damage / second) over the window.
---@param npc            userdata
---@param window_seconds number|nil
---@return number
function Damage.GetDamageRate(npc, window_seconds)
    local w = window_seconds or 1.5
    if w <= 0 then return 0 end
    return Damage.GetRecentDamage(npc, w) / w
end

---Drop all buffered entries for `npc` (e.g., on respawn).
---@param npc userdata
function Damage.Forget(npc)
    if not npc then return end
    local idx = Entity.GetIndex(npc)
    buffers[idx] = nil
    entity_handle[idx] = nil
end

----------------------------------------------------------------------------
-- damage-vs-target calculation
--
-- Frame-correct kill / damage math. Each damage instance is mitigated by the
-- target's MATCHING defense, then the results are summed in RAW HP - so a
-- dual- or triple-instance ability (e.g. Sniper Assassinate = a magical
-- instance + a physical instant-attack instance) is added correctly instead
-- of mixing a magic-resist frame with an armor frame (the v6.15.142 bug:
-- post-armor physical damage was summed straight into a magic-resist-frame
-- total and the kill check under-counted the physical instance).
--
-- `components` is a table of PRE-mitigation damage amounts:
--     { physical = , magical = , pure = }
-- Any field omitted (or 0) contributes nothing - a hero passes only the
-- instances it actually has.
--   physical → mitigated by armor         (NPC.GetArmorDamageMultiplier)
--   magical  → mitigated by magic resist  (NPC.GetMagicalArmorDamageMultiplier)
--   pure     → unmitigated
----------------------------------------------------------------------------

---Raw HP a pre-mitigation damage bundle removes from `target`, after the
---target's armor and magic resistance.
---@param target userdata
---@param components table  { physical?:number, magical?:number, pure?:number }
---@return number rawHpRemoved
function Damage.MitigatedToRawHP(target, components)
    if not target or not components then return 0 end
    local phys = components.physical or 0
    local magi = components.magical  or 0
    local pure = components.pure     or 0
    local total = pure
    if phys ~= 0 then
        local pm = (NPC.GetArmorDamageMultiplier
                    and NPC.GetArmorDamageMultiplier(target)) or 1.0
        total = total + phys * pm
    end
    if magi ~= 0 then
        local mm = (NPC.GetMagicalArmorDamageMultiplier
                    and NPC.GetMagicalArmorDamageMultiplier(target)) or 1.0
        total = total + magi * mm
    end
    return total
end

---True when `components` (pre-mitigation) kill `target`. `extra_hp` is any
---additional RAW HP the caller wants treated as survivable - cast-time
---regen, shields/barriers, active heals, or an overkill safety margin.
---@param target userdata
---@param components table  { physical?:number, magical?:number, pure?:number }
---@param extra_hp? number
---@return boolean kills
---@return number rawHpRemoved
---@return number targetCurrentHp
function Damage.Kills(target, components, extra_hp)
    local removed = Damage.MitigatedToRawHP(target, components)
    local hp = (Entity.GetHealth and Entity.GetHealth(target)) or 0
    return removed >= (hp + (extra_hp or 0)), removed, hp
end

----------------------------------------------------------------------------
-- callbacks
----------------------------------------------------------------------------

-- per-frame dedup so multiple wirings don't double-count the same event
local last_hurt_seen = {}   -- key → frame
local function dedup(key)
    local f = frame()
    if last_hurt_seen[key] == f then return true end
    last_hurt_seen[key] = f
    -- bounded GC: when table grows large, drop entries older than current frame
    if (last_hurt_seen.__count or 0) > 512 then
        for k, v in pairs(last_hurt_seen) do
            if k ~= "__count" and v < f then last_hurt_seen[k] = nil end
        end
        last_hurt_seen.__count = 0
    else
        last_hurt_seen.__count = (last_hurt_seen.__count or 0) + 1
    end
    return false
end

---OnEntityHurt - Stage 2 typed damage feed.
---@param data {source:userdata|nil, target:userdata|nil, ability:userdata|nil, damage:number}
function Damage.OnEntityHurt_handler(data)
    if not data or not data.target then return end
    local key = "h" .. Entity.GetIndex(data.target) .. ":" .. tostring(data.damage) .. ":" .. frame()
    if dedup(key) then return end

    if not stage2_active then
        stage2_active = true
        if not first_callback_logged then
            first_callback_logged = true
            Log.Write("[damage] Stage 2 OnEntityHurt active - typed feed engaged")
        end
    end

    push(data.target, now(), data.source, data.ability, data.damage)
    local b = buffers[Entity.GetIndex(data.target)]
    if b then b.last_hurt_t = now() end
end

---OnUpdateEx - fallback polling path. Records hero damage by diffing
---`Hero.GetLastHurtTime` (framework time base) but pushes entries with
---`time = now()` (wall time) so windowing math stays uniform across both
---Stage 2 and fallback paths.
local function poll_one_hero(hero)
    if not hero or not Entity.IsAlive(hero) then return end
    local last_t = Hero.GetLastHurtTime(hero)
    if not last_t or last_t <= 0 then return end
    local b = buf_for(hero)
    if last_t > b.last_hurt_framework then
        local amount = Hero.GetHurtAmount(hero)
        if amount and amount > 0 then
            push(hero, now(), nil, nil, amount)
            b.last_hurt_t = now()
        end
        b.last_hurt_framework = last_t
    end
end

local last_gc_frame = -1
function Damage.OnUpdateEx_handler()
    local f = frame()
    if f == last_gc_frame then return end
    last_gc_frame = f

    if not stage2_active then
        -- Poll the local hero and every visible hero. Cheap (<10 heroes).
        local heroes = Heroes.GetAll()
        for i = 1, #heroes do poll_one_hero(heroes[i]) end
    end

    -- GC stale entries / dead buffers periodically. Walks the (sparse)
    -- ring buffer via `pairs` so missing slots don't crash; counts kept
    -- entries explicitly since `#` is unreliable on a sparse table.
    if f % 60 == 0 then
        local t_min = now() - BUF_AGE
        for idx, b in pairs(buffers) do
            local kept = 0
            if b.entries then
                for i, e in pairs(b.entries) do
                    if not e or e.time < t_min then
                        b.entries[i] = nil
                    else
                        kept = kept + 1
                    end
                end
            end
            local handle = entity_handle[idx]
            if not handle or not Entity.IsEntity(handle) then
                buffers[idx] = nil
                entity_handle[idx] = nil
            elseif kept == 0 and (b.last_hurt_t or 0) < t_min then
                -- empty + cold: drop to keep table small
                buffers[idx] = nil
                entity_handle[idx] = nil
            end
        end
    end
end

---OnEntityDestroy - drop buffer for destroyed entity.
function Damage.OnEntityDestroy_handler(entity)
    if not entity then return end
    Damage.Forget(entity)
end

---OnProjectile - speculative incoming-damage entries (callback-only path,
---spec mentions this for the Stage-2-OFF prediction case). v1 stub: no
---speculative push by default to avoid noise; future hero brains can call
---`Damage.PushSpeculative` when they want projectile-driven preemption.
function Damage.OnProjectile_handler(_data) end

---OnLinearProjectileCreate - same stance as OnProjectile. Stub for v1.
function Damage.OnLinearProjectileCreate_handler(_data) end

---OnModifierCreate - DoT estimation hook. v1 stub; integrating DoT estimates
---requires hero-side knowledge of which modifiers represent DoT and at what
---rate. Tracked as a Tier 2 hook.
function Damage.OnModifierCreate_handler(_entity, _modifier) end

---@param callbacks table
function Damage.Wire(callbacks)
    local function chain(name, ours)
        local prev = callbacks[name]
        callbacks[name] = function(...)
            if prev then prev(...) end
            ours(...)
        end
    end
    chain("OnEntityHurt",             Damage.OnEntityHurt_handler)
    chain("OnUpdateEx",               Damage.OnUpdateEx_handler)
    chain("OnEntityDestroy",          Damage.OnEntityDestroy_handler)
    chain("OnProjectile",             Damage.OnProjectile_handler)
    chain("OnLinearProjectileCreate", Damage.OnLinearProjectileCreate_handler)
    chain("OnModifierCreate",         Damage.OnModifierCreate_handler)
end

----------------------------------------------------------------------------
-- init
----------------------------------------------------------------------------

local inited = false

function Damage.Init()
    if inited then return end
    inited = true
    stage2_active = false
    first_callback_logged = false
end

return Damage
