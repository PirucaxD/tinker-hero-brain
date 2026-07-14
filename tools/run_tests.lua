#!/usr/bin/env lua
-- tools/run_tests.lua - pure-Lua test runner for hero-brain lib helpers.
--
-- Runs unit tests on the lib/ modules that are pure (no game state):
--   - lib/threat_data.lua's SaveCounters / SeverityOf / CategoryOf / etc.
--   - lib/target.lua's NotClone (with stub NPC)
--   - lib/timing.lua's EscapeReadiness (with stub APIs)
--
-- Game-side APIs are stubbed at the top so the libs load without errors.
-- Run with:  lua tools/run_tests.lua

----------------------------------------------------------------------------
-- API STUBS (so the libs can be required without a running game)
----------------------------------------------------------------------------

-- Most lib code reads game globals (Entity, NPC, Ability, etc.). For pure
-- helpers we provide no-op stubs; for predicate-helpers we provide minimal
-- behavior. Tests that need real game state are not runnable here.

NPC = NPC or {}
NPC.IsIllusion       = function() return false end
NPC.IsMeepoClone     = function() return false end
NPC.HasModifier      = function() return false end
NPC.HasState         = function() return false end
NPC.GetItem          = function() return nil end
NPC.GetMana          = function() return 100 end
NPC.GetStatesDuration= function() return 0 end
NPC.IsRunning        = function() return false end
NPC.IsAttacking      = function() return false end
NPC.GetAttackRange   = function() return 550 end
NPC.FindRotationAngle= function() return 0 end

Entity = Entity or {}
Entity.IsNPC         = function() return true end
Entity.IsAlive       = function() return true end
Entity.IsSameTeam    = function(a, b) return false end
Entity.GetIndex      = function(e) return e and e.idx or 0 end
Entity.GetAbsOrigin  = function(e) return e and e.pos or { x = 0, y = 0, z = 0 } end
Entity.GetHealth     = function() return 1000 end
Entity.GetMaxHealth  = function() return 1000 end
Entity.IsEntity      = Entity.IsEntity or function(e) return e ~= nil end
-- v0.5.108.1: do NOT stub a global `Target` here. Target is a PROJECT lib
-- (require("lib.target")), not a framework global -- stubbing it globally is
-- what hid the v0.5.108 missing-require crash. lib/item_saves requires
-- lib.target itself; the test loads the real module (its IsAlive resolves
-- against the Entity stubs above), so a future missing-require regresses LOUD.

Ability = Ability or {}
Ability.IsReady      = function() return false end
Ability.GetCooldown  = function() return 999 end
Ability.GetManaCost  = function() return 0 end
Ability.GetLevel     = function() return 0 end

Hero = Hero or {}
Hero.GetLastVisibleTime = function() return nil end

GlobalVars = GlobalVars or {}
GlobalVars.GetCurTime = function() return 0 end

Enum = Enum or {}
Enum.ModifierState = setmetatable({}, { __index = function(_, k) return k end })
Enum.UnitOrder     = setmetatable({}, { __index = function(_, k) return k end })  -- v0.5.16x Phase B: UO for the escape safe_issue path

-- v0.5.82: Vector stub for lib/farm pure-geometry tests. farm only reads
-- .x / .y and constructs Vector(x, y, z) for aim points; no Vector methods.
Vector = Vector or function(x, y, z) return { x = x, y = y, z = z } end

-- Patch package.path so requires from lib/ resolve.
package.path = "./?.lua;./?/init.lua;" .. package.path

----------------------------------------------------------------------------
-- TEST FRAMEWORK
----------------------------------------------------------------------------

local pass, fail = 0, 0
local fails = {}
local function it(name, fn)
    local ok, err = pcall(fn)
    if ok then pass = pass + 1; print("  pass  " .. name)
    else fail = fail + 1; print("  FAIL  " .. name); fails[#fails + 1] = { name = name, err = err }
    end
end
local function describe(group, fn)
    print("[" .. group .. "]")
    fn()
end
local function assert_eq(a, b, msg)
    if a ~= b then error((msg or "expected eq") .. ": got " .. tostring(a)
        .. ", want " .. tostring(b), 2) end
end
local function assert_true(v, msg) if not v then error(msg or "expected true", 2) end end
local function assert_false(v, msg) if v then error(msg or "expected false", 2) end end

----------------------------------------------------------------------------
-- TESTS
----------------------------------------------------------------------------

local TD = require("lib.threat_data")

describe("lib/threat_data - SAVE_KIND data integrity", function()
    it("SAVE_KIND populated", function()
        local n = 0
        for _ in pairs(TD.SAVE_KIND) do n = n + 1 end
        assert_true(n > 10, "fewer than 10 SAVE_KIND entries")
    end)
    it("ESCAPE_ITEM_NAMES derived at load", function()
        assert_true(type(TD.ESCAPE_ITEM_NAMES) == "table", "ESCAPE_ITEM_NAMES not table")
        assert_true(#TD.ESCAPE_ITEM_NAMES > 0, "empty escape list")
    end)
    it("ESCAPE_ITEM_NAMES includes BKB", function()
        local found = false
        for i = 1, #TD.ESCAPE_ITEM_NAMES do
            if TD.ESCAPE_ITEM_NAMES[i] == "item_black_king_bar" then found = true; break end
        end
        assert_true(found, "BKB missing from ESCAPE_ITEM_NAMES")
    end)
    it("ESCAPE_ITEM_NAMES includes strong-dispel-only items (Disperser)", function()
        -- dispel_strong supersets dispel_basic, so a strong-dispel item must
        -- still count as an escape item (regression guard for the v0.5.x
        -- dispel_strong vocab split, which moved Disperser off dispel_basic).
        local found = false
        for i = 1, #TD.ESCAPE_ITEM_NAMES do
            if TD.ESCAPE_ITEM_NAMES[i] == "item_disperser" then found = true; break end
        end
        assert_true(found, "strong-dispel item dropped out of ESCAPE_ITEM_NAMES")
    end)
    it("ESCAPE_ITEM_NAMES excludes non-item saves", function()
        for i = 1, #TD.ESCAPE_ITEM_NAMES do
            local s = TD.ESCAPE_ITEM_NAMES[i]
            assert_true(s:sub(1, 5) == "item_", "non-item in escape list: " .. s)
        end
    end)
end)

describe("lib/threat_data - SaveCounters", function()
    it("BKB counters Bane Nightmare (magic_immune)", function()
        assert_true(TD.SaveCounters("item_black_king_bar", "modifier_bane_nightmare"))
    end)
    it("Force Staff does NOT counter Doom (no displacement_perp on Doom)", function()
        -- modifier_doom_bringer_doom has counter {invuln, magic_immune, reflect_target}
        assert_false(TD.SaveCounters("item_force_staff", "modifier_doom_bringer_doom"))
    end)
    it("Pike DOES counter Pudge hook (displacement_perp)", function()
        assert_true(TD.SaveCounters("item_hurricane_pike", "modifier_pudge_meat_hook"))
    end)
    it("Cyclone does NOT counter Pudge hook in-flight (v6.14.1 M3 fix)", function()
        -- modifier_pudge_meat_hook should NOT have `invuln` in THREAT_COUNTER.
        assert_false(TD.SaveCounters("item_cyclone", "modifier_pudge_meat_hook"))
    end)
end)

describe("lib/threat_data - SeverityOf / CategoryOf", function()
    it("SeverityOf returns low/medium/high for known threats", function()
        local sev = TD.SeverityOf("modifier_bane_nightmare")
        assert_true(sev == "low" or sev == "medium" or sev == "high",
            "got severity=" .. tostring(sev))
    end)
    it("Axe Call severity is medium post-v6.14.1 M4", function()
        assert_eq(TD.SeverityOf("modifier_axe_berserkers_call"), "medium")
    end)
    it("Pudge hook is high severity (a connecting hook is a lethal pull, not low/sidesteppable for an auto-defending brain)", function()
        -- v0.5.147.x hook cast-poll demo: severity 'low' made the low_severity_high_hp
        -- gate withhold WW (the only owned save) at full HP. THREAT_PROFILE already says
        -- severity='lethal'; align the tier table with it. Matches rattletrap_hookshot.
        assert_eq(TD.SeverityOf("modifier_pudge_meat_hook"), "high")
    end)
    it("Rattletrap hookshot is high severity (lethal pull, matches Pudge hook)", function()
        assert_eq(TD.SeverityOf("modifier_rattletrap_hookshot"), "high")
    end)
    it("Power Cogs trap marker + push are medium severity (not low; keeps the WW/Eul eat-time saves off the low_severity_high_hp gate)", function()
        assert_eq(TD.SeverityOf("modifier_rattletrap_cog_marker"), "medium")
        assert_eq(TD.SeverityOf("modifier_rattletrap_cog_push"), "medium")
    end)
    it("Techies mines + sticky + M.A.D. are all low-severity chip (sticky downranked from medium so the low_severity_high_hp gate withholds saves at full HP)", function()
        assert_eq(TD.SeverityOf("modifier_techies_land_mine_burn"), "low")
        assert_eq(TD.SeverityOf("modifier_techies_sticky_bomb_slow"), "low")
        assert_eq(TD.SeverityOf("modifier_techies_mutually_assured_destruction"), "low")
    end)
    it("Techies Blast Off! is a high-severity leap answered by the airborne/displacement/BKB close_gap chain", function()
        -- Blast Off (techies_suicide) leaps onto Lina and detonates the mine/sticky combo on
        -- landing; arm on the in-flight modifier_techies_suicide_leap (modseen-confirmed on the
        -- caster) like Slark/Huskar. high -> NOT withheld by low_severity_high_hp.
        assert_eq(TD.SeverityOf("modifier_techies_suicide_leap"), "high")
        assert_eq(TD.CategoryOf("modifier_techies_suicide_leap"), "close_gap")
        assert_true(TD.SaveCounters("item_cyclone", "modifier_techies_suicide_leap"), "Eul/WW (invuln/airborne) dodges the leap landing")
        assert_true(TD.SaveCounters("item_blink", "modifier_techies_suicide_leap"), "Blink out of the 400 AoE")
        assert_true(TD.SaveCounters("item_black_king_bar", "modifier_techies_suicide_leap"), "BKB (magical, no spell-immunity pierce) eats it")
    end)
    it("Techies Minefield Sign (Aghs) -> Blink, then BKB, then WW last (the only 3 escapes; zone outlasts cyclone, 1000r field)", function()
        -- 1000-radius "damages moving units" aura. BLINK (1200u) leads -- the only clean full-clear.
        -- Then BKB (immune, walk out). WW LAST: untargetable 2.5s but the 10s minefield OUTLASTS the
        -- cyclone so she lands back in it -- a last resort. NOT Eul (same outlast) and NOT Force/Pike
        -- (600u cannot clear a 1000r field). medium -> not withheld at full HP.
        assert_eq(TD.SeverityOf("modifier_techies_minefield_sign_scepter_aura"), "medium")
        local rs = TD.RECOMMENDED_SAVES["modifier_techies_minefield_sign_scepter_aura"]
        assert_true(rs ~= nil, "Minefield Sign has a RECOMMENDED_SAVES list")
        assert_eq(table.concat(rs, ","), "item_blink,item_black_king_bar,item_wind_waker")
    end)
    it("close_gap backbone puts item_blink 3rd (after the two airborne saves) so leaps/zones get a clean full-exit", function()
        -- v0.5.149: blink bumped ahead of the invis tier + BKB (was 8th). SaveCounters still
        -- filters it out for charges (re-homes) + physical_chase; leaps/lines/zones keep it.
        assert_eq(TD.CATEGORY_CHAINS.close_gap[1], "item_wind_waker")
        assert_eq(TD.CATEGORY_CHAINS.close_gap[2], "item_cyclone")
        assert_eq(TD.CATEGORY_CHAINS.close_gap[3], "item_blink")
    end)
end)

describe("lib/threat_data - ENEMY_BUFF_THREATS", function()
    it("contains expected entries", function()
        assert_true(TD.ENEMY_BUFF_THREATS["modifier_sven_gods_strength"] ~= nil)
        assert_true(TD.ENEMY_BUFF_THREATS["modifier_ursa_enrage"] ~= nil)
        assert_true(TD.ENEMY_BUFF_THREATS["modifier_troll_warlord_battle_trance"] ~= nil)
    end)
end)

local Target = require("lib.target")

describe("lib/target - pure predicates", function()
    it("NotClone is true for nil-safe", function() assert_false(Target.NotClone(nil)) end)
    -- More target.lua tests need richer NPC stubs (per-entity behavior) - defer.
end)

describe("lib/target - cannot-kill predicates (v0.5.152)", function()
    local e = { idx = 1 }

    it("HasUnkillableModifier: shallow grave + false promise; pruned _timer not matched", function()
        NPC.HasModifier = function(_, m) return m == "modifier_dazzle_shallow_grave" end
        assert_true(Target.HasUnkillableModifier(e))
        NPC.HasModifier = function(_, m) return m == "modifier_oracle_false_promise" end
        assert_true(Target.HasUnkillableModifier(e))
        NPC.HasModifier = function(_, m) return m == "modifier_oracle_false_promise_timer" end
        assert_false(Target.HasUnkillableModifier(e))  -- pruned: bare modifier confirmed to land (modseen 2026-06-17)
        NPC.HasModifier = function() return false end
        assert_false(Target.HasUnkillableModifier(e))
    end)

    it("WillReincarnate: WK + Reincarnation leveled + off CD; false otherwise", function()
        local s_name, s_ab, s_lvl, s_rdy = NPC.GetUnitName, NPC.GetAbility, Ability.GetLevel, Ability.IsReady
        NPC.GetUnitName  = function() return "npc_dota_hero_skeleton_king" end
        NPC.GetAbility   = function() return { reinc = true } end
        Ability.GetLevel = function() return 1 end
        Ability.IsReady  = function() return true end
        assert_true(Target.WillReincarnate(e))
        Ability.IsReady  = function() return false end                  -- on CD -> false
        assert_false(Target.WillReincarnate(e))
        Ability.IsReady  = function() return true end
        Ability.GetLevel = function() return 0 end                      -- unleveled -> false
        assert_false(Target.WillReincarnate(e))
        Ability.GetLevel = function() return 1 end
        NPC.GetUnitName  = function() return "npc_dota_hero_sniper" end  -- not WK -> false
        assert_false(Target.WillReincarnate(e))
        NPC.GetUnitName, NPC.GetAbility, Ability.GetLevel, Ability.IsReady = s_name, s_ab, s_lvl, s_rdy
    end)

    it("IsUnkillableNow: true if modifier OR reincarnation, else false", function()
        NPC.HasModifier = function(_, m) return m == "modifier_dazzle_shallow_grave" end
        assert_true(Target.IsUnkillableNow(e))
        NPC.HasModifier = function() return false end
        assert_false(Target.IsUnkillableNow(e))   -- no mod + GetUnitName unstubbed (not WK)
    end)
end)

local Timing = require("lib.timing")

describe("lib/timing - EscapeReadiness", function()
    it("returns 0 for entity without items", function()
        local r = Timing.EscapeReadiness({ idx = 1 }, 2.0)
        assert_eq(r, 0)
    end)
end)

local Farm = require("lib.farm")
local Map  = require("lib.map")
local Lane = require("lib.lane")
local Route = require("lib.route")
local Nav = require("lib.nav")
local Schedule = require("lib.schedule")

describe("lib/farm , pure geometry (v0.5.82)", function()
    local function u(x, y, hp) return { pos = { x = x, y = y, z = 0 }, hp = hp or 100 } end
    local origin = { x = 0, y = 0, z = 0 }

    it("WorthCasting respects min_count", function()
        assert_true(Farm.WorthCasting(3, 3))
        assert_false(Farm.WorthCasting(2, 3))
        assert_true(Farm.WorthCasting(1))
        assert_false(Farm.WorthCasting(0, 1))
    end)

    it("CountInLine counts units inside the line band", function()
        local units = { u(100, 0), u(500, 50), u(500, 300), u(-100, 0), u(1200, 0) }
        local n = Farm.CountInLine(origin, { x = 1, y = 0, z = 0 }, 1000, 100, units)
        assert_eq(n, 2, "expected 2 in-line")
    end)

    it("BestLineAim picks the densest direction", function()
        local units = { u(200, 0), u(400, 0), u(600, 0), u(0, 400) }
        local aim, hit = Farm.BestLineAim(origin, units, 1075, 110)
        assert_eq(hit, 3, "expected 3 hits on the +x line")
        assert_true(aim ~= nil and aim.x > aim.y, "aim should point +x")
    end)

    it("BestLineAim tie-break prefers the closer pack (v0.5.81)", function()
        local near = u(300, 0, 100)
        local far  = u(0, 900, 100)
        local aim, hit = Farm.BestLineAim(origin, { far, near }, 1075, 110)
        assert_eq(hit, 1)
        assert_true(aim.x > aim.y, "tie-break should favor the nearer (+x) unit")
    end)

    it("BestPointAim finds the densest cluster center", function()
        local units = { u(0, 0), u(50, 0), u(60, 30), u(1000, 1000) }
        local center, hit = Farm.BestPointAim(units, 250)
        assert_eq(hit, 3, "cluster of 3 within 250")
        assert_true(center ~= nil)
    end)

    it("empty / degenerate inputs are safe", function()
        local aim, h1 = Farm.BestLineAim(origin, {}, 1000, 100)
        assert_true(aim == nil and h1 == 0)
        local c, h2 = Farm.BestPointAim({}, 250)
        assert_true(c == nil and h2 == 0)
    end)
end)

describe("lib/farm -- BestLineAim hero-clip bonus (v0.5.111)", function()
    local function u(x, y, hp) return { pos = { x = x, y = y, z = 0 }, hp = hp or 100 } end
    local origin = { x = 0, y = 0, z = 0 }
    -- Layout A: +x lane = 3 creeps with a hero behind them; +y lane = 5 creeps.
    local CREEPS_A = { u(200, 0), u(400, 0), u(600, 0),
                       u(0, 150), u(0, 300), u(0, 450), u(0, 600), u(0, 750) }
    local HERO_A   = { u(900, 0) }

    it("back-compat: no opts -> raw densest line (+y, 5 creeps)", function()
        local aim, hit = Farm.BestLineAim(origin, CREEPS_A, 1075, 110)
        assert_eq(hit, 5)
        assert_true(aim.y > aim.x, "no-opts pick must ignore the hero")
    end)
    it("weighted: hero-clip line wins when both qualify", function()
        local aim, hit, _, bn = Farm.BestLineAim(origin, CREEPS_A, 1075, 110,
            { bonus_units = HERO_A, bonus_weight = 3, min_hits = 3 })
        assert_eq(hit, 3, "primary hit count stays creeps-only")
        assert_eq(bn, 1, "bonus hits returned 4th")
        assert_true(aim.x > aim.y, "hero-clip (+x) line must win: 3 + 3 > 5")
    end)
    it("equal creeps: hero-clip beats the closer-pack tie-break", function()
        -- two 2-creep lanes; the +y pack is nearer (the v0.5.81 tie-break
        -- alone would pick +y); the hero behind +x must flip the pick.
        local creeps = { u(300, 0), u(500, 0), u(0, 150), u(0, 350) }
        local aim, hit, _, bn = Farm.BestLineAim(origin, creeps, 1075, 110,
            { bonus_units = HERO_A, bonus_weight = 3 })
        assert_eq(hit, 2)
        assert_eq(bn, 1)
        assert_true(aim.x > aim.y, "hero bonus must beat the closer-pack tie-break")
    end)
    it("min_hits protection: under-threshold hero line loses to a qualifying line", function()
        -- +x = 2 creeps + 2 heroes (score 8 but NOT qualified at min 3);
        -- +y = 5 creeps (score 5, qualified) -> +y wins.
        local creeps = { u(200, 0), u(400, 0),
                         u(0, 150), u(0, 300), u(0, 450), u(0, 600), u(0, 750) }
        local heroes = { u(700, 0), u(900, 0) }
        local aim, hit = Farm.BestLineAim(origin, creeps, 1075, 110,
            { bonus_units = heroes, bonus_weight = 3, min_hits = 3 })
        assert_eq(hit, 5)
        assert_true(aim.y > aim.x, "qualified pool must beat unqualified score")
    end)
    it("no qualified line -> best raw fallback (caller gate then rejects)", function()
        local creeps = { u(300, 0), u(500, 0) }
        local aim, hit = Farm.BestLineAim(origin, creeps, 1075, 110,
            { bonus_units = HERO_A, bonus_weight = 3, min_hits = 3 })
        assert_true(aim ~= nil)
        assert_eq(hit, 2, "falls back to the raw best so WorthCasting can reject")
    end)
    it("pure-bonus bearing rejected: a line must hit at least one creep", function()
        local creeps = { u(0, 200), u(0, 400) }
        local hero_far = { u(800, -300) }  -- bearing toward it clips zero creeps
        local aim, hit, _, bn = Farm.BestLineAim(origin, creeps, 1075, 110,
            { bonus_units = hero_far, bonus_weight = 99 })
        assert_eq(hit, 2)
        assert_eq(bn, 0)
        assert_true(aim.y > aim.x, "creep line wins; hero-only bearing is not wave-clear")
    end)
end)

describe("lib/farm -- PairStandCandidates (Tinker two-camp stand search, task A)", function()
    -- Deterministic opts so counts/order don't depend on lib defaults. rmax = 280.
    local OPTS = { cast_range = 300, range_pad = 20, halfwidth = 450,
                   march_len = 1800, backs = { 250, 180, 130 },
                   lats = { 0, 110, -110, 220, -220 } }
    local function V(x, y, z) return { x = x, y = y, z = z or 0 } end
    local function distxy(a, b) local dx, dy = a.x - b.x, a.y - b.y; return math.sqrt(dx * dx + dy * dy) end

    it("primary candidate is the zero-tilt on-axis midpoint stand", function()
        local cs = Farm.PairStandCandidates(V(0, 0, 0), V(1000, 0, 0), OPTS)
        assert_true(#cs > 0, "expected candidates")
        local c = cs[1]
        assert_true(math.abs(c.aim.x - 500) < 1e-6 and math.abs(c.aim.y) < 1e-6, "cast at the midpoint")
        assert_true(math.abs(c.stand.x - 250) < 1e-6 and math.abs(c.stand.y) < 1e-6, "stand STAND_RING back on the axis")
        assert_true(math.abs(c.lat) < 1e-6, "primary lat=0 (no tilt)")
    end)

    it("every candidate is within March cast range of its cast point", function()
        local cs = Farm.PairStandCandidates(V(0, 0, 0), V(1000, 0, 0), OPTS)
        for _, c in ipairs(cs) do
            assert_true(distxy(c.stand, c.aim) <= 280 + 1e-6,
                "stand within rmax of cast, got " .. distxy(c.stand, c.aim))
        end
    end)

    it("lateral offsets fall on BOTH perpendicular sides", function()
        local cs = Farm.PairStandCandidates(V(0, 0, 0), V(1000, 0, 0), OPTS)
        local pos, neg = false, false
        for _, c in ipairs(cs) do
            if c.lat > 1 then pos = true elseif c.lat < -1 then neg = true end
        end
        assert_true(pos and neg, "candidates on both sides of the A->B axis")
    end)

    it("a tight pair drops the high-tilt candidates that lose far-camp coverage", function()
        local loose = Farm.PairStandCandidates(V(0, 0, 0), V(1000, 0, 0), OPTS)   -- d=1000
        local tight = Farm.PairStandCandidates(V(0, 0, 0), V(1780, 0, 0), OPTS)   -- d=1780
        assert_eq(#loose, 15, "loose pair: the full back x lat grid keeps coverage")
        assert_eq(#tight, 7, "tight pair: only the low-tilt candidates keep both camps covered")
        for _, c in ipairs(tight) do
            assert_true(c.tilt <= 450 + 1e-6, "every kept candidate holds the far camp within half-width")
        end
    end)

    it("diagonal pair: a lateral candidate uses the true perpendicular", function()
        local cs = Farm.PairStandCandidates(V(0, 0, 0), V(1000, 1000, 0),
            { cast_range = 300, range_pad = 20, halfwidth = 450, march_len = 1600,
              backs = { 250 }, lats = { 0, 100 } })
        local c = cs[2]   -- back=250 lat=100 on the 45-degree axis
        assert_true(math.abs(c.stand.x - 252.513) < 0.1, "stand.x off the perpendicular, got " .. tostring(c.stand.x))
        assert_true(math.abs(c.stand.y - 393.934) < 0.1, "stand.y off the perpendicular, got " .. tostring(c.stand.y))
    end)

    it("pair too far to cover longitudinally -> no candidates", function()
        local cs = Farm.PairStandCandidates(V(0, 0, 0), V(2000, 0, 0), OPTS)   -- d/2=1000 > half=900
        assert_eq(#cs, 0, "infeasible pair returns empty")
    end)

    it("degenerate (coincident camps) -> no candidates, no crash", function()
        local cs = Farm.PairStandCandidates(V(100, 100, 0), V(100, 100, 0), OPTS)
        assert_eq(#cs, 0)
    end)

    it("respects an along-axis pair_offset (cast shifts toward the far camp)", function()
        local cs = Farm.PairStandCandidates(V(0, 0, 0), V(1000, 0, 0),
            { cast_range = 300, range_pad = 20, halfwidth = 450, march_len = 1800,
              backs = { 250 }, lats = { 0 }, pair_offset = 150 })
        assert_eq(#cs, 1)
        assert_true(math.abs(cs[1].aim.x - 650) < 1e-6, "cast = midpoint + offset along the axis")
        assert_true(math.abs(cs[1].stand.x - 400) < 1e-6, "stand = cast - STAND_RING along the axis")
    end)

    it("offset feasibility boundary: a nonzero pair_offset shrinks the coverable distance", function()
        -- far_long = d/2 + |off|; feasible iff far_long <= march_len/2 (=900). The hero's
        -- partner-accept gate must track THIS (off=0 -> <=1800; off=150 -> <=1500), else it
        -- accepts partners the lib always rejects (silent never-pairs). (COR-A3 guard)
        local function n(d) return #Farm.PairStandCandidates(V(0, 0, 0), V(d, 0, 0),
            { cast_range = 300, range_pad = 20, halfwidth = 450, march_len = 1800,
              backs = { 250 }, lats = { 0 }, pair_offset = 150 }) end
        assert_true(n(1500) >= 1, "d=1500 off=150 is coverable (far_long=900=half)")
        assert_eq(n(1650), 0, "d=1650 off=150 exceeds coverage (far_long=975>900)")
    end)
end)

describe("lib/farm -- PairClearClass (Tinker tight-pair 'best distance' model, task B)", function()
    -- disc model: camp = creep disc radius `disc` at d/2 from the cast. half=march_len/2.
    -- clean: d/2+disc <= half (one March clears both). clip: d/2-disc <= half (outer creeps
    -- clip, finish with extra marches + aggro-pull). none: even the nearest creep is outside.
    local OPTS = { march_len = 1800, disc = 200 }   -- half=900 -> clean<=1400, clip<=2200

    it("clean when both full discs fit (d <= 2*(half-disc))", function()
        assert_eq(Farm.PairClearClass(1000, OPTS).class, "clean")
        assert_eq(Farm.PairClearClass(1400, OPTS).class, "clean")   -- boundary: full_margin=0
    end)

    it("clip when the centre is reachable but outer creeps spill out", function()
        assert_eq(Farm.PairClearClass(1500, OPTS).class, "clip")
        assert_eq(Farm.PairClearClass(1800, OPTS).class, "clip")
        assert_eq(Farm.PairClearClass(2200, OPTS).class, "clip")   -- boundary: clip_margin=0
    end)

    it("none when even the nearest creep is outside coverage (d > 2*(half+disc))", function()
        assert_eq(Farm.PairClearClass(2300, OPTS).class, "none")
    end)

    it("returns the full + clip margins (calibration readout)", function()
        local r = Farm.PairClearClass(1500, OPTS)
        assert_true(math.abs(r.full_margin - (-50)) < 1e-6, "full_margin = half-(d/2+disc) = -50")
        assert_true(math.abs(r.clip_margin - 350) < 1e-6, "clip_margin = half-(d/2-disc) = 350")
    end)

    it("a bigger real footprint (march_len) promotes tight pairs from clip to clean", function()
        -- the user's manual d=1854 clear implies the real MARCH_LEN ~1900-2000, not 1800.
        assert_eq(Farm.PairClearClass(1780, { march_len = 1800, disc = 200 }).class, "clip")
        assert_eq(Farm.PairClearClass(1780, { march_len = 2400, disc = 200 }).class, "clean") -- half=1200 -> clean<=2000
    end)

    it("degenerate / nil distance -> none, no crash", function()
        assert_eq(Farm.PairClearClass(0, OPTS).class, "none")
        assert_eq(Farm.PairClearClass(nil, OPTS).class, "none")
    end)
end)

describe("lib/farm -- GreedyPairs (merged-pair matching, #2/#3)", function()
    it("pairs each camp with its nearest free neighbor; lone camp stays single", function()
        local pts = { {x=0,y=0}, {x=300,y=0}, {x=1000,y=0}, {x=1300,y=0}, {x=5000,y=0} }
        local g = Farm.GreedyPairs(pts, 500)
        assert_eq(#g, 3)
        assert_eq(g[1].a, 1); assert_eq(g[1].b, 2)      -- 1<->2 (d=300)
        assert_eq(g[2].a, 3); assert_eq(g[2].b, 4)      -- 3<->4 (d=300)
        assert_eq(g[3].a, 5); assert_eq(g[3].b, nil)    -- 5 too far -> single
    end)
    it("never double-assigns a camp", function()
        local pts = { {x=0,y=0}, {x=300,y=0}, {x=350,y=0} }   -- 1-2 d=300, 2-3 d=50(<min), 1-3 d=350
        local g = Farm.GreedyPairs(pts, 500)
        assert_eq(#g, 2)
        assert_eq(g[1].a, 1); assert_eq(g[1].b, 2)       -- 1 takes its nearest (2)
        assert_eq(g[2].a, 3); assert_eq(g[2].b, nil)     -- 3's only free neighbor is gone -> single
    end)
    it("min_sep drops coincident/too-close pairs", function()
        local g = Farm.GreedyPairs({ {x=0,y=0}, {x=100,y=0} }, 500, 200)
        assert_eq(#g, 2); assert_eq(g[1].b, nil); assert_eq(g[2].b, nil)  -- d=100 < 200 -> two singles
    end)
    it("mutual-nearest: a camp pairs with its TRUE nearest, not whoever grabs it first (anti-orphan)", function()
        -- A(0) B(1000) C(1300): B's nearest is C (300), not A (1000). The old greedy paired A-B (A first)
        -- and orphaned C; mutual-nearest pairs B-C and leaves A single -> stable + symmetric.
        local g = Farm.GreedyPairs({ {x=0,y=0}, {x=1000,y=0}, {x=1300,y=0} }, 1500)
        assert_eq(#g, 2)
        local pair, single
        for _, grp in ipairs(g) do if grp.b then pair = grp else single = grp end end
        assert_eq(pair.a, 2); assert_eq(pair.b, 3)   -- B-C are mutual nearest
        assert_eq(single.a, 1)                        -- A's nearest (B) is taken -> A single
    end)
    it("allow predicate force-pairs a specific over-range pair, else single", function()
        local pts = { {x=0,y=0}, {x=1854,y=0} }                        -- d=1854 > pair_max 1800
        assert_eq(#Farm.GreedyPairs(pts, 1800), 2)                     -- no allow -> two singles
        local g = Farm.GreedyPairs(pts, 1800, 200, function() return true end)
        assert_eq(#g, 1); assert_eq(g[1].a, 1); assert_eq(g[1].b, 2); assert_eq(g[1].d, 1854)  -- whitelisted -> pair
    end)
end)

describe("lib/farm -- WaveAimCenter (ranged-creep coverage)", function()
    it("aims at the along-lane span center, not the melee-weighted centroid", function()
        -- 3 melee near x=400 + 1 ranged trailing at x=0, axis (1,0). mean x = 300;
        -- proj rel mean = {100,120,80,-300}; (lo+hi)/2 = (-300+120)/2 = -90; center.x = 210.
        -- (the count centroid is x=300, melee-biased; the span center 210 covers the ranged.)
        local pts = { {x=400,y=0}, {x=420,y=10}, {x=380,y=-10}, {x=0,y=0} }
        local c = Farm.WaveAimCenter(pts, 1, 0)
        assert_true(math.abs(c.x - 210) < 1, "span center x ~210, got " .. tostring(c.x))
        assert_true(math.abs(c.y - 0) < 1, "lateral stays mean ~0, got " .. tostring(c.y))
    end)
    it("empty -> nil", function()
        assert_true(Farm.WaveAimCenter({}, 1, 0) == nil, "empty -> nil")
    end)
end)

describe("lib/farm -- DeepFarmFactor (F3 missing-enemy gate)", function()
    it("missing <= safe -> relax", function()
        assert_eq(Farm.DeepFarmFactor(0, 1, 0.8), 0.8)
        assert_eq(Farm.DeepFarmFactor(1, 1, 0.8), 0.8)
    end)
    it("missing > safe -> 1.0 (full veto)", function()
        assert_eq(Farm.DeepFarmFactor(2, 1, 0.8), 1.0)
    end)
    it("defaults (safe=1, relax=0.4) when omitted", function()
        assert_eq(Farm.DeepFarmFactor(1), 0.4); assert_eq(Farm.DeepFarmFactor(2), 1.0)
    end)
end)

describe("lib/farm -- DepthLineRisk (review #2 tower-line depth risk)", function()
    it("0 on our side of mid (depth <= 0)", function()
        assert_eq(Farm.DepthLineRisk(-500, 2000, 0.5, 0.5), 0)
        assert_eq(Farm.DepthLineRisk(0, 2000, 0.5, 0.5), 0)
    end)
    it("ramps linearly to at_line at the enemy T1 line", function()
        assert_true(math.abs(Farm.DepthLineRisk(1000, 2000, 0.5, 0.5) - 0.25) < 1e-9, "half-way = at_line/2")
        assert_true(math.abs(Farm.DepthLineRisk(2000, 2000, 0.5, 0.5) - 0.5) < 1e-9, "at the line = at_line")
    end)
    it("escalates past the line, capped at 1", function()
        assert_true(math.abs(Farm.DepthLineRisk(3000, 2000, 0.5, 0.5) - 0.75) < 1e-9, "one line past = at_line + past_rate")
        assert_eq(Farm.DepthLineRisk(9000, 2000, 0.5, 0.5), 1, "far past the line caps at 1")
    end)
    it("no line_depth -> 0 (no anchor)", function()
        assert_eq(Farm.DepthLineRisk(1000, 0, 0.5, 0.5), 0)
    end)
end)

describe("lib/farm -- PathRisk (route-risk sampler for laning)", function()
    -- risk_at: a hot zone around x=1000 (danger corridor) that safe endpoints miss.
    local function risk_at(p) return (math.abs(p.x - 1000) < 250) and 0.9 or 0.0 end
    it("catches danger mid-route that both endpoints miss", function()
        local mx = Farm.PathRisk({ x = 0, y = 0 }, { x = 2000, y = 0 }, risk_at, { step = 100 })
        assert_true(math.abs(mx - 0.9) < 1e-9, "the hot corridor is sampled")
    end)
    it("endpoint-only check would have read safe", function()
        assert_eq(risk_at({ x = 0, y = 0 }), 0); assert_eq(risk_at({ x = 2000, y = 0 }), 0)
    end)
    it("all-safe route -> 0; zero-length -> endpoint risk", function()
        assert_eq((Farm.PathRisk({ x = 0, y = 0 }, { x = 100, y = 0 }, function() return 0 end)), 0)
        assert_true(math.abs(Farm.PathRisk({ x = 1000, y = 0 }, { x = 1000, y = 0 }, risk_at) - 0.9) < 1e-9, "degenerate segment samples the point")
    end)
    it("worst_point is returned alongside the max", function()
        local _, wp = Farm.PathRisk({ x = 0, y = 0 }, { x = 2000, y = 0 }, risk_at, { step = 100 })
        assert_true(risk_at(wp) == 0.9, "worst point is inside the hot zone")
    end)
end)

describe("lib/nav -- SafeDest (lane movement clamp, Piece 0)", function()
    local function safe_x(pt) return pt.x <= 1000 end   -- safe on/left of x=1000 (a 'tower' to the right)
    it("already-safe dest passes through unclamped", function()
        local pt, cl = Nav.SafeDest({ x = 500, y = 0 }, { x = -1, y = 0 }, safe_x)
        assert_eq(pt.x, 500); assert_eq(pt.y, 0); assert_true(not cl, "not clamped")
    end)
    it("unsafe dest clamps back along retreat to the nearest safe step", function()
        local pt, cl = Nav.SafeDest({ x = 1450, y = 0 }, { x = -1, y = 0 }, safe_x)
        assert_true(cl, "clamped")
        assert_true(pt.x <= 1000, "on the safe side")
        assert_true(pt.x >= 950, "nearest safe step (1450-5*100=950), not over-retreated")
    end)
    it("never-safe returns the max-back point, clamped (degraded, caller reports)", function()
        local pt, cl = Nav.SafeDest({ x = 0, y = 0 }, { x = 1, y = 0 },
                                     function() return false end, { step = 100, max_steps = 5 })
        assert_true(cl, "clamped"); assert_eq(pt.x, 500)
    end)
end)

describe("lib/nav -- Ladder (transport eligibility, Piece 0)", function()
    it("far + keen ready -> keen first, walk last", function()
        local r = Nav.Ladder(3000, { keen_ready = true, keen_min_gain = 800 })
        assert_eq(r[1], "keen"); assert_eq(r[#r], "walk")
    end)
    it("far + keen on cd -> rearm rung replaces keen (a safe Rearm resets Keen)", function()
        local r = Nav.Ladder(3000, { keen_ready = false, keen_min_gain = 800 })
        assert_eq(r[1], "rearm")
    end)
    it("already keened this spot -> no keen/rearm rung", function()
        local r = Nav.Ladder(3000, { keened = true, keen_ready = true, keen_min_gain = 800 })
        assert_true(r[1] ~= "keen" and r[1] ~= "rearm", "keen family suppressed")
    end)
    it("short leg -> walking beats spending the keen", function()
        local r = Nav.Ladder(500, { keen_ready = true, keen_min_gain = 800 })
        assert_eq(r[1], "walk")
    end)
    it("blink eligible only inside its band", function()
        local ctx = { keened = true, blink_ready = true, blink_min = 800, blink_max = 1160 }
        assert_eq(Nav.Ladder(1000, ctx)[1], "blink")
        assert_eq(Nav.Ladder(500,  ctx)[1], "walk")
        assert_eq(Nav.Ladder(2000, ctx)[1], "walk")
    end)
    it("empty ctx -> just walk", function()
        local r = Nav.Ladder(0, {})
        assert_eq(#r, 1); assert_eq(r[1], "walk")
    end)
end)

describe("lib/nav -- Stuck (progress supervision)", function()
    it("improving legs never read stuck and rebaseline", function()
        local tr, st = Nav.Stuck(nil, 2000, 10)
        assert_true(not st)
        tr, st = Nav.Stuck(tr, 1500, 12)                    -- real progress -> rebaseline
        assert_true(not st); assert_eq(tr.best_d, 1500)
        tr, st = Nav.Stuck(tr, 900, 20)                     -- still improving, even much later
        assert_true(not st)
    end)
    it("a frozen hero reads stuck after the window", function()
        local tr = select(1, Nav.Stuck(nil, 1000, 10))
        local st
        tr, st = Nav.Stuck(tr, 990, 12); assert_true(not st, "jitter under eps, inside window")
        tr, st = Nav.Stuck(tr, 995, 13.1); assert_true(st, "no eps-progress for >= 3s")
    end)
    it("moving AWAY reads stuck too (regression is not progress)", function()
        local tr = select(1, Nav.Stuck(nil, 1000, 0))
        local st
        tr, st = Nav.Stuck(tr, 1400, 3.5)
        assert_true(st)
    end)
end)

describe("lib/nav -- TreeHideSpot (tree-blink landing)", function()
    local function grid(cx, cy, n)                          -- n trees clustered ~60u apart around (cx,cy)
        local t = {}
        for i = 1, n do t[#t + 1] = { x = cx + (i % 3) * 60, y = cy + math.floor(i / 3) * 60 } end
        return t
    end
    local hero, wave = { x = 0, y = 0 }, { x = 1200, y = 0 }
    it("picks the densest qualifying cluster", function()
        local trees = {}
        for _, p in ipairs(grid(-700, 0, 6)) do trees[#trees + 1] = p end    -- dense, safe side
        for _, p in ipairs(grid(500, -700, 3)) do trees[#trees + 1] = p end  -- sparse
        local s = Nav.TreeHideSpot(trees, hero, wave, { blink_max = 950, min_trees = 4 })
        assert_true(s ~= nil and s.x < -500, "the dense far-side cluster wins")
    end)
    it("rejects clusters out of blink range or too close to the threat", function()
        local far   = grid(-2000, 0, 6)                      -- dense but unreachable
        local close = grid(900, 0, 6)                        -- dense but on top of the wave
        assert_true(Nav.TreeHideSpot(far, hero, wave, { blink_max = 950, min_trees = 4 }) == nil)
        assert_true(Nav.TreeHideSpot(close, hero, wave, { blink_max = 950, min_trees = 4, threat_min = 800 }) == nil)
    end)
    it("nil on no trees / thin cover", function()
        assert_true(Nav.TreeHideSpot({}, hero, wave, {}) == nil)
        assert_true(Nav.TreeHideSpot(grid(-500, 0, 2), hero, wave, { min_trees = 4 }) == nil)
    end)
end)

describe("lib/farm -- StructuralRisk (Note 3 position-based risk)", function()
    local of = { x = -7456, y = -6938 }   -- radiant fountain
    local ef = { x = 7408, y = 6848 }     -- dire fountain
    local opts = { our_fountain = of, enemy_fountain = ef, half_weight = 0.6,       -- matches K.RISK_HALF_WEIGHT
                   zones = { { x = -4797, y = -104, radius = 700, bump = 0.08 },   -- radiant ancient (contested)
                             { x = 4099, y = 63, radius = 700, bump = 0.08 } } }   -- dire ancient (contested)

    it("rises toward the enemy fountain", function()
        local near = Farm.StructuralRisk({ x = -6000, y = -5500 }, opts)   -- deep radiant
        local far  = Farm.StructuralRisk({ x = 5000, y = 4500 }, opts)     -- deep dire
        assert_true(far > near, "enemy-half camp is riskier")
    end)

    it("a contested mid ancient outranks a same-axis safelane camp via the explicit bump", function()
        local safelane = Farm.StructuralRisk({ x = -1512, y = -3458 }, opts)   -- radiant safelane large
        local ancient  = Farm.StructuralRisk({ x = -4797, y = -104 }, opts)    -- radiant ancient (tagged)
        assert_true(ancient > safelane, "the tagged contested ancient is riskier than the safe safelane camp")
    end)

    it("the dire ancient exceeds the hard-risk veto (0.45)", function()
        assert_true(Farm.StructuralRisk({ x = 4099, y = 63 }, opts) >= 0.45, "deep + tagged -> vetoed")
    end)

    it("clamps to [0,1] and is 0 with no fountains", function()
        assert_eq(Farm.StructuralRisk({ x = 0, y = 0 }, {}), 0)
        assert_true(Farm.StructuralRisk(ef, opts) <= 1)
    end)
end)

describe("lib/lane -- aggregate helpers", function()
    local function c(x, y, hp, gold) return { pos = { x = x, y = y }, hp = hp or 100, gold = gold or 40 } end

    it("_centroid averages member positions; nil on empty", function()
        local m = { c(0, 0), c(100, 0), c(0, 300) }
        local ce = Lane._centroid(m)
        assert_true(math.abs(ce.x - 100/3) < 1e-6 and math.abs(ce.y - 100) < 1e-6, "centroid")
        assert_true(Lane._centroid({}) == nil, "empty -> nil")
    end)

    it("_hp / _gold sum members (missing -> 0)", function()
        local m = { c(0,0,100,40), c(0,0,250,55), { pos = {x=0,y=0} } }
        assert_eq(Lane._hp(m), 350)
        assert_eq(Lane._gold(m), 95)
    end)

    it("_strength defaults to summed hp; strength_fn overrides", function()
        local m = { c(0,0,100), c(0,0,200) }
        assert_eq(Lane._strength(m), 300)
        assert_eq(Lane._strength(m, { strength_fn = function(g) return #g end }), 2)
    end)

    it("_front picks the member furthest along push_dir", function()
        local m = { c(0,0), c(500,500), c(1000,1000) }
        local f = Lane._front(m, { x = 1, y = 1 })   -- toward +x+y
        assert_true(math.abs(f.x - 1000) < 1e-6 and math.abs(f.y - 1000) < 1e-6, "furthest +xy")
        local f2 = Lane._front(m, { x = -1, y = -1 })
        assert_true(math.abs(f2.x) < 1e-6 and math.abs(f2.y) < 1e-6, "furthest -xy")
    end)
end)

describe("lib/lane -- _cluster (single-link proximity)", function()
    local function c(x, y) return { pos = { x = x, y = y }, hp = 100, gold = 40 } end

    it("groups near creeps, separates far ones", function()
        local creeps = { c(0,0), c(100,0), c(200,0),    -- chain within 600
                         c(3000,0), c(3100,0) }          -- a second pack
        local cl = Lane._cluster(creeps, 600)
        assert_eq(#cl, 2, "two clusters")
        local sizes = { #cl[1], #cl[2] }
        table.sort(sizes)
        assert_eq(sizes[1], 2); assert_eq(sizes[2], 3)
    end)

    it("single-link is transitive (a chain is one cluster)", function()
        local creeps = { c(0,0), c(500,0), c(1000,0), c(1500,0) }   -- each 500 from the next
        assert_eq(#Lane._cluster(creeps, 600), 1)
    end)

    it("empty input -> no clusters", function()
        assert_eq(#Lane._cluster({}, 600), 0)
    end)
end)

describe("lib/lane -- _assign_lane (mid-diagonal band)", function()
    it("classifies by x-y vs the mid band", function()
        local o = { mid_band = 2500 }
        assert_eq(Lane._assign_lane({ x = 5000, y = 0 }, o), "bot")   -- x-y = 5000 > band
        assert_eq(Lane._assign_lane({ x = 0, y = 5000 }, o), "top")   -- x-y = -5000 < -band
        assert_eq(Lane._assign_lane({ x = 1000, y = 1000 }, o), "mid")-- on the diagonal
        assert_eq(Lane._assign_lane({ x = 0, y = 0 }, o), "mid")
    end)

    it("default band when opts omitted", function()
        assert_eq(Lane._assign_lane({ x = 6000, y = 0 }), "bot")
    end)
end)

describe("lib/lane -- DetectWaves", function()
    local function c(x, y, team, hp, gold) return { pos = {x=x,y=y}, team = team or 3, hp = hp or 100, gold = gold or 40 } end

    it("one bot-lane wave with full granularity", function()
        local creeps = { c(5000,0,3,100,40), c(5100,0,3,200,55), c(5200,0,3,300,38) }
        local waves = Lane.DetectWaves(creeps, { x = -1, y = -1 }, { cluster_radius = 600, mid_band = 2500 })
        assert_eq(#waves, 1)
        local w = waves[1]
        assert_eq(w.lane, "bot"); assert_eq(w.team, 3)
        assert_eq(w.count, 3); assert_eq(w.hp, 600); assert_eq(w.gold, 133)
        assert_eq(w.strength, 600)               -- default = summed hp
        assert_eq(#w.creeps, 3)                  -- members retained (each creep's life/gold)
        assert_true(math.abs(w.front.x - 5000) < 1e-6, "front = furthest toward -x-y (the enemy base)")
    end)

    it("splits two packs in different lanes", function()
        local creeps = { c(5000,0,3), c(5100,0,3),      -- bot pack
                         c(0,5000,3), c(100,5000,3) }    -- top pack
        local waves = Lane.DetectWaves(creeps, { x = -1, y = -1 }, {})
        assert_eq(#waves, 2)
        local lanes = { waves[1].lane, waves[2].lane }
        table.sort(lanes)
        assert_eq(lanes[1], "bot"); assert_eq(lanes[2], "top")
    end)

    it("empty -> no waves", function()
        assert_eq(#Lane.DetectWaves({}, { x = 1, y = 1 }, {}), 0)
    end)
end)

describe("lib/lane -- PredictClash", function()
    local function wave(team, frontx, fronty, strength)
        return { team = team, front = { x = frontx, y = fronty }, strength = strength }
    end
    local OPTS = { drift_coeff = 0.5, horizon = 6, creep_speed = 300, move_threshold = 0.1, tower_weight = 4000 }

    it("even strengths -> not moving, settle == contact", function()
        local e = wave(3, 100, 0, 500)
        local a = wave(2, -100, 0, 500)
        local cl = Lane.PredictClash(e, a, {}, OPTS)
        assert_eq(cl.pushing, "even"); assert_false(cl.moving)
        assert_true(math.abs(cl.contact.x) < 1e-6, "contact at the midpoint x=0")
        assert_true(math.abs(cl.settle.x - cl.contact.x) < 1e-6, "settle == contact")
        assert_eq(cl.settle_eta, 0)
    end)

    it("stronger enemy pushes toward the ally front", function()
        local e = wave(3, 100, 0, 1000)   -- enemy at +x, ally at -x
        local a = wave(2, -100, 0, 200)
        local cl = Lane.PredictClash(e, a, {}, OPTS)
        assert_eq(cl.pushing, "enemy"); assert_true(cl.moving)
        assert_true(cl.drift_dir.x < 0, "drift toward the ally side (-x)")
        assert_true(cl.settle.x < cl.contact.x, "settle moved -x")
    end)

    it("a defending tower in the drift path clamps the settle to its line", function()
        -- enemy(2000) strongly out-pushes ally(100): drift toward -x. An ally tower at (-800,0),
        -- OUTSIDE the contact's tower range (so it adds no weight, only clamps), holds the line ->
        -- settle clamps to it. (A tower WITHIN range of the contact instead adds tower_weight to
        -- its side, which is the separate "a tower at the clash defends" effect.)
        local e = wave(3, 100, 0, 2000)
        local a = wave(2, -100, 0, 100)
        local towers = { { pos = { x = -800, y = 0 }, team = 2, range = 700, alive = true } }
        local cl = Lane.PredictClash(e, a, towers, OPTS)
        assert_eq(cl.pushing, "enemy")
        assert_true(cl.settle.x <= -799 and cl.settle.x >= -801, "clamped to the tower line ~-800, got " .. cl.settle.x)
    end)

    it("uncontested push (no ally wave) drifts fully toward the enemy base", function()
        local e = wave(3, 100, 0, 800)
        local cl = Lane.PredictClash(e, nil, {}, OPTS)
        assert_eq(cl.pushing, "enemy"); assert_true(cl.moving)
        assert_true(cl.contact.x == 100 and cl.contact.y == 0, "contact = the lone front")
    end)

    it("no waves -> nil", function()
        assert_true(Lane.PredictClash(nil, nil, {}, OPTS) == nil)
    end)

    it("flags crashing when the wave pushes into a defending tower", function()
        -- enemy(2000) out-pushes ally(100): drift toward -x; an ally tower at (-800,0) (outside the
        -- contact's range, so it adds no weight) sits in the drift path -> the wave crashes into it.
        local e = wave(3, 100, 0, 2000)
        local a = wave(2, -100, 0, 100)
        local towers = { { pos = { x = -800, y = 0 }, team = 2, range = 700, alive = true } }
        local cl = Lane.PredictClash(e, a, towers, OPTS)
        assert_true(cl.crashing, "crashing into the defending tower")
        assert_true(cl.crash_tower ~= nil and cl.crash_tower.team == 2, "crash tower is the ally (defending) tower")
    end)

    it("no crash when the settle does not reach a tower", function()
        local e = wave(3, 100, 0, 600)    -- mild push
        local a = wave(2, -100, 0, 400)
        local towers = { { pos = { x = -3000, y = 0 }, team = 2, range = 700, alive = true } }
        local cl = Lane.PredictClash(e, a, towers, OPTS)
        assert_false(cl.crashing, "settle short of the tower -> not crashing")
    end)
end)

describe("lib/lane -- InterceptETA + NearestTeleportAnchor", function()
    local tp = { channel = 3 }

    it("teleport beats walking when an anchor is near the target", function()
        local from = { x = 0, y = 0 }
        local target = { x = 6000, y = 0 }
        local anchors = { { pos = { x = 5800, y = 0 }, ready = true, kind = "building" } }
        local r = Lane.InterceptETA(from, anchors, 300, tp, target, 9999)
        -- walk = 6000/300 = 20s; tp = 3 + 200/300 = 3.67s
        assert_true(math.abs(r.eta - (3 + 200/300)) < 1e-6, "tp eta")
        assert_true(r.best_anchor ~= nil, "anchor chosen")
        assert_true(r.reachable, "reachable within window")
    end)

    it("plain walk wins when no anchor helps; reachable boundary respected", function()
        local from = { x = 0, y = 0 }
        local target = { x = 600, y = 0 }    -- walk = 2s
        local r = Lane.InterceptETA(from, {}, 300, tp, target, 1.5)
        assert_true(r.best_anchor == nil, "walk")
        assert_true(math.abs(r.eta - 2.0) < 1e-6)
        assert_false(r.reachable, "2.0 > 1.5 window")
    end)

    it("works from an arbitrary from_pos (next-lane reuse)", function()
        local r = Lane.InterceptETA({ x = 1000, y = 1000 }, {}, 300, tp, { x = 1000, y = 1300 }, nil)
        assert_true(math.abs(r.eta - 1.0) < 1e-6, "300/300 = 1s")
        assert_true(r.reachable, "nil window -> always reachable")
    end)

    it("NearestTeleportAnchor filters by allowed kind + ready", function()
        local anchors = {
            { pos = { x = 100, y = 0 }, ready = true, kind = "ally" },
            { pos = { x = 50, y = 0 }, ready = false, kind = "building" },
            { pos = { x = 300, y = 0 }, ready = true, kind = "building" },
        }
        local a = Lane.NearestTeleportAnchor({ x = 0, y = 0 }, anchors, { "building" })
        assert_true(a ~= nil and math.abs(a.pos.x - 300) < 1e-6, "nearest READY building (50 is not ready)")
    end)
end)

describe("lib/lane -- PredictMeeting (one expression, all three lanes)", function()
    it("mid: equal spawn distance + equal speed -> midpoint, eta = gap/650", function()
        local m = Lane.PredictMeeting({ pos = {x=-3000,y=-3000}, speed = 325 },
                                      { pos = {x= 3000,y= 3000}, speed = 325 })
        assert_true(math.abs(m.point.x) < 1e-9 and math.abs(m.point.y) < 1e-9, "meets at the midpoint (0,0)")
        local gap = math.sqrt((6000)^2 + (6000)^2)
        assert_true(math.abs(m.eta - gap/650) < 1e-6, "eta = gap / closing speed 650")
    end)
    it("side lane: +30%/-35% speed split -> meeting off-centre toward the faster side", function()
        -- one side boosted (422.5), the other slowed (211.25); 1000 apart on a straight axis.
        local m = Lane.PredictMeeting({ pos = {x=0,y=0}, speed = 422.5 },
                                      { pos = {x=1000,y=0}, speed = 211.25 })
        -- the boosted wave covers 422.5/633.75 = 2/3 of the gap before they meet.
        assert_true(math.abs(m.point.x - 2000/3) < 1e-6, "meeting at 2/3 toward the slow side")
        assert_true(math.abs(m.eta - 1000/633.75) < 1e-6, "eta = gap / 633.75")
    end)
    it("not closing (both speed 0) -> nil", function()
        assert_true(Lane.PredictMeeting({ pos={x=0,y=0}, speed=0 }, { pos={x=10,y=0}, speed=0 }) == nil)
    end)
end)

describe("lib/lane -- MeetingPoint", function()
    it("both fronts visible -> midpoint of the two fronts", function()
        local m = Lane.MeetingPoint({ front = {x=0,y=0} }, { front = {x=1000,y=1000} }, {x=500,y=500})
        assert_eq(m.x, 500); assert_eq(m.y, 500)
    end)
    it("fogged enemy (no front) -> midpoint of our front and the lane centre", function()
        local m = Lane.MeetingPoint({ front = {x=200,y=200} }, { estimated = true }, {x=0,y=0})
        assert_eq(m.x, 100); assert_eq(m.y, 100)
    end)
    it("neither front -> the lane centre", function()
        local m = Lane.MeetingPoint(nil, { estimated = true }, {x=7,y=9})
        assert_eq(m.x, 7); assert_eq(m.y, 9)
    end)
    it("BUG 3: closing pair (enemy front still ahead of ours) -> midpoint", function()
        local push = { x = 1, y = 0 }                            -- toward the enemy = +x
        local m = Lane.MeetingPoint({ front = {x=-500,y=0} }, { front = {x=500,y=0} }, {x=0,y=0}, push)
        assert_eq(m.x, 0); assert_eq(m.y, 0)                     -- they are closing -> midpoint
    end)
    it("BUG 3: passed pair (our front overran past the enemy front) -> lane centre, not the deep midpoint", function()
        local push = { x = 1, y = 0 }
        local m = Lane.MeetingPoint({ front = {x=1500,y=0} }, { front = {x=-200,y=0} }, {x=0,y=0}, push)
        assert_eq(m.x, 0); assert_eq(m.y, 0)                     -- not closing -> fall back to mid (not 650)
    end)
    it("BUG 3: push_dir nil keeps the old midpoint behavior (back-compat)", function()
        local m = Lane.MeetingPoint({ front = {x=1500,y=0} }, { front = {x=-200,y=0} }, {x=0,y=0})
        assert_eq(m.x, 650)                                      -- no closure check -> midpoint
    end)
end)

describe("lib/lane -- engaged (most-advanced) wave selection", function()
    local function c(x, y, team) return { pos = {x=x,y=y}, team = team, hp = 100, gold = 40 } end
    it("picks the most-advanced front, NOT the biggest cluster", function()
        -- us = team 2, ally_push toward (+,+). A bigger FRESH pack deep at our base (~-4000) and a
        -- smaller ENGAGED pack forward near mid (~0): the forward one must be chosen (fixes notes 1/2/3).
        local creeps = {
            c(-4000,-4000,2), c(-4100,-4000,2), c(-4000,-4100,2), c(-4100,-4100,2),  -- 4: fresh, deep own
            c(-100,-100,2), c(-200,-200,2),                                          -- 2: engaged, near mid
        }
        local mid = Lane.BuildLaneStates(creeps, {}, {},
            { team = 2, enemy_push = {x=-1,y=-1}, ally_push = {x=1,y=1} }).mid
        assert_true(mid.ally_wave ~= nil, "ally wave on mid")
        assert_eq(mid.ally_wave.count, 2, "the forward engaged pack wins over the bigger fresh pack")
    end)
end)

describe("lib/lane -- BuildLaneStates", function()
    local function c(x, y, team, hp, gold) return { pos = {x=x,y=y}, team = team, hp = hp or 100, gold = gold or 40 } end

    it("assembles per-lane state with enemy/ally waves, gold, hero counts", function()
        -- team 2 (us). Enemy(3) + ally(2) clash in bot lane near (5000,0).
        local creeps = {
            c(5000,0,3,100,40), c(5100,0,3,100,40), c(5200,0,3,100,40),   -- enemy bot wave
            c(4600,0,2,100,40), c(4700,0,2,100,40),                       -- ally bot wave
        }
        local towers = { { pos = {x=4000,y=0}, team = 2, range = 700, alive = true } }
        local heroes = { { pos = {x=4850,y=0}, team = 3 }, { pos = {x=4850,y=0}, team = 2 } }
        local opts = { team = 2, enemy_push = {x=-1,y=-1}, ally_push = {x=1,y=1},
                       cluster_radius = 600, mid_band = 2500, hero_radius = 1200 }
        local lanes = Lane.BuildLaneStates(creeps, towers, heroes, opts)
        local bot = lanes.bot
        assert_true(bot.enemy_wave ~= nil and bot.ally_wave ~= nil, "both waves on bot")
        assert_eq(bot.enemy_wave.count, 3); assert_eq(bot.ally_wave.count, 2)
        assert_eq(bot.gold, 120, "lane gold = enemy wave gold (3*40)")
        assert_eq(bot.enemy_heroes, 1); assert_eq(bot.ally_heroes, 1)
        assert_true(bot.clash ~= nil, "clash predicted")
        assert_true(lanes.top ~= nil and lanes.mid ~= nil, "all three lanes present")
    end)

    it("computes intercept when anchors + kinematics are supplied", function()
        local creeps = { c(5000,0,3), c(5100,0,3) }
        local opts = { team = 2, enemy_push = {x=-1,y=-1}, ally_push = {x=1,y=1},
                       anchors = { { pos = {x=4900,y=0}, ready = true, kind = "building" } },
                       allowed_kinds = { "building" }, hero_pos = {x=0,y=0}, move_speed = 300,
                       tp = { channel = 3 }, clear_window = 5 }
        local lanes = Lane.BuildLaneStates(creeps, {}, {}, opts)
        assert_true(lanes.bot.intercept ~= nil, "intercept computed")
        assert_true(lanes.bot.intercept.best_anchor ~= nil, "anchor used (near the clash)")
    end)

    it("empty creeps -> three empty lanes, no crash", function()
        local lanes = Lane.BuildLaneStates({}, {}, {}, { team = 2 })
        assert_true(lanes.top and lanes.mid and lanes.bot, "lanes present")
        assert_true(lanes.bot.enemy_wave == nil and lanes.bot.clash == nil, "empty bot")
    end)
end)

describe("lib/lane -- ExpectedWave (Liquipedia-validated wave model)", function()
    it("t=0: 3 melee + 1 ranged, cycle 0", function()
        local w = Lane.ExpectedWave(0, {})
        assert_eq(w.wave, 1); assert_eq(w.cycle, 0)
        assert_eq(w.melee, 3); assert_eq(w.ranged, 1); assert_eq(w.siege, 0); assert_eq(w.flagbearer, 0)
        assert_eq(w.count, 4); assert_eq(w.hp, 1950); assert_eq(w.gold, 169)   -- gold = sum GetGoldBountyMax (3*39 + 52)
    end)
    it("flagbearer wave (2:00, wave 5) replaces a melee + adds area gold", function()
        local w = Lane.ExpectedWave(120, {})
        assert_eq(w.flagbearer, 1); assert_eq(w.melee, 2); assert_eq(w.count, 4)
        -- Piece 1.5 fix: the flagbearer BOUNTY is already in the base sum; the area term adds ONLY
        -- the +10 area gold (the old 218 double-counted the bounty: base 39 + area(10+39)).
        assert_eq(w.gold, 179)   -- 2*39 + 52 + 39(flag) + 10(area)
    end)
    it("siege wave (5:00, wave 11) adds a siege creep (also a flagbearer wave)", function()
        local w = Lane.ExpectedWave(300, {})
        assert_eq(w.siege, 1); assert_eq(w.flagbearer, 1); assert_eq(w.melee, 2); assert_eq(w.count, 5)
    end)
    it("upgrade cycle scales hp + gold (7:30 = cycle 1, plain wave 16)", function()
        local w = Lane.ExpectedWave(450, {})
        assert_eq(w.cycle, 1); assert_eq(w.hp, 1998); assert_eq(w.gold, 175)   -- 3*(39+1) + (52+3)
    end)
    it("composition scales by time (16:30, wave 34 -> 4 melee, even wave = no flag/siege)", function()
        local w = Lane.ExpectedWave(990, {})
        assert_eq(w.wave, 34); assert_eq(w.melee, 4); assert_eq(w.ranged, 1)
        assert_eq(w.siege, 0); assert_eq(w.flagbearer, 0)
    end)
    it("super creeps swap stats, no flagbearer", function()
        local w = Lane.ExpectedWave(0, { super = true })
        assert_eq(w.flagbearer, 0); assert_eq(w.melee, 3); assert_eq(w.ranged, 1)
        assert_eq(w.hp, 2575); assert_eq(w.gold, 103)   -- super 3*26 + 25
    end)
    it("nil/negative time -> wave 1, no crash", function()
        local w = Lane.ExpectedWave(nil, {})
        assert_eq(w.wave, 1); assert_eq(w.melee, 3)
    end)
end)

describe("lib/lane -- BuildLaneStates fog-fill (ExpectedWave estimate)", function()
    local function c(x, y, team) return { pos = {x=x,y=y}, team = team, hp = 100, gold = 40 } end

    it("a fogged enemy lane gets an ExpectedWave estimate when game_time is given", function()
        local creeps = { c(4600,0,2), c(4700,0,2) }   -- only the ally bot wave is visible
        local opts = { team = 2, enemy_push = {x=-1,y=-1}, ally_push = {x=1,y=1}, game_time = 0 }
        local bot = Lane.BuildLaneStates(creeps, {}, {}, opts).bot
        assert_true(bot.enemy_wave ~= nil and bot.enemy_wave.estimated, "fogged enemy wave estimated")
        assert_eq(bot.enemy_wave.count, 4); assert_eq(bot.gold, 169)   -- GetGoldBountyMax basis
        assert_true(bot.enemy_wave.centroid == nil, "estimate has no position")
    end)
    it("no game_time -> fogged lane stays empty (no estimate)", function()
        local bot = Lane.BuildLaneStates({ c(4600,0,2) }, {}, {},
            { team = 2, enemy_push = {x=-1,y=-1}, ally_push = {x=1,y=1} }).bot
        assert_true(bot.enemy_wave == nil, "no estimate without game_time")
    end)
    it("a VISIBLE enemy wave is used as-is, not estimated", function()
        local creeps = { c(5000,0,3), c(5100,0,3) }   -- real enemy bot wave (team 3)
        local bot = Lane.BuildLaneStates(creeps, {}, {},
            { team = 2, enemy_push = {x=-1,y=-1}, ally_push = {x=1,y=1}, game_time = 0 }).bot
        assert_true(bot.enemy_wave ~= nil and not bot.enemy_wave.estimated, "real wave, not an estimate")
        assert_eq(bot.enemy_wave.count, 2)
    end)
end)

describe("lib/lane -- polyline utils (Piece 1.5)", function()
    local L = { { x = 0, y = 0 }, { x = 1000, y = 0 }, { x = 1000, y = 1000 } }   -- L-shape, len 2000
    it("PathLength sums the segments", function()
        assert_eq(Lane.PathLength(L), 2000)
    end)
    it("PointAtArc walks the polyline (and clamps both ends)", function()
        local p = Lane.PointAtArc(L, 500);  assert_eq(p.x, 500);  assert_eq(p.y, 0)
        p = Lane.PointAtArc(L, 1500);       assert_eq(p.x, 1000); assert_eq(p.y, 500)
        p = Lane.PointAtArc(L, -50);        assert_eq(p.x, 0);    assert_eq(p.y, 0)
        p = Lane.PointAtArc(L, 99999);      assert_eq(p.x, 1000); assert_eq(p.y, 1000)
    end)
    it("ArcOfPoint projects onto the nearest segment", function()
        assert_true(math.abs(Lane.ArcOfPoint(L, { x = 600, y = 50 }) - 600) < 1e-6, "off-lane point projects to arc 600")
        assert_true(math.abs(Lane.ArcOfPoint(L, { x = 1100, y = 500 }) - 1500) < 1e-6, "second segment, arc 1500")
    end)
    it("PathTangent = unit dir of the nearest segment (glue rebuild item 3)", function()
        local t = Lane.PathTangent(L, { x = 600, y = 50 })          -- nearest = first segment (+x)
        assert_eq(t.x, 1); assert_eq(t.y, 0)
        t = Lane.PathTangent(L, { x = 1100, y = 500 })              -- nearest = second segment (+y)
        assert_eq(t.x, 0); assert_eq(t.y, 1)
        assert_true(Lane.PathTangent({ { x = 0, y = 0 } }, { x = 1, y = 1 }) == nil, "degenerate path -> nil")
        assert_true(Lane.PathTangent(nil, { x = 1, y = 1 }) == nil, "nil path -> nil")
    end)
end)

describe("lib/lane -- BuildLanePaths (real map_data towers + spawns)", function()
    local MapData = require("lib.map_data")
    local paths = Lane.BuildLanePaths(MapData.TOWERS, MapData.SPAWNS)
    it("mid = 6 towers ordered good T3 -> bad T3 (no mid spawns captured)", function()
        assert_eq(#paths.mid, 6)
        assert_eq(paths.mid[1].x, -4640); assert_eq(paths.mid[1].y, -4144)
        assert_eq(paths.mid[6].x, 4272);  assert_eq(paths.mid[6].y, 3759)
    end)
    it("top = spawn + 6 towers + spawn, Radiant end first", function()
        assert_eq(#paths.top, 8)
        assert_eq(paths.top[1].x, -6608); assert_eq(paths.top[1].y, -4064)   -- Radiant top creep spawn
        assert_eq(paths.top[8].x, 3173);  assert_eq(paths.top[8].y, 5761)    -- Dire top creep spawn
    end)
    it("bot = spawn + 6 towers + spawn, Radiant end first", function()
        assert_eq(#paths.bot, 8)
        assert_eq(paths.bot[1].x, -3600); assert_eq(paths.bot[1].y, -6152)
        assert_eq(paths.bot[8].x, 6272);  assert_eq(paths.bot[8].y, 3648)
    end)
end)

describe("lib/lane -- MirrorWave (arc-length fogged estimate)", function()
    local A = { { x = 0, y = 0 },    { x = 4000, y = 0 } }      -- our role-paired lane
    local B = { { x = 0, y = 2000 }, { x = 4000, y = 2000 } }   -- the fogged enemy's lane
    local function wave(fx, fy, speed)
        return { front = { x = fx, y = fy }, centroid = { x = fx - 100, y = fy },
                 creeps = { { pos = { x = fx, y = fy }, speed = speed } } }
    end
    it("team 2: our wave s from the START -> enemy estimate s from the END of its lane", function()
        local m = Lane.MirrorWave(wave(500, 0, 422), A, B, 2)
        assert_true(math.abs(m.front.x - 3500) < 1e-6, "arc 500 from the Dire end = x 3500")
        assert_eq(m.front.y, 2000)
        assert_eq(m.speed, 422)
    end)
    it("team 3: symmetric (our end is the path END)", function()
        local m = Lane.MirrorWave(wave(3500, 0, 325), A, B, 3)
        assert_true(math.abs(m.front.x - 500) < 1e-6, "arc 500 from the Radiant end = x 500")
    end)
    it("centroid mirrors too; missing front -> nil", function()
        local m = Lane.MirrorWave(wave(500, 0, 400), A, B, 2)
        assert_true(math.abs(m.centroid.x - 3600) < 1e-6, "centroid arc 400 -> 3600 from their end")
        assert_true(Lane.MirrorWave({ creeps = {} }, A, B, 2) == nil, "no front -> no estimate")
    end)
end)

describe("lib/lane -- BuildLaneStates fog-fill MIRROR (Piece 1.5)", function()
    local paths = {
        top = { { x = 0, y = 5000 },  { x = 4000, y = 5000 } },
        mid = { { x = 0, y = 0 },     { x = 4000, y = 4000 } },
        bot = { { x = 0, y = -5000 }, { x = 4000, y = -5000 } },
    }
    local function c(x, y, team, speed) return { pos = { x = x, y = y }, team = team, hp = 100, gold = 40, speed = speed } end
    it("a fogged enemy lane mirrors our role-paired wave (position + speed)", function()
        -- our SAFE (bot, team 2) wave visible at arc ~3000; enemy TOP (their safe) is fogged.
        local creeps = { c(2900, -5000, 2, 422), c(3000, -5000, 2, 422) }
        local lanes = Lane.BuildLaneStates(creeps, {}, {}, {
            team = 2, enemy_push = { x = -1, y = 0 }, ally_push = { x = 1, y = 0 },
            game_time = 0, paths = paths,
        })
        local ew = lanes.top.enemy_wave
        assert_true(ew and ew.estimated, "estimated")
        assert_eq(ew.est_src, "mirror")
        assert_true(math.abs(ew.front.x - 1000) < 1e-6, "our arc 3000 -> 1000 from their end")
        assert_eq(ew.front.y, 5000)
        assert_eq(ew.speed, 422)
    end)
    it("no role-paired wave -> clock fallback (composition only, no position)", function()
        local creeps = { c(2900, -5000, 2, 422) }   -- only bot; MID enemy fogged, our mid dead
        local lanes = Lane.BuildLaneStates(creeps, {}, {}, {
            team = 2, enemy_push = { x = -1, y = 0 }, ally_push = { x = 1, y = 0 },
            game_time = 0, paths = paths,
        })
        local ew = lanes.mid.enemy_wave
        assert_true(ew and ew.estimated, "estimated")
        assert_eq(ew.est_src, "clock")
        assert_true(ew.front == nil, "clock estimate has no position")
    end)
    it("vision-edge clamp: a fogged front is never placed inside our same-lane sight", function()
        -- our TOP wave pushed to arc 2400 (x-y=-2600 -> top band); the bot-mirrored top estimate
        -- (arc 1000 from our end) would sit BEHIND our own front = inside our creeps' vision =
        -- impossible while fogged -> floored to our front + 800.
        local creeps = { c(2900, -5000, 2, 422), c(3000, -5000, 2, 422), c(2400, 5000, 2, 400) }
        local lanes = Lane.BuildLaneStates(creeps, {}, {}, {
            team = 2, enemy_push = { x = -1, y = 0 }, ally_push = { x = 1, y = 0 },
            game_time = 0, paths = paths,
        })
        local ew = lanes.top.enemy_wave
        assert_eq(ew.est_src, "mirror")
        assert_true(math.abs(ew.front.x - 3200) < 1e-6, "floored to our front (2400) + vis (800)")
    end)
end)

describe("lib/lane -- SimFight (attrition combat sim; imbalance = damage, not just life)", function()
    local function melee(n) local t = {} for i = 1, n do t[i] = { hp = 550, dmg = 21, atk = 1, armor = 2, atype = "basic" } end return t end
    it("3v2 equal creeps -> the extra creep COMPOUNDS: 2 survivors, not 1", function()
        local f = Lane.SimFight(melee(3), melee(2), { dt = 0.25 })
        assert_eq(f.winner, "a")
        assert_eq(#f.remnant_a, 2, "Lanchester compounding: the +1 advantage preserves ~2 survivors")
        assert_true(f.t > 15 and f.t < 25, "fight duration ~19s")
    end)
    it("pierce multiplier matters: 1 melee beats 1 ranged head-to-head (ranged is squishier)", function()
        local ranged = { { hp = 300, dmg = 23.5, atk = 1, armor = 0, atype = "pierce" } }
        local f = Lane.SimFight(ranged, melee(1), { dt = 0.25 })
        assert_eq(f.winner, "b", "the melee outlasts (550hp vs 300) despite pierce 1.5x")
    end)
    it("an untargetable support attacker (tower) swings the fight", function()
        local f = Lane.SimFight(melee(1), melee(1), { dt = 0.25, support_b = { { dmg = 110, atk = 1, atype = "siege" } } })
        assert_eq(f.winner, "b"); assert_true(f.t < 8, "tower support ends it fast")
    end)
    it("empty sides -> draw, no crash", function()
        local f = Lane.SimFight({}, {}, {})
        assert_eq(f.winner, "draw")
    end)
end)

describe("lib/lane -- WaveCombatants + PushForecast (lane balance)", function()
    it("an ESTIMATED wave builds full-hp combat records from its composition", function()
        local est = Lane.ExpectedWave(0, {})
        local c = Lane.WaveCombatants(est, 0)
        assert_eq(#c, 4, "3 melee + 1 ranged at 0:00")
        local nr = 0
        for _, u in ipairs(c) do if u.atype == "pierce" then nr = nr + 1 end end
        assert_eq(nr, 1, "one ranged (pierce)")
    end)
    it("a REAL wave uses LIVE hp + per-member kind", function()
        local w = { creeps = { { hp = 120, kind = "ranged" }, { hp = 400, kind = "melee" } } }
        local c = Lane.WaveCombatants(w, 0)
        assert_eq(#c, 2)
        local hp = {}
        for _, u in ipairs(c) do hp[#hp + 1] = u.hp end
        table.sort(hp); assert_eq(hp[1], 120); assert_eq(hp[2], 400)
    end)
    it("PushForecast: equal waves ~balance 0; a 4v3 wave reads positive bal + winner a", function()
        local even = Lane.PushForecast(Lane.ExpectedWave(0, {}), Lane.ExpectedWave(0, {}), { rounds = 1 })
        assert_true(math.abs(even.bal or 99) <= 1, "equal waves near-zero balance")
        local big = { melee = 4, ranged = 1, siege = 0, flagbearer = 0 }
        local small = { melee = 3, ranged = 1, siege = 0, flagbearer = 0 }
        local pf = Lane.PushForecast(big, small, { rounds = 2 })
        assert_true((pf.bal or 0) > 0, "the extra melee wins the balance")
        assert_eq(pf.rounds[1].winner, "a")
        assert_eq(#pf.rounds, 2)
        assert_true((pf.first_t or 0) > 0, "fight duration reported (peta basis)")
    end)
end)

describe("lib/lane -- ClampBeyondSight (fog absence-of-vision floor)", function()
    local P = { { x = 0, y = 0 }, { x = 4000, y = 0 } }
    it("team 2: an estimate inside our sight moves to our front + vis", function()
        local p = Lane.ClampBeyondSight({ x = 1500, y = 0 }, { x = 2500, y = 0 }, P, 2, 800)
        assert_true(math.abs(p.x - 3300) < 1e-6, "2500 + 800")
    end)
    it("an estimate already beyond sight is untouched", function()
        local p = Lane.ClampBeyondSight({ x = 3600, y = 0 }, { x = 2500, y = 0 }, P, 2, 800)
        assert_eq(p.x, 3600)
    end)
    it("team 3: symmetric (our end is the path END)", function()
        local p = Lane.ClampBeyondSight({ x = 2500, y = 0 }, { x = 1500, y = 0 }, P, 3, 800)
        assert_true(math.abs(p.x - 700) < 1e-6, "their arc floor mirrored: 4000-(2500+800)")
    end)
end)

describe("lib/schedule -- Plan low_hp dispatch gate (case-file #2)", function()
    local CAL = { march_dmg_per_cast = 300, cast_dur = 0.5, robot_kill = 1.5, rearm_channel = 1.25, lead = 1 }
    local function base(over)
        local c = { now = 100, wave = { arrival = 100, eff_hp = 450, present = true },
                    cal = CAL, travel_to_mid = 3, mana = 500, shove_cost = 200, safe = true }
        for k, v in pairs(over or {}) do c[k] = v end
        return c
    end
    it("a due shove below the hp bar recovers first (run-72 t=445: panic on arrival)", function()
        local d = Schedule.Plan(base({ hp_frac = 0.35, min_hp_frac = 0.50 }))
        assert_eq(d.action, "recover"); assert_eq(d.reason, "low_hp")
    end)
    it("healthy hp dispatches unchanged; nil ctx fields = rule inactive (back-compat)", function()
        local d = Schedule.Plan(base({ hp_frac = 0.80, min_hp_frac = 0.50 }))
        assert_eq(d.action, "shove")
        local d2 = Schedule.Plan(base({}))
        assert_eq(d2.action, "shove")
    end)
end)

describe("lib/channel_gate -- DisableRange (ARC E1)", function()
    local CG = require("lib.channel_gate")
    local AD = { CastRange = function(n) return ({ lion_impale = 750, lion_voodoo = 525, generic_nuke = 800 })[n] end }
    local TD = { ABILITY_TO_THREAT = { lion_impale = "m_impale", lion_voodoo = "m_hex",
                                       pudge_dismember = "m_dis", generic_nuke = "m_nuke" },
                 THREATS_ON_SELF = { m_impale = { role = "hard_disable" }, m_hex = { role = "hard_disable" },
                                     m_dis = { role = "channel_on_me" }, m_nuke = { role = "magic_burst" } } }
    it("max cast range over the disable kit", function()
        assert_eq(CG.DisableRange({ "lion_impale", "lion_voodoo", "generic_nuke" }, AD, TD), 750)
    end)
    it("channel_on_me counts; unknown/short range floors at 250 (melee disables break on arrival)", function()
        assert_eq(CG.DisableRange({ "pudge_dismember" }, AD, TD), 250)
    end)
    it("no disable kit -> nil (never gates)", function()
        assert_eq(CG.DisableRange({ "generic_nuke" }, AD, TD), nil)
    end)
    it("nil-safe on missing inputs", function()
        assert_eq(CG.DisableRange(nil, AD, TD), nil)
        assert_eq(CG.DisableRange({ "lion_impale" }, nil, TD), nil)
    end)
end)

describe("lib/channel_gate -- Breakers + stamps (ARC E2)", function()
    local CG = require("lib.channel_gate")
    local AD = { CastRange = function(n) return ({ lion_impale = 750, lion_voodoo = 525, generic_nuke = 800 })[n] end }
    local TD = { ABILITY_TO_THREAT = { lion_impale = "m_impale", lion_voodoo = "m_hex",
                                       pudge_dismember = "m_dis", generic_nuke = "m_nuke" },
                 THREATS_ON_SELF = { m_impale = { role = "hard_disable" }, m_hex = { role = "hard_disable" },
                                     m_dis = { role = "channel_on_me" }, m_nuke = { role = "magic_burst" } } }
    it("Breakers lists each channel-breaking ability with its range", function()
        local br = CG.Breakers({ "lion_impale", "lion_voodoo", "generic_nuke" }, AD, TD)
        assert_eq(#br, 2)                        -- impale + voodoo break; the nuke does not
        local seen, mods = {}, {}
        for _, b in ipairs(br) do seen[b.ability] = b.range; mods[b.ability] = b.mod end
        assert_eq(seen["lion_impale"], 750)
        assert_eq(seen["lion_voodoo"], 525)                                 -- non-max entry keeps its own range
        assert_eq(mods["lion_impale"], "m_impale")                          -- modifier name carried through
        assert_eq(math.max(seen["lion_impale"], seen["lion_voodoo"]), 750)  -- matches DisableRange
    end)
    it("Breakers returns nil for a kit with no breakers", function()
        assert_eq(CG.Breakers({ "generic_nuke" }, AD, TD), nil)
    end)
    it("breaks_channel-tagged entries gate regardless of role (E3c)", function()
        local AD2 = { CastRange = function(n) return ({ ministun_bolt = 700, plain_nuke = 800 })[n] end }
        local TD2 = { ABILITY_TO_THREAT = { ministun_bolt = "m_bolt", plain_nuke = "m_nuke" },
                      THREATS_ON_SELF = { m_bolt = { role = "magic_burst", breaks_channel = true },
                                          m_nuke = { role = "magic_burst" } } }
        local br = CG.Breakers({ "ministun_bolt", "plain_nuke" }, AD2, TD2)
        assert_eq(#br, 1)                       -- only the tagged ministun gates; the plain nuke does not
        assert_eq(br[1].ability, "ministun_bolt")
        assert_eq(br[1].range, 700)
    end)
    it("Stamp + ReadyAt: stamped ability reads not-ready until expiry", function()
        local st = {}
        CG.Stamp(st, "npc_dota_hero_lion", "lion_impale", 100, 12)
        assert_eq(st["npc_dota_hero_lion"]["lion_impale"], 112)                    -- table shape + t+cd arithmetic
        assert_true(not CG.ReadyAt(st, "npc_dota_hero_lion", "lion_impale", 105))  -- 5s in, cd 12
        assert_true(not CG.ReadyAt(st, "npc_dota_hero_lion", "lion_impale", 111.9))
        assert_true(CG.ReadyAt(st, "npc_dota_hero_lion", "lion_impale", 112))      -- >= boundary reads ready
        assert_true(CG.ReadyAt(st, "npc_dota_hero_lion", "lion_impale", 112.5))    -- past expiry
        assert_true(CG.ReadyAt(st, "npc_dota_hero_lion", "lion_voodoo", 105))      -- unstamped = assume ready
        assert_true(CG.ReadyAt(st, "npc_dota_hero_pudge", "lion_impale", 105))     -- other caster = assume ready
    end)
end)

describe("lib/schedule -- StackWindow (v0.1.224)", function()
    it("mid-minute before the window targets THIS minute", function()
        local w = Schedule.StackWindow(120 + 30, { aggro_sec = 54 })
        assert_eq(w.aggro_at, 174)
        assert_eq(w.done, 180.5)
        assert_true(w.from < w.aggro_at and w.to > w.done, "from/to bracket the maneuver")
    end)
    it("past the miss slack rolls to the NEXT minute", function()
        local w = Schedule.StackWindow(120 + 57, { aggro_sec = 54, miss_slack = 1.5 })
        assert_eq(w.aggro_at, 234)
        assert_eq(w.done, 240.5)
    end)
    it("timeline semantics: start at aggro collects, a late start overruns to", function()
        local w = Schedule.StackWindow(60, { aggro_sec = 54, miss_slack = 1.5 })
        assert_true(w.aggro_at + w.clear_t <= w.to, "on-time start finishes inside the window")
        assert_true((w.aggro_at + 3) + w.clear_t > w.to, "a 3s-late start overruns")
    end)
    it("minute-0 window rolls past the first neutral spawn (run-66: 40s walk to an unspawned camp)", function()
        local w = Schedule.StackWindow(30, { aggro_sec = 54 })
        assert_eq(w.aggro_at, 114)                          -- 0:54 targets nothing (spawn at 1:00) -> 1:54
        assert_eq(w.done, 120.5)
        local w2 = Schedule.StackWindow(70, { aggro_sec = 54 })
        assert_eq(w2.aggro_at, 114)                         -- minute 1 unaffected
    end)
end)

describe("lib/route -- _leg_time", function()
    local hs = { pos = { x = 0, y = 0 }, move_speed = 300, tp = nil, anchors = {} }

    it("walk leg = distance / move_speed when no anchors help", function()
        local t = Route._leg_time({ x = 0, y = 0 }, { pos = { x = 900, y = 0 } }, hs)
        assert_true(math.abs(t - 3.0) < 1e-6, "900/300 = 3s")
    end)

    it("a ready anchor near the target beats walking (tp.channel + short hop)", function()
        local hs2 = { pos = { x = 0, y = 0 }, move_speed = 300, tp = { channel = 3 },
                      anchors = { { pos = { x = 5800, y = 0 }, ready = true, kind = "building" } } }
        local t = Route._leg_time({ x = 0, y = 0 }, { pos = { x = 6000, y = 0 } }, hs2)
        assert_true(math.abs(t - (3 + 200 / 300)) < 1e-6, "tp 3 + 200/300")
    end)
end)

describe("lib/route -- _timeline", function()
    local hs = { pos = { x = 0, y = 0 }, move_speed = 300, tp = nil, anchors = {} }
    local function tgt(x, value, clear_t, window) return { pos = { x = x, y = 0 }, value = value, clear_t = clear_t, window = window } end

    it("collects reachable targets and sums gold; time = elapsed", function()
        local seq = { tgt(900, 60, 3), tgt(1800, 40, 1) }   -- legs 3 + clear 3 = 6; leg 3 + clear 1 = 10
        local tl = Route._timeline(seq, hs, { now = 0, horizon_s = 30 })
        assert_eq(#tl.collected, 2)
        assert_eq(tl.gold, 100)
        assert_true(math.abs(tl.time - 10) < 1e-6, "finish at t=10")
    end)

    it("waits until window.from before clearing (a not-yet-spawned wave)", function()
        local seq = { tgt(900, 180, 2, { from = 20, to = 999 }) }   -- arrive 3, wait to 20, clear 2 -> 22
        local tl = Route._timeline(seq, hs, { now = 0, horizon_s = 30 })
        assert_eq(tl.gold, 180)
        assert_true(math.abs(tl.time - 22) < 1e-6, "waited to window.from then cleared")
    end)

    it("stops at the first target that overruns the horizon", function()
        local seq = { tgt(900, 60, 3), tgt(9000, 40, 1) }   -- second: leg 9000-900=8100/300=27 -> way past 30
        local tl = Route._timeline(seq, hs, { now = 0, horizon_s = 30 })
        assert_eq(#tl.collected, 1, "only the first fits")
        assert_eq(tl.gold, 60)
    end)

    it("drops a target that finishes after window.to", function()
        local seq = { tgt(900, 50, 3, { from = 0, to = 4 }) }   -- finish 6 > to 4
        local tl = Route._timeline(seq, hs, { now = 0, horizon_s = 30 })
        assert_eq(#tl.collected, 0)
    end)
end)

describe("lib/route -- _score", function()
    local hs = { pos = { x = 0, y = 0 }, move_speed = 300, tp = nil, anchors = {} }
    local function tgt(x, value, clear_t, risk) return { pos = { x = x, y = 0 }, value = value, clear_t = clear_t, risk = risk } end

    it("score = gold - risk_weight * sum(risk) over collected", function()
        local seq = { tgt(900, 100, 3, 0.5), tgt(1800, 100, 1, 0.0) }
        local sc = Route._score(seq, hs, { now = 0, horizon_s = 30, risk_weight = 40 })
        assert_eq(sc.gold, 200)
        assert_true(math.abs(sc.score - (200 - 40 * 0.5)) < 1e-6, "200 - 20 = 180")
        assert_eq(#sc.collected, 2)
    end)

    it("risk on an UNcollected target does not count", function()
        local seq = { tgt(900, 60, 3, 0.0), tgt(9000, 100, 1, 1.0) }   -- 2nd overruns horizon
        local sc = Route._score(seq, hs, { now = 0, horizon_s = 30, risk_weight = 40 })
        assert_eq(sc.gold, 60)
        assert_true(math.abs(sc.score - 60) < 1e-6, "the far risky target was never collected")
    end)

    it("step_decay discounts later steps in the SCORE, gold stays the true sum (v0.1.212)", function()
        local seq = { tgt(900, 100, 3, 0.0), tgt(1800, 200, 1, 0.0) }
        local sc = Route._score(seq, hs, { now = 0, horizon_s = 30, risk_weight = 0, step_decay = 0.6 })
        assert_eq(sc.gold, 300)
        assert_true(math.abs(sc.score - (100 + 0.6 * 200)) < 1e-6, "100 + 120 = 220")
    end)

    it("step_decay makes Plan bank the big node FIRST (pair-first over single-first)", function()
        -- single near (value 85), pair far (value 245): undecayed, [single, pair] = 330 beats
        -- [pair, single] = 330 only on time; decayed, front-loading the pair wins the score.
        local single = { pos = { x = 900,  y = 0 }, value = 85,  clear_t = 3, risk = 0 }
        local pair   = { pos = { x = 2400, y = 0 }, value = 245, clear_t = 3, risk = 0 }
        local plan = Route.Plan({ single, pair }, hs,
            { now = 0, horizon_s = 60, max_steps = 2, step_decay = 0.6 })
        assert_eq(plan.steps[1].value, 245, "the pair is banked first under step_decay")
        local plain = Route.Plan({ single, pair }, hs,
            { now = 0, horizon_s = 60, max_steps = 2 })
        assert_eq(plain.gold, 330, "undecayed still collects both")
    end)
end)

describe("lib/route -- Plan + Select", function()
    local hs = { pos = { x = 0, y = 0 }, move_speed = 300, tp = nil, anchors = {} }

    it("plans the triangle: camp now, wave when it spawns, tie-break by time", function()
        local A = { kind = "camp", pos = { x = 900,  y = 0 }, value = 60,  clear_t = 3 }
        local W = { kind = "wave", pos = { x = 1800, y = 0 }, value = 180, clear_t = 2, window = { from = 20, to = 999 } }
        local plan = Route.Plan({ W, A }, hs, { now = 0, horizon_s = 30, max_steps = 4, risk_weight = 0 })
        assert_eq(plan.gold, 240, "both collected")
        assert_eq(#plan.steps, 2)
        assert_true(plan.steps[1] == A, "camp first (the wave is not up yet -> farm the camp meanwhile)")
        assert_true(plan.steps[2] == W, "wave second, when it has spawned")
    end)

    it("respects the horizon (drops a target that cannot finish in time)", function()
        local A = { kind = "camp", pos = { x = 900,  y = 0 }, value = 60,  clear_t = 3 }
        local W = { kind = "wave", pos = { x = 1800, y = 0 }, value = 180, clear_t = 2, window = { from = 20, to = 999 } }
        local plan = Route.Plan({ W, A }, hs, { now = 0, horizon_s = 10, max_steps = 4, risk_weight = 0 })
        assert_eq(#plan.steps, 1, "only the camp fits in a 10s horizon")
        assert_true(plan.steps[1] == A)
        assert_eq(plan.gold, 60)
    end)

    it("vetoes risk >= risk_hard and skips contested targets", function()
        local good = { kind = "camp", pos = { x = 600, y = 0 }, value = 50, clear_t = 1 }
        local risky = { kind = "camp", pos = { x = 300, y = 0 }, value = 999, clear_t = 1, risk = 0.9 }
        local owned = { kind = "wave", pos = { x = 450, y = 0 }, value = 999, clear_t = 1, contested = true }
        local plan = Route.Plan({ risky, owned, good }, hs, { now = 0, horizon_s = 30, max_steps = 4, risk_weight = 0, risk_hard = 0.45 })
        for _, s in ipairs(plan.steps) do
            assert_true(s ~= risky and s ~= owned, "risky/contested excluded")
        end
        assert_true(plan.steps[1] == good, "the safe, uncontested target is chosen")
    end)

    it("max_leg_s drops an unreachable far camp (the far-camp stuck guard)", function()
        local near = { kind = "camp", pos = { x = 600,  y = 0 }, value = 50, clear_t = 1 }
        local far  = { kind = "camp", pos = { x = 9000, y = 0 }, value = 999, clear_t = 1 }  -- 9000/300 = 30s > 20
        local plan = Route.Plan({ far, near }, hs, { now = 0, horizon_s = 60, max_steps = 4, risk_weight = 0, max_leg_s = 20 })
        for _, s in ipairs(plan.steps) do assert_true(s ~= far, "far/unreachable camp excluded despite huge value") end
        assert_true(plan.steps[1] == near)
    end)

    it("Select returns the first leg; empty input -> nil / empty plan", function()
        local A = { kind = "camp", pos = { x = 600, y = 0 }, value = 50, clear_t = 1 }
        assert_true(Route.Select({ A }, hs, { now = 0, horizon_s = 30 }) == A)
        local empty = Route.Plan({}, hs, { now = 0, horizon_s = 30 })
        assert_eq(#empty.steps, 0); assert_eq(empty.gold, 0)
        assert_true(Route.Select({}, hs, { now = 0, horizon_s = 30 }) == nil)
    end)

    it("round-trip: return_pos drops a camp it cannot walk back from in time (v0.1.93)", function()
        local near = { kind = "camp", pos = { x = 600,  y = 0 }, value = 100, clear_t = 2 }
        local far  = { kind = "camp", pos = { x = 2000, y = 0 }, value = 200, clear_t = 2 }
        -- without return_pos the higher-value far camp fits the 12s horizon (reach+clear ~8.7s).
        local without = Route.Plan({ near, far }, hs, { now = 0, horizon_s = 12, risk_weight = 0 })
        local has_far = false
        for _, s in ipairs(without.steps) do if s == far then has_far = true end end
        assert_true(has_far, "without return_pos: far camp is collectable")
        -- with return_pos: far finish ~8.7s + walk back 2000/300 ~6.7s = ~15.3s > 12 -> excluded.
        local withrp = Route.Plan({ near, far }, hs,
            { now = 0, horizon_s = 12, risk_weight = 0, return_pos = { x = 0, y = 0 }, return_speed = 300 })
        assert_eq(#withrp.steps, 1, "only the near camp survives the round-trip check")
        assert_true(withrp.steps[1] == near, "near camp kept")
        assert_eq(withrp.gold, 100, "gold = near camp only")
    end)

    it("round-trip: keen-aware return (return_anchors) keeps a far camp a ready anchor can cover (v0.1.125 BUG 2)", function()
        local hs2 = { pos = { x = 0, y = 0 }, move_speed = 300, tp = nil, anchors = {} }
        local far = { kind = "camp", pos = { x = 2000, y = 0 }, value = 200, clear_t = 2 }
        -- walk-only return: camp->mid walk 2000/300 ~6.7s; finish ~8.7 + 6.7 = 15.3 > 12 -> excluded.
        local walk = Route.Plan({ far }, hs2,
            { now = 0, horizon_s = 12, risk_weight = 0, return_pos = { x = 0, y = 0 }, return_speed = 300 })
        assert_eq(#walk.steps, 0, "walk-back return excludes the far camp")
        -- keen-aware: a ready anchor AT mid makes the return ~0 (channel 0) -> finish ~8.7 < 12 -> kept.
        local anchors = { { pos = { x = 0, y = 0 }, ready = true, kind = "building" } }
        local keen = Route.Plan({ far }, hs2,
            { now = 0, horizon_s = 12, risk_weight = 0, return_pos = { x = 0, y = 0 },
              return_speed = 300, return_anchors = anchors, return_tp = { channel = 0 } })
        assert_eq(#keen.steps, 1, "keen-aware return keeps the far camp (cheap anchor return)")
        assert_true(keen.steps[1] == far, "the far camp is kept")
    end)
end)

describe("lib/route -- resource gating (Note 4)", function()
    -- hero with mana so a hop costs mana; no anchors so legs are plain walk (dist/300).
    local function hsr(over)
        local hs = { pos = { x = 0, y = 0 }, move_speed = 300, tp = nil, anchors = {},
                     mana = 200, max_mana = 400, mana_regen = 0, reserve_mana = 0, hp_floor = 0 }
        for k, v in pairs(over or {}) do hs[k] = v end
        return hs
    end
    local function ctg(x, value, clear_t, mana_cost, hp_cost)
        return { pos = { x = x, y = 0 }, value = value, clear_t = clear_t, mana_cost = mana_cost, hp_cost = hp_cost }
    end

    it("no resource fields -> gating is inert (back-compat)", function()
        local hs = { pos = { x = 0, y = 0 }, move_speed = 300, tp = nil, anchors = {} }
        local seq = { { pos = { x = 900, y = 0 }, value = 60, clear_t = 3, mana_cost = 9999 } }
        local tl = Route._timeline(seq, hs, { now = 0, horizon_s = 30 })
        assert_eq(#tl.collected, 1, "no hero.mana -> mana_cost ignored")
    end)

    it("breaks the chain at the first unaffordable hop (mana)", function()
        local seq = { ctg(900, 60, 1, 120), ctg(1800, 60, 1, 120) }   -- 200 -> 80 after first; 80 < 120
        local tl = Route._timeline(seq, hsr(), { now = 0, horizon_s = 30 })
        assert_eq(#tl.collected, 1, "second hop unaffordable")
        assert_eq(tl.gold, 60)
    end)

    it("reserve_mana is kept untouched", function()
        local seq = { ctg(900, 60, 1, 120) }   -- need 120 + reserve 100 = 220 > 200
        local tl = Route._timeline(seq, hsr({ reserve_mana = 100 }), { now = 0, horizon_s = 30 })
        assert_eq(#tl.collected, 0, "cannot dip into the escape reserve")
    end)

    it("regen during travel lifts an otherwise-unaffordable hop", function()
        -- mana 100, cost 130; leg 900/300 = 3s; regen 20/s -> 100 + 60 = 160 >= 130
        local seq = { ctg(900, 60, 1, 130) }
        local tl = Route._timeline(seq, hsr({ mana = 100, mana_regen = 20 }), { now = 0, horizon_s = 30 })
        assert_eq(#tl.collected, 1, "regen made it affordable")
    end)

    it("HP gate trips only below the floor, not on a safe (hp_cost~0) hop", function()
        local safe = { ctg(900, 60, 1, 0, 0) }
        local hurt = { ctg(900, 60, 1, 0, 300) }   -- hp 250 - 300 = -50 < floor 100
        local hs = hsr({ hp = 250, max_hp = 600, hp_regen = 0, hp_floor = 100 })
        assert_eq(#Route._timeline(safe, hs, { now = 0, horizon_s = 30 }).collected, 1, "safe hop ok")
        assert_eq(#Route._timeline(hurt, hs, { now = 0, horizon_s = 30 }).collected, 0, "hp would drop below floor")
    end)
end)

describe("lib/route -- refill node (Note 4)", function()
    local function hsr(over)
        local hs = { pos = { x = 0, y = 0 }, move_speed = 300, tp = nil, anchors = {},
                     mana = 100, max_mana = 400, mana_regen = 0, reserve_mana = 0 }
        for k, v in pairs(over or {}) do hs[k] = v end
        return hs
    end

    it("a refill node tops mana to refill_frac*max and adds no gold", function()
        -- start mana 100; cost-200 hop unaffordable; refill (frac 1.0) -> 400; then affordable
        local refill = { pos = { x = 300, y = 0 }, value = 0, clear_t = 2, restore = true }
        local ancient = { pos = { x = 600, y = 0 }, value = 160, clear_t = 3, mana_cost = 200 }
        local nofill = Route._timeline({ ancient }, hsr(), { now = 0, horizon_s = 60, refill_frac = 1 })
        assert_eq(#nofill.collected, 0, "unaffordable without a refill")
        local withfill = Route._timeline({ refill, ancient }, hsr(), { now = 0, horizon_s = 60, refill_frac = 1 })
        assert_eq(#withfill.collected, 2, "refill then ancient")
        assert_eq(withfill.gold, 160, "refill adds 0 gold; ancient adds 160")
    end)

    it("refill is COST-AWARE: tops up past refill_frac to the NEXT target's need (ancient arc)", function()
        local refill = { pos = { x = 300, y = 0 }, value = 0, clear_t = 0, restore = true }
        local hop = { pos = { x = 600, y = 0 }, value = 50, clear_t = 0, mana_cost = 300 }
        -- frac 0.7 -> 400*0.7 = 280 < 300, but the refill sees the next node needs 300 -> fills to 300
        local tl = Route._timeline({ refill, hop }, hsr(), { now = 0, horizon_s = 60, refill_frac = 0.7 })
        assert_eq(#tl.collected, 2, "refill fills to the next target's cost; hop affordable")
    end)

    it("cost-aware refill includes the reserve and caps at max_mana", function()
        local refill = { pos = { x = 300, y = 0 }, value = 0, clear_t = 0, restore = true }
        local hop = { pos = { x = 600, y = 0 }, value = 50, clear_t = 0, mana_cost = 350 }
        -- need = 350 + reserve 60 = 410 > max 400 -> capped at 400 < 410 -> still unaffordable
        local tl = Route._timeline({ refill, hop }, hsr({ reserve_mana = 60 }),
                                   { now = 0, horizon_s = 60, refill_frac = 0.7 })
        assert_eq(#tl.collected, 1, "pool cannot cover cost+reserve even full: only the refill")
        -- reserve 40 -> need 390 <= 400 -> fills to 390, hop affordable
        local tl2 = Route._timeline({ refill, hop }, hsr({ reserve_mana = 40 }),
                                    { now = 0, horizon_s = 60, refill_frac = 0.7 })
        assert_eq(#tl2.collected, 2, "fills to cost+reserve within the pool")
    end)
end)

describe("lib/route -- Plan with refill node (Note 4)", function()
    local function hsr(over)
        local hs = { pos = { x = 0, y = 0 }, move_speed = 300, tp = nil, anchors = {},
                     mana = 120, max_mana = 400, mana_regen = 0, reserve_mana = 0 }
        for k, v in pairs(over or {}) do hs[k] = v end
        return hs
    end

    it("inserts the refill when it unlocks a downstream prize", function()
        local near    = { kind = "camp", pos = { x = 300, y = 0 }, value = 40, clear_t = 1, mana_cost = 60 }
        local ancient = { kind = "camp", pos = { x = 900, y = 0 }, value = 200, clear_t = 2, mana_cost = 200 }
        local refill  = { kind = "refill", pos = { x = 0, y = 0 }, value = 0, clear_t = 2, restore = true }
        local plan = Route.Plan({ near, ancient, refill }, hsr(),
                                { now = 0, horizon_s = 120, max_steps = 4, risk_weight = 0, refill_frac = 1 })
        local hasRefill = false
        for _, s in ipairs(plan.steps) do if s.restore then hasRefill = true end end
        assert_true(hasRefill, "refill routed in to unlock the ancient")
        assert_true(plan.gold >= 240, "near 40 + ancient 200 collected after refill")
    end)

    it("omits the refill when the chain is already affordable", function()
        local a = { kind = "camp", pos = { x = 300, y = 0 }, value = 40, clear_t = 1, mana_cost = 30 }
        local b = { kind = "camp", pos = { x = 600, y = 0 }, value = 40, clear_t = 1, mana_cost = 30 }
        local refill = { kind = "refill", pos = { x = 0, y = 0 }, value = 0, clear_t = 2, restore = true }
        local plan = Route.Plan({ a, b, refill }, hsr({ mana = 400 }),
                                { now = 0, horizon_s = 120, max_steps = 4, risk_weight = 0, refill_frac = 1 })
        for _, s in ipairs(plan.steps) do assert_true(not s.restore, "no wasteful refill") end
    end)

    it("the refill node survives the pool_cap trim even with value 0", function()
        local hs = hsr({ mana = 50 })
        local targets = { { kind = "refill", pos = { x = 0, y = 0 }, value = 0, clear_t = 1, restore = true } }
        for i = 1, 15 do   -- 15 cheap normals + 1 refill, pool_cap default 10
            targets[#targets + 1] = { kind = "camp", pos = { x = 200 + i * 50, y = 0 }, value = 10, clear_t = 1, mana_cost = 200 }
        end
        local plan = Route.Plan(targets, hs, { now = 0, horizon_s = 120, max_steps = 4, risk_weight = 0, refill_frac = 1 })
        -- with mana 50 every camp (cost 200) needs a refill first; if the trim dropped the refill, gold would be 0
        local hasRefill = false
        for _, s in ipairs(plan.steps) do if s.restore then hasRefill = true end end
        assert_true(hasRefill, "refill retained through the trim")
    end)

    it("#3: the pool_cap trim ranks by risk-adjusted value (a close risky camp does not crowd out a safer one)", function()
        local hs = { pos = { x = 0, y = 0 }, move_speed = 300 }
        local targets = {}
        for i = 1, 11 do   -- 11 close high-value RISKY camps: net = 100 - 70*0.3 = 79
            targets[i] = { kind = "camp", pos = { x = 300 + i * 20, y = 0 }, value = 100, risk = 0.3, clear_t = 25 }
        end                -- + 1 safe lower-value camp: net = 90. 12 > pool_cap 10 -> trim; clear_t 25 -> only one fits 30s.
        targets[12] = { kind = "camp", pos = { x = 320, y = 0 }, value = 90, clear_t = 25 }
        local plan = Route.Plan(targets, hs, { now = 0, horizon_s = 30, max_steps = 4, risk_weight = 70 })
        assert_eq(#plan.steps, 1, "only one camp fits the horizon")
        -- value-only trim would drop the value-90 safe camp (all value-100 risky rank higher) and pick a
        -- risky one; the risk-adjusted trim keeps the safe camp (net 90 > 79) so it wins the single slot.
        assert_true((plan.steps[1].risk or 0) == 0, "the safer camp survived the trim and won on risk-adjusted value")
    end)
end)

describe("lib/route -- time-decay value (wave urgency)", function()
    local hs = { pos = { x = 0, y = 0 }, move_speed = 300, tp = nil, anchors = {} }

    it("a decaying target is worth less collected later (age from born)", function()
        local seq = { { pos = { x = 900, y = 0 }, value = 100, clear_t = 0, decay_per_s = 8, value_floor = 50, born = 0 } }
        local tl = Route._timeline(seq, hs, { now = 0, horizon_s = 30 })   -- leg 3s -> 100 - 8*3 = 76
        assert_true(math.abs(tl.gold - 76) < 1e-6, "100 - 8*3 = 76 at collection t=3")
    end)

    it("the planner orders a decaying wave BEFORE a constant camp", function()
        local camp = { kind = "camp", pos = { x = 300, y = 0 }, value = 100, clear_t = 1 }
        local wave = { kind = "wave", pos = { x = 300, y = 0 }, value = 100, clear_t = 1, decay_per_s = 20, value_floor = 0, born = 0 }
        local plan = Route.Plan({ camp, wave }, hs, { now = 0, horizon_s = 30, max_steps = 4, risk_weight = 0 })
        assert_true(plan.steps[1] == wave, "take the decaying wave first; the camp keeps its value")
    end)

    it("decay floors at value_floor for a stale target", function()
        local seq = { { pos = { x = 9000, y = 0 }, value = 100, clear_t = 0, decay_per_s = 50, value_floor = 30, born = 0 } }
        local tl = Route._timeline(seq, hs, { now = 0, horizon_s = 60 })   -- leg 30s -> 100-1500 floored 30
        assert_eq(tl.gold, 30)
    end)
end)

describe("lib/escape - BlinkInLanding", function()
    Vector = Vector or function(x, y, z) return { x = x, y = y, z = z } end
    Heroes = Heroes or {}
    Heroes.GetAll = function() return {} end
    Heroes.InRadius = function() return {} end
    -- Entity.GetTeamNum is called by FogSnapshot; stub so it returns a team
    -- number without erroring. Heroes.GetAll returns {} so no enemy loop runs.
    Entity.GetTeamNum = Entity.GetTeamNum or function() return 2 end
    local Escape = require("lib.escape")
    local me = { pos = { x = 0, y = 0, z = 0 } }

    it("lands at the near edge of engage range, reachable, within blink range", function()
        local aim = { x = 1000, y = 0, z = 0 }
        local landing, risk, reachable = Escape.BlinkInLanding(me, aim, 1200, 700, { margin = 50 })
        assert_true(reachable, "should be reachable")
        assert_true(type(risk) == "number", "risk is a number")
        assert_true(math.abs(landing.x - 350) < 1, "landing.x near 350, got " .. tostring(landing.x))
        assert_true(landing.x <= 1200, "within blink range")
    end)

    it("target beyond blink+engage reach -> not reachable", function()
        local aim = { x = 3000, y = 0, z = 0 }
        local landing, _, reachable = Escape.BlinkInLanding(me, aim, 1200, 700, {})
        assert_false(reachable, "should NOT be reachable")
        assert_true(math.abs(landing.x - 1200) < 1, "lands at max blink reach 1200")
    end)

    it("nil args -> nil landing, not reachable", function()
        local landing, _, reachable = Escape.BlinkInLanding(me, nil, 1200, 700, {})
        assert_true(landing == nil, "nil landing")
        assert_false(reachable, "not reachable")
    end)
end)

describe("lib/escape - SafestSpotNear dual-winner (Phase B)", function()
    local Escape = require("lib.escape")
    local me = {}   -- Entity.GetAbsOrigin stub returns {0,0,0} for a posless entity
    -- Drive a deterministic risk field + terrain mask; restore globals after.
    local function with_field(scores, blocked, fn)
        local s_ars, s_fs, s_grid = Escape.AdvanceRiskScore, Escape.FogSnapshot, GridNav
        Escape.FogSnapshot      = function() return { heroes = {} } end
        Escape.AdvanceRiskScore = function(_me, p) return scores(p) end
        GridNav = { IsTraversableFromTo = function(_a, b) return not blocked(b) end }
        local ok, err = pcall(fn)
        Escape.AdvanceRiskScore, Escape.FogSnapshot, GridNav = s_ars, s_fs, s_grid
        if not ok then error(err, 2) end
    end

    it("terrain-locked spot is safest -> best_pos locked, info reports it", function()
        with_field(function(p) return (p.x > 600) and 1 or 100 end,
                   function(p) return p.x > 600 end, function()
            local best, score, info = Escape.SafestSpotNear(me, 700)
            assert_true(best.x > 600, "best_pos is the locked safe spot")
            assert_true(info.locked, "info.locked true")
            assert_false(info.traversable, "best not traversable")
            assert_true(info.walkable_score >= 100, "walkable best is safe-less ground")
            assert_true((info.walkable_score - score) >= 20, "locked is margin-safer")
        end)
    end)

    it("all-walkable -> best_pos == walkable, not locked", function()
        with_field(function(p) return (p.y > 600) and 1 or 50 end,
                   function() return false end, function()
            local best, _score, info = Escape.SafestSpotNear(me, 700)
            assert_false(info.locked, "not locked")
            assert_true(info.traversable, "traversable")
            assert_true(best.x == info.walkable_pos.x and best.y == info.walkable_pos.y,
                        "best_pos == walkable_pos")
        end)
    end)

    it("nil args -> nil, huge, nil", function()
        local best, score, info = Escape.SafestSpotNear(nil, 700)
        assert_true(best == nil and info == nil, "nil best + info")
        assert_true(score == math.huge, "huge score")
    end)
end)

describe("lib/escape - PostAirborneMoveTick recompute_dest (Phase B)", function()
    local Escape = require("lib.escape")
    local me = { pos = { x = 0, y = 0, z = 0 } }
    local s_hasmod = NPC.HasModifier
    NPC.HasModifier = function() return true end   -- FC modifier present (airborne window)
    local function make_cfg(cap)
        return { now = function() return 100.0 end, hero_key = "lina", layer = "def",
                 safe_issue = function(o) cap.pos = o.position end, tlog = nil }
    end

    it("recompute_dest overrides the dest each reissue", function()
        local cap = {}
        local pending = {
            dest = Vector(500, 0, 0), modifier_name = "modifier_lina_flame_cloak",
            moves_during_airborne = true, deadline = 107, intent = "fc_escape",
            observed_airborne = false, last_reissue_t = 0, reissue_seq = 0,
            recompute_dest = function() return Vector(900, 0, 0) end,
        }
        local p = Escape.PostAirborneMoveTick(me, pending, make_cfg(cap))
        assert_true(p ~= nil, "still pending")
        assert_true(cap.pos and cap.pos.x == 900,
            "reissued to recomputed dest, got " .. tostring(cap.pos and cap.pos.x))
    end)

    it("no recompute_dest, no threat_caster -> dest frozen", function()
        local cap = {}
        local pending = {
            dest = Vector(500, 0, 0), modifier_name = "modifier_lina_flame_cloak",
            moves_during_airborne = true, deadline = 107, intent = "ww",
            observed_airborne = false, last_reissue_t = 0, reissue_seq = 0,
        }
        Escape.PostAirborneMoveTick(me, pending, make_cfg(cap))
        assert_true(cap.pos and cap.pos.x == 500, "dest unchanged (frozen)")
    end)

    NPC.HasModifier = s_hasmod   -- restore the global stub after the block
end)

describe("lib/escape - ChaseWindow (Phase C)", function()
    Vector = Vector or function(x, y, z) return { x = x, y = y, z = z } end
    local Escape = require("lib.escape")
    local me  = { x = 0,   y = 0, z = 0 }
    local tgt = { x = 400, y = 0, z = 0 }   -- 400u east of Lina

    it("catch-ETA = straight dist / fly_speed", function()
        local w = Escape.ChaseWindow(me, tgt, { x = 0, y = 0 }, { fly_speed = 400, kill_reach = 2000 })
        assert_true(math.abs(w.catch_eta - 1.0) < 1e-6, "400u / 400ms = 1.0s, got " .. tostring(w.catch_eta))
    end)

    it("out-of-reach ETA: target fleeing east exits kill_reach", function()
        -- target at 400, fleeing +x at 300/s, kill_reach 1000 from me(0): exits at (1000-400)/300 = 2.0s
        local w = Escape.ChaseWindow(me, tgt, { x = 300, y = 0 }, { fly_speed = 400, kill_reach = 1000 })
        assert_true(math.abs(w.escape_eta - 2.0) < 1e-6, "out-of-reach 2.0s, got " .. tostring(w.escape_eta))
    end)

    it("protection ETA wins when a tower is closer than out-of-reach", function()
        -- tower at (700,0) range 300 -> target reaches its rim (700-300=400) at (400-400)/300 = 0.0s? place tower farther:
        -- tower center (1300,0) range 300 -> rim at 1000; target reaches 1000 at (1000-400)/300 = 2.0s; out-of-reach 2000 -> later
        local w = Escape.ChaseWindow(me, tgt, { x = 300, y = 0 },
            { fly_speed = 400, kill_reach = 5000, tower_circles = { { pos = { x = 1300, y = 0 }, range = 300 } } })
        assert_true(math.abs(w.escape_eta - 2.0) < 1e-6, "protection 2.0s, got " .. tostring(w.escape_eta))
    end)

    it("stationary target never out of reach -> escape_eta huge", function()
        local w = Escape.ChaseWindow(me, tgt, { x = 0, y = 0 }, { fly_speed = 400, kill_reach = 1000 })
        assert_true(w.escape_eta == math.huge, "no flee -> never escapes, got " .. tostring(w.escape_eta))
    end)

    it("nil args -> nil", function()
        assert_true(Escape.ChaseWindow(nil, tgt, { x = 0, y = 0 }, {}) == nil, "nil me -> nil")
    end)
end)

describe("lib/escape - CutoffLock (Phase C2)", function()
    local Escape = require("lib.escape")
    local me = { x = 0, y = 0, z = 0 }
    local ip = { x = 1000, y = 0, z = 0 }   -- straight = 1000

    it("big detour walk -> locked", function()
        local path = { { x = 0, y = 0 }, { x = 0, y = 900 }, { x = 1000, y = 900 }, { x = 1000, y = 0 } } -- 900+1000+900=2800
        local r = Escape.CutoffLock(me, ip, path, { ratio = 1.3, min_gain = 250 })
        assert_true(r.locked, "walk 2800 vs straight 1000 should lock, got walk=" .. tostring(r.walk))
    end)

    it("straight walk -> not locked", function()
        local r = Escape.CutoffLock(me, ip, { { x = 0, y = 0 }, { x = 1000, y = 0 } }, { ratio = 1.3, min_gain = 250 })
        assert_true(not r.locked, "walk == straight must not lock")
    end)

    it("short detour under min_gain -> not locked", function()
        -- me->(100,0): walk (0,0)->(0,80)->(100,80)->(100,0) = 80+100+80=260; straight 100; ratio 2.6 but gain 160 < 250
        local r = Escape.CutoffLock(me, { x = 100, y = 0 },
            { { x = 0, y = 0 }, { x = 0, y = 80 }, { x = 100, y = 80 }, { x = 100, y = 0 } },
            { ratio = 1.3, min_gain = 250 })
        assert_true(not r.locked, "gain 160 < min 250 must not lock")
    end)

    it("nil walk_path -> not locked", function()
        local r = Escape.CutoffLock(me, ip, nil, {})
        assert_true(not r.locked, "no path -> not locked")
    end)

    it("nil me_pos -> not locked (safe)", function()
        local r = Escape.CutoffLock(nil, ip, { { x = 0, y = 0 }, { x = 1, y = 0 } }, {})
        assert_true(not r.locked, "nil me -> not locked")
    end)
end)

describe("lib/escape - MissingCount", function()
    local E = require("lib.escape")
    it("counts fogged (visible=false) enemies", function()
        local snap = { heroes = { { visible = true }, { visible = false }, { visible = false } } }
        assert_eq(E.MissingCount(snap), 2)
    end)
    it("all visible -> 0", function()
        assert_eq(E.MissingCount({ heroes = { { visible = true }, { visible = true } } }), 0)
    end)
    it("empty / nil -> 0", function()
        assert_eq(E.MissingCount({}), 0); assert_eq(E.MissingCount(nil), 0)
    end)
end)

describe("lib/escape - FogProximityRisk", function()
    local Escape = require("lib.escape")
    -- Vector stub with Distance2D (the file's base Vector stub lacks it).
    local function Vec(x, y)
        return { x = x, y = y, z = 0,
                 Distance2D = function(self, o)
                     local dx, dy = self.x - o.x, self.y - o.y
                     return math.sqrt(dx * dx + dy * dy)
                 end }
    end
    local OPTS = { risk_radius = 1400, fog_ms = 550, fog_spread = 900, age_cap = 5 }
    local function snap(heroes) return { t = 0, heroes = heroes } end

    it("no enemies -> 0", function()
        assert_eq(Escape.FogProximityRisk(snap({}), Vec(0, 0), OPTS), 0)
    end)

    it("visible enemy == (1 - d/risk_radius)^2 (continuity)", function()
        local pt = Vec(0, 0)
        local h = { pos = Vec(700, 0), age = 0, probable_radius = 0, visible = true }
        local r = 1 - 700 / 1400
        assert_true(math.abs(Escape.FogProximityRisk(snap({ h }), pt, OPTS) - r * r) < 1e-9,
            "visible must match the plain proximity falloff")
    end)

    it("recently-fogged enemy near pt scores high", function()
        -- last seen 400u away 2s ago: disc radius 1100 reaches well past pt,
        -- edge = max(0, 400 - 1100) = 0 -> base 1; conf = 900/(900+1100) = 0.45
        local h = { pos = Vec(400, 0), age = 2, probable_radius = 0, visible = false }
        local got = Escape.FogProximityRisk(snap({ h }), Vec(0, 0), OPTS)
        assert_true(got > 0.4, "near recent fog should score high, got " .. got)
    end)

    it("stale (but within cap) fog scores lower than fresh (decay bites)", function()
        local near = Vec(400, 0)
        local fresh = { pos = near, age = 1, probable_radius = 0, visible = false }
        local stale = { pos = near, age = 5, probable_radius = 0, visible = false }
        local rf = Escape.FogProximityRisk(snap({ fresh }), Vec(0, 0), OPTS)
        local rs = Escape.FogProximityRisk(snap({ stale }), Vec(0, 0), OPTS)
        assert_true(rs < rf, "older fog must decay below fresher, fresh=" .. rf .. " stale=" .. rs)
    end)

    it("weight_fn scales a hero's risk (0.5 halves it)", function()
        local h = { pos = Vec(700, 0), age = 0, probable_radius = 0, visible = true }
        local plain = Escape.FogProximityRisk(snap({ h }), Vec(0, 0), OPTS)
        local opts2 = { risk_radius = 1400, fog_ms = 550, fog_spread = 900, age_cap = 5,
                        weight_fn = function(_) return 0.5 end }
        local weighted = Escape.FogProximityRisk(snap({ h }), Vec(0, 0), opts2)
        assert_true(math.abs(weighted - plain * 0.5) < 1e-9, "weight 0.5 must halve, got " .. weighted)
    end)
    it("absent weight_fn is unchanged (regression guard)", function()
        local h = { pos = Vec(700, 0), age = 0, probable_radius = 0, visible = true }
        local r = 1 - 700 / 1400
        assert_true(math.abs(Escape.FogProximityRisk(snap({ h }), Vec(0, 0), OPTS) - r * r) < 1e-9,
            "no weight_fn must equal the plain falloff")
    end)

    it("age beyond age_cap contributes 0", function()
        local h = { pos = Vec(100, 0), age = 6, probable_radius = 0, visible = false }
        assert_eq(Escape.FogProximityRisk(snap({ h }), Vec(0, 0), OPTS), 0)
    end)

    it("takes the max over enemies", function()
        local far = { pos = Vec(1300, 0), age = 0, probable_radius = 0, visible = true }
        local near = { pos = Vec(200, 0), age = 0, probable_radius = 0, visible = true }
        local both = Escape.FogProximityRisk(snap({ far, near }), Vec(0, 0), OPTS)
        local solo = Escape.FogProximityRisk(snap({ near }), Vec(0, 0), OPTS)
        assert_true(math.abs(both - solo) < 1e-9, "max enemy must dominate")
    end)
end)

local HV = require("lib.hero_value")

describe("lib/hero_value -- FarmPriority", function()
    it("maps role 1..5 to a strictly descending priority (carry highest)", function()
        local p1 = HV.FarmPriority({ role = 1 })
        local p3 = HV.FarmPriority({ role = 3 })
        local p5 = HV.FarmPriority({ role = 5 })
        assert_true(p1 > p3 and p3 > p5, "pos1 > pos3 > pos5")
        assert_true(p1 <= 1.0 and p5 >= 0.0, "within 0..1")
    end)

    it("role nil -> normalized hero_value, clamped to 0..1", function()
        local hi = HV.FarmPriority({ role = nil, value = 1.6 })   -- a max-value carry
        local lo = HV.FarmPriority({ role = nil, value = 0.27 })  -- a low support
        assert_true(math.abs(hi - 1.0) < 1e-6, "1.6 / 1.6 = 1.0")
        assert_true(lo > 0 and lo < hi, "support below carry, still positive")
        assert_true(HV.FarmPriority({ role = nil, value = 5.0 }) <= 1.0, "clamped at 1.0")
        assert_eq(HV.FarmPriority({}), HV.FarmPriority({ value = HV.DEFAULT_VALUE }))
    end)
end)

describe("lib/hero_value -- base (KV-tag derive + override)", function()
    it("Carry primary tag -> 1.0 (antimage)", function()
        assert_eq(HV.base("npc_dota_hero_antimage"), 1.00)
    end)
    it("Support primary tag -> 0.45 (crystal_maiden)", function()
        assert_eq(HV.base("npc_dota_hero_crystal_maiden"), 0.45)
    end)
    it("unknown hero -> default 0.5", function()
        assert_eq(HV.base("npc_dota_hero_does_not_exist"), 0.50)
    end)
    it("nil name -> default", function()
        assert_eq(HV.base(nil), 0.50)
    end)
    it("override beats the KV-tag derive", function()
        HV.HERO_VALUE_OVERRIDE["npc_dota_hero_antimage"] = 0.33
        assert_eq(HV.base("npc_dota_hero_antimage"), 0.33)
        HV.HERO_VALUE_OVERRIDE["npc_dota_hero_antimage"] = nil
    end)
    it("seeded override applies (doom_bringer offlane 0.70)", function()
        assert_eq(HV.base("npc_dota_hero_doom_bringer"), 0.70)
    end)
end)

describe("lib/hero_value -- KillThreat", function()
    it("lethal cataloged ability -> HI (pudge)", function()
        assert_eq(HV.KillThreat("npc_dota_hero_pudge"), HV.KILL_W_HI)
    end)
    it("Initiator with no cataloged lethal -> HI (axe)", function()
        assert_eq(HV.KillThreat("npc_dota_hero_axe"), HV.KILL_W_HI)
    end)
    it("support, no lethal, not initiator -> LO (dazzle)", function()
        assert_eq(HV.KillThreat("npc_dota_hero_dazzle"), HV.KILL_W_LO)
    end)
    it("core nuker without cataloged lethal -> BASE (sniper)", function()
        assert_eq(HV.KillThreat("npc_dota_hero_sniper"), HV.KILL_W_BASE)
    end)
    it("unknown hero -> BASE", function()
        assert_eq(HV.KillThreat("npc_dota_hero_nonexistent"), HV.KILL_W_BASE)
    end)
end)

describe("lib/hero_value -- live_mult (peer-relative stats->level)", function()
    local E, P1, P2 = { id = "E" }, { id = "P1" }, { id = "P2" }
    local function restore(s) NPC.GetPlayerOwner, Player, NPC.GetCurrentLevel = s.po, s.pl, s.cl end
    local function snapshot() return { po = NPC.GetPlayerOwner, pl = Player, cl = NPC.GetCurrentLevel } end

    it("level fallback: fed enemy above peer mean clamps to HI 1.6", function()
        local s = snapshot()
        NPC.GetPlayerOwner = function() return nil end      -- force the level path
        local LV = { [E] = 25, [P1] = 10, [P2] = 10 }       -- mean 15; 25/15 = 1.667 -> 1.6
        NPC.GetCurrentLevel = function(u) return LV[u] end
        assert_true(math.abs(HV.live_mult(E, { E, P1, P2 }) - 1.6) < 1e-9, "clamp HI")
        restore(s)
    end)
    it("level fallback: within band, unclamped", function()
        local s = snapshot()
        NPC.GetPlayerOwner = function() return nil end
        local LV = { [E] = 18, [P1] = 12, [P2] = 12 }       -- mean 14; 18/14 = 1.2857
        NPC.GetCurrentLevel = function(u) return LV[u] end
        assert_true(math.abs(HV.live_mult(E, { E, P1, P2 }) - (18/14)) < 1e-9, "ratio")
        restore(s)
    end)
    it("stats preferred when they read for the whole set", function()
        local s_str, s_agi, s_int = Hero.GetStrengthTotal, Hero.GetAgilityTotal, Hero.GetIntellectTotal
        local s_cl = NPC.GetCurrentLevel
        local ST = { [E] = 600, [P1] = 300, [P2] = 300 }     -- mean 400; 600/400 = 1.5
        Hero.GetStrengthTotal  = function(u) return ST[u] end
        Hero.GetAgilityTotal   = function() return 0 end
        Hero.GetIntellectTotal = function() return 0 end
        NPC.GetCurrentLevel    = function() return 1 end      -- level would give 1.0; proves stats win
        assert_true(math.abs(HV.live_mult(E, { E, P1, P2 }) - 1.5) < 1e-9, "stats ratio")
        Hero.GetStrengthTotal, Hero.GetAgilityTotal, Hero.GetIntellectTotal = s_str, s_agi, s_int
        NPC.GetCurrentLevel = s_cl
    end)
    it("fewer than 2 peers sampled -> 1.0", function()
        local s = snapshot()
        NPC.GetPlayerOwner = function() return nil end
        NPC.GetCurrentLevel = function(u) return (u == E) and 20 or nil end
        assert_eq(HV.live_mult(E, { E }), 1.0)
        restore(s)
    end)
    it("nil args -> 1.0", function()
        assert_eq(HV.live_mult(nil, { E }), 1.0)
        assert_eq(HV.live_mult(E, nil), 1.0)
    end)
end)

describe("lib/hero_value -- of (base x live_mult)", function()
    local E, P1, P2 = { id = "E" }, { id = "P1" }, { id = "P2" }
    it("of = base * mult", function()
        local s_un, s_po, s_cl = NPC.GetUnitName, NPC.GetPlayerOwner, NPC.GetCurrentLevel
        NPC.GetUnitName = function() return "npc_dota_hero_antimage" end   -- base 1.0 (Carry tag)
        NPC.GetPlayerOwner = function() return nil end
        local LV = { [E] = 18, [P1] = 12, [P2] = 12 }          -- mult 18/14
        NPC.GetCurrentLevel = function(u) return LV[u] end
        assert_true(math.abs(HV.of(E, { E, P1, P2 }) - (1.0 * 18/14)) < 1e-9, "of value")
        NPC.GetUnitName, NPC.GetPlayerOwner, NPC.GetCurrentLevel = s_un, s_po, s_cl
    end)
    it("nil enemy -> 0", function() assert_eq(HV.of(nil, { E }), 0) end)
    it("debug_reads returns raw networth/level for the eval log", function()
        local s_po, s_cl = NPC.GetPlayerOwner, NPC.GetCurrentLevel
        NPC.GetPlayerOwner = function() return nil end
        NPC.GetCurrentLevel = function() return 17 end
        local nw, lvl = HV.debug_reads(E)
        assert_true(nw == nil, "no networth -> nil")
        assert_eq(lvl, 17)
        NPC.GetPlayerOwner, NPC.GetCurrentLevel = s_po, s_cl
    end)
end)

describe("lib/hero_value -- best_cluster (D3b cluster value tie-break)", function()
    it("exact count tie -> higher value wins; pure = first max-count", function()
        local b, p = HV.best_cluster({ 3, 3 }, { 1.0, 2.0 })
        assert_eq(b, 2, "value breaks the count tie")
        assert_eq(p, 1, "pure pick = first max-count")
    end)
    it("strictly more bodies always wins, value ignored", function()
        local b, p = HV.best_cluster({ 4, 3 }, { 0.1, 9.0 })
        assert_eq(b, 1, "4 bodies beats 3 regardless of value")
        assert_eq(p, 1)
    end)
    it("full tie (equal count + equal value) -> first index", function()
        local b, p = HV.best_cluster({ 2, 2 }, { 1.0, 1.0 })
        assert_eq(b, 1)
        assert_eq(p, 1)
    end)
    it("value tie-break picks the higher-value cluster among three", function()
        local b, p = HV.best_cluster({ 2, 3, 3 }, { 5.0, 1.0, 2.0 })
        assert_eq(b, 3, "among the two 3-clusters, higher value (idx 3) wins")
        assert_eq(p, 2, "pure = first 3-cluster")
    end)
    it("single element", function()
        local b, p = HV.best_cluster({ 5 }, { 0.3 })
        assert_eq(b, 1); assert_eq(p, 1)
    end)
    it("empty -> nil, nil", function()
        local b, p = HV.best_cluster({}, {})
        assert_true(b == nil and p == nil, "empty is safe")
    end)
end)

local ItemSaves = require("lib.item_saves")

describe("lib/item_saves - cyclone_launch_decision", function()
    it("nil cp_t -> proceed (fire)", function()
        assert_eq(ItemSaves.cyclone_launch_decision(nil, false), "fire")
        assert_eq(ItemSaves.cyclone_launch_decision(nil, true), "fire")
    end)
    it("mid-cast (cp_t>-0.05) + marker -> defer", function()
        assert_eq(ItemSaves.cyclone_launch_decision(0.50, true), "defer")
    end)
    it("mid-cast + no marker -> instant", function()
        assert_eq(ItemSaves.cyclone_launch_decision(0.50, false), "instant")
    end)
    it("post-launch (cp_t<=-0.05) + marker -> fire", function()
        assert_eq(ItemSaves.cyclone_launch_decision(-0.20, true), "fire")
    end)
    it("post-launch + no marker -> skip", function()
        assert_eq(ItemSaves.cyclone_launch_decision(-0.20, false), "skip")
    end)
    it("boundary cp_t==-0.05 counts as post-launch", function()
        assert_eq(ItemSaves.cyclone_launch_decision(-0.05, true), "fire")
    end)
end)

describe("lib/item_saves - tier 1 bare casts", function()
    -- stub cfg that records the last issue call + whether a guard fired.
    local function mk_cfg(opts)
        opts = opts or {}
        local rec = { calls = {}, logs = {} }
        local cfg = {
            self_npc = function() return { idx = 1 } end,
            -- NOTE: `opts.no_item and nil or {..}` would be the Lua ternary
            -- trap (nil or X always yields X), so branch explicitly.
            item = function(_) if opts.no_item then return nil end; return { idx = 9 } end,
            -- mirror the real hero issue_* wrappers: no-op + false on a nil
            -- item handle (so builders that pass cfg.item(name) straight
            -- through get the same false-on-missing-item behavior).
            issue_self      = function(i, it) if not it then return false end; rec.calls[#rec.calls+1] = "self";      return true end,
            issue_target    = function(i, it, t) if not it then return false end; rec.calls[#rec.calls+1] = "target"; return true end,
            issue_position  = function(i, it, p) if not it then return false end; rec.calls[#rec.calls+1] = "position"; return true end,
            issue_no_target = function(i, it) if not it then return false end; rec.calls[#rec.calls+1] = "no_target"; return true end,
            tlog = function(_, name, _) rec.logs[#rec.logs+1] = name end,
            uname = function(_) return "x" end,
            dist_to = function(_) return 9999 end,
        }
        return cfg, rec
    end
    _G.__mk_cfg = mk_cfg  -- shared with later describe blocks

    it("BKB: not guarded -> no_target cast + save_fire_invoked log", function()
        local cfg, rec = mk_cfg()
        local m = ItemSaves.build(cfg)
        local ok = m.item_black_king_bar.fire("intent")
        assert_true(ok, "bkb fired")
        assert_eq(rec.calls[1], "no_target")
        assert_eq(rec.logs[1], "save_fire_invoked")
    end)
    it("Manta: bare no_target, NO log", function()
        local cfg, rec = mk_cfg()
        local m = ItemSaves.build(cfg)
        m.item_manta.fire("intent")
        assert_eq(rec.calls[1], "no_target")
        assert_eq(#rec.logs, 0, "manta must not log save_fire_invoked")
    end)
    it("Ethereal-self: self cast, NO log", function()
        local cfg, rec = mk_cfg()
        local m = ItemSaves.build(cfg)
        m.item_ethereal_blade_self.fire("intent")
        assert_eq(rec.calls[1], "self")
        assert_eq(#rec.logs, 0)
    end)
    it("missing item handle -> false, no cast", function()
        local cfg, rec = mk_cfg({ no_item = true })
        local m = ItemSaves.build(cfg)
        local ok = m.item_manta.fire("intent")
        assert_false(ok, "no item -> false")
        assert_eq(#rec.calls, 0)
    end)
end)

describe("lib/item_saves - lotus", function()
    local mk_cfg = _G.__mk_cfg
    it("gate true -> self cast", function()
        local cfg, rec = mk_cfg()
        cfg.lotus_gate = function(_) return true end
        local m = ItemSaves.build(cfg)
        local ok = m.item_lotus_orb.fire("intent", nil, "modifier_lion_finger_of_death")
        assert_true(ok)
        assert_eq(rec.calls[1], "self")
    end)
    it("gate false -> no cast, skip log", function()
        local cfg, rec = mk_cfg()
        cfg.lotus_gate = function(_) return false end
        local m = ItemSaves.build(cfg)
        local ok = m.item_lotus_orb.fire("intent", nil, "modifier_doom_bringer_doom")
        assert_false(ok)
        assert_eq(#rec.calls, 0)
        assert_eq(rec.logs[1], "lotus_dmg_gate_skip")
    end)
    it("no hook -> legacy default skips at full HP / unknown threat", function()
        local cfg, rec = mk_cfg()  -- no lotus_gate hook; stub HP = 1000/1000
        local m = ItemSaves.build(cfg)
        local ok = m.item_lotus_orb.fire("intent", nil, "modifier_unknown")
        assert_false(ok, "legacy 0.85 gate skips at full HP")
    end)
end)

describe("lib/item_saves - cyclones", function()
    local mk_cfg = _G.__mk_cfg
    it("WW guarded (already airborne) -> false", function()
        local cfg, rec = mk_cfg()
        NPC.HasModifier = function(_, m) return m == "modifier_wind_waker" end
        local m = ItemSaves.build(cfg)
        local ok = m.item_wind_waker.fire("intent", nil, nil)
        NPC.HasModifier = function() return false end  -- restore
        assert_false(ok)
        assert_eq(rec.logs[1], "save_fire_invoked")
    end)
    it("WW no gate, no target -> self cast + post_move", function()
        local cfg, rec = mk_cfg()
        local moved = { n = 0 }
        cfg.queue_post_move = function() moved.n = moved.n + 1 end
        local m = ItemSaves.build(cfg)
        local ok = m.item_wind_waker.fire("intent", nil, nil)
        assert_true(ok)
        assert_eq(rec.calls[1], "self")
        assert_eq(moved.n, 1, "WW must queue a post-airborne move")
    end)
    it("Eul no gate, no target -> self cast, NO post_move", function()
        local cfg, rec = mk_cfg()
        local moved = { n = 0 }
        cfg.queue_post_move = function() moved.n = moved.n + 1 end
        local m = ItemSaves.build(cfg)
        local ok = m.item_cyclone.fire("intent", nil, nil)
        assert_true(ok)
        assert_eq(rec.calls[1], "self")
        assert_eq(moved.n, 0, "Eul must NOT post-move")
    end)
    it("situational target present -> target cast + cyclone_harasser_target log", function()
        local cfg, rec = mk_cfg()
        cfg.cyclone_target = function() return { idx = 7 } end
        local m = ItemSaves.build(cfg)
        local ok = m.item_cyclone.fire("intent", { idx = 7 }, "lina_committed_attacker_ranged")
        assert_true(ok)
        assert_eq(rec.calls[1], "target")
        local found = false
        for _, n in ipairs(rec.logs) do if n == "cyclone_harasser_target" then found = true end end
        assert_true(found, "harasser-target log emitted")
    end)
    it("launch gate defer (mid-cast + marker) -> false + wait log", function()
        local cfg, rec = mk_cfg()
        cfg.armed_cp_t = function() return 0.50 end
        cfg.armed_threat_mod = function() return "modifier_sniper_assassinate" end
        NPC.HasModifier = function(_, m) return m == "modifier_sniper_assassinate" end
        local m = ItemSaves.build(cfg)
        local ok = m.item_wind_waker.fire("intent", nil, "modifier_sniper_assassinate")
        NPC.HasModifier = function() return false end
        assert_false(ok)
        local found = false
        for _, n in ipairs(rec.logs) do if n == "cyclone_wait_for_launch" then found = true end end
        assert_true(found, "wait-for-launch log emitted")
    end)
end)

describe("lib/item_saves - displacement", function()
    local mk_cfg = _G.__mk_cfg
    it("Force -> self_push delegated", function()
        local cfg = mk_cfg()
        local pushed = { n = 0 }
        cfg.self_push = function() pushed.n = pushed.n + 1; return true end
        local m = ItemSaves.build(cfg)
        local ok = m.item_force_staff.fire("intent", { idx = 3 })
        assert_true(ok)
        assert_eq(pushed.n, 1)
    end)
    it("Force no self_push hook -> bare self cast fallback", function()
        local cfg, rec = mk_cfg()
        local m = ItemSaves.build(cfg)
        local ok = m.item_force_staff.fire("intent", { idx = 3 })
        assert_true(ok)
        assert_eq(rec.calls[1], "self")
    end)
    it("Blink: recent damage broken -> false + skip log", function()
        local cfg, rec = mk_cfg()
        cfg.recent_damage = function(_) return 50 end
        cfg.compute_safe_dest = function() return nil, { x = 1, y = 2 } end
        local m = ItemSaves.build(cfg)
        local ok = m.item_blink.fire("intent", { idx = 3 })
        assert_false(ok)
        assert_eq(rec.logs[1], "blink_skip_broken")
    end)
    it("Blink: clean + landing -> position cast + escape log", function()
        local cfg, rec = mk_cfg()
        cfg.recent_damage = function(_) return 0 end
        cfg.compute_safe_dest = function() return nil, { x = 5, y = 6 } end
        local m = ItemSaves.build(cfg)
        local ok = m.item_blink.fire("intent", { idx = 3 })
        assert_true(ok)
        assert_eq(rec.calls[1], "position")
        assert_eq(rec.logs[1], "blink_escape")
    end)
    it("Pike: enemy in range -> target cast + after_target_fire", function()
        local cfg, rec = mk_cfg()
        cfg.pike_enemy_range = function() return 425 end
        cfg.dist_to = function(_) return 300 end       -- inside range
        local primed = { n = 0 }
        cfg.pike_after_target_fire = function(_) primed.n = primed.n + 1 end
        local m = ItemSaves.build(cfg)
        local ok = m.item_hurricane_pike.fire("intent", { idx = 3 }, nil)
        assert_true(ok)
        assert_eq(rec.calls[1], "target")
        assert_eq(primed.n, 1)
    end)
    it("Pike: enemy out of range -> self_push fallback", function()
        local cfg = mk_cfg()
        cfg.pike_enemy_range = function() return 425 end
        cfg.dist_to = function(_) return 900 end        -- out of range
        local pushed = { n = 0 }
        cfg.self_push = function() pushed.n = pushed.n + 1; return true end
        local m = ItemSaves.build(cfg)
        local ok = m.item_hurricane_pike.fire("intent", { idx = 3 }, nil)
        assert_true(ok)
        assert_eq(pushed.n, 1)
    end)
end)

describe("lib/item_saves -- expansion: diffusal blade", function()
    local mk_cfg = _G.__mk_cfg
    it("enemy in range -> target cast", function()
        local cfg, rec = mk_cfg()
        cfg.dist_to = function(_) return 400 end       -- inside 600
        local m = ItemSaves.build(cfg)
        assert_eq(m.item_diffusal_blade.short, "diffusal")
        assert_true(m.item_diffusal_blade.fire("intent", { idx = 3 }))
        assert_eq(rec.calls[1], "target")
    end)
    it("enemy out of range -> no cast", function()
        local cfg, rec = mk_cfg()
        cfg.dist_to = function(_) return 900 end        -- outside 600
        local m = ItemSaves.build(cfg)
        assert_false(m.item_diffusal_blade.fire("intent", { idx = 3 }))
        assert_eq(#rec.calls, 0)
    end)
    it("no caster -> no cast", function()
        local cfg, rec = mk_cfg()
        local m = ItemSaves.build(cfg)
        assert_false(m.item_diffusal_blade.fire("intent", nil))
        assert_eq(#rec.calls, 0)
    end)
end)

describe("lib/item_saves -- expansion: blink variants", function()
    local mk_cfg = _G.__mk_cfg
    for _, c in ipairs({ { key = "item_swift_blink",        short = "swiftblink" },
                         { key = "item_arcane_blink",       short = "arcaneblink" },
                         { key = "item_overwhelming_blink", short = "overwhelmingblink" } }) do
        it(c.key .. " -> position cast + escape log", function()
            local cfg, rec = mk_cfg()
            cfg.recent_damage = function(_) return 0 end
            cfg.compute_safe_dest = function() return nil, { x = 5, y = 6 } end
            local m = ItemSaves.build(cfg)
            assert_eq(m[c.key].short, c.short)
            assert_true(m[c.key].fire("intent", { idx = 3 }))
            assert_eq(rec.calls[1], "position")
            assert_eq(rec.logs[1], "blink_escape")
        end)
    end
    it("item_blink still works (default opts)", function()
        local cfg, rec = mk_cfg()
        cfg.recent_damage = function(_) return 0 end
        cfg.compute_safe_dest = function() return nil, { x = 1, y = 2 } end
        local m = ItemSaves.build(cfg)
        assert_eq(m.item_blink.short, "blink")
        assert_true(m.item_blink.fire("intent", { idx = 3 }))
        assert_eq(rec.calls[1], "position")
    end)
end)

describe("lib/item_saves -- expansion: UNIT_TARGET self", function()
    local mk_cfg = _G.__mk_cfg
    for _, c in ipairs({ { key = "item_solar_crest", short = "solar" },
                         { key = "item_disperser",   short = "disperser" } }) do
        it(c.key .. " -> self cast", function()
            local cfg, rec = mk_cfg()
            local m = ItemSaves.build(cfg)
            assert_eq(m[c.key].short, c.short)
            assert_true(m[c.key].fire("intent"))
            assert_eq(rec.calls[1], "self")
        end)
        it(c.key .. " missing item -> false", function()
            local cfg, rec = mk_cfg({ no_item = true })
            local m = ItemSaves.build(cfg)
            assert_false(m[c.key].fire("intent"))
            assert_eq(#rec.calls, 0)
        end)
    end
end)

describe("lib/item_saves -- expansion: NO_TARGET bare casts", function()
    local mk_cfg = _G.__mk_cfg
    local cases = {
        { key = "item_ghost",          short = "ghost" },
        { key = "item_satanic",        short = "satanic" },
        { key = "item_pipe",           short = "pipe" },
        { key = "item_crimson_guard",  short = "crimson" },
        { key = "item_blade_mail",     short = "blademail" },
        { key = "item_phase_boots",    short = "phase" },
    }
    for _, c in ipairs(cases) do
        it(c.key .. " -> no_target cast, short=" .. c.short, function()
            local cfg, rec = mk_cfg()
            local m = ItemSaves.build(cfg)
            assert_true(m[c.key] ~= nil, c.key .. " builder missing")
            assert_eq(m[c.key].short, c.short)
            local ok = m[c.key].fire("intent")
            assert_true(ok)
            assert_eq(rec.calls[1], "no_target")
            assert_eq(#rec.logs, 0, c.key .. " must be silent (no save_fire_invoked)")
        end)
        it(c.key .. " missing item -> false", function()
            local cfg, rec = mk_cfg({ no_item = true })
            local m = ItemSaves.build(cfg)
            assert_false(m[c.key].fire("intent"))
            assert_eq(#rec.calls, 0)
        end)
    end
end)

describe("lib/threat_data -- pipe name fix", function()
    local function scan_for(needle)
        local hits = 0
        for _, tbl in ipairs({ TD.RECOMMENDED_SAVES, TD.CATEGORY_CHAINS }) do
            for _, chain in pairs(tbl or {}) do
                if type(chain) == "table" then
                    for _, name in ipairs(chain) do
                        if name == needle then hits = hits + 1 end
                    end
                end
            end
        end
        return hits
    end
    it("the dead item_pipe_of_insight name is gone", function()
        assert_eq(scan_for("item_pipe_of_insight"), 0)
    end)
    it("real item_pipe is referenced instead", function()
        assert_true(scan_for("item_pipe") > 0, "item_pipe missing from chains")
    end)
end)

----------------------------------------------------------------------------
-- v0.5.114 precise charge-ramp kinematics (lib/threat_data.lua)
----------------------------------------------------------------------------

describe("lib/threat_data -- RampTravel / RampImpactT (v0.5.114)", function()
    local function near(got, want, tol, msg)
        assert_true(math.abs(got - want) <= (tol or 0.5),
                    (msg or "near") .. ": got " .. tostring(got)
                    .. ", want " .. tostring(want))
    end
    it("constant speed (accel 0) -> live * T", function()
        near(TD.RampTravel(400, 0, 0, 2.0), 800)
    end)
    it("full-ramp window integrates 0.5*a*t^2", function()
        -- lvl-4 Bara mid-ramp: live 556, accel 212.5, 1.5s ramp left, 0.95s lead
        near(TD.RampTravel(556, 212.5, 1.5, 0.95), 624.1, 1.0)
    end)
    it("ramp ending mid-window goes constant after rem", function()
        -- 0.4s of ramp left, then constant at live + accel*0.4
        near(TD.RampTravel(556, 212.5, 0.4, 0.95), 591.9, 1.0)
    end)
    it("rem 0 -> already at peak, constant", function()
        near(TD.RampTravel(700, 212.5, 0, 1.0), 700)
    end)
    it("horizon 0 -> 0", function()
        assert_eq(TD.RampTravel(556, 212.5, 1.5, 0), 0)
    end)
    it("RampImpactT constant-speed inverse", function()
        near(TD.RampImpactT(500, 0, 0, 1000), 2.0, 0.001)
    end)
    it("RampImpactT inverts RampTravel inside the ramp", function()
        local d = TD.RampTravel(556, 212.5, 1.5, 0.6)
        near(TD.RampImpactT(556, 212.5, 1.5, d), 0.6, 0.001)
    end)
    it("RampImpactT inverts RampTravel past the ramp", function()
        local d = TD.RampTravel(556, 212.5, 0.5, 2.0)
        near(TD.RampImpactT(556, 212.5, 0.5, d), 2.0, 0.001)
    end)
    it("dist 0 -> 0; dead inputs -> nil", function()
        assert_eq(TD.RampImpactT(556, 212.5, 1.5, 0), 0)
        assert_eq(TD.RampImpactT(0, 0, 0, 500), nil)
    end)
end)

describe("lib/threat_data -- ChargeRampKinematics (v0.5.114)", function()
    local ENTRY = {
        ramp_accel = 213, ramp_windup_s = 1.5, speed_fallback = 700,
        kv_ability = "spirit_breaker_charge_of_darkness",
    }
    local KV = function(ab, key, fb)
        return ({ movement_speed = 425, min_movespeed_bonus_pct = 25,
                  windup_time = 1.5 })[key] or fb
    end
    it("KV path: per-level accel from movement_speed * 0.75 / windup", function()
        NPC.GetMoveSpeed = function() return 556 end
        NPC.GetAbility   = function() return { ab = true } end
        local live, accel, rem = TD.ChargeRampKinematics(ENTRY, { idx = 1 }, KV, 0.5)
        assert_eq(live, 556)
        assert_true(math.abs(accel - 212.5) < 0.1, "accel from KV")
        assert_true(math.abs(rem - 1.0) < 0.001, "rem = windup - elapsed")
    end)
    it("no kv_lookup -> entry.ramp_accel fallback, unknown elapsed -> full windup", function()
        NPC.GetMoveSpeed = function() return 556 end
        local live, accel, rem = TD.ChargeRampKinematics(ENTRY, { idx = 1 }, nil, nil)
        assert_eq(live, 556)
        assert_eq(accel, 213)
        assert_true(math.abs(rem - 1.5) < 0.001, "worst-case still-ramping")
    end)
    it("elapsed past windup -> rem clamps to 0", function()
        NPC.GetMoveSpeed = function() return 740 end
        local _, _, rem = TD.ChargeRampKinematics(ENTRY, { idx = 1 }, KV, 3.0)
        assert_eq(rem, 0)
    end)
end)

----------------------------------------------------------------------------
-- v0.5.110 chain composition (lib/defense.lua)
----------------------------------------------------------------------------

local Defense = require("lib.defense")

describe("lib/defense -- ShouldDeferDodge (Note-1)", function()
    it("immediate save ready -> no defer (Ghost/E-blade fires now)", function()
        assert_false(Defense.ShouldDeferDodge(true, 1000, 450))
        assert_false(Defense.ShouldDeferDodge(true, 10, 450))
    end)
    it("no immediate + HP at/above floor -> defer (accept first strike)", function()
        assert_true(Defense.ShouldDeferDodge(false, 450, 450))
        assert_true(Defense.ShouldDeferDodge(false, 451, 450))
    end)
    it("no immediate + HP below floor -> no defer (dodge at cast to survive)", function()
        assert_false(Defense.ShouldDeferDodge(false, 449, 450))
    end)
    it("nil hp defaults 0 -> no defer", function()
        assert_false(Defense.ShouldDeferDodge(false, nil, 450))
    end)
end)

describe("lib/defense -- ComposeChain truth table", function()
    local function chain_eq(got, want)
        assert_eq(#got, #want, "length")
        for i = 1, #want do assert_eq(got[i], want[i], "slot " .. i) end
    end
    it("head anchor -> position 1", function()
        chain_eq(Defense.ComposeChain({ "a", "b", "c" },
                 { { save = "x", anchor = "head" } }, nil),
                 { "x", "a", "b", "c" })
    end)
    it("tail anchor -> appended", function()
        chain_eq(Defense.ComposeChain({ "a", "b", "c" },
                 { { save = "x", anchor = "tail" } }, nil),
                 { "a", "b", "c", "x" })
    end)
    it("before=b -> immediately before b", function()
        chain_eq(Defense.ComposeChain({ "a", "b", "c" },
                 { { save = "x", anchor = { before = "b" } } }, nil),
                 { "a", "x", "b", "c" })
    end)
    it("after=b -> immediately after b", function()
        chain_eq(Defense.ComposeChain({ "a", "b", "c" },
                 { { save = "x", anchor = { after = "b" } } }, nil),
                 { "a", "b", "x", "c" })
    end)
    it("before target absent -> tail (never dropped)", function()
        chain_eq(Defense.ComposeChain({ "a", "b" },
                 { { save = "x", anchor = { before = "zz" } } }, nil),
                 { "a", "b", "x" })
    end)
    it("after target absent -> tail (never dropped)", function()
        chain_eq(Defense.ComposeChain({ "a", "b" },
                 { { save = "x", anchor = { after = "zz" } } }, nil),
                 { "a", "b", "x" })
    end)
    it("nil anchor -> tail", function()
        chain_eq(Defense.ComposeChain({ "a" }, { { save = "x" } }, nil),
                 { "a", "x" })
    end)
    it("exclusion removes a backbone item", function()
        chain_eq(Defense.ComposeChain({ "a", "b", "c" }, nil, { b = true }),
                 { "a", "c" })
    end)
    it("exclusion naming an absent item is a no-op", function()
        chain_eq(Defense.ComposeChain({ "a", "b" }, nil, { zz = true }),
                 { "a", "b" })
    end)
    it("dedupe first-wins: head-injecting an existing item moves it", function()
        chain_eq(Defense.ComposeChain({ "a", "b", "c" },
                 { { save = "b", anchor = "head" } }, nil),
                 { "b", "a", "c" })
    end)
    it("multi-injection: later anchor can reference an earlier injection", function()
        chain_eq(Defense.ComposeChain({ "a", "b" },
                 { { save = "x", anchor = "head" },
                   { save = "y", anchor = { after = "x" } } }, nil),
                 { "x", "y", "a", "b" })
    end)
    it("nil injections + nil exclusions -> backbone copy, new table", function()
        local backbone = { "a", "b" }
        local got = Defense.ComposeChain(backbone, nil, nil)
        chain_eq(got, { "a", "b" })
        assert_false(rawequal(got, backbone), "must be a NEW table")
    end)
    it("never mutates the backbone", function()
        local backbone = { "a", "b", "c" }
        Defense.ComposeChain(backbone,
            { { save = "x", anchor = "head" } }, { b = true })
        chain_eq(backbone, { "a", "b", "c" })
    end)
    it("pre-existing backbone duplicate is deduped", function()
        chain_eq(Defense.ComposeChain({ "a", "b", "a" }, nil, nil), { "a", "b" })
    end)
    it("empty backbone + injection -> injection only", function()
        chain_eq(Defense.ComposeChain({},
                 { { save = "x", anchor = "head" } }, nil), { "x" })
    end)
end)

describe("lib/defense -- ResolveSaveOrder tier 3 (composed)", function()
    local TD_STUB = {
        CategoryOf = function(mod)
            return ({ modifier_stub_gap   = "close_gap",
                      modifier_stub_burst = "targeted_burst",
                      modifier_stub_weird = "weird_cat" })[mod]
        end,
        CATEGORY_CHAINS = {
            close_gap      = { "item_p", "item_f", "item_g" },
            targeted_burst = { "item_l", "item_e", "item_pi" },
        },
    }
    local PATCHED_CLOSE_GAP = { "item_patched" }
    local function mk(opts)
        opts = opts or {}
        return Defense.New {
            anim_save_overrides = {},
            hero_save_overrides = opts.hero or {},
            patched_recommended = opts.recommended or {},
            category_chains     = { close_gap = PATCHED_CLOSE_GAP,
                                    weird_cat = { "item_weird" } },
            default_chain       = { "item_default" },
            TD                  = TD_STUB,
            tlog                = function() end,
            tlog_level          = function() return 0 end,
            now                 = function() return 0 end,
            ability_injections  = opts.injections,
            exclusions          = opts.exclusions,
        }
    end
    local INJ = {
        { save = "hero_w",  categories = { "close_gap" },      anchor = "head" },
        { save = "hero_fc", categories = { "targeted_burst" }, anchor = "tail" },
    }
    it("composed: injection at head + raw backbone, authoritative", function()
        local d = mk({ injections = INJ })
        local chain, auth = d:ResolveSaveOrder("modifier_stub_gap", nil, nil, nil)
        assert_true(auth, "composed must be authoritative")
        assert_eq(chain[1], "hero_w")
        assert_eq(chain[2], "item_p")
        assert_eq(chain[4], "item_g")
        assert_eq(#chain, 4)
    end)
    it("exclusion removes the item from the composed chain", function()
        local d = mk({ injections = INJ,
                       exclusions = { targeted_burst = { item_e = true } } })
        local chain = d:ResolveSaveOrder("modifier_stub_burst", nil, nil, nil)
        for i = 1, #chain do
            assert_true(chain[i] ~= "item_e", "item_e must be excluded")
        end
        assert_eq(chain[#chain], "hero_fc")
        assert_eq(#chain, 3)
    end)
    it("categories filter: close_gap injection absent from burst chain", function()
        local d = mk({ injections = INJ })
        local chain = d:ResolveSaveOrder("modifier_stub_burst", nil, nil, nil)
        for i = 1, #chain do
            assert_true(chain[i] ~= "hero_w", "hero_w is close_gap-only")
        end
    end)
    it("categories='*' applies everywhere", function()
        local d = mk({ injections = {
            { save = "hero_any", categories = "*", anchor = "tail" } } })
        local c1 = d:ResolveSaveOrder("modifier_stub_gap", nil, nil, nil)
        local c2 = d:ResolveSaveOrder("modifier_stub_burst", nil, nil, nil)
        assert_eq(c1[#c1], "hero_any")
        assert_eq(c2[#c2], "hero_any")
    end)
    it("NO composition cfg -> tier-4 chain IDENTITY, non-authoritative", function()
        local d = mk({})
        local chain, auth = d:ResolveSaveOrder("modifier_stub_gap", nil, nil, nil)
        assert_true(rawequal(chain, PATCHED_CLOSE_GAP),
                    "tier-4 identity (Sniper additivity proof)")
        assert_false(auth, "tier 4 is non-authoritative")
    end)
    it("hero_save_overrides still beats tier 3", function()
        local OVERRIDE = { "item_override" }
        local d = mk({ injections = INJ,
                       hero = { modifier_stub_gap = OVERRIDE } })
        local chain, auth = d:ResolveSaveOrder("modifier_stub_gap", nil, nil, nil)
        assert_true(rawequal(chain, OVERRIDE), "tier 2 wins")
        assert_true(auth, "overrides stay authoritative")
    end)
    it("patched_recommended is bypassed when composition is on", function()
        local d = mk({ injections = INJ,
                       recommended = { modifier_stub_gap = { "item_reco" } } })
        local chain = d:ResolveSaveOrder("modifier_stub_gap", nil, nil, nil)
        assert_eq(chain[1], "hero_w", "composed wins over lib_patched")
    end)
    it("category_hint alone (nil threat_mod) composes", function()
        local d = mk({ injections = INJ })
        local chain, auth = d:ResolveSaveOrder(nil, "close_gap", nil, nil)
        assert_eq(chain[1], "hero_w")
        assert_true(auth)
    end)
    it("category without a lib backbone falls through to tier 4/5", function()
        local d = mk({ injections = INJ })
        local chain, auth = d:ResolveSaveOrder("modifier_stub_weird", nil, nil, nil)
        assert_eq(chain[1], "item_weird", "falls to c.category_chains")
        assert_false(auth)
    end)
    it("memoized: same (category, threat) returns the same table", function()
        local d = mk({ injections = INJ })
        local c1 = d:ResolveSaveOrder("modifier_stub_gap", nil, nil, nil)
        local c2 = d:ResolveSaveOrder("modifier_stub_gap", nil, nil, nil)
        assert_true(rawequal(c1, c2), "same threat+category should reuse cached table")
    end)
end)

describe("lib/defense -- composition proof cases (spec sec 5 shapes)", function()
    -- Pins the CHAIN_COMPOSITION_DESIGN.md sec 5 compositions against the
    -- REAL lib close_gap backbone, as pure ComposeChain regression tests.
    -- NOTE: v0.5.110.1 reverted Lina's LIVE committed chains to hand-curated
    -- literals (lethal-only item rule; user demo feedback), so these no
    -- longer mirror Lina's runtime chains -- they remain the canonical
    -- ComposeChain-over-real-data pins. The deferred backbone-enrichment
    -- follow-up will add items to TD.CATEGORY_CHAINS; when it does, update
    -- these exact lists DELIBERATELY in the same change.
    local function chain_eq(got, want)
        assert_eq(#got, #want, "length")
        for i = 1, #want do assert_eq(got[i], want[i], "slot " .. i) end
    end
    -- v0.5.x: derive expected from the LIVE backbone so enrichment growth does
    -- not re-break these. They pin the ComposeChain anchor/dedupe behavior, not
    -- a frozen item list.
    it("committed melee = W head + full close_gap backbone (in order)", function()
        local bb = TD.CATEGORY_CHAINS.close_gap
        local want = { "lina_w_anti_gap" }
        for i = 1, #bb do want[#want + 1] = bb[i] end  -- W not in bb: no dedupe
        chain_eq(
            Defense.ComposeChain(bb, { { save = "lina_w_anti_gap", anchor = "head" } }, nil),
            want)
    end)
    it("committed ranged = cyclones to head over the same backbone", function()
        local bb = TD.CATEGORY_CHAINS.close_gap
        -- cyclone + WW injected at head; their original backbone slots dedupe away
        local want = { "item_cyclone", "item_wind_waker" }
        for i = 1, #bb do
            local it = bb[i]
            if it ~= "item_cyclone" and it ~= "item_wind_waker" then want[#want + 1] = it end
        end
        chain_eq(
            Defense.ComposeChain(bb,
                { { save = "item_cyclone",    anchor = "head" },
                  { save = "item_wind_waker", anchor = { after = "item_cyclone" } } },
                nil),
            want)
    end)
    it("committed base = backbone copy (displacement-first, no injection)", function()
        local got = Defense.ComposeChain(TD.CATEGORY_CHAINS.close_gap, nil, nil)
        chain_eq(got, TD.CATEGORY_CHAINS.close_gap)
        assert_false(rawequal(got, TD.CATEGORY_CHAINS.close_gap),
                     "copy, not the shared lib table")
    end)
    it("targeted_burst + FC tail injection: Pipe present, FC last", function()
        local got = Defense.ComposeChain(TD.CATEGORY_CHAINS.targeted_burst,
            { { save = "lina_flame_cloak", anchor = "tail" } },
            { item_ethereal_blade_self = true })
        assert_eq(got[#got], "lina_flame_cloak")
        local has_pipe = false
        for i = 1, #got do if got[i] == "item_pipe" then has_pipe = true end end
        assert_true(has_pipe, "item_pipe must be in the composed burst chain")
    end)
end)

describe("close-gap redesign Slice 1 -- composed close_gap chain", function()
    local function has(set, k)
        for _, x in ipairs(set) do if x == k then return true end end
        return false
    end
    -- Mirrors ResolveSaveOrder tier-3: SaveCounters-filter the RAW close_gap
    -- backbone, then inject lina_w_anti_gap at head (Lina CH.ABILITY_INJECTIONS).
    local function composed_close_gap(mod)
        local bb = TD.CATEGORY_CHAINS.close_gap
        local filtered = {}
        for i = 1, #bb do
            if TD.SaveCounters(bb[i], mod) then filtered[#filtered + 1] = bb[i] end
        end
        return Defense.ComposeChain(filtered,
            { { save = "lina_w_anti_gap", anchor = "head" } }, nil)
    end

    it("item_blink is in the close_gap backbone", function()
        assert_true(has(TD.CATEGORY_CHAINS.close_gap, "item_blink"),
            "close_gap backbone must carry item_blink (leap gap-closers escape via blink)")
    end)
    it("item_glimmer_cape is in the close_gap backbone", function()
        assert_true(has(TD.CATEGORY_CHAINS.close_gap, "item_glimmer_cape"),
            "close_gap backbone must carry item_glimmer_cape (physical-chase invis)")
    end)

    -- PHYSICAL CHASE (PA, delivery=attack): facts give ghost/invis/displacement,
    -- correctly drop BKB. The axis withholds blink from attack-delivery (decided),
    -- so the composed chain has NO blink -- documented here.
    it("PA composed: W head + ghost/glimmer/invis/displacement, drops bkb AND blink", function()
        local c = composed_close_gap("modifier_phantom_assassin_phantom_strike_target")
        assert_eq(c[1], "lina_w_anti_gap", "W heads close_gap")
        for _, k in ipairs({ "item_ghost", "item_glimmer_cape", "item_silver_edge",
                             "item_invis_sword", "item_force_staff", "item_hurricane_pike" }) do
            assert_true(has(c, k), "PA chain should keep " .. k)
        end
        assert_false(has(c, "item_black_king_bar"), "PA is physical -> drop BKB")
        assert_false(has(c, "item_blink"),
            "axis withholds blink from attack-delivery (charge re-homes rule is delivery-scoped)")
    end)

    -- LEAP (Slark): derives invuln + displacement_blink -> keeps airborne + blink.
    it("Slark composed: W head + airborne (WW/cyclone) + blink + displacement", function()
        local c = composed_close_gap("modifier_slark_pounce")
        assert_eq(c[1], "lina_w_anti_gap", "W heads close_gap")
        for _, k in ipairs({ "item_cyclone", "item_wind_waker", "item_blink",
                             "item_force_staff", "item_hurricane_pike", "item_black_king_bar" }) do
            assert_true(has(c, k), "Slark chain should keep " .. k)
        end
    end)

    -- CHARGE (Bara, homing_charge): axis withholds invuln (latched) AND blink
    -- (re-homes) -> composed loses the validated WW airborne intercept. This is
    -- why Bara/Tusk STAY overrides (kept mechanical exceptions, not migrated).
    it("Bara composed LACKS airborne+blink -> documents why charges stay overrides", function()
        local c = composed_close_gap("modifier_spirit_breaker_charge_of_darkness")
        assert_false(has(c, "item_wind_waker"),
            "charge: latched -> no invuln -> WW filtered -> composed cannot reproduce the validated intercept")
        assert_false(has(c, "item_cyclone"), "ditto (Eul/cyclone)")
        assert_false(has(c, "item_blink"), "charge re-homes on blink (axis decision)")
        for _, k in ipairs({ "item_black_king_bar", "item_force_staff", "item_hurricane_pike" }) do
            assert_true(has(c, k), "Bara composed still keeps " .. k)
        end
    end)
end)

describe("lib/defense -- v0.5.127 CD-aware lock release", function()
    -- White-box test of the general re-engage structure: a HELD in-flight lock
    -- is released early (before its resolved TTL) once the fired save is
    -- confirmed spent, so a re-engage dispatch advances to the NEXT ready save.
    -- We drive TryAcquireLock directly and stamp save_short the way Dispatch
    -- does on a successful fire (the lock entry is a public field on the
    -- dispatcher object). ent indices are plain numbers (ent_idx treats numeric
    -- inputs as already-an-index).
    local function make_disp(item_on_cd, coalesce, giveup)
        local clock = { t = 0 }
        local d = Defense.New({
            tlog               = function() end,
            now                = function() return clock.t end,
            entity_index       = function(e) return e end,
            item_on_cd         = item_on_cd,   -- nil => opt-out (full TTL)
            lock_cd_coalesce_s = coalesce,     -- nil => lib default 0.30
            lock_cd_giveup_s   = giveup,       -- nil => lib default 0.60
        })
        return d, clock
    end
    -- Acquire a lock at t=0 and stamp save_short like Dispatch's success path.
    local function armed(d, target, mod, caster, ttl, save_short)
        d:TryAcquireLock(target, mod, caster, ttl)
        d.in_flight_locks[target][mod][caster].save_short = save_short
    end

    it("opt-out (no item_on_cd): a live lock blocks for its full TTL", function()
        local d, clock = make_disp(nil)
        armed(d, 1, "modifier_x", 2, 2.0, "item_hurricane_pike")
        clock.t = 0.5  -- well past any coalesce floor, far short of the 2.0 TTL
        local ok = d:TryAcquireLock(1, "modifier_x", 2, 2.0)
        assert_false(ok, "without item_on_cd the lock holds for the resolved TTL (v0.5.40)")
    end)

    it("within the coalesce floor: blocks even when on CD (single-spend)", function()
        local d, clock = make_disp(function() return true end)
        armed(d, 1, "modifier_x", 2, 2.0, "item_hurricane_pike")
        clock.t = 0.10  -- < 0.30 floor: same-instance multi-path dispatch
        local ok = d:TryAcquireLock(1, "modifier_x", 2, 2.0)
        assert_false(ok, "must block within the coalesce floor to coalesce one instance")
    end)

    it("past floor + save confirmed on CD: releases so the re-engage proceeds", function()
        local d, clock = make_disp(function() return true end)
        armed(d, 1, "modifier_x", 2, 2.0, "item_hurricane_pike")
        clock.t = 0.35  -- > 0.30 floor, spent
        local ok = d:TryAcquireLock(1, "modifier_x", 2, 2.0)
        assert_true(ok, "a spent save past the floor releases (chain skips it, fires next)")
    end)

    it("past floor, not on CD, within give-up: still blocks (confirming the cast)", function()
        local d, clock = make_disp(function() return false end)
        armed(d, 1, "modifier_x", 2, 2.0, "item_hurricane_pike")
        clock.t = 0.40  -- > floor 0.30, < give-up 0.60
        local ok = d:TryAcquireLock(1, "modifier_x", 2, 2.0)
        assert_false(ok, "not-yet-on-CD within the give-up window holds to confirm the fire")
    end)

    it("past give-up + still not on CD: releases for re-attempt", function()
        local d, clock = make_disp(function() return false end)
        armed(d, 1, "modifier_x", 2, 2.0, "item_hurricane_pike")
        clock.t = 0.65  -- > give-up 0.60
        local ok = d:TryAcquireLock(1, "modifier_x", 2, 2.0)
        assert_true(ok, "never-on-CD past the give-up window releases so the chain re-attempts")
    end)

    it("thunk save_short keeps the full TTL (not CD-checkable)", function()
        local d, clock = make_disp(function() return true end)
        armed(d, 1, "modifier_x", 2, 2.0, "thunk")
        clock.t = 0.50
        local ok = d:TryAcquireLock(1, "modifier_x", 2, 2.0)
        assert_false(ok, "offensive thunk fires are unnameable -> full TTL")
    end)

    it("TTL backstop still frees the lock regardless of the CD logic", function()
        local d, clock = make_disp(function() return false end)
        armed(d, 1, "modifier_x", 2, 0.4, "item_hurricane_pike")
        clock.t = 0.50  -- past fire_t+ttl (0.4): lazy expiry frees it
        local ok = d:TryAcquireLock(1, "modifier_x", 2, 2.0)
        assert_true(ok, "an expired lock frees via lazy expiry independent of item_on_cd")
    end)

    it("custom windows are honoured (coalesce 0.5 / give-up 1.0)", function()
        local d, clock = make_disp(function() return true end, 0.5, 1.0)
        armed(d, 1, "modifier_x", 2, 3.0, "item_hurricane_pike")
        clock.t = 0.40  -- < custom 0.5 floor, even though on CD
        assert_false(d:TryAcquireLock(1, "modifier_x", 2, 3.0), "below custom floor: hold")
        clock.t = 0.55  -- > custom floor, on CD
        assert_true(d:TryAcquireLock(1, "modifier_x", 2, 3.0), "above custom floor + on CD: release")
    end)
end)

describe("SAVE_KIND dispel vocabulary", function()
    local TD = require("lib.threat_data")
    it("strong-dispel items carry dispel_strong, not dispel_basic", function()
        for _, item in ipairs({ "item_aeon_disk", "item_disperser" }) do
            local kinds = TD.SAVE_KIND[item]
            local has_strong, has_basic = false, false
            for _, k in ipairs(kinds) do
                if k == "dispel_strong" then has_strong = true end
                if k == "dispel_basic" then has_basic = true end
            end
            assert_true(has_strong, item .. " must carry dispel_strong")
            assert_false(has_basic, item .. " must NOT carry dispel_basic")
        end
    end)
    it("basic-dispel items keep dispel_basic only", function()
        for _, item in ipairs({ "item_manta", "item_diffusal_blade", "item_satanic" }) do
            local kinds = TD.SAVE_KIND[item]
            local has_basic = false
            for _, k in ipairs(kinds) do if k == "dispel_basic" then has_basic = true end end
            assert_true(has_basic, item .. " must keep dispel_basic")
        end
    end)
end)

describe("DeriveCounters magical/pure/universal", function()
    local TD = require("lib.threat_data")
    local function has(set, k) for _,x in ipairs(set) do if x==k then return true end end return false end
    it("no-damage magical disable -> magic_immune via school, not damage_type", function()
        local d = TD.DeriveCounters({ school="magical", damage_type="none",
            pierces_spell_immunity=false, dispellable="strong", delivery="spell",
            targeted=true, timing="pre_cast", primary_harm="disable" })
        assert_true(has(d,"magic_immune"), "BKB blocks the disable application")
        assert_false(has(d,"magic_barrier"), "no damage -> no barrier")
    end)
    it("pure + pierces -> no magic_immune, no barrier (Doom class)", function()
        local d = TD.DeriveCounters({ school="pure", damage_type="pure",
            pierces_spell_immunity=true, dispellable="none", delivery="spell",
            targeted=true, timing="pre_cast", primary_harm="disable" })
        assert_false(has(d,"magic_immune"), "Doom pierces BKB")
        assert_false(has(d,"magic_barrier"), "pure ignores barrier")
    end)
    it("partial pierce still gets magic_immune", function()
        local d = TD.DeriveCounters({ school="magical", damage_type="magical",
            pierces_spell_immunity="partial", dispellable="none", delivery="homing_charge",
            targeted=false, timing="pre_cast", primary_harm="disable" })
        assert_true(has(d,"magic_immune"), "only literal true suppresses")
    end)
    it("magic_barrier only when primary_harm == damage", function()
        local nuke = TD.DeriveCounters({ school="magical", damage_type="magical",
            pierces_spell_immunity=false, dispellable="none", delivery="spell",
            targeted=true, timing="pre_cast", primary_harm="damage" })
        assert_true(has(nuke,"magic_barrier"))
        local disable = TD.DeriveCounters({ school="magical", damage_type="magical",
            pierces_spell_immunity=false, dispellable="none", delivery="homing_charge",
            targeted=false, timing="pre_cast", primary_harm="disable" })
        assert_false(has(disable,"magic_barrier"), "token-damage disable: no barrier")
    end)
end)

describe("DeriveCounters physical/dispel/reflect", function()
    local TD = require("lib.threat_data")
    local function has(set, k) for _,x in ipairs(set) do if x==k then return true end end return false end
    it("physical attack chase -> phys_immune, damage_block, invis, self-push", function()
        local d = TD.DeriveCounters({ school="physical", damage_type="physical",
            pierces_spell_immunity=false, dispellable="basic", delivery="attack",
            targeted=false, timing="pre_cast", primary_harm="damage",
            forced_leash=false, debuff_sticks_to_self=false })
        for _,k in ipairs({"physical_immune","damage_block","invis","displacement_far","displacement_perp"}) do
            assert_true(has(d,k), "expected "..k)
        end
        assert_false(has(d,"damage_return"), "damage_return is per-entry opt-in only")
    end)
    it("forced_leash suppresses invis + displacement (Duel)", function()
        local d = TD.DeriveCounters({ school="physical", damage_type="physical",
            pierces_spell_immunity=false, dispellable="none", delivery="attack",
            targeted=false, timing="pre_cast", primary_harm="damage", forced_leash=true })
        assert_false(has(d,"invis")); assert_false(has(d,"displacement_far"))
    end)
    it("strong-only dispel -> dispel_strong only; basic -> both", function()
        local strong = TD.DeriveCounters({ school="magical", damage_type="none",
            pierces_spell_immunity=false, dispellable="strong", delivery="spell",
            targeted=true, timing="reactive", primary_harm="disable" })
        assert_true(has(strong,"dispel_strong")); assert_false(has(strong,"dispel_basic"))
        local basic = TD.DeriveCounters({ school="physical", damage_type="physical",
            pierces_spell_immunity=false, dispellable="basic", delivery="channel",
            targeted=false, timing="mid_channel", primary_harm="disable" })
        assert_true(has(basic,"dispel_basic")); assert_true(has(basic,"dispel_strong"))
    end)
    it("dispel suppressed at at_impact (debuff not present yet)", function()
        local d = TD.DeriveCounters({ school="magical", damage_type="magical",
            pierces_spell_immunity=false, dispellable="strong", delivery="projectile_line",
            targeted=false, timing="at_impact", primary_harm="damage" })
        assert_false(has(d,"dispel_strong"), "no debuff at impact window")
    end)
    it("reflect only for cast-time single-target spell harm", function()
        local yes = TD.DeriveCounters({ school="magical", damage_type="magical",
            pierces_spell_immunity=false, dispellable="none", delivery="spell",
            targeted=true, timing="pre_cast", primary_harm="damage", lotus_reflectable=true })
        assert_true(has(yes,"reflect_target"))
        local no = TD.DeriveCounters({ school="magical", damage_type="magical",
            pierces_spell_immunity=false, dispellable="none", delivery="channel",
            targeted=true, timing="mid_channel", primary_harm="disable" })
        assert_false(has(no,"reflect_target"), "channels are not reflected")
    end)
end)

describe("DeriveCounters displacement + overrides", function()
    local TD = require("lib.threat_data")
    local function has(set, k) for _,x in ipairs(set) do if x==k then return true end end return false end
    it("homing_charge -> at_source+perp, NOT blink/far", function()
        local d = TD.DeriveCounters({ school="magical", damage_type="magical",
            pierces_spell_immunity="partial", dispellable="none", delivery="homing_charge",
            targeted=false, timing="pre_cast", primary_harm="disable" })
        assert_true(has(d,"displacement_at_source")); assert_true(has(d,"displacement_perp"))
        assert_false(has(d,"displacement_blink"), "charge re-homes on blink")
        assert_false(has(d,"displacement_far"), "self-push delay-only vs homing")
    end)
    it("leap -> perp+blink+invuln, NOT at_source", function()
        local d = TD.DeriveCounters({ school="none", damage_type="none",
            pierces_spell_immunity=false, dispellable="basic", delivery="leap",
            targeted=true, timing="pre_cast", primary_harm="disable" })
        assert_true(has(d,"displacement_perp")); assert_true(has(d,"displacement_blink"))
        assert_true(has(d,"invuln"), "leap is dodged by the airborne save (WW/Eul)")
        assert_false(has(d,"displacement_at_source"))
    end)
    it("leap keeps invuln at ANY timing (explicit rule, v0.5.143)", function()
        -- A leap lands ON the target, so untargetable/invuln at impact whiffs it
        -- (DEMO-PROVEN v0.5.142: Lina WW-dodged Huskar Life Break, the _slow never
        -- landed). The universal invuln rule only fires for pre_cast/at_impact;
        -- the explicit leap branch must add invuln for any other timing too, so the
        -- airborne save never silently drops. timing=post_apply skips the universal.
        local d = TD.DeriveCounters({ school="magical", damage_type="magical",
            pierces_spell_immunity=false, dispellable="none", delivery="leap",
            targeted=true, timing="post_apply", primary_harm="damage" })
        assert_true(has(d,"invuln"), "explicit leap rule keeps the airborne save regardless of timing")
    end)
    it("forced_leash leap drops invuln (cyclone cannot break a leash)", function()
        -- guard: a leashing leap is NOT dodged by going airborne (the leash
        -- reapplies), matching the universal rule's forced_leash exclusion.
        local d = TD.DeriveCounters({ school="magical", damage_type="magical",
            pierces_spell_immunity=false, dispellable="none", delivery="leap",
            targeted=true, timing="post_apply", primary_harm="disable",
            forced_leash=true })
        assert_false(has(d,"invuln"), "forced_leash leap keeps invuln out")
    end)
    it("projectile_line -> perp+far+blink; projectile_homing -> blink only", function()
        local line = TD.DeriveCounters({ school="none", damage_type="none",
            pierces_spell_immunity=false, dispellable="none", delivery="projectile_line",
            targeted=false, timing="pre_cast", primary_harm="disable" })
        assert_true(has(line,"displacement_far")); assert_true(has(line,"displacement_perp"))
        local hom = TD.DeriveCounters({ school="magical", damage_type="magical",
            pierces_spell_immunity=false, dispellable="none", delivery="projectile_homing",
            targeted=false, timing="at_impact", primary_harm="damage" })
        assert_true(has(hom,"displacement_blink"))
        assert_false(has(hom,"displacement_far"), "homing missile re-targets")
    end)
    it("channel -> channel_break + at_source + tether displacement", function()
        local d = TD.DeriveCounters({ school="magical", damage_type="magical",
            pierces_spell_immunity=false, dispellable="basic", delivery="channel",
            targeted=true, timing="mid_channel", primary_harm="disable", positional=false })
        assert_true(has(d,"channel_break")); assert_true(has(d,"displacement_at_source"))
        assert_true(has(d,"displacement_far"))
    end)
    it("positional AoE -> perp+far+blink; barrier zone -> no blink", function()
        local zone = TD.DeriveCounters({ school="magical", damage_type="magical",
            pierces_spell_immunity=false, dispellable="none", delivery="spell",
            targeted=false, timing="pre_cast", primary_harm="damage", positional=true,
            blocks_forced_movement=false })
        assert_true(has(zone,"displacement_far")); assert_true(has(zone,"displacement_blink"))
        local wall = TD.DeriveCounters({ school="none", damage_type="none",
            pierces_spell_immunity=false, dispellable="basic", delivery="spell",
            targeted=false, timing="reactive", primary_harm="disable", positional=true,
            blocks_forced_movement=true })
        assert_true(has(wall,"displacement_perp"))
        assert_false(has(wall,"displacement_blink"), "barrier blocks blink")
    end)
    it("drop_kinds / add_kinds applied last", function()
        local d = TD.DeriveCounters({ school="pure", damage_type="pure",
            pierces_spell_immunity=true, dispellable="none", delivery="projectile_line",
            targeted=false, timing="at_impact", primary_harm="disable",
            drop_kinds={"invuln"}, add_kinds={"displacement_far"} })
        assert_false(has(d,"invuln"), "drop_kinds removed it")
        assert_true(has(d,"displacement_far"))
    end)
end)

describe("DeriveCounters gate coverage (suppression paths)", function()
    local TD = require("lib.threat_data")
    local function has(set, k) for _,x in ipairs(set) do if x==k then return true end end return false end

    it("mid_channel suppresses magic_immune (Fiend's Grip class)", function()
        -- BKB cannot strip an already-active channel debuff.
        local d = TD.DeriveCounters({ school="magical", damage_type="magical",
            pierces_spell_immunity=false, dispellable="basic", delivery="channel",
            targeted=true, timing="mid_channel", primary_harm="disable" })
        assert_false(has(d,"magic_immune"), "no BKB out of an active channel")
    end)
    it("enemy_self_buff suppresses dispel (Ursa Overpower class)", function()
        local d = TD.DeriveCounters({ school="none", damage_type="none",
            pierces_spell_immunity=false, dispellable="basic", delivery="attack",
            targeted=false, timing="reactive", primary_harm="disable",
            enemy_self_buff=true })
        assert_false(has(d,"dispel_basic"), "cannot dispel a buff on the enemy")
        assert_false(has(d,"dispel_strong"))
    end)
    it("attack_enabler suppresses dispel (PA Strike marker class)", function()
        local d = TD.DeriveCounters({ school="none", damage_type="none",
            pierces_spell_immunity=false, dispellable="basic", delivery="attack",
            targeted=false, timing="reactive", primary_harm="disable",
            attack_enabler=true })
        assert_false(has(d,"dispel_basic"), "dispelling the marker does not stop the attacks")
    end)
    it("displacement primary_harm suppresses dispel (cannot dispel a knockback)", function()
        local d = TD.DeriveCounters({ school="none", damage_type="none",
            pierces_spell_immunity=false, dispellable="basic", delivery="leap",
            targeted=true, timing="reactive", primary_harm="displacement" })
        assert_false(has(d,"dispel_basic"), "no dispel for pure displacement")
    end)
    it("line_charge -> perp+far+blink (same as projectile_line)", function()
        local d = TD.DeriveCounters({ school="magical", damage_type="magical",
            pierces_spell_immunity=false, dispellable="none", delivery="line_charge",
            targeted=false, timing="pre_cast", primary_harm="disable" })
        assert_true(has(d,"displacement_perp")); assert_true(has(d,"displacement_far"))
        assert_true(has(d,"displacement_blink"))
    end)
    it("positional channel -> channel_break + zone displacement, no tether-only far via channel branch double", function()
        -- A positional AoE channel (targeted=false): channel branch adds
        -- channel_break + at_source (and NOT the tether far/perp/blink because
        -- positional); the positional-AoE branch then adds perp+far+blink.
        local d = TD.DeriveCounters({ school="magical", damage_type="magical",
            pierces_spell_immunity=false, dispellable="none", delivery="channel",
            targeted=false, timing="mid_channel", primary_harm="damage",
            positional=true, blocks_forced_movement=false })
        assert_true(has(d,"channel_break")); assert_true(has(d,"displacement_at_source"))
        assert_true(has(d,"displacement_far")); assert_true(has(d,"displacement_blink"))
    end)
    it("lotus_reflectable=false suppresses reflect_target", function()
        local d = TD.DeriveCounters({ school="magical", damage_type="magical",
            pierces_spell_immunity=false, dispellable="none", delivery="spell",
            targeted=true, timing="pre_cast", primary_harm="damage",
            lotus_reflectable=false })
        assert_false(has(d,"reflect_target"), "explicitly un-reflectable")
    end)
    it("already_locked_channel suppresses invis (Omnislash class)", function()
        local d = TD.DeriveCounters({ school="physical", damage_type="physical",
            pierces_spell_immunity=false, dispellable="none", delivery="attack",
            targeted=false, timing="mid_channel", primary_harm="damage",
            already_locked_channel=true })
        assert_true(has(d,"physical_immune"), "Ghost still works")
        assert_false(has(d,"invis"), "invis useless under a locked channel")
    end)
    it("debuff_sticks_to_self suppresses physical self-push (Open Wounds class)", function()
        local d = TD.DeriveCounters({ school="physical", damage_type="physical",
            pierces_spell_immunity=false, dispellable="basic", delivery="attack",
            targeted=false, timing="reactive", primary_harm="damage",
            debuff_sticks_to_self=true })
        assert_false(has(d,"displacement_far"), "pushing away does not shed the debuff")
        assert_false(has(d,"displacement_perp"))
    end)
    it("severity=survivable adds magic_resist cushion", function()
        local d = TD.DeriveCounters({ school="magical", damage_type="magical",
            pierces_spell_immunity=false, dispellable="none", delivery="spell",
            targeted=true, timing="pre_cast", primary_harm="damage",
            severity="survivable" })
        assert_true(has(d,"magic_resist"), "Glimmer/Solar cushion for survivable magic")
    end)
    it("positional branch is nil-safe: omitted targeted (nil) still fires displacement", function()
        -- Profiles omit default-false booleans, so a non-targeted positional zone
        -- has targeted==nil. The positional branch must use `not p.targeted`, not
        -- `== false` (nil == false is false in Lua). Regression for the LSA/
        -- Freezing-Field displacement_far drop.
        local d = TD.DeriveCounters({ school="magical", damage_type="magical",
            pierces_spell_immunity=false, dispellable="none", delivery="spell",
            timing="pre_cast", primary_harm="damage", positional=true })
            -- NOTE: targeted intentionally OMITTED (nil)
        assert_true(has(d,"displacement_far"), "positional zone must give displacement_far even when targeted is nil")
        assert_true(has(d,"displacement_perp"))
    end)
end)

describe("tier-3 compose-time counter filter", function()
    local Defense = require("lib.defense")
    local TD = require("lib.threat_data")

    local function mk()
        TD.THREAT_PROFILE = TD.THREAT_PROFILE or {}
        TD.THREAT_PROFILE["test_phys_chase"] = { school="physical", damage_type="physical",
            pierces_spell_immunity=false, dispellable="none", delivery="attack",
            targeted=false, timing="pre_cast", primary_harm="damage" }
        TD.THREAT_PROFILE["test_magic_nuke"] = { school="magical", damage_type="magical",
            pierces_spell_immunity=false, dispellable="none", delivery="spell",
            targeted=true, timing="pre_cast", primary_harm="damage" }
        TD.THREAT_COUNTER["test_phys_chase"] = TD.DeriveCounters(TD.THREAT_PROFILE["test_phys_chase"])
        TD.THREAT_COUNTER["test_magic_nuke"] = TD.DeriveCounters(TD.THREAT_PROFILE["test_magic_nuke"])
        TD.CATEGORY_CHAINS.test_cat = { "item_ghost", "item_blade_mail", "item_pipe", "item_hurricane_pike" }
        local d = Defense.New({
            TD = TD,
            ability_injections = { { save="hero_ability_x", categories={"test_cat"}, anchor="head" } },
            hero_save_overrides = {}, anim_save_overrides = {}, patched_recommended = {},
            category_chains = {}, default_chain = {},
            tlog = function() end,
        })
        d.cfg.TD.CategoryOf = function() return "test_cat" end
        return d
    end
    local function inchain(chain, x) for _,c in ipairs(chain) do if c==x then return true end end return false end

    it("magic nuke keeps pipe (magic_barrier), drops ghost/blade_mail/pike", function()
        local d = mk()
        local chain = d:ResolveSaveOrder("test_magic_nuke", nil, nil, nil)
        assert_eq(chain[1], "hero_ability_x")  -- injected ability survives the filter
        assert_true(inchain(chain, "item_pipe"), "magic_barrier counters a magic nuke")
        assert_false(inchain(chain, "item_ghost"), "physical_immune does not counter magic")
        assert_false(inchain(chain, "item_hurricane_pike"), "displacement does not counter a target-locked nuke")
    end)
    it("phys chase keeps ghost + pike, drops pipe", function()
        local d = mk()
        local chain = d:ResolveSaveOrder("test_phys_chase", nil, nil, nil)
        assert_true(inchain(chain, "item_ghost"), "physical_immune counters a physical chase")
        assert_true(inchain(chain, "item_hurricane_pike"), "self-push counters a chase")
        assert_false(inchain(chain, "item_pipe"), "magic_barrier useless vs physical")
    end)
    it("cache key is per (category, threat) not per category", function()
        local d = mk()
        d:ResolveSaveOrder("test_magic_nuke", nil, nil, nil)
        d:ResolveSaveOrder("test_phys_chase", nil, nil, nil)
        assert_true(d._composed_cache["test_cat|test_magic_nuke"] ~= nil, "magic-nuke key missing")
        assert_true(d._composed_cache["test_cat|test_phys_chase"] ~= nil, "phys-chase key missing")
    end)
    -- cleanup so test fixtures don't leak into other describe-blocks
    it("cleanup test fixtures", function()
        TD.CATEGORY_CHAINS.test_cat = nil
        TD.THREAT_PROFILE["test_phys_chase"] = nil
        TD.THREAT_PROFILE["test_magic_nuke"] = nil
        TD.THREAT_COUNTER["test_phys_chase"] = nil
        TD.THREAT_COUNTER["test_magic_nuke"] = nil
        assert_true(true)
    end)
end)

describe("migration correctness (42 known threats)", function()
    local TD = require("lib.threat_data")
    local function set_eq(got, want)
        local sg, sw = {}, {}
        for _,x in ipairs(got) do sg[x]=true end
        for _,x in ipairs(want) do sw[x]=true end
        for k in pairs(sg) do if not sw[k] then return false, k.." extra" end end
        for k in pairs(sw) do if not sg[k] then return false, k.." missing" end end
        return true
    end
    local EXPECT = {
        ["modifier_abyssal_underlord_pit_of_malice_ensare"] = { "magic_immune", "displacement_perp", "displacement_far", "dispel_basic", "dispel_strong" },
        ["modifier_axe_berserkers_call"] = { "physical_immune", "damage_block" },
        ["modifier_bane_fiends_grip"] = { "invuln", "dispel_strong", "channel_break", "displacement_at_source" },
        ["modifier_bane_nightmare"] = { "invuln", "magic_immune", "reflect_target", "dispel_basic", "dispel_strong" },
        ["modifier_crystal_maiden_freezing_field"] = { "magic_immune", "magic_barrier", "channel_break", "displacement_at_source", "displacement_perp", "displacement_far", "displacement_blink" },
        ["modifier_disruptor_kinetic_field"] = { "displacement_perp", "displacement_far" },
        ["modifier_disruptor_static_storm_thinker"] = { "magic_immune", "magic_barrier", "displacement_perp", "displacement_far", "displacement_blink" },
        ["modifier_doom_bringer_doom"] = { "invuln", "reflect_target" },
        ["modifier_earth_spirit_rolling_boulder"] = { "invuln", "magic_immune", "displacement_perp", "displacement_far", "displacement_blink" },
        ["modifier_earthshaker_echo_slam"] = { "invuln", "magic_immune", "magic_barrier" },
        ["modifier_enigma_black_hole"] = { "channel_break", "displacement_at_source", "displacement_perp", "displacement_far", "displacement_blink" },
        ["modifier_kez_grappling_claw_slow"] = { "invuln", "physical_immune", "damage_block", "displacement_far", "displacement_perp", "displacement_blink", "reflect_target" },
        ["modifier_legion_commander_duel"] = { "physical_immune", "damage_block" },
        ["modifier_life_stealer_open_wounds"] = { "magic_immune", "dispel_basic", "dispel_strong" },
        ["modifier_lina_laguna_blade"] = { "invuln", "magic_immune", "magic_barrier", "reflect_target" },
        ["modifier_lina_light_strike_array"] = { "invuln", "magic_immune", "displacement_perp", "displacement_far", "displacement_blink" },
        ["modifier_lion_finger_of_death"] = { "invuln", "magic_immune", "magic_barrier", "reflect_target" },
        ["modifier_lion_mana_drain"] = { "invuln", "magic_immune", "channel_break", "displacement_at_source", "displacement_far", "displacement_perp", "displacement_blink" },
        ["modifier_lion_voodoo"] = { "invuln", "magic_immune", "reflect_target", "dispel_strong" },
        ["modifier_magnataur_reverse_polarity_stun"] = { "invuln" },
        ["modifier_magnataur_skewer"] = { "invuln", "magic_immune", "displacement_perp", "displacement_far", "displacement_blink" },
        ["modifier_mirana_arrow"] = { "invuln", "magic_immune", "displacement_perp", "displacement_far", "displacement_blink" },
        ["modifier_naga_siren_ensnare"] = { "magic_immune", "displacement_blink", "invuln", "reflect_target", "dispel_basic", "dispel_strong" },
        ["modifier_phantom_assassin_phantom_strike_target"] = { "physical_immune", "damage_block", "invis", "displacement_far", "displacement_perp" },
        ["modifier_pudge_dismember"] = { "invuln", "dispel_strong", "channel_break", "displacement_at_source" },
        ["modifier_pudge_dismember_pull"] = { "invuln", "dispel_strong", "channel_break", "displacement_at_source" },
        ["modifier_pudge_meat_hook"] = { "displacement_perp", "displacement_far", "displacement_blink" },
        ["modifier_pugna_life_drain"] = { "invuln", "magic_immune", "magic_barrier", "channel_break", "displacement_at_source", "displacement_far", "displacement_perp", "displacement_blink" },
        ["modifier_razor_static_link_debuff"] = { "invuln", "reflect_target" },
        ["modifier_shadow_shaman_shackles"] = { "invuln", "magic_immune", "dispel_strong", "channel_break", "displacement_at_source" },
        ["modifier_shadow_shaman_voodoo"] = { "invuln", "magic_immune", "reflect_target", "dispel_strong" },
        ["modifier_slark_pounce"] = { "invuln", "magic_immune", "displacement_perp", "displacement_blink" },
        ["modifier_spirit_breaker_charge_of_darkness"] = { "magic_immune", "displacement_at_source", "displacement_perp" },
        ["modifier_sven_storm_bolt"] = { "invuln", "magic_immune", "reflect_target", "displacement_blink" },
        ["modifier_tidehunter_ravage"] = { "invuln", "magic_immune" },
        ["modifier_treant_overgrowth"] = { "dispel_basic", "dispel_strong", "displacement_perp", "displacement_far" },
        ["modifier_tusk_ice_shards_thinker"] = { "invuln", "magic_immune", "displacement_perp", "displacement_far", "displacement_blink" },
        ["modifier_tusk_snowball_movement"] = { "magic_immune", "magic_barrier", "displacement_at_source", "displacement_perp" },
        ["modifier_ursa_overpower"] = { "invuln", "physical_immune", "damage_block", "invis", "displacement_far", "displacement_perp" },
        ["modifier_witch_doctor_death_ward"] = { "invuln", "invis", "channel_break", "displacement_at_source", "displacement_perp", "displacement_far", "displacement_blink" },
        ["modifier_zuus_lightning_bolt"] = { "invuln", "magic_immune", "magic_barrier", "magic_resist", "reflect_target" },
        ["modifier_zuus_thundergods_wrath"] = { "invuln", "magic_immune", "magic_barrier", "magic_resist" },
        ["modifier_alchemist_unstable_concoction"] = { "magic_immune" },
        ["modifier_ancient_apparition_bone_chill_debuff"] = { "magic_immune" },
        ["modifier_ancientapparition_coldfeet_freeze"] = { "magic_immune", "dispel_strong" },
        ["modifier_arc_warden_flux"] = { "invuln", "magic_immune", "magic_barrier", "magic_resist", "reflect_target" },
        ["modifier_batrider_flaming_lasso"] = { "reflect_target" },
        ["modifier_beastmaster_primal_roar"] = { "invuln", "reflect_target" },
        ["modifier_blinding_light_knockback"] = { "invuln", "magic_immune" },
        ["modifier_bloodseeker_rupture"] = { "invuln", "reflect_target" },
        ["modifier_bounty_hunter_shuriken_toss"] = { "invuln", "magic_immune" },
        ["modifier_brewmaster_cinder_brew"] = { "dispel_basic", "dispel_strong", "magic_immune" },
        ["modifier_bristleback_viscous_nasal_goo"] = { "dispel_basic", "dispel_strong", "magic_immune" },
        ["modifier_broodmother_sticky_snare"] = { "dispel_basic", "dispel_strong", "magic_immune", "magic_barrier" },
        ["modifier_chaos_knight_chaos_bolt"] = { "invuln", "magic_immune", "reflect_target", "dispel_strong" },
        ["modifier_chaos_knight_reality_rift"] = { "dispel_basic" },
        ["modifier_chen_penitence"] = { "dispel_basic", "dispel_strong", "magic_immune" },
        ["modifier_chilling_touch_slow"] = { "dispel_basic", "dispel_strong" },
        ["modifier_chilling_touch_super_slow"] = { "dispel_basic", "dispel_strong" },
        ["modifier_cold_feet"] = { "magic_immune", "dispel_basic", "dispel_strong" },
        ["modifier_crystal_maiden_frostbite"] = { "magic_immune", "dispel_basic", "dispel_strong" },
        ["modifier_dark_seer_ion_shell"] = { "magic_immune", "magic_barrier", "magic_resist", "dispel_basic", "dispel_strong" },
        ["modifier_dark_seer_vacuum"] = { "invuln", "magic_immune" },
        ["modifier_dark_willow_bramble_maze"] = { "magic_immune", "dispel_basic", "dispel_strong", "displacement_perp", "displacement_far", "displacement_blink" },
        ["modifier_dark_willow_cursed_crown"] = { "magic_immune", "dispel_basic", "dispel_strong" },
        ["modifier_dark_willow_terrorize"] = { "magic_immune", "dispel_basic", "dispel_strong" },
        ["modifier_dawnbreaker_celestial_hammer"] = { "invuln", "magic_immune", "magic_barrier", "magic_resist", "displacement_perp", "displacement_far", "displacement_blink" },
        ["modifier_dazzle_poison_touch"] = { "dispel_basic", "dispel_strong" },
        ["modifier_death_prophet_silence"] = { "invuln", "magic_immune", "displacement_perp", "displacement_far", "displacement_blink" },
        ["modifier_doom_bringer_infernal_blade"] = { "invuln", "magic_immune" },
        ["modifier_dragon_knight_dragon_tail"] = { "invuln", "magic_immune", "reflect_target" },
        ["modifier_drow_ranger_frost_arrows_slow"] = { "physical_immune", "damage_block", "invis", "displacement_far", "displacement_perp", "dispel_basic", "dispel_strong" },
        ["modifier_earth_spirit_rolling_boulder_caster"] = { "invuln", "magic_immune", "displacement_perp", "displacement_far", "displacement_blink" },
        ["modifier_earthshaker_earthsplitter"] = { "invuln", "magic_barrier", "magic_resist", "displacement_perp", "displacement_far", "displacement_blink" },
        ["modifier_earthshaker_fissure_stun"] = { "invuln", "magic_immune", "displacement_perp", "displacement_far", "displacement_blink", "dispel_strong" },
        ["modifier_ember_spirit_sleight_of_fist_caster"] = { "physical_immune", "damage_block", "invis", "displacement_far", "displacement_perp", "invuln" },
        ["modifier_enigma_malefice"] = { "invuln", "magic_immune", "reflect_target", "dispel_basic", "dispel_strong" },
        ["modifier_faceless_void_chronosphere"] = { "displacement_perp", "displacement_far", "displacement_blink" },
        ["modifier_faceless_void_chronosphere_freeze"] = { "displacement_perp", "displacement_far", "displacement_blink" },
        ["modifier_faceless_void_time_dilation_distortion"] = { "magic_immune", "dispel_basic", "dispel_strong" },
        ["modifier_faceless_void_timelock_freeze"] = { "dispel_strong" },
        ["modifier_furion_sprout"] = { "displacement_perp", "displacement_far", "displacement_blink" },
        ["modifier_grimstroke_ink_creature"] = { "invuln", "magic_immune" },
        ["modifier_grimstroke_soul_chain"] = { "displacement_blink" },
        ["modifier_gyrocopter_call_down_slow"] = { "magic_immune", "magic_barrier", "magic_resist", "dispel_basic", "dispel_strong" },
        ["modifier_gyrocopter_homing_missile"] = { "invuln", "magic_immune", "displacement_blink" },
        ["modifier_hoodwink_bushwhack"] = { "invuln", "magic_immune" },
        ["modifier_huskar_life_break_charge"] = { "invuln", "displacement_perp", "displacement_blink", "magic_barrier" },
        ["modifier_ice_blast"] = { "invuln", "magic_barrier" },
        ["modifier_ice_vortex"] = { "magic_immune", "magic_barrier", "magic_resist" },
        ["modifier_invoker_cold_snap"] = { "magic_immune", "magic_barrier", "magic_resist", "dispel_basic", "dispel_strong" },
        ["modifier_jakiro_ice_path"] = { "magic_immune", "displacement_perp", "displacement_far", "displacement_blink" },
        ["modifier_jakiro_macropyre_thinker"] = { "magic_immune", "magic_barrier", "magic_resist", "displacement_perp", "displacement_far", "displacement_blink" },
        ["modifier_juggernaut_omni_slash"] = { "physical_immune", "damage_block" },
        ["modifier_keeper_of_the_light_blinding_light"] = { "invuln", "magic_immune", "magic_barrier", "magic_resist" },
        ["modifier_keeper_of_the_light_radiant_bind"] = { "magic_immune", "dispel_basic", "dispel_strong" },
        ["modifier_keeper_of_the_light_will_o_wisp"] = { "magic_immune", "magic_barrier", "magic_resist", "displacement_perp", "displacement_far", "displacement_blink" },
        ["modifier_kez_raptor_dance"] = { "invuln", "displacement_perp", "displacement_far", "displacement_blink" },
        ["modifier_kunkka_torrent_stun"] = { "invuln", "magic_immune", "displacement_perp", "displacement_far", "displacement_blink" },
        ["modifier_kunkka_torrent_thinker"] = { "invuln", "magic_immune", "displacement_perp", "displacement_far", "displacement_blink" },
        ["modifier_kunkka_x_marks_the_spot"] = { "invuln", "magic_immune", "reflect_target" },
        ["modifier_largo_catchy_lick"] = { "invuln", "magic_immune", "magic_barrier", "magic_resist", "reflect_target" },
        ["modifier_largo_catchy_lick_knockback"] = { "invuln", "magic_immune" },
        ["modifier_largo_croak_of_genius_debuff"] = { "magic_immune", "magic_barrier", "magic_resist", "dispel_basic", "dispel_strong" },
        ["modifier_largo_frogstomp_debuff"] = { "magic_immune", "magic_barrier", "magic_resist", "displacement_perp", "displacement_far", "displacement_blink" },
        ["modifier_legion_commander_intimidate_slow"] = { "magic_immune", "dispel_basic", "dispel_strong" },
        ["modifier_leshrac_split_earth"] = { "invuln", "magic_immune" },
        ["modifier_lich_chain_frost"] = { "magic_immune", "magic_barrier", "dispel_basic", "dispel_strong" },
        ["modifier_lich_sinister_gaze"] = { "dispel_basic", "dispel_strong", "channel_break", "displacement_at_source", "displacement_far", "displacement_perp", "displacement_blink" },
        ["modifier_lone_druid_spirit_bear_entangle_effect"] = { "dispel_basic", "dispel_strong" },
        ["modifier_magnataur_shockwave_pull"] = { "invuln", "magic_immune", "magic_barrier", "magic_resist", "displacement_perp", "displacement_far", "displacement_blink" },
        ["modifier_magnataur_skewer_impact"] = { "invuln", "displacement_perp", "displacement_far", "displacement_blink", "magic_immune" },
        ["modifier_magnataur_skewer_slow"] = { "magic_immune", "dispel_basic", "dispel_strong" },
        ["modifier_maledict"] = { "magic_immune", "magic_barrier", "magic_resist" },
        ["modifier_maledict_dot"] = { "magic_immune", "magic_barrier", "magic_resist" },
        ["modifier_marci_grapple"] = { "invuln", "magic_immune" },
        ["modifier_mars_arena_of_blood"] = { "magic_immune", "displacement_perp", "displacement_far" },
        ["modifier_mars_gods_rebuke"] = { "invuln", "damage_block" },
        ["modifier_mars_spear"] = { "invuln", "magic_immune", "displacement_perp", "displacement_far", "displacement_blink" },
        ["modifier_medusa_gorgon_grasp"] = { "invuln", "magic_immune", "displacement_perp", "displacement_far", "displacement_blink" },
        ["modifier_medusa_mystic_snake"] = { "invuln", "magic_immune", "magic_barrier", "magic_resist", "reflect_target" },
        ["modifier_meepo_earthbind"] = { "invuln", "magic_immune", "displacement_perp", "displacement_far", "displacement_blink" },
        ["modifier_monkey_king_wukongs_command_aura"] = { "physical_immune", "damage_block", "invis", "displacement_far", "displacement_perp" },
        ["modifier_morphling_adaptive_strike_agi"] = { "magic_immune", "displacement_blink" },
        ["modifier_muerta_dead_shot"] = { "invuln", "magic_immune", "magic_barrier", "magic_resist", "displacement_perp", "displacement_far", "displacement_blink", "dispel_basic", "dispel_strong" },
        ["modifier_naga_siren_song_of_the_siren"] = { "invuln", "magic_immune" },
        ["modifier_necrolyte_heartstopper_aura_effect"] = { "magic_barrier", "magic_resist" },
        ["modifier_necrolyte_reapers_scythe"] = { "invuln", "magic_immune", "magic_barrier", "reflect_target" },
        ["modifier_nevermore_requiem"] = { "invuln", "magic_immune", "magic_barrier", "magic_resist", "dispel_basic", "dispel_strong" },
        ["modifier_night_stalker_void"] = { "invuln", "magic_immune", "magic_barrier", "magic_resist", "reflect_target", "dispel_basic", "dispel_strong" },
        ["modifier_nyx_assassin_impale"] = { "invuln", "magic_immune", "displacement_perp", "displacement_far", "displacement_blink" },
        ["modifier_nyx_assassin_vendetta"] = { "invuln" },
        ["modifier_obsidian_destroyer_astral_imprisonment"] = { "invuln", "magic_immune", "reflect_target" },
        ["modifier_obsidian_destroyer_sanity_eclipse"] = { "invuln", "magic_immune", "magic_barrier" },
        ["modifier_ogre_magi_fireblast"] = { "invuln", "magic_immune", "reflect_target", "dispel_strong" },
        ["modifier_omniknight_hammer_of_purity"] = { "physical_immune", "damage_block", "invis", "displacement_far", "displacement_perp", "dispel_basic", "dispel_strong" },
        ["modifier_oracle_fortunes_end_channel_target"] = { "dispel_basic", "dispel_strong", "channel_break", "displacement_at_source", "invuln", "magic_immune" },
        ["modifier_oracle_fortunes_end_purge"] = { "dispel_basic", "dispel_strong" },
        ["modifier_oracle_purifying_flames"] = { "invuln", "magic_immune", "magic_barrier", "magic_resist", "reflect_target" },
        ["modifier_pangolier_gyroshell"] = { "displacement_at_source", "displacement_perp" },
        ["modifier_pangolier_swashbuckle"] = { "invuln", "displacement_perp", "displacement_far", "displacement_blink" },
        ["modifier_phantom_assassin_stiflingdagger"] = { "invuln", "displacement_blink" },
        ["modifier_phantom_lancer_spirit_lance"] = { "magic_immune", "magic_barrier", "magic_resist", "displacement_blink" },
        ["modifier_phoenix_sun_ray"] = { "magic_barrier", "magic_resist", "channel_break", "displacement_at_source", "displacement_far", "displacement_perp", "displacement_blink" },
        ["modifier_primal_beast_onslaught"] = { "invuln", "displacement_perp", "displacement_far", "displacement_blink" },
        ["modifier_primal_beast_pulverize"] = { "channel_break", "displacement_at_source", "displacement_far", "displacement_perp", "displacement_blink" },
        ["modifier_puck_dream_coil"] = { "magic_immune" },
        ["modifier_puck_waning_rift"] = { "invuln", "magic_immune" },
        ["modifier_rattletrap_hookshot"] = { "invuln", "displacement_perp", "displacement_far", "displacement_blink" },
        ["modifier_razor_eye_of_the_storm_armor"] = {  },
        ["modifier_razor_plasma_field_slow"] = { "magic_immune", "magic_barrier", "magic_resist", "dispel_basic", "dispel_strong" },
        ["modifier_razor_storm_surge_slow"] = { "magic_immune", "magic_barrier", "magic_resist" },
        ["modifier_riki_smoke_screen"] = { "magic_immune" },
        ["modifier_ringmaster_impalement"] = { "invuln", "magic_barrier", "magic_resist", "displacement_perp", "displacement_far", "displacement_blink", "magic_immune" },
        ["modifier_ringmaster_the_box"] = {  },
        ["modifier_ringmaster_wheel"] = { "magic_immune", "magic_barrier", "magic_resist", "displacement_perp", "displacement_far", "displacement_blink" },
        ["modifier_rubick_fade_bolt_debuff"] = { "magic_immune", "magic_barrier", "magic_resist", "dispel_basic", "dispel_strong" },
        ["modifier_rubick_telekinesis_stun"] = { "invuln", "magic_immune", "reflect_target" },
        ["modifier_sand_king_epicenter"] = { "magic_immune", "magic_barrier", "magic_resist", "displacement_perp", "displacement_far", "displacement_blink" },
        ["modifier_sandking_burrowstrike"] = { "invuln", "magic_immune", "displacement_perp", "displacement_far", "displacement_blink" },
        ["modifier_shadow_demon_demonic_purge"] = { "invuln", "magic_barrier", "reflect_target" },
        ["modifier_shadow_demon_disruption"] = { "invuln", "magic_immune", "reflect_target" },
        ["modifier_shredder_chakram"] = { "invuln", "displacement_perp", "displacement_far", "displacement_blink" },
        ["modifier_silencer_last_word"] = { "invuln", "magic_immune", "reflect_target", "dispel_basic", "dispel_strong" },
        ["modifier_skeleton_king_reincarnate_slow"] = { "magic_immune", "dispel_basic", "dispel_strong" },
        ["modifier_skeleton_king_reincarnation_spawn_skeletons"] = {  },
        ["modifier_skywrath_mage_ancient_seal"] = { "invuln", "magic_immune", "reflect_target", "dispel_basic", "dispel_strong" },
        ["modifier_skywrath_mage_concussive_shot_slow"] = { "magic_immune", "dispel_basic", "dispel_strong" },
        ["modifier_skywrath_mage_mystic_flare_thinker"] = { "invuln", "magic_immune", "magic_barrier", "displacement_perp", "displacement_far", "displacement_blink" },
        ["modifier_skywrath_mystic_flare_aura_effect"] = { "invuln", "magic_immune", "magic_barrier", "displacement_perp", "displacement_far", "displacement_blink" },
        ["modifier_slardar_amplify_damage"] = { "invuln", "reflect_target" },
        ["modifier_slardar_slithereen_crush"] = { "invuln" },
        ["modifier_snapfire_lil_shredder_debuff"] = { "physical_immune", "damage_block", "invis", "displacement_far", "displacement_perp" },
        ["modifier_snapfire_magma_burn_slow"] = { "magic_immune", "displacement_perp", "displacement_far", "displacement_blink" },
        ["modifier_snapfire_mortimer_kisses"] = { "magic_immune", "magic_barrier", "displacement_perp", "displacement_far", "displacement_blink" },
        ["modifier_snapfire_scatterblast_slow"] = { "invuln", "magic_immune", "magic_barrier", "magic_resist", "displacement_perp", "displacement_far", "displacement_blink" },
        ["modifier_sniper_assassinate"] = { "invuln", "magic_immune", "magic_barrier", "reflect_target" },
        ["modifier_spectre_spectral_dagger"] = { "invuln", "magic_immune", "magic_barrier", "magic_resist", "displacement_perp", "displacement_far", "displacement_blink" },
        ["modifier_spectre_spectral_dagger_in_path"] = { "magic_immune", "dispel_basic", "dispel_strong", "displacement_perp", "displacement_far", "displacement_blink" },
        ["modifier_spirit_breaker_nether_strike"] = { "invuln", "displacement_perp", "displacement_blink" },
        ["modifier_templar_assassin_psionic_trap"] = { "magic_immune", "dispel_basic", "dispel_strong", "displacement_perp", "displacement_far", "displacement_blink" },
        ["modifier_tinker_laser"] = { "invuln", "reflect_target" },
        ["modifier_tiny_avalanche"] = { "invuln", "magic_immune", "magic_barrier" },
        ["modifier_tiny_avalanche_stun"] = { "invuln", "magic_immune" },
        ["modifier_tiny_toss"] = { "invuln", "magic_immune", "magic_barrier" },
        ["modifier_troll_warlord_whirling_axes_slow"] = { "invuln", "magic_immune", "displacement_perp", "displacement_far", "displacement_blink" },
        ["modifier_tusk_snowball_target"] = { "magic_immune", "displacement_at_source", "displacement_perp" },
        ["modifier_tusk_tag_team_attack_slow"] = {  },
        ["modifier_tusk_tag_team_slow"] = {  },
        ["modifier_tusk_walrus_punch_air_time"] = { "dispel_basic", "dispel_strong" },
        ["modifier_tusk_walrus_punch_slow"] = { "dispel_basic", "dispel_strong" },
        ["modifier_undying_decay"] = { "invuln", "magic_immune", "magic_barrier", "magic_resist" },
        ["modifier_vengefulspirit_nether_swap"] = { "invuln" },
        ["modifier_vengefulspirit_retribution_tracker"] = {  },
        ["modifier_venomancer_venomous_gale"] = { "magic_immune", "magic_barrier", "magic_resist", "dispel_basic", "dispel_strong" },
        ["modifier_viper_corrosive_skin_slow"] = { "magic_immune", "dispel_basic", "dispel_strong" },
        ["modifier_viper_nethertoxin"] = { "magic_immune", "magic_barrier", "magic_resist", "displacement_perp", "displacement_far", "displacement_blink" },
        ["modifier_viper_nethertoxin_mute"] = { "magic_immune", "displacement_perp", "displacement_far", "displacement_blink" },
        ["modifier_viper_poison_attack_slow"] = { "magic_immune", "dispel_basic", "dispel_strong" },
        ["modifier_visage_grave_chill"] = { "invuln", "magic_immune", "reflect_target" },
        ["modifier_void_spirit_aether_remnant"] = { "invuln", "magic_immune" },
        ["modifier_void_spirit_astral_step"] = { "invuln", "magic_barrier", "magic_resist" },
        ["modifier_weaver_swarm_debuff"] = {  },
        ["modifier_windrunner_shackleshot"] = { "invuln", "magic_immune", "dispel_strong", "displacement_blink" },
        ["modifier_winter_wyvern_winters_curse"] = { "invuln", "reflect_target" },
        ["modifier_witch_doctor_maledict"] = { "magic_immune", "magic_barrier", "magic_resist" },
    }
    for mod, want in pairs(EXPECT) do
        it("derives correct set for "..mod, function()
            local prof = TD.THREAT_PROFILE[mod]
            assert_true(prof ~= nil, "no profile for "..mod)
            local ok, why = set_eq(TD.DeriveCounters(prof), want)
            assert_true(ok, mod..": "..tostring(why))
        end)
    end
    it("THREAT_COUNTER assembled for every profiled threat", function()
        for mod in pairs(TD.THREAT_PROFILE) do
            assert_true(TD.THREAT_COUNTER[mod] ~= nil, "not assembled: "..mod)
        end
    end)
end)

describe("enriched backbones filter correctly (Task 8)", function()
    local TD = require("lib.threat_data")
    local function survivors(chain, mod)
        local k = {}
        for _, it in ipairs(chain) do if TD.SaveCounters(it, mod) then k[#k + 1] = it end end
        return k
    end
    local function has(lst, x) for _, v in ipairs(lst) do if v == x then return true end end return false end

    it("trap vs barrier/root traps keeps knockback (Force/Pike), drops blink", function()
        for _, m in ipairs({ "modifier_disruptor_kinetic_field",
                             "modifier_abyssal_underlord_pit_of_malice_ensare" }) do
            local s = survivors(TD.CATEGORY_CHAINS.trap, m)
            assert_true(#s > 0, "trap composed empty for " .. m)
            assert_true(has(s, "item_force_staff") or has(s, "item_hurricane_pike"),
                "no knockback survives for " .. m)
            assert_false(has(s, "item_blink"),
                "blink must be filtered (blocks_forced_movement) for " .. m)
        end
    end)
    it("channel_on_self vs Omnislash keeps physical answers (Ghost)", function()
        local s = survivors(TD.CATEGORY_CHAINS.channel_on_self, "modifier_juggernaut_omni_slash")
        assert_true(#s > 0, "Omnislash composed empty")
        assert_true(has(s, "item_ghost"), "Ghost (physical_immune) must survive vs Omnislash")
    end)
    it("close_gap vs a magic charge drops physical-only items, keeps the magic answers", function()
        -- Spirit Breaker Charge: magical disable, does not pierce.
        local s = survivors(TD.CATEGORY_CHAINS.close_gap, "modifier_spirit_breaker_charge_of_darkness")
        assert_false(has(s, "item_blade_mail"), "damage_return does not counter a magical charge")
        assert_false(has(s, "item_ghost"), "physical_immune does not counter a magical charge")
        assert_true(has(s, "item_black_king_bar"), "BKB counters a non-piercing magical disable")
    end)
    it("no category composes to empty for any threat that HAS counters", function()
        local bycat = {}
        for mod, c in pairs(TD.THREAT_CATEGORY or {}) do
            bycat[c] = bycat[c] or {}; table.insert(bycat[c], mod)
        end
        for c, chain in pairs(TD.CATEGORY_CHAINS) do
            for _, m in ipairs(bycat[c] or {}) do
                local ctr = TD.THREAT_COUNTER[m]
                if ctr and #ctr > 0 then
                    assert_true(#survivors(chain, m) > 0,
                        "category " .. c .. " composes empty for " .. m
                        .. " (counters exist: " .. table.concat(ctr, ",") .. ")")
                end
            end
        end
    end)
end)

local Geometry = require("lib.geometry")

describe("lib/geometry -- DiscReachPoint / BestReachLanding (Keen/BoT reach landing)", function()
    it("lands ON the target when it is inside the reach disc", function()
        local lx, ly, res = Geometry.DiscReachPoint(0, 0, 700, 300, 0)
        assert_eq(lx, 300); assert_eq(ly, 0); assert_eq(res, 0)
    end)
    it("lands on the disc edge toward the target when it is beyond reach", function()
        local lx, ly, res = Geometry.DiscReachPoint(0, 0, 700, 1000, 0)   -- edge (700,0), residual 300
        assert_eq(lx, 700); assert_eq(ly, 0); assert_eq(res, 300)
    end)
    it("picks the anchor whose landing is nearest the target (both beyond reach)", function()
        local anchors = { { pos = {x=0,y=0}, r=300 }, { pos = {x=600,y=0}, r=100 } }
        local b = Geometry.BestReachLanding(anchors, {x=1000,y=0})
        -- a1 edge (300,0) res 700 ; a2 edge (700,0) res 300 -> a2 wins
        assert_eq(b.anchor.pos.x, 600); assert_eq(b.lx, 700); assert_eq(b.residual, 300)
    end)
    it("prefers an anchor that covers the target (residual 0) over a nearer-centre one", function()
        local anchors = { { pos = {x=0,y=0}, r=300 }, { pos = {x=1200,y=0}, r=250 } }
        local b = Geometry.BestReachLanding(anchors, {x=1000,y=0})   -- a2 covers (d=200<250) -> land on target
        assert_eq(b.anchor.pos.x, 1200); assert_eq(b.lx, 1000); assert_eq(b.residual, 0)
    end)
    it("accept filter rejects the nearer landing, falls back to a farther accepted one", function()
        local anchors = { { pos = {x=0,y=0}, r=300, ok=false }, { pos = {x=600,y=0}, r=100, ok=true } }
        local b = Geometry.BestReachLanding(anchors, {x=1000,y=0}, { accept = function(_, _, a) return a.ok end })
        assert_eq(b.anchor.pos.x, 600)
    end)
    it("returns nil when nothing is accepted", function()
        local b = Geometry.BestReachLanding({ { pos = {x=0,y=0}, r=700 } }, {x=10,y=0}, { accept = function() return false end })
        assert_eq(b, nil)
    end)
end)

describe("lib/geometry -- BestAoeCenter anchored cover-both (v0.5.175)", function()
    -- BestAoeCenter needs Vector:Distance2D; the file's plain Vector stub has no
    -- methods. Install a richer Vector for this block, then restore. With no
    -- SampleVelocities history and lead_s=0, PredictPos returns each unit's origin,
    -- so the geometry is deterministic.
    local saved_vector = Vector
    local function Vec(x, y, z)
        return { x = x, y = y, z = z or 0,
            Distance2D = function(self, o)
                local dx, dy = self.x - o.x, self.y - o.y
                return math.sqrt(dx * dx + dy * dy)
            end }
    end
    Vector = function(x, y, z) return Vec(x, y, z) end
    local function unit(x, y, idx) return { idx = idx, pos = Vec(x, y, 0) } end

    it("catchable pair: BOTH covered, far unit INSIDE the radius with margin (d=480, r=250)", function()
        local A = unit(0, 0, 1)      -- anchor (must_cover)
        local B = unit(480, 0, 2)    -- 480u away: catchable (<= 2*radius)
        local center, covered = Geometry.BestAoeCenter({ A, B }, 250, 0, A)
        assert_true(center ~= nil, "expected a center")
        assert_eq(covered, 2, "both must be covered")
        -- The far unit must sit INSIDE the radius with margin (midpoint placement),
        -- not pinned to the 250 rim (the v<=0.5.174 rim placement put it at exactly
        -- 250, which floating-point could drop just outside -> boundary miss).
        local d_far = center:Distance2D(B.pos)
        assert_true(d_far <= 245, "far unit must be inside radius-5, got " .. tostring(d_far))
        assert_true(center:Distance2D(A.pos) <= 250, "anchor must stay covered")
    end)

    it("comfortable pair both covered (d=300, r=250)", function()
        local A, B = unit(0, 0, 1), unit(300, 0, 2)
        local _, covered = Geometry.BestAoeCenter({ A, B }, 250, 0, A)
        assert_eq(covered, 2, "300u apart fits one 250 AoE")
    end)

    it("pair too far for one AoE -> single (d=600, r=250)", function()
        local A, B = unit(0, 0, 1), unit(600, 0, 2)
        local _, covered = Geometry.BestAoeCenter({ A, B }, 250, 0, A)
        assert_eq(covered, 1, "600u > 2*radius cannot fit; only the anchor")
    end)

    it("margin via reduced radius: double within threshold (d=442, r'=225)", function()
        -- w_aim passes W_AOE - K.W_COVER_MARGIN = 250 - 25 = 225 so a committed
        -- double is a guaranteed hit. 442 <= 2*225 -> still a double.
        local A, B = unit(0, 0, 1), unit(442, 0, 2)
        local _, covered = Geometry.BestAoeCenter({ A, B }, 225, 0, A)
        assert_eq(covered, 2, "442u within 2*225 must double")
    end)

    it("margin via reduced radius: single past threshold (d=482, r'=225)", function()
        -- 482 > 2*225 (450): too far to GUARANTEE both -> single-target the priority.
        local A, B = unit(0, 0, 1), unit(482, 0, 2)
        local _, covered = Geometry.BestAoeCenter({ A, B }, 225, 0, A)
        assert_eq(covered, 1, "482u past the margin threshold must single-target")
    end)

    Vector = saved_vector
end)

describe("lib/farm , valuation GoldValue/EffectiveHP (R3/R4)", function()
    it("GoldValue sums gold, missing gold counts 0", function()
        assert_eq(Farm.GoldValue({ {gold=43}, {gold=56}, {} }), 99)
    end)
    it("GoldValue nil-safe", function() assert_eq(Farm.GoldValue(nil), 0) end)
    it("EffectiveHP sums hp, missing hp counts 0", function()
        assert_eq(Farm.EffectiveHP({ {hp=300}, {hp=550}, {} }), 850)
    end)
    it("EffectiveHP nil-safe", function() assert_eq(Farm.EffectiveHP(nil), 0) end)
end)

describe("lib/farm , CanClear (R3)", function()
    it("clearable when budget >= summed hp", function()
        assert_true(Farm.CanClear({ {hp=300}, {hp=300} }, 600))
    end)
    it("not clearable when budget < summed hp", function()
        assert_false(Farm.CanClear({ {hp=300}, {hp=400} }, 600))
    end)
    it("empty camp trivially clearable", function() assert_true(Farm.CanClear({}, 0)) end)
    it("nil budget cannot clear non-empty", function()
        assert_false(Farm.CanClear({ {hp=1} }, nil))
    end)
    it("ClearBudget: 1-stack ehp keeps the validated base count", function()
        assert_eq(Farm.ClearBudget(4, 1000, 960), 4)   -- need ceil(1.04)=2 < base 4
    end)
    it("ClearBudget: a stacked ehp raises the count above base", function()
        assert_eq(Farm.ClearBudget(4, 5000, 960), 6)   -- need ceil(5.2)=6 > base 4
    end)
    it("ClearBudget: zero ehp / zero dmg are safe (return base)", function()
        assert_eq(Farm.ClearBudget(3, 0, 960), 3)
        assert_eq(Farm.ClearBudget(3, 1000, 0), 3)
    end)
end)

describe("lib/farm , ScoreTarget (R4)", function()
    it("more gold per time scores higher", function()
        assert_true(Farm.ScoreTarget({gold=200,time=10}) > Farm.ScoreTarget({gold=200,time=20}))
    end)
    it("a fat far camp can beat a thin near wave", function()
        assert_true(Farm.ScoreTarget({gold=300,time=12}) > Farm.ScoreTarget({gold=160,time=8}))
    end)
    it("risk reduces score by risk*risk_weight", function()
        local safe  = Farm.ScoreTarget({gold=100,time=10,risk=0})
        local risky = Farm.ScoreTarget({gold=100,time=10,risk=1,risk_weight=4})
        assert_eq(safe - risky, 4)
    end)
    it("zero time does not divide by zero", function()
        local s = Farm.ScoreTarget({gold=100,time=0})
        assert_true(s > 0 and s == s)
    end)
    it("nil opts is 0", function() assert_eq(Farm.ScoreTarget(nil), 0) end)
end)

describe("lib/farm , IsContestedByAlly (R2)", function()
    local mid = { x = 0, y = 0 }
    it("core ally within radius contests", function()
        assert_true(Farm.IsContestedByAlly(mid, { {pos={x=200,y=0}, value=1.0} }, {radius=600, min_value=0.7}))
    end)
    it("support ally does not contest", function()
        assert_false(Farm.IsContestedByAlly(mid, { {pos={x=200,y=0}, value=0.45} }, {radius=600, min_value=0.7}))
    end)
    it("core ally outside radius does not contest", function()
        assert_false(Farm.IsContestedByAlly(mid, { {pos={x=1000,y=0}, value=1.0} }, {radius=600, min_value=0.7}))
    end)
    it("nil args not contested", function()
        assert_false(Farm.IsContestedByAlly(nil, nil))
        assert_false(Farm.IsContestedByAlly(mid, nil))
    end)
end)

describe("lib/map , pure geometry", function()
    it("_center_of_box returns the midpoint", function()
        local c = Map._center_of_box({ min={x=0,y=0,z=0}, max={x=10,y=20,z=0} })
        assert_eq(c.x, 5); assert_eq(c.y, 10)
    end)
    it("_center_of_box nil-safe", function() assert_eq(Map._center_of_box(nil), nil) end)
    it("_in_box_xy true inside, false outside", function()
        local box = { min={x=0,y=0}, max={x=10,y=10} }
        assert_true(Map._in_box_xy({x=5,y=5}, box))
        assert_false(Map._in_box_xy({x=15,y=5}, box))
    end)
    it("_filter_in_box keeps only units inside", function()
        local box = { min={x=0,y=0}, max={x=10,y=10} }
        local units = { {p={x=5,y=5}}, {p={x=50,y=50}}, {p={x=1,y=9}} }
        local kept = Map._filter_in_box(units, box, function(uu) return uu.p end)
        assert_eq(#kept, 2)
    end)
end)

describe("lib/map , nearest anchor (pure)", function()
    local items = {
        { pos = { x = 0,   y = 0 } },
        { pos = { x = 100, y = 0 } },
        { pos = { x = 500, y = 500 } },
    }
    local function pos_of(a) return a.pos end
    it("picks the anchor closest to the target", function()
        assert_true(Map._nearest({ x = 90, y = 0 }, items, pos_of) == items[2])
    end)
    it("empty list returns nil", function()
        assert_true(Map._nearest({ x = 0, y = 0 }, {}, pos_of) == nil)
    end)
end)

describe("lib/farm -- CrashCast (geometry; condensed from lib/shove)", function()
    local function near(a, b, tol) return math.abs(a - b) <= (tol or 1e-6) end
    it("stand sits standback toward the fountain from the centroid", function()
        local r = Farm.CrashCast({ x = 0, y = 0 }, { x = 1, y = 0 },
            { standback = 900, fountain = { x = -3000, y = 0 } })
        assert_true(near(r.stand.x, -900, 1) and near(r.stand.y, 0, 1), "stand 900 toward fountain")
    end)
    it("stand clamps to the fountain distance when closer than standback", function()
        local r = Farm.CrashCast({ x = 0, y = 0 }, { x = 1, y = 0 },
            { standback = 900, fountain = { x = -500, y = 0 } })
        assert_true(near(r.stand.x, -500, 1), "clamped to 500")
    end)
    it("perp is perpendicular to the creep line", function()
        local dir = { x = 3, y = 4 }
        local r = Farm.CrashCast({ x = 0, y = 0 }, dir, { fountain = { x = -1000, y = 0 } })
        local dot = r.perp.x * dir.x + r.perp.y * dir.y
        assert_true(math.abs(dot) <= 1e-6, "perp . dir ~ 0")
        assert_true(near(r.perp.x * r.perp.x + r.perp.y * r.perp.y, 1, 1e-6), "perp is unit")
    end)
    it("degenerate creep dir -> perp zero, no NaN", function()
        local r = Farm.CrashCast({ x = 10, y = 10 }, { x = 0, y = 0 }, { fountain = { x = 0, y = 0 } })
        assert_eq(r.perp.x, 0); assert_eq(r.perp.y, 0)
        assert_true(r.cast_point.x == r.cast_point.x, "cast_point.x not NaN")
    end)
end)

describe("lib/schedule -- ClearTime (hybrid)", function()
    local CAL = { march_dmg_per_cast = 300, cast_dur = 0.5, robot_kill = 1.5, rearm_channel = 1.25 }
    it("small wave -> 1 cast, no rearm gap", function()
        local r = Schedule.ClearTime(250, CAL)
        assert_eq(r.casts, 1); assert_eq(r.t_clear, 2.0)        -- 1*(0.5+1.5) + 0*1.25
    end)
    it("1.5x damage -> 2 casts with one rearm gap", function()
        local r = Schedule.ClearTime(450, CAL)
        -- Piece 2 lib review: cadence + ONE robot tail (the measured camp model, engage_done dur~8.1 vs
        -- the per-cast-robot_kill estimate 10.0) - robots deliver DURING the rearm channel, so charging
        -- robot_kill per cast double-counted the overlap.
        assert_eq(r.casts, 2); assert_eq(r.t_clear, 3.75)       -- 2*0.5 + 1*1.25 + 1.5(one tail)
    end)
    it("rounds to nearest (v0.1.99): a sub-half remainder buys no extra W - the aim fix + allied creeps finish it", function()
        assert_eq(Schedule.ClearTime(400, CAL).casts, 1)        -- 1.33 -> 1
        assert_eq(Schedule.ClearTime(500, CAL).casts, 2)        -- 1.67 -> 2
        assert_eq(Schedule.ClearTime(2012, { march_dmg_per_cast = 450 }).casts, 4)  -- 4.47 -> 4
    end)
    it("exactly one cast worth -> 1 cast", function()
        assert_eq(Schedule.ClearTime(300, CAL).casts, 1)
    end)
    it("zero / nil eff_hp -> at least 1 cast, no NaN", function()
        assert_eq(Schedule.ClearTime(0, CAL).casts, 1)
        assert_eq(Schedule.ClearTime(nil, CAL).casts, 1)
    end)
    it("dmg <= 0 guarded (no div by zero)", function()
        local r = Schedule.ClearTime(500, { march_dmg_per_cast = 0 })
        assert_true(r.casts >= 1, "casts >=1"); assert_true(r.t_clear == r.t_clear, "t_clear not NaN")
    end)
end)

describe("lib/schedule -- NextWaveArrival", function()
    it("fresh last_wave_t -> next arrival on the MEASURED phase, strictly > now", function()
        -- last_wave_t=100 (phase 10 of period 30), now=115 -> next grid point >115 = 130
        local a = Schedule.NextWaveArrival(115, 30, 22, 100, 120)
        assert_eq(a, 130); assert_true(a > 115, "strictly ahead")
    end)
    it("stale last_wave_t -> falls back to the WAVE_PHASE grid", function()
        -- last_wave_t=100 but now=400 (stale > 2*period) -> phase=22 grid: ...382,412 -> >400 = 412
        assert_eq(Schedule.NextWaveArrival(400, 30, 22, 100, 120), 412)
    end)
    it("nil last_wave_t -> WAVE_PHASE grid", function()
        -- phase 22, period 30, now=50 -> 22,52,... -> >50 = 52
        assert_eq(Schedule.NextWaveArrival(50, 30, 22, nil), 52)
    end)
    it("rolls forward when a grid point equals now", function()
        -- phase 22, now=52 (a grid point) -> next is 82
        assert_eq(Schedule.NextWaveArrival(52, 30, 22, nil), 82)
    end)
    it("early game now < phase -> the first grid point", function()
        assert_eq(Schedule.NextWaveArrival(5, 30, 22, nil), 22)
    end)
end)

describe("lib/schedule -- Plan (cycle decision)", function()
    local CAL = { march_dmg_per_cast = 300, cast_dur = 0.5, robot_kill = 1.5, rearm_channel = 1.25, lead = 1 }
    local function base(over)
        local c = { now = 100, wave = { arrival = 100, eff_hp = 450, present = true },
                    cal = CAL, travel_to_mid = 3, mana = 500, shove_cost = 200, safe = true }
        for k, v in pairs(over or {}) do c[k] = v end
        return c
    end
    it("slack <= 0 (wave due) -> shove", function()
        local d = Schedule.Plan(base({ wave = { arrival = 100, eff_hp = 450 } }))  -- leave_by=96 < now 100
        assert_eq(d.action, "shove"); assert_eq(d.reason, "due"); assert_eq(d.casts, 2)
    end)
    it("slack > 0 -> jungle with the slack value", function()
        local d = Schedule.Plan(base({ wave = { arrival = 130, eff_hp = 450 } }))  -- leave_by=126; slack=26
        assert_eq(d.action, "jungle"); assert_eq(d.reason, "slack"); assert_eq(d.slack, 26)
    end)
    it("mana < shove_cost -> recover (even with slack)", function()
        local d = Schedule.Plan(base({ wave = { arrival = 130, eff_hp = 450 }, mana = 100 }))
        assert_eq(d.action, "recover"); assert_eq(d.reason, "mana")
    end)
    it("not safe -> recover (takes precedence)", function()
        local d = Schedule.Plan(base({ wave = { arrival = 130, eff_hp = 450 }, mana = 100, safe = false }))
        assert_eq(d.action, "recover"); assert_eq(d.reason, "unsafe")
    end)
    it("leave_by + casts passed through", function()
        local d = Schedule.Plan(base({ wave = { arrival = 130, eff_hp = 250 } }))
        assert_eq(d.leave_by, 126); assert_eq(d.casts, 1); assert_eq(d.deadline, 130)
    end)

    -- ---- Plan v2 (2026-07-01): the hero veto cascade absorbed as lib rules ----
    it("F2 regen gate: mana at leave_by covers the cost -> no needless fountain trip", function()
        local d = Schedule.Plan(base({ wave = { arrival = 130, eff_hp = 450 }, mana = 100, mana_regen = 10 }))
        assert_eq(d.action, "jungle", "100 + 10*26 = 360 >= 200 at leave_by")
        assert_true(math.abs(d.mana_at_leave_by - 360) < 1e-9)
    end)
    it("F3 recover_fits: a mana-recover reports whether the round trip fits the slack", function()
        local d = Schedule.Plan(base({ wave = { arrival = 130, eff_hp = 450 }, mana = 100, recover_s = 40 }))
        assert_eq(d.action, "recover"); assert_true(not d.recover_fits, "26s slack < 40s round trip")
        d = Schedule.Plan(base({ wave = { arrival = 130, eff_hp = 450 }, mana = 100, recover_s = 20 }))
        assert_true(d.recover_fits)
    end)
    it("far_dead veto: far travel + near-dead wave -> jungle deep_skip", function()
        local d = Schedule.Plan(base({ wave = { arrival = 100, eff_hp = 300 },
                                       travel_to_mid = 13, far_travel_s = 12, min_wave_ehp = 400 }))
        assert_eq(d.action, "jungle"); assert_eq(d.reason, "deep_skip")
    end)
    it("thin veto is VISIBLE-only (fogged estimates stay anticipatory)", function()
        local d = Schedule.Plan(base({ wave = { arrival = 100, eff_hp = 300, visible = true }, thin_ehp = 400 }))
        assert_eq(d.reason, "thin_wave")
        d = Schedule.Plan(base({ wave = { arrival = 100, eff_hp = 300, visible = false }, thin_ehp = 400 }))
        assert_eq(d.action, "shove", "fogged never thin")
    end)
    it("covers=false -> no_safe_stand; covers=nil -> not applicable", function()
        local d = Schedule.Plan(base({ wave = { arrival = 100, eff_hp = 450 }, covers = false }))
        assert_eq(d.reason, "no_safe_stand")
        d = Schedule.Plan(base({ wave = { arrival = 100, eff_hp = 450 } }))
        assert_eq(d.action, "shove")
    end)
    it("bal gate: the push sim vetoes a losing fight", function()
        local d = Schedule.Plan(base({ wave = { arrival = 100, eff_hp = 450 }, bal = -3, bal_min = -2 }))
        assert_eq(d.reason, "losing_fight")
        d = Schedule.Plan(base({ wave = { arrival = 100, eff_hp = 450 }, bal = -1, bal_min = -2 }))
        assert_eq(d.action, "shove", "mildly behind is still a shove")
    end)
    it("INVARIANT (BUG-1): a VETOED jungle never resurrects through the filler", function()
        local d = Schedule.Plan(base({ wave = { arrival = 103, eff_hp = 300, visible = true }, thin_ehp = 400,
                                       filler = { min_camp_slack = 10, min_fountain_slack = 6 } }))
        assert_eq(d.action, "jungle"); assert_eq(d.reason, "thin_wave", "no near_due resurrection")
    end)
    it("filler: a genuine tight slack-jungle converts (recharge when needed+fits, else near_due)", function()
        local c = base({ wave = { arrival = 110, eff_hp = 450 } })     -- leave_by=106; slack=6; 6-3=3 < 10
        c.filler = { min_camp_slack = 10, min_fountain_slack = 6, need_recharge = true }
        local d = Schedule.Plan(c)
        assert_eq(d.action, "recover"); assert_eq(d.reason, "recharge")
        c.filler.need_recharge = false
        d = Schedule.Plan(c)
        assert_eq(d.action, "shove"); assert_eq(d.reason, "near_due")
        c.suppressed = true
        d = Schedule.Plan(c)
        assert_eq(d.action, "recover"); assert_eq(d.reason, "shove_stuck")
    end)
    it("INVARIANT (v0.1.197, BUG-1 sibling): the filler's near_due conversion passes the shove vetoes", function()
        -- run-26 t=220.4: slack>0 made the initial action jungle/slack, so the vetoes never saw
        -- the wave; the filler flipped it to shove/near_due at a covers=false stand 1086 deep ->
        -- a 2435u walk + a 19s-early deep wait. The conversion must re-run the veto chain.
        local c = base({ wave = { arrival = 110, eff_hp = 1650, visible = true }, covers = false })
        c.filler = { min_camp_slack = 10, min_fountain_slack = 6 }   -- slack 6 - travel 3 < 10 -> filler window
        local d = Schedule.Plan(c)
        assert_eq(d.action, "jungle"); assert_eq(d.reason, "no_safe_stand", "no near_due at an illegal stand")
        c.covers = nil; c.gone = true
        d = Schedule.Plan(c)
        assert_eq(d.action, "jungle"); assert_eq(d.reason, "gone_by_arrival", "no near_due at a dead wave")
    end)
    it("INVARIANT (v0.1.198): defend_crash never overrides covers=false (no defense at an illegal stand)", function()
        local d = Schedule.Plan(base({ wave = { arrival = 100, eff_hp = 450 },
                                       covers = false, defend_crash = true }))
        assert_eq(d.action, "jungle"); assert_eq(d.reason, "no_safe_stand")
        d = Schedule.Plan(base({ wave = { arrival = 130, eff_hp = 450 }, defend_crash = true }))
        assert_eq(d.action, "shove"); assert_eq(d.reason, "defend_crash", "a legal defense still fires")
    end)
    it("defend_crash forces the shove over any veto - EXCEPT unsafe (v2 deliberate fix)", function()
        local d = Schedule.Plan(base({ wave = { arrival = 100, eff_hp = 300, visible = true },
                                       thin_ehp = 400, defend_crash = true }))
        assert_eq(d.action, "shove"); assert_eq(d.reason, "defend_crash")
        d = Schedule.Plan(base({ wave = { arrival = 100, eff_hp = 450 }, safe = false, defend_crash = true }))
        assert_eq(d.action, "recover"); assert_eq(d.reason, "unsafe", "never forced into a gank")
    end)
    it("LAW (v0.1.78-83 graveyard): the deadline is ALWAYS the current wave - no defer path exists", function()
        for _, over in ipairs({ {}, { covers = false }, { bal = -9, bal_min = -2 } }) do
            local c = base({ wave = { arrival = 137, eff_hp = 450 } })
            for k, v in pairs(over) do c[k] = v end
            assert_eq(Schedule.Plan(c).deadline, 137)
        end
    end)
    it("far_wave (Risk v2 axis 2): round-trip travel beyond camp_alt_s -> jungle", function()
        -- travel 20 -> RT 40 > 30: the walk out-costs ~2 camp clears
        local d = Schedule.Plan(base({ wave = { arrival = 100, eff_hp = 450 }, travel_to_mid = 20, camp_alt_s = 30 }))
        assert_eq(d.action, "jungle"); assert_eq(d.reason, "far_wave")
        -- travel 12 -> RT 24 <= 30: the normal mid trip stays a shove
        d = Schedule.Plan(base({ wave = { arrival = 100, eff_hp = 450 }, travel_to_mid = 12, camp_alt_s = 30 }))
        assert_eq(d.action, "shove")
        -- no camp_alt_s -> rule inactive (back-compat)
        d = Schedule.Plan(base({ wave = { arrival = 100, eff_hp = 450 }, travel_to_mid = 20 }))
        assert_eq(d.action, "shove")
    end)
    it("far_wave: defend_crash still overrides (never skip defending our tower)", function()
        local d = Schedule.Plan(base({ wave = { arrival = 100, eff_hp = 450 }, travel_to_mid = 20,
                                       camp_alt_s = 30, defend_crash = true }))
        assert_eq(d.action, "shove"); assert_eq(d.reason, "defend_crash")
    end)
    it("gone_by_arrival (run-21): the enemy wave dies to ours before we can arrive -> jungle", function()
        local d = Schedule.Plan(base({ wave = { arrival = 100, eff_hp = 450 }, gone = true }))
        assert_eq(d.action, "jungle"); assert_eq(d.reason, "gone_by_arrival")
        d = Schedule.Plan(base({ wave = { arrival = 100, eff_hp = 450 } }))
        assert_eq(d.action, "shove", "nil gone = rule inactive")
        d = Schedule.Plan(base({ wave = { arrival = 100, eff_hp = 450 }, gone = true, defend_crash = true }))
        assert_eq(d.action, "shove"); assert_eq(d.reason, "defend_crash", "a wave crashing OUR tower is never gone")
    end)
end)

describe("lib/farm -- DepthPoints (Risk v2 axis 1, the user point system)", function()
    it("zero at and inside the T1 line", function()
        assert_eq(Farm.DepthPoints(0, {}), 0)
        assert_eq(Farm.DepthPoints(-500, {}), 0)
        assert_eq(Farm.DepthPoints(nil, {}), 0)
    end)
    it("accrues past the line; the alive T1 doubles, each standing side T1 adds 25%", function()
        assert_eq(Farm.DepthPoints(1000, {}), 1000)
        assert_eq(Farm.DepthPoints(1000, { line_alive = true }), 2000)
        assert_eq(Farm.DepthPoints(1000, { side_t1_up = 2 }), 1500)
        assert_eq(Farm.DepthPoints(1000, { line_alive = true, side_t1_up = 2 }), 3000)
    end)
    it("the Keen shave subtracts flat and floors at zero", function()
        assert_eq(Farm.DepthPoints(1100, { side_t1_up = 2, shave = 1500 }), 150)   -- 1650 - 1500
        assert_eq(Farm.DepthPoints(200, { shave = 1500 }), 0)
    end)
end)

describe("lib/schedule -- EVENTS + NextEvent (the Dota clock, general scheduling)", function()
    it("grid events: power rune honors its first spawn, then the 2:00 grid", function()
        assert_eq(Schedule.NextEvent("power_rune", 100), 360)     -- before the 6:00 first spawn
        assert_eq(Schedule.NextEvent("power_rune", 400), 480)
    end)
    it("one-shot events: water runes expire after 4:00", function()
        assert_eq(Schedule.NextEvent("water_rune", 130), 240)
        assert_true(Schedule.NextEvent("water_rune", 300) == nil)
    end)
    it("kill-anchored events: tormentor first at 20:00, then kill + 10:00 (caller passes the kill)", function()
        assert_eq(Schedule.NextEvent("tormentor", 100), 1200)
        assert_true(Schedule.NextEvent("tormentor", 1300) == nil, "alive/unknown: no grid")
        assert_eq(Schedule.NextEvent("tormentor", 1600, 1500), 2100)
    end)
    it("day/night phases on the 10:00 grid", function()
        assert_eq(Schedule.NextEvent("night_start", 100), 300)
        assert_eq(Schedule.NextEvent("night_start", 400), 900)
        assert_eq(Schedule.NextEvent("day_start", 400), 600)
    end)
    it("unknown event -> nil; NextOnGrid is strictly future", function()
        assert_true(Schedule.NextEvent("roshan_dance", 0) == nil)
        assert_eq(Schedule.NextOnGrid(90, 30, 0), 120)
        assert_eq(Schedule.NextOnGrid(120, 30, 0), 150)           -- exactly on the boundary -> next
    end)
end)

describe("lib/schedule -- SeqFits (ability/channel sequence fitting)", function()
    it("keen + rearm before leave_by: fits with start_by reported", function()
        local r = Schedule.SeqFits({ 2.93, 2.69 }, 110, 100)
        assert_true(r.fits); assert_true(math.abs(r.total - 5.62) < 1e-9)
        assert_true(math.abs(r.start_by - 104.38) < 1e-9)
    end)
    it("a combo that does not fit the window reports fits=false", function()
        local r = Schedule.SeqFits({ 0.45, 0.3, 0.55, 1.7 }, 101, 100)   -- 3.0s combo, 1s window
        assert_true(not r.fits)
    end)
    it("empty sequence always fits, start_by = deadline", function()
        local r = Schedule.SeqFits({}, 50, 10)
        assert_true(r.fits); assert_eq(r.start_by, 50)
    end)
end)

describe("lib/farm -- neutral camps + stacking + dps clear (future-hero additions)", function()
    it("NEUTRAL_STATS carries the 4 tiers with the verified representative stats", function()
        assert_eq(Farm.NEUTRAL_STATS[0].armor, 0)          -- kobold
        assert_eq(Farm.NEUTRAL_STATS[1].mr, 0.30)          -- mud golem 30% MR
        assert_eq(Farm.NEUTRAL_STATS[2].armor, 4)          -- hellbear smasher
        assert_eq(Farm.NEUTRAL_STATS[3].hp, 2000)          -- ancient black dragon
    end)
    it("CampCombatants builds SimFight-ready records; an ancient camp beats a small camp", function()
        local small, anc = Farm.CampCombatants(0), Farm.CampCombatants(3)
        assert_eq(#anc, Farm.NEUTRAL_STATS[3].n)
        assert_eq(anc[1].armor, 4); assert_eq(anc[1].atype, "basic")
        local f = Lane.SimFight(small, anc, { dt = 0.25 })
        assert_eq(f.winner, "b", "ancients out-attrition kobolds")
    end)
    it("ClearTimeDPS applies the armor formula; zero dps -> huge", function()
        local t = Farm.ClearTimeDPS(1900, 100, 4)          -- mult = 1 - 0.24/1.24 = 0.8065
        assert_true(math.abs(t - 23.56) < 0.1, "1900 / (100*0.8065)")
        assert_true(Farm.ClearTimeDPS(1000, 0) == math.huge)
    end)
    it("StackWindow: next :00 spawn, pull = spawn - lead, rolls when the pull passed", function()
        local w = Farm.StackWindow(100, 6)
        assert_eq(w.spawn_at, 120); assert_eq(w.pull_at, 114)
        w = Farm.StackWindow(115, 6)                       -- 114 already passed -> next minute
        assert_eq(w.spawn_at, 180); assert_eq(w.pull_at, 174)
    end)
end)

describe("lib/farm -- stand predicates (condensed from lib/farm_decide)", function()
    it("MarchCovers: meeting within reach -> true, beyond -> false", function()
        assert_true(Farm.MarchCovers({x=0,y=0}, {x=1100,y=0}))          -- 1100 < 1200 reach
        assert_true(not Farm.MarchCovers({x=0,y=0}, {x=1300,y=0}))      -- 1300 > 1200
        assert_true(Farm.MarchCovers({x=0,y=0}, {x=500,y=0}, 600))      -- custom reach
        assert_true(not Farm.MarchCovers({x=0,y=0}, {x=700,y=0}, 600))
        assert_true(not Farm.MarchCovers(nil, {x=0,y=0}))
    end)
    it("OutsideTowerRange: inside 700 -> false, outside -> true, margin respected", function()
        local towers = { { x = 0, y = 0 } }
        assert_true(not Farm.OutsideTowerRange({x=600,y=0}, towers))    -- 600 < 700
        assert_true(Farm.OutsideTowerRange({x=800,y=0}, towers))        -- 800 > 700
        assert_true(not Farm.OutsideTowerRange({x=800,y=0}, towers, 700, 150))  -- 800 < 850
        assert_true(Farm.OutsideTowerRange({x=900,y=0}, {}))            -- no towers -> safe
    end)
end)

local MD = require("lib.map_data")

describe("lib/map -- pure helpers", function()
    -- box shape: {min={x,y,z?}, max={x,y,z?}}  (engine AABB from Camp.GetCampBox)
    -- NOT the flat {minx,miny,maxx,maxy} used by map_data.CAMPS

    it("_center_of_box: midpoint on xy, z defaults to 0 when absent", function()
        local c = Map._center_of_box({ min = { x = 0, y = 0 }, max = { x = 10, y = 20 } })
        assert_true(c ~= nil, "non-nil result")
        assert_eq(c.x, 5)
        assert_eq(c.y, 10)
        assert_eq(c.z, 0)
    end)

    it("_center_of_box: z included when both min.z and max.z are present", function()
        local c = Map._center_of_box({ min = { x = 0, y = 0, z = 100 }, max = { x = 10, y = 20, z = 200 } })
        assert_eq(c.z, 150)
    end)

    it("_center_of_box: nil/bad input -> nil", function()
        assert_true(Map._center_of_box(nil) == nil)
        assert_true(Map._center_of_box({}) == nil)
        assert_true(Map._center_of_box({ min = { x = 0 } }) == nil)
    end)

    it("_in_box_xy: inside returns true", function()
        local box = { min = { x = 0, y = 0 }, max = { x = 100, y = 100 } }
        assert_true(Map._in_box_xy({ x = 50, y = 50 }, box))
    end)

    it("_in_box_xy: on the boundary returns true (inclusive)", function()
        local box = { min = { x = 0, y = 0 }, max = { x = 100, y = 100 } }
        assert_true(Map._in_box_xy({ x = 0, y = 0 }, box))
        assert_true(Map._in_box_xy({ x = 100, y = 100 }, box))
    end)

    it("_in_box_xy: outside returns false", function()
        local box = { min = { x = 0, y = 0 }, max = { x = 100, y = 100 } }
        assert_false(Map._in_box_xy({ x = 101, y = 50 }, box))
        assert_false(Map._in_box_xy({ x = 50, y = -1 }, box))
    end)

    it("_in_box_xy: nil pos/box -> false", function()
        local box = { min = { x = 0, y = 0 }, max = { x = 100, y = 100 } }
        assert_false(Map._in_box_xy(nil, box))
        assert_false(Map._in_box_xy({ x = 50, y = 50 }, nil))
    end)

    it("_filter_in_box: keeps units inside, drops units outside", function()
        local box = { min = { x = 0, y = 0 }, max = { x = 100, y = 100 } }
        local units = { { pos = { x = 50, y = 50 } }, { pos = { x = 200, y = 50 } }, { pos = { x = 10, y = 10 } } }
        local out = Map._filter_in_box(units, box, function(u) return u.pos end)
        assert_eq(#out, 2)
    end)

    it("_filter_in_box: nil list -> empty table, no crash", function()
        local box = { min = { x = 0, y = 0 }, max = { x = 100, y = 100 } }
        local out = Map._filter_in_box(nil, box, function(u) return u end)
        assert_eq(#out, 0)
    end)

    it("_nearest: picks the closest item by xy distance", function()
        local items = { { pos = { x = 10, y = 0 } }, { pos = { x = 100, y = 0 } }, { pos = { x = 3, y = 0 } } }
        local best, dist = Map._nearest({ x = 0, y = 0 }, items, function(i) return i.pos end)
        assert_true(best ~= nil)
        assert_eq(best.pos.x, 3)
        assert_true(math.abs(dist - 3) < 1e-6)
    end)

    it("_nearest: returns both item and euclidean distance", function()
        local items = { { pos = { x = 3, y = 4 } } }
        local _, dist = Map._nearest({ x = 0, y = 0 }, items, function(i) return i.pos end)
        assert_true(math.abs(dist - 5) < 1e-6, "3-4-5 triangle, got " .. tostring(dist))
    end)

    it("_nearest: empty list -> nil, nil", function()
        local best, dist = Map._nearest({ x = 0, y = 0 }, {}, function(i) return i.pos end)
        assert_true(best == nil and dist == nil)
    end)

    it("_nearest: nil target -> nil", function()
        local items = { { pos = { x = 10, y = 0 } } }
        local best = Map._nearest(nil, items, function(i) return i.pos end)
        assert_true(best == nil)
    end)
end)

describe("lib/map_data -- structure self-check", function()
    it("at least 18 camps", function()
        assert_true(#MD.CAMPS >= 18, "expected >= 18 camps, got " .. #MD.CAMPS)
    end)
    it("at least 22 towers", function()
        assert_true(#MD.TOWERS >= 22, "expected >= 22 towers, got " .. #MD.TOWERS)
    end)
    it("every camp has center and a 4-element box", function()
        for i, c in ipairs(MD.CAMPS) do
            assert_true(c.center ~= nil, "camp " .. i .. " missing center")
            assert_true(c.box ~= nil, "camp " .. i .. " missing box")
            -- ponytail: box is a flat {minx,miny,maxx,maxy} array, not a struct
            assert_true(c.box[1] ~= nil and c.box[2] ~= nil, "camp " .. i .. " box missing elements")
        end
    end)
    it("at least 2 mid-T1 towers (goodguys + badguys)", function()
        local n = 0
        for _, t in ipairs(MD.TOWERS) do
            if t.name:find("tower1_mid") then n = n + 1 end
        end
        assert_true(n >= 2, "expected >= 2 tower1_mid entries, got " .. n)
    end)
end)

describe("lib/lane -- TrackFrontSpeed: measured front displacement (arc B)", function()
    local L = require("lib.lane")
    it("steady march measures ~stat", function()
        local tr, spd = L.TrackFrontSpeed({}, "mid:enemy", { x = 0, y = 0 }, 100)
        assert_eq(spd, nil, "first sample has no dt")
        tr, spd = L.TrackFrontSpeed(tr, "mid:enemy", { x = 650, y = 0 }, 102)     -- 325 u/s
        tr, spd = L.TrackFrontSpeed(tr, "mid:enemy", { x = 1300, y = 0 }, 104)
        assert_true(spd and spd > 300 and spd < 350, "expected ~325, got " .. tostring(spd))
    end)
    it("a held wave decays toward 0 and recovers within ~2 samples", function()
        local tr, spd = L.TrackFrontSpeed({}, "k", { x = 0, y = 0 }, 100)
        tr, spd = L.TrackFrontSpeed(tr, "k", { x = 650, y = 0 }, 102)             -- marching
        tr, spd = L.TrackFrontSpeed(tr, "k", { x = 650, y = 0 }, 104)             -- held
        tr, spd = L.TrackFrontSpeed(tr, "k", { x = 650, y = 0 }, 106)
        tr, spd = L.TrackFrontSpeed(tr, "k", { x = 655, y = 0 }, 108)
        assert_true(spd and spd < 80, "held wave should read <80, got " .. tostring(spd))
        tr, spd = L.TrackFrontSpeed(tr, "k", { x = 1305, y = 0 }, 110)            -- released
        tr, spd = L.TrackFrontSpeed(tr, "k", { x = 1955, y = 0 }, 112)
        assert_true(spd and spd > 200, "release should recover within ~2 samples, got " .. tostring(spd))
    end)
    it("a front JUMP (new wave replaced the old) resets the measurement", function()
        local tr, spd = L.TrackFrontSpeed({}, "k", { x = 0, y = 0 }, 100)
        tr, spd = L.TrackFrontSpeed(tr, "k", { x = 650, y = 0 }, 102)
        tr, spd = L.TrackFrontSpeed(tr, "k", { x = 4000, y = 0 }, 104)            -- 1675 u/s = a jump
        assert_eq(spd, nil, "jump resets; no speed until a fresh dt")
        tr, spd = L.TrackFrontSpeed(tr, "k", { x = 4650, y = 0 }, 106)
        assert_true(spd and spd > 300, "fresh measurement after the reset")
    end)
    it("stale sample returns nil (fog)", function()
        local tr, spd = L.TrackFrontSpeed({}, "k", { x = 0, y = 0 }, 100)
        tr, spd = L.TrackFrontSpeed(tr, "k", { x = 650, y = 0 }, 102)
        assert_true(spd ~= nil)
        local _, spd2 = L.TrackFrontSpeed(tr, "k", nil, 112)                      -- no front for 10s
        assert_eq(spd2, nil)
    end)
end)

describe("lib/towers -- registry: alive flag + measured hp-slope death eta", function()
    local TW = require("lib.towers")
    local KEY = "tower1_mid@3"
    it("melt extrapolation: eta ~= hp/rate", function()
        local st = TW.Track({}, { { key = KEY, hp = 1800, alive = true } }, 100)
        st = TW.Track(st, { { key = KEY, hp = 1700, alive = true } }, 102)   -- 50 hp/s
        st = TW.Track(st, { { key = KEY, hp = 1600, alive = true } }, 104)
        local eta = TW.DeathEta(st, KEY, 104)
        assert_true(eta > 25 and eta < 40, "eta ~32s expected, got " .. tostring(eta))
    end)
    it("undamaged tower predicts huge", function()
        local st = TW.Track({}, { { key = KEY, hp = 1800, alive = true } }, 100)
        st = TW.Track(st, { { key = KEY, hp = 1800, alive = true } }, 102)
        assert_eq(TW.DeathEta(st, KEY, 102), math.huge)
    end)
    it("dead latch is permanent (towers never revive)", function()
        local st = TW.Track({}, { { key = KEY, hp = 500, alive = true } }, 100)
        st = TW.Track(st, { { key = KEY, alive = false } }, 102)
        st = TW.Track(st, { { key = KEY, hp = 1800, alive = true } }, 104)   -- mis-key/noise: ignored
        assert_eq(TW.Alive(st, KEY), false)
        assert_eq(TW.DeathEta(st, KEY, 104), 0)
    end)
    it("stale sample disables the prediction (fog decays to OFF)", function()
        local st = TW.Track({}, { { key = KEY, hp = 1800, alive = true } }, 100)
        st = TW.Track(st, { { key = KEY, hp = 1600, alive = true } }, 102)
        assert_true(TW.DeathEta(st, KEY, 103) < math.huge, "fresh melt should predict")
        assert_eq(TW.DeathEta(st, KEY, 112), math.huge)   -- 10s stale > stale_s 6
    end)
    it("never-sampled key: Alive nil, eta huge", function()
        local st = {}
        assert_eq(TW.Alive(st, KEY), nil)
        assert_eq(TW.DeathEta(st, KEY, 100), math.huge)
    end)
    it("EMA smooths a noisy rate", function()
        local st = TW.Track({}, { { key = KEY, hp = 2000, alive = true } }, 100)
        st = TW.Track(st, { { key = KEY, hp = 1900, alive = true } }, 102)   -- 50 hp/s
        st = TW.Track(st, { { key = KEY, hp = 1900, alive = true } }, 104)   -- 0 hp/s
        local eta = TW.DeathEta(st, KEY, 104)
        assert_true(eta < math.huge, "EMA slope (~25 hp/s) should still predict, got " .. tostring(eta))
    end)
    it("heal/backdoor regen resets the melt read", function()
        local st = TW.Track({}, { { key = KEY, hp = 1000, alive = true } }, 100)
        st = TW.Track(st, { { key = KEY, hp = 900, alive = true } }, 102)
        st = TW.Track(st, { { key = KEY, hp = 1100, alive = true } }, 104)   -- healing up
        assert_eq(TW.DeathEta(st, KEY, 104), math.huge)
    end)
end)

----------------------------------------------------------------------------
-- REPORT
----------------------------------------------------------------------------

print()
print(string.format("%d passed, %d failed", pass, fail))
if fail > 0 then
    print()
    for i = 1, #fails do
        print("FAIL: " .. fails[i].name)
        print("  " .. tostring(fails[i].err))
    end
    os.exit(1)
end
os.exit(0)
