---@meta
---lib/hero_value.lua - per-hero combat-value model for the FC TF value-arbiter
---(Phase D). HeroValue.of(enemy, peers) = a role base x a live, peer-relative
---fed-ness multiplier.
---
---Role base: DERIVED from lib/hero_data's KV role tag (the PRIMARY/first tag -> a
---value), so all heroes are covered with exact names and it stays patch-stable;
---a small HERO_VALUE_OVERRIDE table hand-corrects tag-vs-position misreads.
---
---Live multiplier: peer-relative TOTAL STATS (str+agi+int), with hero level as
---the fallback. Stats read on visible enemies AND include item bonuses (so a fed
---enemy reads higher), unlike networth which reads nil on enemies (no CPlayer
---owner). All reads are pcall-guarded and degrade to the base, so the module is
---deterministic and offline-testable by stubbing the Hero/NPC globals. Reusable
---across heroes; LOCAL until public-synced (depends on lib/hero_data).

local HeroValue = {}

local HD = require("lib.hero_data")   -- KV-generated hero reference (role tags, stats)
local TD = require("lib.threat_data") -- kill-threat: ability -> threat modifier + severity

-- KV role TAG -> base value. base() keys on the PRIMARY (first) tag of HD.role.
-- KV tags: Carry, Nuker, Pusher, Initiator, Durable, Disabler, Escape, Support,
-- Jungler. A "Carry" core is ~1.0 (the K.FC_FLIP_VALUE unit); a pure support ~0.45.
HeroValue.TAG_VALUE = {
    Carry     = 1.00,
    Nuker     = 0.80,
    Pusher    = 0.70,
    Initiator = 0.70,
    Durable   = 0.70,
    Disabler  = 0.60,
    Escape    = 0.60,
    Jungler   = 0.50,
    Support   = 0.45,
}
HeroValue.DEFAULT_VALUE = 0.50   -- unknown hero / missing role

-- per-hero overrides where the primary KV tag misreads farm-position value.
-- Outliers only; grows as demos / the user surface misreads.
HeroValue.HERO_VALUE_OVERRIDE = {
    npc_dota_hero_doom_bringer  = 0.70,  -- KV "Carry", but canonically offlane
    npc_dota_hero_earth_spirit  = 0.50,  -- KV "Nuker", but a pos-4 roamer
    npc_dota_hero_bounty_hunter = 0.50,  -- KV "Escape", but a pos-4 roamer
}

local LO, HI = 0.6, 1.6   -- live multiplier clamp (mirror of K.HV_LIVE_LO / K.HV_LIVE_HI)

function HeroValue.base(unit_name)
    if not unit_name then return HeroValue.DEFAULT_VALUE end
    local ov = HeroValue.HERO_VALUE_OVERRIDE[unit_name]
    if ov then return ov end
    local h = HD.HEROES and HD.HEROES[unit_name]
    local role = h and h.role
    if type(role) ~= "string" then return HeroValue.DEFAULT_VALUE end
    local primary = role:match("^(%a+)")
    return (primary and HeroValue.TAG_VALUE[primary]) or HeroValue.DEFAULT_VALUE
end

local function safe_num(fn)
    local ok, v = pcall(fn)
    if ok and type(v) == "number" then return v end
    return nil
end

-- Read total stats (str+agi+int) for a unit, or nil. Item-inclusive and reads on
-- visible enemies; the primary live fed-ness signal.
local function read_stats(u)
    local s = safe_num(function() return Hero.GetStrengthTotal and Hero.GetStrengthTotal(u) end)
    local a = safe_num(function() return Hero.GetAgilityTotal and Hero.GetAgilityTotal(u) end)
    local i = safe_num(function() return Hero.GetIntellectTotal and Hero.GetIntellectTotal(u) end)
    if s and a and i then return s + a + i end
    return nil
end

-- Read hero level for a unit, or nil. The fallback signal when stats are unavailable.
local function read_lvl(u)
    local ok, lvl = pcall(function() return NPC.GetCurrentLevel and NPC.GetCurrentLevel(u) end)
    if ok and type(lvl) == "number" and lvl >= 1 and lvl <= 30 then return lvl end
    return nil
end

-- Read networth for a unit (via its owning player), or nil. NOT used by live_mult
-- (reads nil on enemies); retained for the hero_value_eval diagnostic only.
local function read_nw(u)
    local ok_pw, pw = pcall(function() return NPC.GetPlayerOwner and NPC.GetPlayerOwner(u) end)
    if not (ok_pw and pw) then return nil end
    local ok, tp = pcall(function() return Player.GetTeamPlayer and Player.GetTeamPlayer(pw) end)
    if ok and type(tp) == "table" and type(tp.networth) == "number" and tp.networth > 0 then
        return tp.networth
    end
    return nil
end

-- Peer-relative fed-ness multiplier. Total stats are used if they read for the
-- enemy AND every peer (apples-to-apples ratio); otherwise level for all. The
-- peer set includes the enemy itself (the cluster mean). < 2 samples -> 1.0.
function HeroValue.live_mult(enemy, peers)
    if not (enemy and peers) then return 1.0 end
    local reader = read_stats
    local my_v = read_stats(enemy)
    if my_v then
        for i = 1, #peers do
            if not read_stats(peers[i]) then my_v = nil; break end
        end
    end
    if not my_v then
        reader = read_lvl
        my_v = read_lvl(enemy)
    end
    if not my_v then return 1.0 end
    local sum, n = 0, 0
    for i = 1, #peers do
        local v = reader(peers[i])
        if v then sum = sum + v; n = n + 1 end
    end
    if n < 2 then return 1.0 end
    local mean = sum / n
    if mean <= 0 then return 1.0 end
    local mult = my_v / mean
    if mult < LO then return LO elseif mult > HI then return HI end
    return mult
end

function HeroValue.of(enemy, peers)
    if not enemy then return 0 end
    local name
    local ok = pcall(function() name = NPC.GetUnitName and NPC.GetUnitName(enemy) end)
    if not ok then name = nil end
    return HeroValue.base(name) * HeroValue.live_mult(enemy, peers)
end

-- Kill-threat weight: how dangerous a fogged/visible enemy is, multiplied into
-- Escape.FogProximityRisk. PRECISE signal = a cataloged lethal ability
-- (hero_data abilities -> ThreatData.AbilityToCanonical -> THREAT_PROFILE.severity);
-- COMPLETE fallback = role tags (ABILITY_TO_THREAT is curated, not exhaustive).
-- "Disabler"/"Nuker" are over-tagged so ignored; "Initiator" (dive-kill) and
-- primary "Support" are the clean role signals. Calibratable; shared with Lina.
HeroValue.KILL_W_HI   = 1.15  -- lethal kit / diving initiator (1.4 -> 1.15 v0.1.90: a carry like Razor inflated mid risk so Tinker bailed too early; softened so he holds mid longer, still recovers on genuine danger)
HeroValue.KILL_W_BASE = 1.0   -- baseline (cores, unknown)
HeroValue.KILL_W_LO   = 0.6   -- support-tagged, no lethal kit, not a diver

function HeroValue.KillThreat(hero_name)
    local h = HD.Get(hero_name)
    if not h then return HeroValue.KILL_W_BASE end
    local lethal = false
    if h.abilities then
        for _, ab in ipairs(h.abilities) do
            local mod = TD.AbilityToCanonical(ab)
            if mod then
                local prof = TD.THREAT_PROFILE[mod]
                if prof and prof.severity == "lethal" then lethal = true; break end
            end
        end
    end
    local role = h.role or ""
    if lethal or role:find("Initiator") then return HeroValue.KILL_W_HI end
    if role:find("Support") then return HeroValue.KILL_W_LO end
    return HeroValue.KILL_W_BASE
end

-- Cluster value tie-break (FC consumer 3b). Given parallel per-anchor arrays of
-- member COUNT and summed VALUE, return (best_idx, pure_idx): best = argmax count
-- with EXACT-count ties broken by higher value (full ties keep the first); pure =
-- first argmax count (the geometric pick, for the fc_cluster_flip diag). Strictly
-- more bodies always wins, so value never reduces the W stun-count. Empty -> nil,nil.
function HeroValue.best_cluster(counts, values)
    local n = counts and #counts or 0
    if n == 0 then return nil, nil end
    local best_i, best_c, best_v = 1, counts[1], values[1] or 0
    local pure_i, pure_c = 1, counts[1]
    for i = 2, n do
        local c = counts[i]
        if c > pure_c then pure_c, pure_i = c, i end
        local v = values[i] or 0
        if c > best_c or (c == best_c and v > best_v) then
            best_c, best_v, best_i = c, v, i
        end
    end
    return best_i, pure_i
end

-- diagnostics only: the raw reads behind the live multiplier + alternatives, so
-- the hero_value_eval log can show what's driving the scale. debug_reads returns
-- (networth|nil, level|nil); debug_signals returns (max_hp, total_stats,
-- true_max_damage) -- the candidate item-sensitive signals. Any unreadable -> nil.
function HeroValue.debug_reads(u)
    return read_nw(u), read_lvl(u)
end

function HeroValue.debug_signals(u)
    local maxhp = safe_num(function() return Entity.GetMaxHealth and Entity.GetMaxHealth(u) end)
    local stats = read_stats(u)
    local dmg   = safe_num(function() return NPC.GetTrueMaximumDamage and NPC.GetTrueMaximumDamage(u) end)
    return maxhp, stats, dmg
end

-- Farm priority on a unified 0..1 scale: how much this hero "owns" farm (pos1 carry highest,
-- pos5 hard support lowest). Role-FIRST (the ground truth in matches with attributed positions);
-- hero_value is the FALLBACK when role is nil, normalized onto the same scale. Used by an auto-farm
-- consumer to gate "stealing": contested = a nearby ally with a HIGHER FarmPriority than ours.
HeroValue.ROLE_PRIORITY = { [1] = 1.00, [2] = 0.80, [3] = 0.60, [4] = 0.30, [5] = 0.15 }
HeroValue.VALUE_NORM = 1.6   -- hero_value.of upper bound (base<=1.0 * live clamp HI 1.6); fallback scaler

-- args { role = <1..5|nil>, value = <hero_value number|nil> }. Pure.
---@return number priority 0..1
function HeroValue.FarmPriority(args)
    args = args or {}
    if args.role and HeroValue.ROLE_PRIORITY[args.role] then
        return HeroValue.ROLE_PRIORITY[args.role]
    end
    local v = (args.value or HeroValue.DEFAULT_VALUE) / HeroValue.VALUE_NORM
    if v < 0 then return 0 elseif v > 1 then return 1 end
    return v
end

-- Player role / position (1 = carry .. 5 = hard support), or nil. VERIFIED 2026-06-26 on the gitbook
-- (game-components/core/player): UCZone exposes NO clean position/role/assigned-lane API. The Player
-- class (GetPlayerData / GetTeamData / GetTeamPlayer) has no position field; the ONLY hint is
-- GetTeamData.lane_selection_flags, a pre-game lane-PREFERENCE bitflag of undocumented encoding, NOT a
-- reliable assigned position. So this returns nil and consumers fall back to the role-tag point system.
-- This is the single place to wire a real read if the API appears or the flag encoding is confirmed.
function HeroValue.role(_hero)
    return nil
end

-- Is this hero a CORE (carry / mid / offlane) for farm-ownership decisions? Role-FIRST (positions 1-3)
-- when HeroValue.role is available; else the role-tag BASE value (patch-stable + fed-ness-independent,
-- so an under-levelled offlaner still reads as a core) >= core_base (default 0.55: carry/nuker/pusher/
-- initiator/durable/disabler/escape are >= 0.55, jungler/support/default are below).
function HeroValue.IsCore(hero, name, core_base)
    local r = HeroValue.role(hero)
    if r then return r >= 1 and r <= 3 end
    return HeroValue.base(name) >= (core_base or 0.55)
end

return HeroValue
