---@meta
---lib/item_saves.lua - hero-agnostic defensive ITEM save bodies.
---
---Owns one `.fire`-shaped builder per defensive item plus a `build(cfg)`
---factory. The hero passes a `cfg` bundle (cast primitives + optional
---policy hooks) and merges the result into its own SAVE_FIRE map alongside
---its hero-ABILITY saves. Item-save behavior is a property of the item and
---the threat geometry, not the hero ("WW out of Disruptor field" == "WW out
---of Underlord pit"), so every hero shares these. See
---Lina/ITEM_SAVES_LIFT_DESIGN.md.
---
---v0.5.108: created by lifting Lina's v0.5.107 SAVE_FIRE item bodies.

-- v0.5.108.1: Target is a PROJECT lib (require), NOT a framework global like
-- Entity/NPC/Enum. The Pike enemy-target-primary check calls Target.IsAlive,
-- so the module must require it (the v0.5.108 lift omitted this -> the Pike
-- fire crashed on every live threat_caster: "PA blink/AA did not trigger
-- pike"). No require cycle: item_saves -> target -> threat_data -> (lazy)
-- target. Matches lib/escape.lua which also requires lib.target.
local Target = require("lib.target")

local ItemSaves = {}

-- The v0.5.107 launch-in-vain truth table as a PURE predicate (offline
-- testable). cp_t = cast-point remaining for the armed threat (nil = no
-- cast-point gate active). has_marker = the during-cast threat modifier is
-- on the hero (present while casting AND in flight, destroyed on
-- cancel/impact). "fire"/"instant" PROCEED to the cast; "defer"/"skip" HOLD
-- (the cyclone body returns false). The four-way return lets each path log
-- its own reason.
function ItemSaves.cyclone_launch_decision(cp_t, has_marker)
    if cp_t == nil then return "fire" end
    if cp_t > -0.05 then
        return has_marker and "defer" or "instant"
    end
    return has_marker and "fire" or "skip"
end

-- Shared guard+log helper for the items that emit save_fire_invoked and
-- early-return when their own self-buff modifier is already active (parity:
-- only WW / Eul / Glimmer / BKB log + guard; the others are silent).
local function guard_active(cfg, item_name, intent, guard_mod)
    local me = cfg.self_npc()
    local guarded = (guard_mod and me and NPC.HasModifier(me, guard_mod)) and true or false
    cfg.tlog(1, "save_fire_invoked", { item = item_name, intent = tostring(intent),
        guarded = guarded and "y" or "n" })
    return guarded
end

-- Builders return a { short, fire } entry. Each reads cfg at call time so a
-- hero can register hooks after build().
function ItemSaves.glimmer_cape(cfg)
    return { short = "glimmer", fire = function(intent)
        if guard_active(cfg, "item_glimmer_cape", intent, "modifier_item_glimmer_cape_fade") then return false end
        return cfg.issue_self(intent, cfg.item("item_glimmer_cape"))
    end }
end
function ItemSaves.black_king_bar(cfg)
    return { short = "bkb", fire = function(intent)
        if guard_active(cfg, "item_black_king_bar", intent, "modifier_black_king_bar_immune") then return false end
        return cfg.issue_no_target(intent, cfg.item("item_black_king_bar"))
    end }
end
function ItemSaves.manta(cfg)
    return { short = "manta", fire = function(intent)
        return cfg.issue_no_target(intent, cfg.item("item_manta"))
    end }
end
function ItemSaves.invis_sword(cfg)
    return { short = "shadowblade", fire = function(intent)
        return cfg.issue_no_target(intent, cfg.item("item_invis_sword"))
    end }
end
function ItemSaves.silver_edge(cfg)
    return { short = "silveredge", fire = function(intent)
        return cfg.issue_no_target(intent, cfg.item("item_silver_edge"))
    end }
end
function ItemSaves.ethereal_blade_self(cfg)
    return { short = "ether_self", fire = function(intent)
        local eb = cfg.item("item_ethereal_blade"); if not eb then return false end
        return cfg.issue_self(intent, eb)
    end }
end

-- Legacy 0.85 HP-fraction gate (the nil-hook default): fire Lotus when the
-- hero is below 85% HP, else skip. Matches pre-v0.5.21 behavior so a hero
-- with no expected-damage table does not regress.
local function default_lotus_gate(cfg)
    local me = cfg.self_npc()
    local hp    = (me and Entity.GetHealth    and Entity.GetHealth(me))    or 0
    local hpmax = (me and Entity.GetMaxHealth and Entity.GetMaxHealth(me)) or 1
    local hp_frac = (hpmax > 0) and (hp / hpmax) or 1
    return hp_frac <= 0.85
end
function ItemSaves.lotus_orb(cfg)
    return { short = "lotus", fire = function(intent, threat_caster, threat_mod)
        local fire_ok
        if cfg.lotus_gate then
            fire_ok = cfg.lotus_gate(threat_mod)
        else
            fire_ok = default_lotus_gate(cfg)
        end
        if not fire_ok then
            cfg.tlog(3, "lotus_dmg_gate_skip", { mod = tostring(threat_mod) })
            return false
        end
        return cfg.issue_self(intent, cfg.item("item_lotus_orb"))
    end }
end

-- Shared cyclone core for WW + Eul. opts = { item, guard_mod, fallback_range,
-- post_move }. Order is a byte-equivalent port of the v0.5.107 WW/Eul bodies.
local function cyclone_fire(cfg, opts, intent, threat_caster, threat_mod)
    if guard_active(cfg, opts.item, intent, opts.guard_mod) then return false end
    -- launch-in-vain gate (cast-point threats only; armed_cp_t nil = inert).
    local cp_t = cfg.armed_cp_t and cfg.armed_cp_t()
    if cp_t then
        local me = cfg.self_npc()
        local tm = cfg.armed_threat_mod and cfg.armed_threat_mod()
        local marker = (tm and me and NPC.HasModifier(me, tm)) and true or false
        local decision = ItemSaves.cyclone_launch_decision(cp_t, marker)
        if decision == "defer" then
            cfg.tlog(2, "cyclone_wait_for_launch", { item = opts.item,
                cp_t = string.format("%.2f", cp_t) })
            return false
        elseif decision == "skip" then
            cfg.tlog(2, "cyclone_skip_cast_gone", { item = opts.item,
                cp_t = string.format("%.2f", cp_t) })
            return false
        end
        -- "fire" / "instant" fall through to the cast.
    end
    -- situational target vs self (committed-ranged harasser only; default nil).
    local tgt = cfg.cyclone_target
                and cfg.cyclone_target(threat_mod, threat_caster, opts.item, opts.fallback_range)
    if tgt then
        local ok_t = cfg.issue_target(intent, cfg.item(opts.item), tgt)
        if ok_t then
            cfg.tlog(1, "cyclone_harasser_target", { item = opts.item, target = cfg.uname(tgt) })
            return true
        end
    end
    local ok = cfg.issue_self(intent, cfg.item(opts.item))
    if ok and opts.post_move and cfg.queue_post_move then
        -- WW self-cast moves at 300 MS during the 2.5s airborne (movable=true).
        cfg.queue_post_move("ww", 600, threat_caster, opts.guard_mod, true)
    end
    return ok
end
function ItemSaves.wind_waker(cfg, opts)
    opts = opts or {}
    local o = { item = "item_wind_waker", guard_mod = "modifier_wind_waker",
                fallback_range = opts.fallback_range or 700, post_move = true }
    return { short = "windwaker", fire = function(intent, tc, tm)
        return cyclone_fire(cfg, o, intent, tc, tm)
    end }
end
function ItemSaves.cyclone(cfg, opts)
    opts = opts or {}
    local o = { item = "item_cyclone", guard_mod = "modifier_eul_cyclone",
                fallback_range = opts.fallback_range or 700, post_move = false }
    return { short = "eul", fire = function(intent, tc, tm)
        return cyclone_fire(cfg, o, intent, tc, tm)
    end }
end

function ItemSaves.force_staff(cfg)
    return { short = "force", fire = function(intent, threat_caster)
        local it = cfg.item("item_force_staff"); if not it then return false end
        if cfg.self_push then
            return cfg.self_push(intent, it, "item_force_staff", 600, threat_caster)
        end
        return cfg.issue_self(intent, it)
    end }
end
-- v0.5.109: generalized over opts.item/opts.short so item_blink and the
-- POINT blink variants (Swift / Arcane / Overwhelming) share one body.
function ItemSaves.blink(cfg, opts)
    local item  = (opts and opts.item)  or "item_blink"
    local short = (opts and opts.short) or "blink"
    return { short = short, fire = function(intent, threat_caster)
        local me = cfg.self_npc()
        local it = me and cfg.item(item); if not it then return false end
        -- blink-broken gate: any recent damage disables the dagger ~3s.
        local dmg = cfg.recent_damage and cfg.recent_damage(3.0) or 0
        if dmg and dmg > 0 then
            cfg.tlog(2, "blink_skip_broken", { dmg = string.format("%.0f", dmg) })
            return false
        end
        local _, landing = nil, nil
        if cfg.compute_safe_dest then _, landing = cfg.compute_safe_dest(threat_caster, 1200) end
        if not landing then
            cfg.tlog(3, "blink_no_safe_dest", {})
            return false
        end
        local ok = cfg.issue_position(intent, it, landing)
        if ok then
            cfg.tlog(1, "blink_escape", {
                x = string.format("%.0f", landing.x),
                y = string.format("%.0f", landing.y),
                caster = threat_caster and cfg.uname(threat_caster) or "centroid",
            })
        end
        return ok
    end }
end
function ItemSaves.hurricane_pike(cfg)
    return { short = "pike", fire = function(intent, threat_caster, threat_mod)
        local it = cfg.item("item_hurricane_pike"); if not it then return false end
        local enemy_range = (cfg.pike_enemy_range and cfg.pike_enemy_range()) or 0
        if threat_caster and Entity.IsEntity(threat_caster) and Target.IsAlive(threat_caster)
           and not (NPC.HasState and NPC.HasState(threat_caster, Enum.ModifierState.MODIFIER_STATE_MAGIC_IMMUNE))
           and cfg.dist_to(threat_caster) <= enemy_range then
            local ok = cfg.issue_target(intent, it, threat_caster)
            if ok and cfg.pike_after_target_fire then cfg.pike_after_target_fire(threat_caster) end
            return ok
        end
        if cfg.self_push then
            return cfg.self_push(intent, it, "item_hurricane_pike", 600, threat_caster)
        end
        return cfg.issue_self(intent, it)
    end }
end

-- v0.5.109 expansion: NO_TARGET bare-cast defensive actives (one-liner, no
-- guard, silent -- matches the manta / shadow-blade pattern). Cast types
-- KV-verified (items.json AbilityBehavior NO_TARGET). Already referenced by
-- the threat_data chains; the builders are the missing actuators.
function ItemSaves.ghost(cfg)
    return { short = "ghost", fire = function(intent)
        return cfg.issue_no_target(intent, cfg.item("item_ghost"))
    end }
end
function ItemSaves.satanic(cfg)
    return { short = "satanic", fire = function(intent)
        return cfg.issue_no_target(intent, cfg.item("item_satanic"))
    end }
end
function ItemSaves.pipe(cfg)
    return { short = "pipe", fire = function(intent)
        return cfg.issue_no_target(intent, cfg.item("item_pipe"))
    end }
end
function ItemSaves.crimson_guard(cfg)
    return { short = "crimson", fire = function(intent)
        return cfg.issue_no_target(intent, cfg.item("item_crimson_guard"))
    end }
end
function ItemSaves.blade_mail(cfg)
    return { short = "blademail", fire = function(intent)
        return cfg.issue_no_target(intent, cfg.item("item_blade_mail"))
    end }
end
function ItemSaves.phase_boots(cfg)
    return { short = "phase", fire = function(intent)
        return cfg.issue_no_target(intent, cfg.item("item_phase_boots"))
    end }
end

-- v0.5.109 expansion: UNIT_TARGET-self defensive actives. KV-verified self is
-- a valid target (Solar Crest FRIENDLY, Disperser BOTH). issue_self = cast-
-- target on self, like ethereal_blade_self.
function ItemSaves.solar_crest(cfg)
    return { short = "solar", fire = function(intent)
        local it = cfg.item("item_solar_crest"); if not it then return false end
        return cfg.issue_self(intent, it)
    end }
end
function ItemSaves.disperser(cfg)
    return { short = "disperser", fire = function(intent)
        local it = cfg.item("item_disperser"); if not it then return false end
        return cfg.issue_self(intent, it)
    end }
end

-- v0.5.109 expansion: Diffusal Blade enemy-purge. KV-verified UNIT_TARGET
-- ENEMY, cast range 600. Defensively purges the attacker (strips positive
-- buffs). Mirrors the hurricane_pike enemy-primary guard; no valid caster ->
-- no-op. 600 is a builder constant (Diffusal's range is fixed).
function ItemSaves.diffusal_blade(cfg)
    return { short = "diffusal", fire = function(intent, threat_caster)
        local it = cfg.item("item_diffusal_blade"); if not it then return false end
        if threat_caster and Entity.IsEntity(threat_caster) and Target.IsAlive(threat_caster)
           and not (NPC.HasState and NPC.HasState(threat_caster, Enum.ModifierState.MODIFIER_STATE_MAGIC_IMMUNE))
           and cfg.dist_to(threat_caster) <= 600 then
            return cfg.issue_target(intent, it, threat_caster)
        end
        return false
    end }
end

-- Factory: assemble the full item map. Builders append to this list as later
-- groups are added; keep it the single source of the roster.
local BUILDERS = {
    item_glimmer_cape        = ItemSaves.glimmer_cape,
    item_black_king_bar      = ItemSaves.black_king_bar,
    item_manta               = ItemSaves.manta,
    item_invis_sword         = ItemSaves.invis_sword,
    item_silver_edge         = ItemSaves.silver_edge,
    item_ethereal_blade_self = ItemSaves.ethereal_blade_self,
    item_lotus_orb           = ItemSaves.lotus_orb,
    item_wind_waker          = ItemSaves.wind_waker,
    item_cyclone             = ItemSaves.cyclone,
    item_force_staff         = ItemSaves.force_staff,
    item_blink               = ItemSaves.blink,
    item_hurricane_pike      = ItemSaves.hurricane_pike,
    item_ghost               = ItemSaves.ghost,
    item_satanic             = ItemSaves.satanic,
    item_pipe                = ItemSaves.pipe,
    item_crimson_guard       = ItemSaves.crimson_guard,
    item_blade_mail          = ItemSaves.blade_mail,
    item_phase_boots         = ItemSaves.phase_boots,
    item_solar_crest         = ItemSaves.solar_crest,
    item_disperser           = ItemSaves.disperser,
    item_swift_blink         = function(cfg) return ItemSaves.blink(cfg, { item = "item_swift_blink",        short = "swiftblink" }) end,
    item_arcane_blink        = function(cfg) return ItemSaves.blink(cfg, { item = "item_arcane_blink",       short = "arcaneblink" }) end,
    item_overwhelming_blink  = function(cfg) return ItemSaves.blink(cfg, { item = "item_overwhelming_blink", short = "overwhelmingblink" }) end,
    item_diffusal_blade      = ItemSaves.diffusal_blade,
}
function ItemSaves.build(cfg)
    local map = {}
    for name, builder in pairs(BUILDERS) do
        map[name] = builder(cfg)
    end
    return map
end

return ItemSaves
