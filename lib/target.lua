---@meta
---lib/target.lua - composable predicate helpers.
---
---Per project plan: there is no `Target.Pick()`. Heroes compose these
---predicates inline because target-picking is per-hero (Tier 3) and
---baseline Target Selection handles the default picking.
---
---Convention: every predicate accepts `nil` and returns `false` (or 0 for
---numeric helpers). Eliminates nil-checks at call sites.
---
---Protection helpers use framework primitives (`NPC.IsLinkensProtected`,
---`NPC.IsMirrorProtected`, `NPC.HasAegis`, `Humanizer.IsSafeTarget`); these
---supersede hand-rolled `has-item + cooldown` composition.

local Target = {}

local MS = Enum.ModifierState
local DT = Enum.DamageTypes
local INF = math.huge

----------------------------------------------------------------------------
-- existence / liveness
----------------------------------------------------------------------------

---@param e userdata|nil
---@return boolean
function Target.IsValid(e)
    if e == nil then return false end
    return Entity.IsEntity(e)
end

---@param e userdata|nil
---@return boolean
function Target.IsAlive(e)
    if not Target.IsValid(e) then return false end
    return Entity.IsAlive(e)
end

----------------------------------------------------------------------------
-- type classification
----------------------------------------------------------------------------

---@param e userdata|nil
---@return boolean
function Target.IsHero(e)
    if e == nil then return false end
    if not Entity.IsNPC(e) then return false end
    return NPC.IsHero(e)
end

---@param e userdata|nil
---@return boolean
function Target.IsConsideredHero(e)
    if e == nil or not Entity.IsNPC(e) then return false end
    return NPC.IsConsideredHero(e)
end

---@param e      userdata|nil
---@param source userdata|nil
---@return boolean
function Target.IsEnemyHero(e, source)
    if not source then return false end
    if not Target.IsHero(e) then return false end
    return not Entity.IsSameTeam(source, e)
end

---@param e      userdata|nil
---@param source userdata|nil
---@return boolean
function Target.IsAllyHero(e, source)
    if not source then return false end
    if not Target.IsHero(e) then return false end
    return Entity.IsSameTeam(source, e)
end

----------------------------------------------------------------------------
-- illusion / clone filters
----------------------------------------------------------------------------

---@param e userdata|nil
---@return boolean
function Target.NotIllusion(e)
    if e == nil or not Entity.IsNPC(e) then return false end
    return not NPC.IsIllusion(e)
end

---@param e userdata|nil
---@return boolean
function Target.NotMeepoClone(e)
    if e == nil or not Entity.IsNPC(e) then return false end
    return not NPC.IsMeepoClone(e)
end

---@param e userdata|nil
---@return boolean
function Target.NotClone(e)
    if e == nil or not Entity.IsNPC(e) then return false end
    if NPC.IsIllusion(e) then return false end
    if NPC.IsMeepoClone(e) then return false end
    if NPC.HasModifier(e, "modifier_arc_warden_tempest_double") then return false end
    return true
end

---True if `e` is not a hero-owned summon (filters spirit-bear, brood
---spiders, familiars, etc.). Real heroes pass.
---@param e userdata|nil
---@return boolean
function Target.NotSummon(e)
    if e == nil or not Entity.IsNPC(e) then return false end
    if NPC.IsHero(e) then return true end
    local owner = NPC.GetOwnerNPC(e)
    if not owner then return true end
    return not NPC.IsHero(owner)
end

----------------------------------------------------------------------------
-- positional / visibility
----------------------------------------------------------------------------

---@param target userdata|nil
---@param source userdata|nil
---@param range  number
---@param hull   number|nil
---@return boolean
function Target.InRange(target, source, range, hull)
    if not target or not source then return false end
    local pos = Entity.GetAbsOrigin(target)
    if not pos then return false end
    return NPC.IsPositionInRange(source, pos, range, hull or 0)
end

---@param e userdata|nil
---@return boolean
function Target.IsVisible(e)
    if not e or not Entity.IsNPC(e) then return false end
    return NPC.IsVisible(e)
end

----------------------------------------------------------------------------
-- state / killability
----------------------------------------------------------------------------

---@param e userdata|nil
---@return boolean
function Target.IsKillable(e)
    if not e or not Entity.IsNPC(e) then return false end
    return NPC.IsKillable(e)
end

---@param e     userdata|nil
---@param state integer  -- Enum.ModifierState.MODIFIER_STATE_*
---@return boolean
function Target.HasState(e, state)
    if not e or not Entity.IsNPC(e) then return false end
    return NPC.HasState(e, state)
end

---@param e userdata|nil
---@return boolean
function Target.IsSafeTarget(e)
    if not e then return false end
    return Humanizer.IsSafeTarget(e)
end

----------------------------------------------------------------------------
-- protection (framework-aware)
----------------------------------------------------------------------------

---@param e userdata|nil
---@return boolean
function Target.HasReadyLinkens(e)
    if not e or not Entity.IsNPC(e) then return false end
    return NPC.IsLinkensProtected(e)
end

---@param e userdata|nil
---@return boolean
function Target.HasReadyLotus(e)
    if not e or not Entity.IsNPC(e) then return false end
    return NPC.IsMirrorProtected(e)
end

---@param e userdata|nil
---@return boolean
function Target.HasAegis(e)
    if not e or not Entity.IsNPC(e) then return false end
    return NPC.HasAegis(e)
end

----------------------------------------------------------------------------
-- invuln-window prediction
----------------------------------------------------------------------------

---Will `entity` be invulnerable (or out-of-game) at any point in the next
---`ms` milliseconds? v1 reads state durations only - any currently-active
---invuln state means the answer is yes for any positive window. Cast-window
---prediction (self-cast Eul / Manta dispel-into-invuln) is a Tier 2 hook
---(`lib/timing.lua`) and not folded in here.
---@param entity userdata|nil
---@param ms     number  -- accepted for API symmetry; unused in v1
---@return boolean
function Target.WillBeInvulnIn(entity, ms)
    if not entity or not Entity.IsNPC(entity) then return false end
    local _ = ms
    local durations = NPC.GetStatesDuration(entity, {
        [MS.MODIFIER_STATE_INVULNERABLE] = true,
        [MS.MODIFIER_STATE_OUT_OF_GAME]  = true,
    })
    local d1 = durations[MS.MODIFIER_STATE_INVULNERABLE] or 0
    local d2 = durations[MS.MODIFIER_STATE_OUT_OF_GAME]  or 0
    return d1 > 0 or d2 > 0
end

----------------------------------------------------------------------------
-- effective HP (kill-confirm math)
----------------------------------------------------------------------------

---Effective HP a `damage_type` burst must chew through to kill `target`.
---Returns 0 for dead targets, +Infinity for fully-immune targets.
---@param target      userdata|nil
---@param source      userdata|nil  -- unused in v1; kept for API symmetry
---@param damage_type integer       -- Enum.DamageTypes
---@return number
function Target.EffectiveHpVs(target, source, damage_type)
    if not target or not Entity.IsNPC(target) then return 0 end
    if not Target.IsAlive(target) then return 0 end

    -- hard invuln / out-of-game
    if NPC.HasState(target, MS.MODIFIER_STATE_INVULNERABLE) then return INF end
    if NPC.HasState(target, MS.MODIFIER_STATE_OUT_OF_GAME) then return INF end
    if NPC.HasState(target, MS.MODIFIER_STATE_UNTARGETABLE) then return INF end

    local hp = Entity.GetHealth(target)
    local barriers = NPC.GetBarriers(target)
    local b_phys = (barriers and barriers.physical and barriers.physical.current) or 0
    local b_magi = (barriers and barriers.magic and barriers.magic.current) or 0
    local b_all  = (barriers and barriers.all and barriers.all.current) or 0

    if damage_type == DT.DAMAGE_TYPE_PHYSICAL then
        if NPC.HasState(target, MS.MODIFIER_STATE_ATTACK_IMMUNE) then return INF end
        -- Presence-guard like lib/damage.lua + Sniper: the multiplier getters
        -- are possibly-absent on some builds; a bare call throws and breaks the
        -- kill-confirm hot path. Fallback 1.0 = no armor adjustment.
        local mult = (NPC.GetArmorDamageMultiplier and NPC.GetArmorDamageMultiplier(target)) or 1.0
        if mult <= 0 then return INF end
        return (hp + b_phys + b_all) / mult
    end

    if damage_type == DT.DAMAGE_TYPE_MAGICAL then
        if NPC.HasState(target, MS.MODIFIER_STATE_MAGIC_IMMUNE) then return INF end
        local mult = (NPC.GetMagicalArmorDamageMultiplier and NPC.GetMagicalArmorDamageMultiplier(target)) or 1.0
        if mult <= 0 then return INF end
        return (hp + b_magi + b_all) / mult
    end

    if damage_type == DT.DAMAGE_TYPE_PURE then
        if NPC.HasState(target, MS.MODIFIER_STATE_DEBUFF_IMMUNE) then return INF end
        return hp + b_all
    end

    -- DAMAGE_TYPE_HP_REMOVAL or other: treat as raw HP minus universal barriers.
    return hp + b_all
end

----------------------------------------------------------------------------
-- v6.8 - combat-state predicates for combo/sequence decisions
----------------------------------------------------------------------------

-- Items the target could use to escape a committed ult: invuln, dispel,
-- magic-immune. v6.13 Cross F#7: derived from threat_data.SAVE_KIND instead
-- of hardcoded - when SAVE_KIND changes (e.g. v6.7 BKB gained dispel_basic),
-- this list updates automatically. Picks items whose kinds include any of
-- {invuln, dispel_basic, reflect_target, magic_immune}.
local TD = require("lib.threat_data")
local ESCAPE_ITEMS = TD.ESCAPE_ITEM_NAMES

----------------------------------------------------------------------------
-- v0.5.152 - "cannot be killed right now" predicates (offensive-side target
-- gating; companions to HasAegis / HasReadyLinkens / HasReadyLotus, placed here
-- because HasUnkillableModifier reads the threat_data set TD required just above).
-- Heroes call IsUnkillableNow to skip wasting a kill combo and prefer a killable
-- target. WK Reincarnation has no off-CD modifier -> ability-readiness check.
----------------------------------------------------------------------------

local UNKILLABLE_MODIFIERS = TD.UNKILLABLE_MODIFIERS or {}

---Target has an active modifier that prevents death (Dazzle Shallow Grave = min
---HP 1; Oracle False Promise = damage/healing delayed, cannot die during it).
---@param e userdata|nil
---@return boolean
function Target.HasUnkillableModifier(e)
    if not e or not Entity.IsNPC(e) or not NPC.HasModifier then return false end
    for mod in pairs(UNKILLABLE_MODIFIERS) do
        if NPC.HasModifier(e, mod) then return true end
    end
    return false
end

---Wraith King will revive if killed now: Reincarnation leveled + off cooldown
---(IsReady also covers the 220/110/0 mana cost). No off-CD modifier exists (VPK +
---Sniper modseen), so this is an ability-readiness check, gated on the unit name so
---GetAbility is only probed on WK. IsReady is coerced truthy (codebase convention,
---never == true).
---@param e userdata|nil
---@return boolean
function Target.WillReincarnate(e)
    if not e or not Entity.IsNPC(e) then return false end
    if not (NPC.GetUnitName and NPC.GetUnitName(e) == "npc_dota_hero_skeleton_king") then
        return false
    end
    if not (NPC.GetAbility and Ability and Ability.GetLevel and Ability.IsReady) then return false end
    local reinc = NPC.GetAbility(e, "skeleton_king_reincarnation")
    if not (reinc and Ability.GetLevel(reinc) > 0) then return false end
    return Ability.IsReady(reinc) and true or false
end

---Combined: target cannot be killed right now (death-preventing modifier OR WK
---Reincarnation ready). The single predicate heroes gate kill-commit and target
---selection on.
---@param e userdata|nil
---@return boolean
function Target.IsUnkillableNow(e)
    return Target.HasUnkillableModifier(e) or Target.WillReincarnate(e)
end

---Target has an off-CD invuln / dispel / magic-immune item in active slots.
---Used by combo selection to bias toward grenade-first sequences (interrupt
---their cast point) and away from R-only against equipped backliners.
---@param e userdata|nil
---@return boolean
function Target.HasReadyEscapeItem(e)
    if not e or not Entity.IsNPC(e) then return false end
    for i = 1, #ESCAPE_ITEMS do
        local it = NPC.GetItem(e, ESCAPE_ITEMS[i], true)
        if it and Ability.IsReady(it) then return true end
    end
    return false
end

---v6.12: window-aware escape detection. Returns one of:
---  `"active"` - a dispel/immunity buff is currently on the target. R wasted.
---  `"ready"`  - at least one escape item off CD. Likely popped during our cast.
---  `"soon"`   - no escape ready, but at least one comes off CD within
---               `soon_window_s` (default 2.4s ~= Sniper R cast point + buffer).
---               Pro behavior: target will pop dispel as R impacts → R wasted.
---  `"long"`   - escape item(s) exist but all on CD beyond the cast window.
---  `"none"`   - target has no escape items at all.
---
---Hedges:
---  - If target has Refresher Orb / Shard, downgrade `"long"` to `"soon"`
---    (Refresher could snap CDs back; defensive assumption).
---  - If target last visible > 3s ago, return `"ready"` (stale fog data ≠
---    safety; assume worst case, consistent with project fog-data rule).
---@param e             userdata|nil
---@param soon_window_s number|nil   default 2.4
---@return string
function Target.EscapeItemWindowState(e, soon_window_s)
    if not e or not Entity.IsNPC(e) then return "none" end
    if NPC.HasState(e, MS.MODIFIER_STATE_MAGIC_IMMUNE) then return "active" end
    if NPC.HasState(e, MS.MODIFIER_STATE_OUT_OF_GAME)  then return "active" end
    if NPC.HasState(e, MS.MODIFIER_STATE_INVULNERABLE) then return "active" end

    local soon = soon_window_s or 2.4

    -- Stale-fog defense: if we haven't seen them recently, assume worst case.
    local last_t = Hero.GetLastVisibleTime(e)
    if last_t and (GlobalVars.GetCurTime() - last_t) > 3.0 then
        return "ready"
    end

    -- Refresher hedge: if target has Refresher Orb / Shard, treat any "long"
    -- as "soon" (escape items could come back any time during our cast).
    local has_refresher = (NPC.GetItem(e, "item_refresher", true) ~= nil)
                       or (NPC.GetItem(e, "item_refresher_shard", true) ~= nil)

    local any_long = false
    for i = 1, #ESCAPE_ITEMS do
        local it = NPC.GetItem(e, ESCAPE_ITEMS[i], true)
        if it then
            if Ability.IsReady(it) then return "ready" end
            local cd = Ability.GetCooldown(it) or 999
            if cd <= soon then return "soon" end
            any_long = true
        end
    end

    if any_long then
        return has_refresher and "soon" or "long"
    end
    return "none"
end

---Target is actively moving AWAY from `me`. Heuristic: target is running
---AND its facing is in the rough "away from me" hemisphere (angle > 90°).
---Used to bias toward grenade-poke / shrap-zone setups (kite punishment).
---@param target userdata|nil
---@param me userdata|nil
---@return boolean
-- v6.15 D3: now also velocity-tracks distance from `me` over recent frames.
-- A target who is running orbital-laterally (facing 90° off-axis from me but
-- not actually increasing distance) is no longer mis-classified as kiting.
-- Cache lives on `Target` itself, keyed by entity index.
-- v6.15.2 M2: opportunistic GC + pause-time skew + EntIndex reuse handling.
local _kite_track = {}  -- idx → { last_dist_sqr, last_t, spawn_t }
local _kite_last_gc = 0
function Target.IsKitingUs(target, me)
    if not target or not me or not Entity.IsNPC(target) then return false end
    if not NPC.IsRunning(target) then return false end
    local m_pos = Entity.GetAbsOrigin(me)
    if not m_pos then return false end
    -- v6.15.232: FindRotationAngle is radians - math.deg before the compare.
    local angle_to_me = math.deg(math.abs(NPC.FindRotationAngle(target, m_pos)))
    if angle_to_me <= 90 then return false end  -- not even facing away

    -- Velocity check: is distance from me increasing over the last ~0.25s?
    local t_pos = Entity.GetAbsOrigin(target)
    local dx = t_pos.x - m_pos.x
    local dy = t_pos.y - m_pos.y
    local cur_d2 = dx*dx + dy*dy
    local idx = Entity.GetIndex(target)
    local t_now = GlobalVars.GetCurTime()
    local rec = _kite_track[idx]
    -- v6.15.2 M2: opportunistic GC every 5s - drop entries where last_t is
    -- older than 30s (entity dead / fog / index reused for a different
    -- entity since). Cheap pass; runs at most once per 5s of game time.
    if (t_now - _kite_last_gc) > 5.0 then
        _kite_last_gc = t_now
        for k, r in pairs(_kite_track) do
            if (t_now - r.last_t) > 30 then _kite_track[k] = nil end
        end
    end
    -- v6.15.2 M2: dead-target check - if the entity died and respawned
    -- (Source reuses EntIndex), the cached `last_dist_sqr` is stale. Drop
    -- the record when the target shows signs of newness (alive again after
    -- being unseen for > 5s).
    local stale = rec and ((t_now - rec.last_t) > 5.0)
    if stale then rec = nil end
    _kite_track[idx] = { last_dist_sqr = cur_d2, last_t = t_now }
    if not rec or (t_now - rec.last_t) > 0.5 then
        -- Insufficient history; fall back to angle-only behavior.
        return true
    end
    -- Allow a 50u dead zone for noisy/orbital movement.
    local DEAD_ZONE_SQR = 50 * 50
    return cur_d2 > (rec.last_dist_sqr + DEAD_ZONE_SQR)
end

---Target is right-clicking `me`: attacking and within their attack range
---of us. Used to bias toward grenade-disarm (3s disarm removes their auto
---chain).
---@param target userdata|nil
---@param me userdata|nil
---@return boolean
function Target.IsRightClicking(target, me)
    if not target or not me or not Entity.IsNPC(target) then return false end
    if not NPC.IsAttacking(target) then return false end
    local t_pos = Entity.GetAbsOrigin(target)
    local m_pos = Entity.GetAbsOrigin(me)
    if not t_pos or not m_pos then return false end
    -- v6.15.234: GetAttackRange is BASE only; add the item/talent bonus
    -- (Dragon Lance, Hurricane Pike) so a ranged carry is not under-ranged.
    local atk_range = (NPC.GetAttackRange(target) or 600)
        + (NPC.GetAttackRangeBonus and NPC.GetAttackRangeBonus(target) or 0)
    local dx = t_pos.x - m_pos.x
    local dy = t_pos.y - m_pos.y
    return (dx*dx + dy*dy) <= (atk_range + 100) * (atk_range + 100)
end

return Target
