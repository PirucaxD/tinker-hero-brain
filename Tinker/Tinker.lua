---@meta
---Tinker brain (farm-first). The auto-farm subsystem (Layer F) on the Lina/Sniper
---brain skeleton. See Tinker/FARM_PATTERN.md (the Layer F spec),
---Tinker/TINKER_BRAIN_SKELETON.md (the shell), Tinker/BRIDGE_TINKER_NEW_HERO.md.
---
---F0: the scope-A farm FSM re-homed onto the skeleton, NO farm-behavior change.
---Shell = cache-clear+require, Logger/tlog telemetry, the State table, setup_menu
---(Find-then-Create under Heroes/Hero List/Tinker/Brain), callbacks.OnUpdateEx
---layered dispatch, the hero-gate wrapper, return callbacks. The order chokepoint
---stays direct issue() (V2-confirmed issuer/flags that fire the point casts);
---now() stays GameRules.GetGameTime() to avoid a timing change in the re-home.
---Jungle only; lane/split-push/stacking + the farm-button (F5) + defense/offense
---are later phases. UNVERIFIED in-engine: F1 = in-client calibration.

if package and package.loaded then
    for _, m in ipairs({ "lib.map", "lib.farm", "lib.lane", "lib.route", "lib.nav", "lib.schedule",
                         "lib.escape", "lib.hero_value", "lib.geometry", "lib.map_data" }) do
        package.loaded[m] = nil
    end
end
local Map       = require("lib.map")
local Farm      = require("lib.farm")
local HeroValue = require("lib.hero_value")
local MapData   = require("lib.map_data")   -- static positions fallback (camps/towers/outposts/fountains)
local Lane      = require("lib.lane")        -- lane intel (waves + clash + intercept), Task C foundation
local Route     = require("lib.route")       -- farm-route planner (Stage 0: diagnostic only)
local Nav       = require("lib.nav")          -- lane nav chokepoint (Piece 0): SafeDest clamp + transport ladder
-- (lib.shove + lib.farm_decide were CONDENSED into lib.farm 2026-07-01 - cohesive domain libs, like
-- C's math.h: Farm.CrashCast / Farm.MarchCovers / Farm.OutsideTowerRange.)
local Schedule  = require("lib.schedule")     -- timing-anchored shove-cycle controller (ClearTime + Plan)
local Escape    = require("lib.escape")        -- fog-aware proximity risk (COR-1)
local Geometry  = require("lib.geometry")      -- pure geometry: teleport reach-disc landing (Keen/BoT)

local UO = Enum.UnitOrder
local HERO_KEY = "tinker"

-- Forward-declared module state; telemetry + helpers capture it as an upvalue.
local State = {}

----------------------------------------------------------------- telemetry --
-- Logger is a callable TABLE (not a function); construct via pcall, else a
-- type=="function" guard silences all logging. Writes [INFO] [Tinker] to
-- C:\Umbrella\debug.log (same channel as Lina/Sniper).
local LOG
do local ok, l = pcall(function() return Logger("Tinker") end); if ok then LOG = l end end

local function v_level()
    if State.menu and State.menu.diag then return State.menu.diag:Get() end
    return 1
end

-- Verbosity-gated structured logging: "event | k=v | k=v". level 0=err 1..2=info 3=trace.
local function tlog(level, event, kv)
    if not LOG then return end
    if level > v_level() then return end
    local parts = { event }
    if kv then
        for k, v in pairs(kv) do parts[#parts + 1] = tostring(k) .. "=" .. tostring(v) end
    end
    local msg = table.concat(parts, " | ")
    if     level == 0 then pcall(function() LOG:error(msg) end)
    elseif level <= 2 then pcall(function() LOG:info(msg) end)
    else                   pcall(function() LOG:debug(msg) end)
    end
end

-- Legacy line logger: routes the scope-A logline(string) calls through tlog at
-- level 1 so they stay verbosity-gated. New code calls tlog(level, event, kv).
local function logline(s) tlog(1, s) end

-- ── tuning (all calibratable; March extents confirmed only in-game) ──────────
local K = {
    HERO            = "npc_dota_hero_tinker",
    MARCH_LEN       = 1800, MARCH_HALFWIDTH = 900, MARCH_CAST_RANGE = 300,   -- coverage = rectangle CENTRED on the cast point: +/- MARCH_LEN/2 along facing, +/- HALFWIDTH perpendicular (Liquipedia: target = area centre; robots spawn at the back edge behind Tinker). CALIBRATED in-client 2026-06-24: the real sweep is a ~SQUARE box (HALFWIDTH 900, was a too-thin 450); MARCH_LEN kept canonical 1800 (the real footprint reads slightly longer but that's likely item/level/just visual).
    ARRIVE_DIST     = 120,   -- must be THIS close to the computed stand before casting W (so the cast point at the camp centre is within cast range)
    MARCHES         = { [0] = 2, [1] = 2, [2] = 2, [3] = 4 },  -- per camp tier 0=small 1=medium 2=large 3=ancient (0-indexed). v0.1.183 user-calibrated PLANNING floors (per-creep damage model): small/medium/large 2 (big camps clear in 2, at most 3 - the live execution budget tops up the occasional 3rd from the on-arrival ehp; Bottle/regen cover its mana), ancient 4 (user: 3-4, Dragon ~5 self-corrects live).
    STACK_AGGRO_SEC = 54.0,                       -- v0.1.224 STACKING (user: LARGE camps only, 2x cap, GPM-first): aggro second-of-minute (Liquipedia: most camps ~:54-55, varies by box) - the old creeps cross the :00 respawn and the camp doubles. Calibrate off stack_done -> next-cycle cstk=2.
    STACK_STAND_DIST = 450,                       -- stand this far from the camp centre toward our fountain for the aggro attack (Tinker attack range 500)
    STACK_FLEE_DIST  = 700,                       -- after the aggro, drag the creeps this far past the stand until :00 (out of the spawn box)
    STACK_VALUE_FRAC = 0.6,                       -- planner value of a stack node = the camp's gold x this (the extra gold lands NEXT cycle; same discount spirit as ROUTE_STEP_DECAY)
    MAX_CLEAR_MARCHES = 6,                                    -- cap on Marches to clear ONE camp. A camp is a candidate iff clearable within this (ceil(ehp/per-cast dmg) <= this); the same cap bounds the valuation + execution count. Unifies candidacy with execution (was: candidacy used a fixed tier count while execution added Marches -> tanky/stacked/low-March-level camps wrongly excluded). Calibrate.
    PER_MARCH_DMG   = { 13, 22, 31, 40 },                     -- detonate dmg per robot per March level (7.41c)
    ROBOTS_EFFECTIVE = 24,                                    -- robots that realistically detonate on a clustered camp (CALIBRATE; max 144)
    CAMP_MR         = { [0] = 0.0, [1] = 0.0, [2] = 0.0, [3] = 0.30 }, -- coarse fallback by tier; live per-unit MR read is primary
    REARM_CHANNEL   = { 2.69, 1.93, 1.20 },                  -- channel time per Rearm level (IN-CLIENT v0.1.130 capture; was 2.75/2/1.25)
    CHANNEL_PAD     = 0.20,                                   -- timer backstop beyond the channel
    KEEN_CHANNEL    = 2.93,                                   -- Keen channel, FLAT all levels (IN-CLIENT v0.1.130 capture; was a padded 4.0 -> overestimated keen-travel ~1s on every timing decision). Also the InterceptETA travel cost.
    KEEN_LAND_STRUCTURE = 700,                                -- Keen reach radius around a tower/building: we can land ANYWHERE within this of it (user-confirmed 700, not the KV 800). We cast at the point in this disc nearest the stand, so travel ~= 0 when a tower covers the stand.
    KEEN_LAND_OUTPOST   = 250,                                -- ... and this of an outpost/watch-tower
    KEEN_CREEP_MIN_HP   = 300,                                -- v0.1.215: a keen-anchor creep must survive the ~3s channel (a dying one cancels the keen + burns the cd). Rear units (ranged/siege) are preferred structurally; this floors the rest. Calibrate.
    KEEN_CREEP_DRIFT_S  = 3.5,                                -- v0.1.228/236 (user rule, motion-aware): creep-anchor exclusion around ALIVE enemy towers = TOWER_RISK_RADIUS 900 + measured lane wave speed x this (the cast->teleport window: KEEN_CHANNEL + pad + order latency). Marching wave 325 -> ~2040 (the v0.1.228 worst case); stalled tower fight -> rear creeps eligible again (run-54 over-exclusion fix). Calibrate.
    KEEN_WAIT_MARGIN    = 4.0,                                -- v0.1.232 wait-for-keen rung: hold for the keen cd only when cd + channel + this margin still beats the walk (short walks keep walking). Calibrate.
    KEEN_CREEP_CLEAR    = 250,                                -- reject a keen landing with an ALLIED lane creep within this (Keen L2 auto-conveys to the nearest ally -> the creep would hijack the landing + cancel when it moves/dies). Jungle has none; matters near lanes. Calibrate.
    KEEN_TREE_CLEAR     = 140,                                -- a keen landing needs no TREE within this (GridNav.IsTraversable does NOT flag trees, so a disc-edge point can land in a grove -> stuck). The landing is nudged toward the anchor onto clear ground. Calibrate (hero radius + tree hull).
    KEEN_LAND_SAFE_RISK = 0.35,                               -- TRAVEL-BLINK landing gate: don't blink to a landing whose fog-aware risk + tower risk is >= this (a blink is instant, no en-route abort). The KEEN landing moved to the count-aware lane_unsafe gate at v0.1.157 (glue review F5; the raw gate rejected every landing near a healthy 1v1).
    KEEN_DEPTH_MARGIN   = 150,                                -- HARD STOP for the keen LANDING: a keen lands at the ANCHOR, not the (depth-capped) stand, so it could jump PAST the safe stand under the enemy tower (v0.1.143 capped the stand only). Reject any anchor whose stand_depth is more than this past the safe stand's depth (small margin for the keen's landing scatter). Calibrate.
    FOUNTAIN_WALK_IN    = 1200,                               -- note 5: when within this of the fountain but lacking the regen buff, WALK in (keen lands 70-800 NEAR it, often outside the zone) instead of re-keening outside.
    RETURN_RESUME_FRAC  = 0.70,                               -- note 2 (over-return): abort the trip home + resume farming when mana AND hp recover to this fraction of max EN ROUTE and it's safe (regen/Bottle often refill before we arrive; we were teleporting to base at 70% mana).
    ESCAPE_MANA     = 150,
    REFILL_FRAC     = 0.70,                         -- leave base + Keen back to the farm at THIS fraction of max HP AND mana (was ~full); do not idle at base to 100%.
    PANIC_HP        = 0.40, PANIC_ARM = 0.25,
    CONTEST_RADIUS  = 700,
    CONTEST_CORE_BASE = 0.55,                      -- a lane wave is YIELDED to a CORE ally: role 1-3 (if a role API exists) OR role-tag base value >= this (carry/nuker/pusher/initiator/durable/disabler/escape >= 0.55; jungler/support/default below). Tunable.
    RISK_RADIUS     = 1400, RISK_HARD = 0.34,   -- camp-selection veto: a camp with risk >= this is NOT picked. Lowered 0.45->0.34 (v0.1.90) so DIRE-side / contested camps (a Radiant Tinker was farming dire camps at risk 0.36-0.44 under the old 0.45) are vetoed; own jungle + own ancient (~0.29-0.32) + up to the river still farm. Tight boundary (own ancient ~0.32 vs dire camp ~0.36); calibrate.
    GANK_RADIUS     = 1000,                      -- v0.1.95: lane_unsafe counts a GANK (>=2 enemies) only within this of the point - 2 DISTANT enemies (the v0.1.94 log recovered at risk 0.06 with enH=2 ~1057u away) are not a gank. Tighter than RISK_RADIUS. ponytail ceiling.
    GANK_FOG_REACH  = 600,                       -- v0.1.158 (F4 recalibration): cap on how far a FOGGED enemy's probable disc extends its gank reach (~1.1s of fog) - the raw disc hits 2750u at the age cap and matched stale enemies from half a screen away (risk-0.14 aborts).
    TOWER_ALIVE_R     = 300,                       -- v0.1.105 lane-prioritization: an enemy tower this near a static T1 spot = that T1 is alive (towers don't move; T1<->T2 mid are ~2200u apart so no cross-match). ponytail ceiling.
    TOWER_RISK_RADIUS = 900, TOWER_RISK_WEIGHT = 0.7, TOWER_ATTACK_RANGE = 700,   -- Deep 1 (v0.1.76 PLATEAU): the live-abort positional veto. A live enemy tower within ATTACK_RANGE = full WEIGHT (decisively unsafe), tapering linearly to 0 at RADIUS. WEIGHT 0.7 > SHOVE_SAFE_RISK 0.35 so lane_unsafe trips within ~800; catches the v0.1.73 death stand (791u -> 0.38).
    TOWER_SAFE_MARGIN = 200,                       -- note 1 / option A (v0.1.159): a STAND must sit at least ATTACK_RANGE + this from every alive enemy tower (900 = the taper edge, risk 0). The old risk<0.35 gate stopped clamping at ~800 = "barely outside" the tower. March reach (1200) still covers 300 past the tower from 900, so the tower-border W-farm is intact. Stricter than the live abort = the SAFE direction of the v0.1.148 consistency rule.
    FRONTIER_CACHE_S  = 0.5,                       -- structure-list cache for frontier_excess (enumerating every call inside the 40-step clamp loop is waste)
    FOG_MS = 550, FOG_SPREAD = 900, FOG_AGE_CAP = 5,        -- COR-1: fogged-enemy disc growth (Liquipedia move cap) / confidence decay length / drop fog staler than this (s). Tune off the `sched ... risk=` log.
    FARM_SAFE_RISK  = 0.42,                                 -- Part A (N3): abort a COMMITTED camp trip (move/engage) when LIVE fog-aware risk at the stand hits this; mark cleared + recover so the planner picks elsewhere (no churn). Below RISK_HARD 0.45 so it bails before the camp would re-veto.
    STAND_RING      = 250, STAND_STEP = 30,    -- stand THIS far from the camp CENTRE (< March cast range 300) so W lands on the creep cluster + the hero has vision. The old box-corner ring (cluster_radius+margin) put the stand ~800 out (box half-diag ~737), past cast range, casting short into fog.
    PAIR_RADIUS     = 1800,                       -- pair an assumed-occupied partner within this. The centred March covers up to MARCH_LEN apart, so set ~= MARCH_LEN; 1500 wrongly excluded the river/lane pairs at d=1500-1800. Lower to skip far/edge-clipping pairs. (Specific over-range pairs are whitelisted via K.FORCE_PAIRS.)
    CREEP_DISC      = 200,                        -- creep disc radius for the pair clear-class (Farm.PairClearClass): clean if d/2+CREEP_DISC <= MARCH_LEN/2 (one March clears both), else clip. Feeds the lean-in clip budget + the calibration overlay; calibrate off the overlay.
    CLIP_EXTRA_MARCHES = 2,                       -- lean-in: a 'clip' pair (far camp's outer creeps spill outside one March) gets THIS many extra Marches at the midpoint to finish them as the aggro'd creeps chase inward. Calibrate in-client.
    CAMP_CACHE_S    = 60,                          -- F1: a fogged camp uses its last-seen real value for this long, then reverts to TIER_EST (we cannot know if an ally cleared it; bounded staleness, UCZone has the same blind spot).
    MARCH_PAIR_OFFSET = 0,                        -- nudge of the pair cast point along the A->B axis off the MIDPOINT (0 = midpoint; + = toward the far camp). Calibrate off the overlay.
    -- WHITELIST: specific camp pairs allowed to merge even though they exceed PAIR_RADIUS. Each entry is
    -- { {x1,y1}, {x2,y2} } (camp centres, matched by camp_key = 100-unit bucket). Use the "Mark pairable
    -- here" bind to find the two camps, then add the pair. NOT a global pair_max change - only these pairs.
    FORCE_PAIRS = {
        -- (empty) The -769,-7685 + -2480,-8400 d=1854 pair was removed: it DOES pair, but the midpoint stand
        -- path is blocked by woods -> move-stuck (3 in-client), doing more harm than good for ~one camp.
    },
    MOVE_TIMEOUT    = 25.0,                       -- abandon a stand we cannot reach in this many seconds
    WAVE_HOLD_EPS   = 150,                        -- v0.1.153: within this of the wave stand = ARRIVED; issue NO movement orders while holding (re-issuing move_to every tick made Tinker twitch in place)
    WAVE_HOLD_NEXT  = 12.0,                       -- v0.1.153: when the hold deadline expires with no wave, KEEP holding if the measured rhythm puts the next wave within this many seconds (a window this small is never worth a camp trip; ~MIN_CAMP_SLACK at zero travel)
    WAIT_PROTECT_AHEAD = 350,                     -- note 3: wait this far from the structure TOWARD the stand (inside its cover, facing the lane)
    WAIT_BACKOFF       = 600,                     -- note 3: no structure in scan range -> wait this far back from the stand toward our fountain
    WAIT_ENEMY_R       = 1400,                    -- note 3: an enemy hero within this of the stand moves the wait to the protected spot (GANK_RADIUS + harass reach)
    STEP_OUT_LEAD      = 1.5,                     -- task #12 (anchor tether): leave the tether this many s BEFORE eta_live - walk_time (turn + hold-eps + cast setup). Calibrate off --cycle-report.
    DEPTH_POINT_BUDGET = 600,                     -- Risk v2 axis 1 (task #11, user point system): a shove stand whose Farm.DepthPoints exceed this reads covers=false -> no_safe_stand -> jungle. DECIDE-only (never a movement veto). Run-13 anchors: dead-T1 meeting ~1100 past x1.5 side-T1s = 1650 (excluded at L1); with the keen shave 150 (allowed at L2). Calibrate off ft.dpts.
    DEPTH_KEEN_SHAVE   = 1500,                    -- axis 1: flat point shave when Keen L2 is READY (the escape capability; "having keen can shave off points"). Sized so typical post-T1 meetings (~1000-1400 past, 1.5x) pass at L2 while T2-deep territory (2500+ past) still busts even with keen.
    WAVE_CAMP_ALT_S    = 30,                      -- Risk v2 axis 2: a shove whose ROUND-TRIP travel exceeds this jungles instead (reason=far_wave) - the walk out-costs ~2 camp clears. The fed travel is raid-aware (L2 creep-keen collapses it), so deep waves re-qualify at Keen L2 automatically. Run-13: deep walks RT ~40 (skip at L1), river meetings RT ~25 (keep).
    SIDE_STAMP_MAX_S   = 60,                      -- PHASE 2 (TINKER_SIDE_ANTICIPATION_DESIGN.md): a side lane's cadence stamp is FRESH for this long (2 wave periods) - fresh = fogged side anticipation dispatches like mid (asrc=stamp); staler = verdict stale, not a candidate. Calibrate off ssrc=stamp arrival eta_err.
    GONE_BAL_MIN       = 2,                       -- gone-by-arrival (run-21): our wave wins by >= this (push-sim bal) AND the fight ends before we can arrive -> nothing to farm, jungle. bal=1 marginal keeps the shove. Calibrate off reason=gone_by_arrival vs arrivals that DID have creeps.
    WALK_DEPTH_MAX     = 550,                     -- THE STAIRS LINE (v0.1.192 user; v0.1.193 = EXCLUSION not clamp): a wave whose NATURAL stand (CrashCast standback, unclamped) sits deeper than this is not walk-farmable -> covers=false -> Plan jungles it (no_safe_stand / gone_by_arrival). Never clamps movement or parks stands at the line (the run-23 22-25s waits). stand_depth 0 = the fountain-axis midpoint = the mid river. KEEN-TO-CREEP (raid/deep_ok) is EXEMPT pre-T1-drop; after the enemy mid T1 falls the T1DOWN_LEASH binds everything (v0.1.201). Calibrate vs the actual ramp on the overlay.
    T1DOWN_LEASH       = 3000,                    -- v0.1.201 (user, run-29): after the enemy mid T1 DROPS, max lane-position distance from our foremost alive mid tower. Exclusion (covers -> jungle), never a movement clamp; forward-only (positions behind the tower never bind). UNGANKABLE creep-keen raids exempt (v0.1.202). v0.1.204 (user MAP-MEASURED): our T1 -> river center ~2000-2200; the expected post-T1 equilibrium ~3000 = the END OF THE STEPS (matches code geometry: T1 depth -2041 + 3000 reaches ~depth +950; the stairs line 550 still governs walking stands, so the leash trims off-axis/deep cases). Calibrate per the leash standing rule (careful analysis first).
    ENGAGE_EMPTY_GRACE = 1.2,                      -- tolerate this many seconds of occupancy=false at the camp (creeps chasing out of the box) before bailing
    MIN_CASTS_BEFORE_EMPTY = 2,                     -- A: require at least this many fired Marches before honouring an "empty" read (a 1-cast occupancy flicker as creeps aggro out was bailing with got=6)
    KEEN_TRAVEL_MIN = 1600,                       -- only Keen out if the stand is at least this far
    KEEN_GAIN_MIN   = 800,                        -- the anchor must be >= this much closer to the stand than we are
    DECIDE_GAP      = 0.4, ORDER_GAP = 0.05,
    MOVE_DEDUP_DIST = 75,                         -- v0.1.161 (flicker): a MOVE to within this of the last issued move target is a re-issue, not a new destination - skip it (bigger than the per-tick live-stand drift ~10-20u, smaller than a meaningful target change)
    MOVE_DEDUP_S    = 0.5,                        -- v0.1.161: re-assert an unchanged MOVE this often anyway (a swallowed order self-heals; twitch needs ~20/s, 2/s is invisible)
    TEST_OVERLAY_SEC = 120,                       -- how long the "Test all pairs" overlay stays up (seconds)
    AUTO_WAVESCAN_S = 2.0,                         -- v0.1.92: automatic all-lanes wavescan LOG cadence (the bind still arms the visual overlay)
    ROUTE_HORIZON_S = 30,                          -- planner time budget (the dead-time window)
    MAX_CAMP_TRAVEL_S = 20,                         -- reachability: don't pick a camp whose reach ETA (walk / ready keen) exceeds this - Tinker would time out en route (the move stuck d=9338 far-camp). Under MOVE_TIMEOUT (25) with margin. Keen-L2 creep-reach will relax this later. Calibrate.
    ROUTE_MAX_STEPS = 4,                           -- max planned sequence length
    ROUTE_STEP_DECAY = 0.6,                        -- v0.1.212 (run-35 census: plans promised [single, PAIR] but the pair step NEVER executed - real clear cost ~2x the planned mana_cost broke every tail at the replan): later plan steps execute with p<1, so their value is discounted in the SCORE (0.6^i). Makes [pair NOW] beat [single now, pair promised]. 1 = off. Calibrate off the plan= vs real= census line.
    ROUTE_POOL_CAP = 16,                            -- #3: DFS candidate cap (was the lib default 10). Raised so a far high-value camp is not trimmed by the one-step rate before the planner weighs it. Own-side reachable jungle is ~13 camps; the DFS is cheap at this n (the 30s horizon caps collectable depth to ~2-3, so the effective branching is small).
    ROUTE_RISK_WEIGHT = 70,                        -- gold penalty per unit risk in the planner score. Raised 40->70 so low-value ENEMY-side camps lose to safe own-jungle/lane (Note 2: Tinker was dipping into enemy jungle for a value-101 camp).
    HOME_LANE       = "mid",                        -- Tinker's lane: never yielded to allies (Note 3), so he returns to farm his own waves.
    WAVE_STANDBACK  = 900,                          -- Tinker Marches a wave from RANGE: the wave STAND (+ its risk) sits THIS far back toward our fountain from the creep cluster (Note 2: ~900u from the wave so it stays safe + March's forward sweep still covers it). Calibrate.
    ANTICIP_RANGED_REACH = 800,                     -- LANE ANTICIPATION: when the lane is clear, the forward stand sits THIS far back from the trailing RANGED creep so the March footprint lands on it as the wave arrives. 850 -> 800 (2026-07-02, user: stand 50u closer to the ranged). Contested -> falls back to WAVE_STANDBACK. Calibrate in-client.
    WAVE_LEAD       = 150,                           -- Note 5: lead the WAVE aim this far toward the TRAILING ranged creep (the side away from our fountain) so the March footprint spans it. Waves only (camps unaffected). Calibrate in-client.
    W_FRONT_MAX     = 800,                          -- v0.1.221: hold the FRONT W until the wave is within this (arrivals trigger at 950; casting at the clamp put the wave at the sweep's far edge = partial/zero kills). Calibrate.
    W_EDGE_DELAY_S  = 2.5,                          -- v0.1.221: max hold for the edge-close (a stalling/retreating wave still gets served). Calibrate.
    WAVE_MAX_W      = 2,                            -- DEFAULT for the "Marches: lane wave (max W)" menu slider: HARD CAP on W (March) casts per LANE-wave clear (the engage budget). shoveCasts from ClearTime(eff_hp) is capped to it so a big/over-estimated wave can't burn endless W under the tower. Applies to the wave being ENGAGED (visible or an arrived incoming one); waiting casts nothing. Camps have their own budget. Live-tunable on the HUD.
    WAVE_TRACK_RADIUS  = 1600,                      -- read enemy lane creeps within this of the wave's last-known point to TRACK the moving wave (recompute the live centroid each tick); generous so a pushing wave is not lost.
    WAVE_ENGAGE_RANGE  = 950,                       -- ENGAGE + keep Marching while within this of the LIVE centroid (~= WAVE_STANDBACK; March's ~300 cast + ~900 forward sweep still covers it). Calibrate (Note 2: stand ~900u from the wave).
    DEEP_THIN_EFFHP    = 1150,                       -- v0.1.195/196 (user, deep era = lane-phase timing): in the T1-DEAD era ONLY (the lane phase is perfect, untouched), a VISIBLE wave past the stairs line must be ~3+ creeps (full wave 1950, 2-creep remnant ~1100) to justify the raid trip; thinner -> jungle, the next FULL predicted wave gets the timed raid. Fogged ExpectedWave estimates are full waves and pass untouched.
    NC_GRACE_S         = 3.0,                        -- v0.1.195 (run-25): a live nocover wave gets this long to prove it is CLOSING before the commit bails - nocover fired on an INBOUND wave (their push crashing our tower) whose current position read deep, and the abort+suppress walked him to our T1 as the full wave arrived.
    NC_CLOSE_EPS       = 100,                        -- v0.1.195: dWave must drop this much to re-arm the nocover grace (a closing wave covers it in ~0.3s at 325; a held fight wobbles less).
    W_BEHIND_STEPIN_MAX = 1000,                      -- v0.1.195 (user, run-25 "all W cast from front at center meetings"): a due-but-ineligible BEHIND cast steps IN toward the aim when the shortfall is near (aim <= this), instead of burning the turn on another front cast. At the 850 stand the rear sweep is geometrically impossible (spawn edge ~840 < aim 850+), so a wave HELD at the meeting starved the latch (run-25: 30F/5B).
    TETHER_MAX_HOLD_S  = 10.0,                       -- v0.1.208 (run-33 "eternal waiting"): a tether whose step-out is farther out than this releases to the planner (shove suppressed for the wait) - a raid's keen transit (~4s) makes long closes pure idle at the hold spot; the window fits a camp. Calibrate.
    TETHER_WALK_MAX_S  = 6.0,                        -- v0.1.194 F2 (run-24): a raid-capable tether leg WALKS only when the hold is this close (v0.1.188's keen-preservation case); farther rides the keen ladder - the step-out re-arms (rearm-reset -> keen) for the raid hop anyway (v0.1.175), while the walk-always rule marched him 8-10k from the fountain.
    STUCK_TELEPORT_S   = 4.0,                        -- v0.1.121 (note 3, user): GLOBAL stuck-breaker - if the hero is moving toward a target (MOVE/RETURN), is FAR from it, and his position has not changed for this long, he is physically blocked -> TELEPORT (keen home) to unstick. Last-resort backstop over the per-state watchdogs.
    STUCK_FROZEN_DIST  = 60,                         -- v0.1.121: position moved LESS than this over the window = "not moving" (frozen).
    STUCK_FAR_DIST     = 400,                        -- v0.1.121: only count as stuck if this far from the move target (else he is legitimately standing AT the stand/target waiting - do not teleport).
    REARM_SAFE_RISK    = 0.20,                      -- Rearm in the field only when enemy_risk_at(hero) < this (else exposed near enemies); at base risk ~0 so always allowed (Note 3: safe Rearm).
    BLINK_RANGE        = 1200,                      -- item_blink cast range (regular dagger; arcane=1400). ponytail: const, not lib/item_data (no extra deploy) since Tinker buys regular blink. Read item_data if he ever buys arcane/overwhelming.
    BLINK_CLAMP        = 960,                       -- max landing distance (blink_range_clamp); overshoot beyond this lands at the clamp
    BLINK_TRAVEL_MIN   = 400,                       -- v0.1.209 (user FINAL blink doctrine: "use blink whenever it is safe... no chances of getting jumped"): the dagger is NOT rationed by distance anymore - the fog-aware risk gates own the only veto (jump risk), Eureka refunds the cd. This floor is order-sanity only (a <400u blink is a twitch, not travel). Was 800 ("protect the escape") - that protection is the risk gate's job now.
    BLINK_DEBOUNCE     = 0.5,                       -- min seconds between blinks (downloaded-script idiom)
    -- Note 4 (mana/HP-aware routing): per-hop cost gating + refill-as-node. Costs are read LIVE via
    -- Ability.GetManaCost (level-scaled); these _FB are the Liquipedia fallbacks if the read fails.
    HP_FLOOR_FRAC       = 0.35,                     -- next-hop HP gate: keep projected HP above this fraction of max HP
    HP_RISK_DMG         = 600,                      -- expected HP lost on a hop = enemy_risk * this (jungle risk ~0 -> ~0 cost). Calibrate.
    KEEN_MANA_FB        = 75,                        -- Keen Conveyance mana (Liquipedia, flat)
    MARCH_MANA_FB       = 120,                       -- March of the Machines mana per cast (Liquipedia 100/120/140/160)
    REARM_MANA_FB       = 225,                       -- Rearm mana (Liquipedia 150/225/300)
    LASER_MANA_FB       = 95,                         -- Laser mana fallback (Liquipedia ~95-120); abil_mana reads the real cost, this is only used if that read fails
    LASER_DMG           = { 75, 150, 225, 300 },      -- pure damage per Laser level (lib/ability_data, KV/Liquipedia-verified). PURE = ignores armor + magic resist, so a neutral is last-hittable iff its CURRENT hp <= this.
    MANA_REGEN_FALLBACK = 4.0,                       -- if NPC.GetManaRegen read fails
    HP_REGEN_FALLBACK   = 6.0,                       -- if NPC.GetHealthRegen read fails
    FOUNTAIN_MANA_PCT_S = 0.06, FOUNTAIN_HP_PCT_S = 0.05,   -- fountain regen rates (fraction of max per second; IN-CLIENT v0.1.130 capture) - drives the deficit-based refill duration (v0.1.162; replaced the flat REFILL_WAIT 4.0, which under/over-priced the trip and skewed camp-vs-refill choices)
    -- Note 3 (structural risk): position-based risk added to the live enemy-proximity risk so an own-side
    -- safelane camp ranks safer than a contested mid camp even with no enemy on the minimap.
    RISK_HALF_WEIGHT    = 0.75,                         -- gradient weight: risk rises 0 (our fountain) -> half_weight (enemy fountain). 0.75 so deep-enemy camps (t>~0.6 toward enemy fountain) cross RISK_HARD 0.45 and are VETOED (N3: stop farming the enemy-outpost ancients = deaths); own/mid camps (t<=0.5 -> <=0.375) stay farmable.
    RISK_CONTESTED_BUMP = 0.05,                          -- + this for a camp in a tagged contested zone. SMALL nudge only: at 0.18 it inverted the order (tagged radiant ancient out-risked a deeper untagged dire camp); at 0.08 the own-ancient PAIR midpoint (gradient ~0.27) hit 0.35 > RISK_HARD 0.34 = a hard VETO, so the close own ancient was never farmed even at max March. 0.05 keeps the deprioritizing nudge (own pair -> 0.32, farmable when safe; a live enemy near it still tips >0.34) while the ENEMY ancient stays vetoed by its gradient (~0.49) + reach anyway. Only affects the 2 tagged ancients.
    RISK_CONTESTED_RADIUS = 700,                         -- contested-zone radius around a tagged camp centre
    RISK_CONTESTED_CAMPS = { { -4797, -104 }, { 4099, 63 } },   -- the mid-river ancients, contested by both teams (calibrate from the overlay)
    -- Note 1 (lane-wave timing + crash/push):
    WAVE_PERIOD         = 30,                            -- creep waves spawn every 30s (Liquipedia)
    WAVE_PHASE          = 14,                             -- spawn-clock phase (sec after a 30s boundary that a wave reaches the mid meeting). Piece 1: MEASURED from the cycle-gated --lane-report (median 14.2 over 8 genuine arrivals; the +2.8s grid error was exactly 17-14). The grid is now only the FALLBACK - the kinematic kpred (live fronts+speeds) measured median -0.4s and takes over as the primary arrival input in Piece 2.
    WAVE_WAIT_GRACE     = 8,
    WAVE_WAIT_GRACE_VIS = 4,                               -- v0.1.222: AT the stand (vision up-lane) an arriving wave shows ~4s before eta - an invisible one past eta+this is a phantom; bail early. Calibrate vs the prediction-late median (~3-7s).                               -- at the wave stand, wait until waveEta + this for the creeps to arrive before re-asking the schedule. Calibrate.
    -- P0 move watchdog: bail a stand we are not closing toward (bad keen landing / unwalkable), so a far
    -- keen anchor (d2stand large) cannot lock Tinker walking-in-place at a camp he can never reach.
    NO_PROGRESS_S       = 3.0,                               -- backstop only now: with area-engage the hero engages from the coverage band, so this rarely fires (true can't-get-within-range)
    PROGRESS_EPS        = 60,                                -- "improved" = closed at least this many units
    SHOVE_STUCK_S       = 6,                                 -- Note 1: after a shove crash stand proved unreachable (keen landed on tower high ground), suppress re-picking the shove for this long (recover instead) so Tinker does not loop re-keening the same unwalkable spot
    ENGAGE_COVER_DIST   = 450,                               -- AREA engage: within THIS of the cast aim, March's square already covers the camp -> engage (no exact-point requirement). MARCH_CAST_RANGE 300 + ~150 slack; cast clamps 280 ahead, the square reaches well past. Calibrate vs clear quality.
    MULTI_W_OFFSET      = 50,                                 -- W cast offset FROM TINKER in the (90-deg-rotated) target direction. Small: the ~1800 box covers the cluster from right next to Tinker, so casting close (in-range, robots sweep THROUGH the creeps) beats pushing the box 300 off-centre. Calibrate.
    W_BEHIND_BACKSTEP   = 60,                                -- v0.1.173 (run-11 user report: both W's flew the SAME direction): the BEHIND cast targets THIS far behind the hero (opposite the wave), FLIPPING the facing so the robots spawn at the box's far edge (me + (MARCH_LEN/2 - backstep) toward the wave) and sweep BACK through it - the enemy REAR (the ranged) eats them first. The old aim+350 target clamped onto the SAME forward ray as the front cast (cast range ~280 << the shift) = two identical casts.
    W_BEHIND_CLEAR      = 60,                                -- v0.1.176 (run-14 census: 20 front / 2 behind): rear-sweep eligibility margin - the spawn edge (me + 900 - backstep) must clear the AIM (trailing ranged) by this. Was CREEP_DISC(200) -> <=600, then 100 -> <=700; v0.1.184 (run-19 dig: 22F vs 4B lost in the dWave 500-699 band - the aim reads +200-400 deeper than the centroid) 60 + backstep 60 -> eligible at aim-dist <= 780 (worst-case edge clearance 60u = still past the ranged creep's center). Physics bounds the rest: 35/74 fronts fired at dWave >= 700 where no rear sweep can exist.
    MARCH_REACH         = 1150,                               -- a camp is March-coverable from here if within this (cast clamps 280 ahead + the square reaches ~900 more). Used by the river-fallback pair engage + the watchdog.
    -- THE BOX = a THIN RECTANGLE aligned to the camp-connecting (A->B) axis, centred on the midpoint.
    -- ALONG the axis is the CRITICAL direction (moving unbalances the two camp distances) so it is tight;
    -- PERPENDICULAR keeps both camps ~symmetric so the hero may shift more there. More precise than a disc.
    BOX_ALONG           = 50,                                 -- half-extent ALONG the camp axis (the WIDTH, the critical direction - moving along unbalances the two camp distances). v0.1.107 (user note 1): halved 100->50 (the "cut the width in half" that was asked; v0.1.101 wrongly cut the perpendicular/length instead).
    BOX_PERP            = 300,                                -- half-extent PERPENDICULAR to the camp axis (the LENGTH, roomy - both camps stay ~symmetric when shifting here). v0.1.107 (user note 1): restored 150->300 (v0.1.101 had halved this by mistake).
    WAVE_STRUCT_SCALE   = 0.5,                                -- R2: waves are Marched from WAVE_STANDBACK(900), so positional danger is halved - scale the structural risk for wave stands so a near-tower wave is not vetoed (we farm it from range).
    WAVE_STRUCT_CAP     = 0.35,                               -- R2: cap the structural part of wave risk below RISK_HARD(0.45) so position alone never vetoes a wave; live enemy proximity still can.
    -- Shove gates (TINKER_SCHEDULE_DESIGN.md):
    SHOVE_SAFE_RISK     = 0.35,                               -- skip a shove when the 900u-stand risk is >= this. Calibrate.
    -- (the depth-veto patch family - DEPTH_AT_LINE/DEPTH_PAST_LINE/DEPTH_DIVE_MARGIN/SHOVE_MAX_DEPTH/
    -- SAFE_DEPTH_MARGIN/ENEMY_MS/DIVE_ESCAPE_S + depth_line_risk/enemy_eta_to + the too_deep/deep-cap
    -- gates - was REMOVED 2026-07-01: layered under-tower patches, wrong direction. Tower safety will
    -- live ONCE in the unified order/movement layer for the lane foundation rebuild.)
    SHOVE_MANA_RESERVE  = 0,                                  -- extra mana floor beyond the per-hop cost for shove + escape (0 = just the hop). Calibrate.
    SHOVE_FAR_TRAVEL    = 12.0,                               -- v0.1.93 deep-shove guard: a shove whose crash point is THIS far (s, travel_to_mid) AND...
    SHOVE_MIN_EFFHP     = 400,                               -- ...whose wave eff_hp is below this (a near-dead, already-pushed wave) is NOT worth the long keen -> hold near mid + let allies/tower finish it. ponytail ceiling: tune both off clean data (caught the v0.1.92 log's 21.8s keen for 300hp).
    LANE_TRADE_HP       = 0.40,                              -- v0.1.94 lane risk: a 1v1 is a TRADE, not a death - DON'T flee a single visible enemy unless HP fraction is below this (then a burst could kill). 2+ visible = a gank = flee regardless. ponytail ceiling.
    SHOVE_THIN_EFFHP    = 400,                               -- v0.1.102 (note 1): skip a shove when the VISIBLE mid enemy wave is below this eff_hp (a lone creep, ~1 ranged 300) - not worth a keen-to-mid, our creeps + tower handle it. Fogged uses the full ExpectedWave estimate so anticipation is unaffected. ponytail ceiling.
    MIN_CAMP_SLACK      = 10.0,                               -- v0.1.108 lane-first: only commit to a camp when the working budget (slack minus the reserved return-to-mid) is at least this. Below it a camp gets left half-done / walked back from (note 2), so do a fountain trip or hold at mid instead. ponytail ceiling, calibrate.
    MIN_FOUNTAIN_SLACK  = 6.0,                                -- v0.1.108 lane-first: minimum slack to fit a fountain recharge round-trip (keen home + top off + keen back) and still return for the fresh wave; below this just hold at mid. ponytail ceiling, calibrate.
    -- Timing scheduler (TINKER_SCHEDULE_DESIGN.md) calibration:
    MARCH_DMG_PER_CAST  = 450,                               -- effective wave damage one March cast deals (in-client v0.1.59: mid waves eff_hp ~1500-2000 clear in ~3-5 casts, so ~450/cast; was 300 -> casts 6-7 too high)
    MARCH_CAST_DUR      = 0.53,                              -- March cast point (Liquipedia 7.41c; was 0.5)
    ROBOT_KILL          = 1.5,                               -- robot sweep-to-kill duration (wave cal only; camp uses ROBOT_TAIL)
    ROBOT_TAIL          = 1.5,                               -- camp clear: per-clear overhead beyond nominal March cadence (approach wind-up + fire-verification lag). NOT a robot-death tail: Tinker leaves at the March budget and the robots finish autonomously while he walks off, so clear_t models COMMITMENT time (arrival -> last cast -> leave) = the quantity the planner schedules against. Calibrated off engage_done dur ~8.1 vs cadence 6.97 (3-cast Rearm-L1 clean pairs, v0.1.151); raw fit ~1.1, +0.4 margin for the unsampled operating points (singles/ancients/L2-L3 rearm).
    SCHED_LEAD          = 1.5,                               -- safety lead subtracted from leave_by so Tinker arrives early
    BOTTLE_MANA         = 200,                               -- drink Bottle when mana below this (and safe + not channeling)
    SOUL_RING_MANA      = 170,                               -- mana engine part 3 (Liquipedia 7.41c): Sacrifice = +170 TEMP mana (10s window - spend immediately), costs 170 HP, cd 30
    SR_HP_FRAC_MIN      = 0.55,                              -- never Sacrifice below this hp fraction (the 170 HP must be safe to pay)
    ARCANE_MANA         = 150,                               -- Arcane Boots Replenish: +150 mana, cd 55, free (Liquipedia)
    BOTTLE_HP_FRAC      = 0.55,                              -- drink Bottle when hp fraction below this
    BOTTLE_MANA_PER_CHARGE = 60,                             -- mana restored per Bottle charge (v0.1.130 capture, Liquipedia): effective-mana term in the shove afford gate
    PATH_RISK_MAX       = 0.42,                              -- item 6 (Farm.PathRisk): worst fog-aware enemy risk allowed along the hero->stand corridor; = FARM_SAFE_RISK (the live-abort threshold) so decide and abort agree. Calibrate off ft.prisk.
}

-- (Adjacent-camp pairing is computed LIVE in pair_spot_for below; the old static
-- CAMP_PAIRS table + tools/gen_camp_pairs.lua are retired.)

----------------------------------------------------------------- state ----
State.fsm          = "DECIDE"
State.laneWaveT    = {}    -- PHASE 2 (TINKER_SIDE_ANTICIPATION_DESIGN.md): per-lane cadence anchors {mid=,top=,bot=} - game-time a wave was last cleared at that lane's shove point. Mid consumers read .mid (the old lastWaveT, unchanged semantics); side entries feed side_wave_ctx stamp anticipation.
State.shoveLeaveBy = nil   -- leave-by deadline set by Schedule.Plan when a camp is picked (preemption)
State.schedSlack   = nil   -- slack budget handed to the jungle planner
State.marchCasts   = 0
State.nextDecide   = 0
State.nextOrder    = 0
State.panicUntil   = 0
State.channelUntil = 0
State.keenedSpot   = false   -- one Keen hop per committed spot, then walk
State.shoveSuppress = { mid = 0, top = 0, bot = 0 }  -- Note 1 + ALL-LANES v0.1.225: after a shove got stuck (crash stand unreachable / tether release), recover instead of re-keening THAT LANE until this time; per-lane so a stuck side stand never suppresses mid
State.dumped       = false   -- one-shot position-dump guard
State.cleared      = {}      -- camp_key -> game-time the camp re-opens (next xx:00 spawn)
State.campSeen     = {}      -- F1: camp_key -> { gold, ehp, seen_at }: last-seen REAL value (stacks included), used while fogged
-- nil by default: hero, player, team, march, rearm, keen, laser, spot, menu,
-- lowHpSince, moveSince, pendingVerify, cands, frame_t

------------------------------------------------------- helpers + pipeline --
-- On-screen DOTA clock (0:00 = first spawn), so next_respawn()/is_cleared align to
-- the real xx:00 neutral respawn (GetGameTime carries the ~90s pregame offset).
-- Falls back to the proven GetGameTime if GetDOTATime is absent.
local function now()
    if GameRules.GetDOTATime then return GameRules.GetDOTATime(false, false) end
    return (GameRules.GetGameTime and GameRules.GetGameTime()) or 0
end

-- Occupancy is VISION-limited (the neutral scan only returns camps in sight), so
-- the bot ASSUMES a camp is occupied unless it recently visited it and found it
-- empty / did its march budget. Cleared camps re-open at the next xx:00 spawn.
-- Fogged camps are valued from a per-tier estimate (TINKER_JUNGLE_REF midpoints).
local TIER_EST = {
    [0] = { gold = 55,  hp = 1400 },   -- small
    [1] = { gold = 85,  hp = 1900 },   -- medium
    [2] = { gold = 105, hp = 2400 },   -- large
    [3] = { gold = 160, hp = 3600 },   -- ancient (raw midpoint; v0.1.183 reverts the 4300 MR bump - the tier FLOOR owns the planning count now, and the sum-ceil only binds for stacks where raw totals are the honest input)
}
local function camp_key(c)
    return string.format("%d,%d", math.floor((c and c.x or 0) / 100), math.floor((c and c.y or 0) / 100))
end
local function next_respawn() return (math.floor(now() / 60) + 1) * 60 end   -- next xx:00 (neutral spawn)
local function is_cleared(key)
    local t = State.cleared and State.cleared[key]
    return t ~= nil and now() < t
end
local function mark_cleared(key)
    if key then State.cleared = State.cleared or {}; State.cleared[key] = next_respawn() end
end
-- Clear the chosen spot. For a PAIR, mark BOTH camps: the centred March (+ the extra clip
-- Marches) cleared both, and from the midpoint both centres are in vision so the occupancy
-- read that triggered this was valid. (Night + a very wide clip pair could put the far camp
-- out of vision -> a rare false-clear that self-heals at the next xx:00 respawn.)
local function mark_spot_cleared(s)
    if not s then return end
    mark_cleared(s.key)
    local ss = s.standSpot
    if ss and ss.paired and ss.partner then mark_cleared(camp_key(ss.partner)) end
end

local function marches_for(t)   -- tier 0=small 1=medium 2=large 3=ancient
    local m = State.menu
    if t == 0 then return m.mSmall:Get() elseif t == 1 then return m.mMedium:Get()
    elseif t == 2 then return m.mLarge:Get() elseif t == 3 then return m.mAncient:Get() end
    return 2
end

-- Do camp centres a,b match a K.FORCE_PAIRS whitelist entry (either order)? Matched by camp_key (100-unit
-- bucket, robust to rounding). Feeds Farm.GreedyPairs' `allow` so ONLY these pairs may exceed PAIR_RADIUS.
local function forced_pair(a, b)
    if not (a and b) then return false end
    local ka, kb = camp_key(a), camp_key(b)
    for _, f in ipairs(K.FORCE_PAIRS or {}) do
        local k1 = camp_key({ x = f[1][1], y = f[1][2] })
        local k2 = camp_key({ x = f[2][1], y = f[2][2] })
        if (ka == k1 and kb == k2) or (ka == k2 and kb == k1) then return true end
    end
    return false
end

local function refresh_handles(h)
    State.march = NPC.GetAbility(h, "tinker_march_of_the_machines")
    State.rearm = NPC.GetAbility(h, "tinker_rearm")
    State.keen  = NPC.GetAbility(h, "tinker_keen_teleport")  -- KV name (Liquipedia: "Keen Conveyance")
    State.laser = NPC.GetAbility(h, "tinker_laser")
end

local function ready(ab) return ab and Ability.CanBeExecuted(ab) == -1 end
local function mana() return NPC.GetMana(State.hero) or 0 end

-- EFFECTIVE mana for the shove afford gate = raw + Bottle charges (review #3: Tinker with charges
-- kept trekking home at ~70% mana because the gate only read raw mana; the charges ARE spendable).
local function effective_mana()
    local h = State.hero
    local bt = NPC.GetItem(h, "item_bottle", true)
    local ch = (bt and Item.GetCurrentCharges and Item.GetCurrentCharges(bt)) or 0
    local m = mana() + ch * K.BOTTLE_MANA_PER_CHARGE
    -- mana engine part 3 (2026-07-04): READY mana items are spendable on demand mid-clear, the
    -- same way charges are - counting them here is what lets the planner take a camp the raw
    -- pool cannot pay, instead of a fountain trip (17 trips/24min in run-19 = the top time sink).
    local ab = NPC.GetItem(h, "item_arcane_boots", true)
    if ab and Ability.CanBeExecuted(ab) == -1 then m = m + K.ARCANE_MANA end
    local sr = NPC.GetItem(h, "item_soul_ring", true)
    if sr and Ability.CanBeExecuted(sr) == -1
       and (Entity.GetHealth(h) or 0) >= (Entity.GetMaxHealth(h) or 1) * K.SR_HP_FRAC_MIN then
        m = m + K.SOUL_RING_MANA
    end
    return m
end

-- ── gold tracking (camp value via ACTUAL gold gained + GPM; camps respawn each xx:00) ──────────
-- Player.GetTotalGold (gitbook Player class) = the player's total gold. We track POSITIVE deltas as
-- "earned" (for GPM, so item spending does not skew it). Camp REMAINING value is NOT derived from these
-- deltas (they are contaminated by passive/lane/kill gold); it comes from the live alive-creep bounty
-- (gather_candidates + the fsm_engage cache refresh), so per-camp gold attribution lives there, not here.
local function total_gold()
    local ok, g = pcall(function() return Player.GetTotalGold and Player.GetTotalGold(State.player) end)
    return (ok and type(g) == "number") and g or nil
end

local function gold_tick()
    local g = total_gold()
    if g == nil then return end
    if State.goldPrev == nil then State.goldPrev = g; State.gpmT0 = now() end
    local delta = g - State.goldPrev
    State.goldPrev = g
    if delta > 0 then State.earned = (State.earned or 0) + delta end   -- GPM only (sum of positive deltas)
end

-- gold per minute over the run (earned = sum of positive deltas).
local function gpm()
    local mins = (now() - (State.gpmT0 or now())) / 60
    return (mins > 0.05) and ((State.earned or 0) / mins) or 0
end
local function origin(e) return Entity.GetAbsOrigin(e) end

-- True while the Rearm/Keen channel must be protected: the live channel read OR
-- the timer backstop. Panic runs before this gate, so a save can still break it.
local function is_channeling()
    if NPC.IsChannellingAbility and NPC.IsChannellingAbility(State.hero) then return true end
    return now() < (State.channelUntil or 0)
end

-- cast-fired verification (cooldown jump): an ISSUED order only counts as FIRED if
-- the ability stops being ready / goes on cooldown shortly after.
local function cd_remaining(ab)
    if not ab then return 0 end
    local ok, cd = pcall(function() return Ability.GetCooldownTimeRemaining and Ability.GetCooldownTimeRemaining(ab) end)
    if ok and type(cd) == "number" and cd > 0 then return cd end
    return ready(ab) and 0 or 0.1
end
local function verify_cast(name, ab)
    State.pendingVerify = { name = name, ab = ab, baseCD = cd_remaining(ab), expire = now() + 0.6 }
end
local function process_verify()
    local v = State.pendingVerify
    if not v then return end
    if (not ready(v.ab)) or cd_remaining(v.ab) > v.baseCD + 0.05 then
        logline(v.name .. " FIRED"); State.pendingVerify = nil
    elseif now() > v.expire then
        logline(v.name .. " issued_NOT_fired"); State.pendingVerify = nil
    end
end

-- single order chokepoint (throttled). Direct PrepareUnitOrders with the
-- V2-confirmed issuer/flags that PROVABLY fire the point casts. lib/order
-- migration is deferred until its issuer/flags are confirmed in-client.
local function issue(order, ability, target, pos)
    local t = now()
    if t < State.nextOrder then return false end
    Player.PrepareUnitOrders(State.player, order, target, pos, ability,
        Enum.PlayerOrderIssuer.DOTA_ORDER_ISSUER_HERO_ONLY, State.hero,
        false, false, false, true, false, false)   -- V2-confirmed (matches Autofarm V2)
    State.nextOrder = t + K.ORDER_GAP
    return true
end
-- Movement dedup (v0.1.161, user: flickering movement = orders issued one after another): the live
-- re-stand drifts a few units per tick with the creeps, so callers re-issued MOVE to a near-identical
-- point up to 20x/s (ORDER_GAP 0.05) - each re-issue restarts pathing/turning = the visible twitch.
-- ONE guard at the chokepoint covers every caller: skip when the target is within MOVE_DEDUP_DIST of
-- the last issued move AND that order is younger than MOVE_DEDUP_S (re-assert ~2x/s so a swallowed
-- order self-heals; a genuinely NEW destination >75u away still issues immediately).
local function move_to(pos, src)
    local lm = State.lastMove
    if lm and now() - lm.t < K.MOVE_DEDUP_S then
        local dx, dy = pos.x - lm.x, pos.y - lm.y
        if dx * dx + dy * dy <= K.MOVE_DEDUP_DIST * K.MOVE_DEDUP_DIST then return true end   -- already moving there
    end
    if issue(UO.DOTA_UNIT_ORDER_MOVE_TO_POSITION, nil, nil, pos) then
        -- src (v0.1.242) names the producer; kept as documentation + for any future move-level
        -- diagnosis (the v0.1.244 flicker took two instrument versions to name - never again).
        State.lastMove = { x = pos.x, y = pos.y, t = now(), src = src }
        return true
    end
    return false
end
local function cast_pos(ab, pos) return issue(UO.DOTA_UNIT_ORDER_CAST_POSITION, ab, nil, pos) end
local function cast_no_target(ab) return issue(UO.DOTA_UNIT_ORDER_CAST_NO_TARGET, ab, nil, nil) end
local function cast_target(ab, ent) return issue(UO.DOTA_UNIT_ORDER_CAST_TARGET, ab, ent, nil) end

-- friendly fountain position from the static table (team-matched).
local function friendly_fountain_pos()
    for _, f in ipairs(MapData.FOUNTAINS or {}) do
        if f.team == State.team and f.pos then return Vector(f.pos[1], f.pos[2], f.pos[3]) end
    end
    return nil
end
local function enemy_fountain_pos()
    for _, f in ipairs(MapData.FOUNTAINS or {}) do
        if f.team ~= State.team and f.pos then return { x = f.pos[1], y = f.pos[2] } end
    end
    return nil
end

-- v0.1.97: signed DEPTH of `pos` past mid along the lane axis (own fountain -> enemy fountain).
-- + = enemy side (units past mid center toward the enemy), - = own side. Vetoes a DEEP shove (keening
-- into enemy territory to chase a winning wave = under-tower stuck / a collapse / a backline keen). A
-- depth threshold catches the deep stand regardless of travel-to-mid (the v0.1.96 log's deep shove had
-- travel 11.6, just under SHOVE_FAR_TRAVEL 12, so the old travel-only gate missed it). 0 if a fountain
-- is unknown. Replaces the v0.1.95 binary stand_enemy_side (which over-triggered on a barely-past-mid stand).
local function stand_depth(pos)
    local fp, ep = friendly_fountain_pos(), enemy_fountain_pos()
    if not (fp and ep and pos) then return 0 end
    local mx, my = (fp.x + ep.x) * 0.5, (fp.y + ep.y) * 0.5     -- mid center
    local ax, ay = ep.x - fp.x, ep.y - fp.y
    local al = math.sqrt(ax * ax + ay * ay); if al < 1 then return 0 end
    return (pos.x - mx) * (ax / al) + (pos.y - my) * (ay / al)
end
-- Note 3: opts for Farm.StructuralRisk (fountains + the tagged contested-camp zones).
local function risk_opts()
    local of, ef = friendly_fountain_pos(), enemy_fountain_pos()
    -- F3 deep-farm relax REVERTED (v0.1.88): it opened contested enemy-side camps (a Dire Tinker
    -- farming radiant camps at risk ~0.36 that are ~0.45 = vetoed without the relax). Back to the
    -- conservative static veto: enemy-territory camps stay vetoed by RISK_HARD.
    local zones = {}
    for _, c in ipairs(K.RISK_CONTESTED_CAMPS or {}) do
        zones[#zones + 1] = { x = c[1], y = c[2], radius = K.RISK_CONTESTED_RADIUS, bump = K.RISK_CONTESTED_BUMP }
    end
    return { our_fountain = of and { x = of.x, y = of.y } or nil, enemy_fountain = ef,
             half_weight = K.RISK_HALF_WEIGHT, zones = zones }
end
-- Keen home = CAST_POSITION at the friendly fountain (CAST_NO_TARGET self-cast was
-- issued-but-never-fired; CAST_POSITION is the order type that actually fires).
local function keen_home()
    local fp = friendly_fountain_pos()
    if not fp then return false end
    if cast_pos(State.keen, fp) then
        State.channelUntil = now() + K.KEEN_CHANNEL + K.CHANNEL_PAD
        verify_cast("keen_home", State.keen)
        return true
    end
    return false
end
-- Rearm if ready and affordable (reserves escape mana); sets the channel timer + verify.
local function try_rearm()
    if not ready(State.rearm) then return false end
    local rcost = (Ability.GetManaCost and Ability.GetManaCost(State.rearm)) or K.REARM_MANA_FB   -- v0.1.97: was a hardcoded 150 (Rearm fallback is 225)
    if mana() < State.menu.escapeMana:Get() + rcost then return false end
    if not cast_no_target(State.rearm) then return false end
    local lvl = (Ability.GetLevel and Ability.GetLevel(State.rearm)) or 1
    State.channelUntil = now() + (K.REARM_CHANNEL[lvl] or K.REARM_CHANNEL[1]) + K.CHANNEL_PAD
    verify_cast("rearm", State.rearm)
    return true
end

-- ── safety: enemy sampling + risk ────────────────────────────────────────────
-- Per-decide fog snapshot (COR-1): visible enemies at true pos + recently-fogged
-- enemies as a last-seen pos + age, consumed by FogProximityRisk. Replaces the
-- old enemy_positions() which froze fog enemies at a stale point (no disc).
local function enemy_snapshot()
    return Escape.FogSnapshot(State.hero, { max_ms = K.FOG_MS, now = now })
end

-- Blink+Threat pt2: weight a fogged/visible enemy's proximity risk by its KILL-THREAT
-- kit (lethal -> 1.4, harmless support -> 0.6) so a fogged Pudge near mid reads riskier
-- than a fogged support. Every safety consumer (shove gate, camp abort, rearm, blink
-- escape/travel) reads enemy_risk_at, so all become threat-aware. pcall: NPC.GetUnitName
-- throws on a non-NPC entity (Lina idiom); snapshot entries are heroes so it is safe.
local function kill_threat_w(h)
    local ok, name = pcall(function() return NPC.GetUnitName and NPC.GetUnitName(h.entity) end)
    if not (ok and name) then return 1 end
    return HeroValue.KillThreat(name)
end

local function enemy_risk_at(pt)
    local snap = State.fog or enemy_snapshot()   -- per-decide snapshot (set in fsm_decide); avoids rebuilding it ~40x
    return Escape.FogProximityRisk(snap, pt, {
        risk_radius = K.RISK_RADIUS, fog_ms = K.FOG_MS,
        fog_spread = K.FOG_SPREAD, age_cap = K.FOG_AGE_CAP, now = now,
        weight_fn = kill_threat_w })
end

-- Deep 1 (v0.1.76): risk from a live ENEMY tower near a point. PLATEAU model - full inside the
-- tower's attack range, linear taper to 0 at TOWER_RISK_RADIUS. The shove gate's positional veto
-- + (v0.1.87) the keen/blink landing safety. Ganks are caught by enemy_risk_at; this catches the
-- tower itself. Enumerate-then-filter by team (robust to the API's team default).
local function enemy_tower_risk(pos)
    local R, rng = K.TOWER_RISK_RADIUS, K.TOWER_ATTACK_RANGE
    local best = 0
    local p = Vector(pos.x, pos.y, 0)
    for _, t in ipairs(Map.TowersInRadius(p, R) or {}) do
        if Entity.GetTeamNum(t) ~= State.team and Entity.IsAlive(t) then
            local d = origin(t):Distance(p)
            local f = (d <= rng) and 1 or (d < R and (R - d) / (R - rng) or 0)
            if f > best then best = f end
        end
    end
    return best * K.TOWER_RISK_WEIGHT
end

-- v0.1.105 LANE PRIORITIZATION: the enemy T1 of a LANE from the static map (name+team) + whether it
-- is still ALIVE (any alive enemy tower within TOWER_ALIVE_R of its static spot). Drives the
-- tower-aware shove veto (supersedes the crude SHOVE_MAX_DEPTH depth proxy). Returns ({x,y} or nil),
-- alive. ALL-LANES v0.1.225: lane-parameterized (absorbs enemy_mid_t1 - one producer for the crash
-- clamp + the leash trigger on every lane).
local function enemy_lane_t1(lane)
    local pos
    local key = "tower1_" .. (lane or K.HOME_LANE)
    for _, t in ipairs(MapData.TOWERS or {}) do
        if t.team ~= State.team and t.pos and t.name and t.name:find(key, 1, true) then
            pos = { x = t.pos[1], y = t.pos[2] }; break
        end
    end
    if not pos then return nil, false end
    for _, t in ipairs(Map.TowersInRadius(Vector(pos.x, pos.y, 0), K.TOWER_ALIVE_R) or {}) do
        if Entity.GetTeamNum(t) ~= State.team and Entity.IsAlive(t) then return pos, true end
    end
    return pos, false
end

-- v0.1.201 (user directive, run-29): after the enemy mid T1 DROPS, lane positioning is LEASHED to
-- our foremost ALIVE mid tower: max K.T1DOWN_LEASH (1100 = tower range 700 + ~400 to the river end)
-- from it, for anything FORWARD of that tower. Run-29 sighting: a deep raid stand (depth 1672)
-- arrived at 148 mana and WALKED home through enemy ground; the fix is an EXCLUSION at the same
-- sites as the stairs line (covers / lane_go tripwire / step-in), RAIDS INCLUDED in the deep era -
-- the deep meeting is excluded so Plan jungles instead of walking/waiting deep (the user's "right
-- decision"). Pre-drop: inert (the lane phase stays untouched). Positions BEHIND the anchor tower
-- (retreats, holds at T2, own jungle) never bind - the leash is a forward cap, not a bubble.
-- Optional slop widens the radius for tripwire-style callers.
-- ALL-LANES v0.1.225: lane-parameterized (trigger = THAT lane's enemy T1; anchor = our alive towers
-- of that lane); radius shared = T1DOWN_LEASH (a calibration knob for the side lanes; cwhy=leash
-- names any miscalibration in the farm/swave trace).
local function lane_leash_ok(pos, slop, lane)
    lane = lane or K.HOME_LANE
    local _, t1alive = enemy_lane_t1(lane)
    if t1alive then return true end
    local anchor
    for _, nm in ipairs({ "tower1_" .. lane, "tower2_" .. lane, "tower3_" .. lane }) do
        for _, t in ipairs(MapData.TOWERS or {}) do
            if t.team == State.team and t.pos and t.name and t.name:find(nm, 1, true) then
                for _, e in ipairs(Map.TowersInRadius(Vector(t.pos[1], t.pos[2], 0), K.TOWER_ALIVE_R) or {}) do
                    if Entity.GetTeamNum(e) == State.team and Entity.IsAlive(e) then
                        anchor = { x = t.pos[1], y = t.pos[2] }; break
                    end
                end
            end
            if anchor then break end
        end
        if anchor then break end
    end
    if not anchor then return true end   -- no mid tower left: no anchor (base defense is not farm's problem)
    if stand_depth(pos) <= stand_depth(anchor) then return true end   -- behind the tower = home territory
    local dx, dy = pos.x - anchor.x, pos.y - anchor.y
    local r = K.T1DOWN_LEASH + (slop or 0)
    return dx * dx + dy * dy <= r * r
end

-- per-lane shove suppression (ALL-LANES v0.1.225): set on stuck stands / tether releases, consumed
-- by the lane's own dispatch gate only - no cross-lane poisoning (a stuck side stand must never
-- convert a due MID shove to recover).
local function suppress_shove(lane, untilT)
    State.shoveSuppress[lane or K.HOME_LANE] = untilT
end
local function shove_suppressed(lane)
    return now() < (State.shoveSuppress[lane or K.HOME_LANE] or 0)
end

-- Risk v2 axis 1 inputs (task #11, the user POINT SYSTEM): for a lane position, the NEAREST static
-- enemy tier-1 spot (= the depth zero-line), whether THAT tower still stands, and how many of their
-- OTHER tier-1s do. Feeds Farm.DepthPoints at DECIDE time only (schedule exclusion via covers ->
-- no_safe_stand -> jungle) - NEVER a movement/landing veto (hard vetoes froze/idled the hero).
local function enemy_t1_points_info(pos)
    local best, bd, others_up, best_alive = nil, nil, 0, false
    for _, t in ipairs(MapData.TOWERS or {}) do
        if t.team ~= State.team and t.pos and t.name and t.name:find("tower1_", 1, true) then
            local alive = false
            for _, e in ipairs(Map.TowersInRadius(Vector(t.pos[1], t.pos[2], 0), K.TOWER_ALIVE_R) or {}) do
                if Entity.GetTeamNum(e) ~= State.team and Entity.IsAlive(e) then alive = true; break end
            end
            local dx, dy = t.pos[1] - pos.x, t.pos[2] - pos.y
            local d = dx * dx + dy * dy
            if not bd or d < bd then
                if best and best_alive then others_up = others_up + 1 end   -- the displaced nearest counts as "other"
                bd, best, best_alive = d, { x = t.pos[1], y = t.pos[2] }, alive
            elseif alive then
                others_up = others_up + 1
            end
        end
    end
    if not best then return nil end
    return { depth_past = stand_depth(pos) - stand_depth(best), line_alive = best_alive, others_up = others_up }
end

-- v0.1.94: enemy_risk_at scores DISTANCE - a single mid laner at trading range reads ~0.5-0.7, which
-- made Tinker FLEE a normal healthy 1v1 (wave move/engage abort) AND blocked safe_rearm so he stood
-- IDLE in ENGAGE (March on cd + an enemy near -> no rearm -> wait). Laning is a TRADE: a 1v1 + the odd
-- hit is normal, not a death. So the "leave the lane / don't rearm" call is COUNT + HP aware:
--   >=2 visible enemies near the point -> a gank -> flee;
--   1 visible -> a trade -> STAY unless HP fraction < LANE_TRADE_HP (then a burst could kill);
--   0 visible -> keep the COR-1 fogged-proximity gate (don't keen into a fog gank).
-- Under an enemy tower always flees. LANE paths only (shove gate, wave move/engage abort, safe_rearm);
-- camps keep plain enemy_risk_at (jungle context).
local function lane_unsafe(pos)
    local p = Vector(pos.x, pos.y, 0)
    if enemy_tower_risk(p) >= K.SHOVE_SAFE_RISK then return true end
    -- CLEANUP(review#2): depth is now MEASUREMENT-only here (logged via srisk + ft.depth). The deep
    -- decision moved to the guard (rule 2): T1 dead + deep -> keen-to-creep DIVE if Keen L2 + safe, else
    -- jungle. A hard lane_unsafe depth veto would recover BEFORE the guard, blocking the dive, so it was
    -- removed. (The crash-clamp already keeps a T1-alive stand in front of the tower.)
    local snap = State.fog or enemy_snapshot()
    -- v0.1.95: count a GANK only within GANK_RADIUS (2 far enemies are not a gank).
    -- v0.1.157 (glue review F4): FOGGED enemies count toward the GANK test - 1 visible + 1
    -- recently-fogged is a 2-man gank, not a trade. v0.1.158 recalibration (the first run
    -- aborted at risk 0.14): the raw probable disc reaches 2750u at the age cap, so stale
    -- discs matched from half a screen away - fogged reach is now capped at GANK_FOG_REACH
    -- (fresh info only), and fogged-only pairs do NOT gank (0 visible stays with the COR-1
    -- fog gate below, as before F4); the fogged count only augments a VISIBLE enemy.
    local nv, nf = 0, 0
    for _, h in ipairs(snap.heroes or {}) do
        if h.pos then
            local dx, dy = h.pos.x - p.x, h.pos.y - p.y
            local d = math.sqrt(dx * dx + dy * dy)
            if h.visible then
                if d <= K.GANK_RADIUS then nv = nv + 1 end
            elseif d - math.min(h.probable_radius or 0, K.GANK_FOG_REACH) <= K.GANK_RADIUS then
                nf = nf + 1
            end
        end
    end
    if nv >= 2 or (nv >= 1 and nv + nf >= 2) then return true end
    if nv == 1 then
        local h0 = State.hero
        local hpf = (Entity.GetHealth(h0) or 1) / math.max(1, Entity.GetMaxHealth(h0) or 1)
        return hpf < K.LANE_TRADE_HP
    end
    return enemy_risk_at(p) >= K.SHOVE_SAFE_RISK   -- 0 visible: fogged-proximity COR-1 gate (unchanged)
end

-- REBUILD: clear of EVERY alive enemy tower's attack range + a real margin = no tower damage AND no
-- barely-outside anxiety. note 1 / option A (v0.1.159): the old risk<SHOVE_SAFE_RISK gate stopped the
-- Nav.SafeDest clamp at ~800 from tower center (attack range 700 + the taper edge), which put stands
-- 100u outside the tower 3+ times a game. Now a stand needs ATTACK_RANGE + TOWER_SAFE_MARGIN (900);
-- March reach (1200) still covers 300 past the tower, so the tower-border W-farm is intact. STRICTER
-- than the live abort (lane_unsafe trips ~800) is the safe direction of the v0.1.148 consistency rule:
-- every stand tower_safe accepts, lane_unsafe accepts too (the old bug was the reverse band).
local function tower_safe(pos)
    if not pos then return false end
    local rr = K.TOWER_ATTACK_RANGE + K.TOWER_SAFE_MARGIN
    local p = Vector(pos.x, pos.y, 0)
    for _, t in ipairs(Map.TowersInRadius(p, rr + 100) or {}) do
        if Entity.GetTeamNum(t) ~= State.team and Entity.IsAlive(t) and origin(t):Distance(p) < rr then
            return false
        end
    end
    return true
end

-- Risk v2 STOPGAP (v0.1.164, user: "we will hardly make 450 if tinker keeps walking further into
-- enemy field"): the STRUCTURE FRONT. frontier_excess(P) = (dist to our nearest ALIVE structure -
-- dist to their nearest ALIVE structure) / 2 = how far P sits past the equidistant front line.
-- Tower-state-aware by construction (their T1 dies -> their nearest alive = T2 -> the line
-- advances; ours dies -> it retreats = the user's intensity model). This is Risk v2's unseen-
-- threat floor in its cheapest form; the full reach-time model (task #11) refines it into an ETA.
local function frontier_excess(pos)
    local c = State.structCache
    if not c or now() - c.t > K.FRONTIER_CACHE_S then
        c = { t = now(), list = {} }
        for _, e in ipairs(NPCs.GetAll(Enum.UnitTypeFlags.TYPE_STRUCTURE) or {}) do
            if Entity.IsAlive(e) then
                local p = Entity.GetAbsOrigin(e)
                if p then c.list[#c.list + 1] = { x = p.x, y = p.y, ours = Entity.GetTeamNum(e) == State.team } end
            end
        end
        State.structCache = c
    end
    local df, de = math.huge, math.huge
    for _, s in ipairs(c.list) do
        local dx, dy = s.x - pos.x, s.y - pos.y
        local d = dx * dx + dy * dy
        if s.ours then if d < df then df = d end else if d < de then de = d end end
    end
    if df == math.huge or de == math.huge then return 0 end
    return (math.sqrt(df) - math.sqrt(de)) / 2
end

-- ONE lane-position predicate for the movement/stand/landing chokepoints. DEPTH VETOES REMOVED
-- (user directive 2026-07-03, run-12 evidence: 29 of 33 idle decides were no_safe_stand - the
-- v0.1.164 frontier cap + v0.1.168 T1-line-without-L2 gate turned every deep meeting into dead
-- time instead of farm; "stop vetoing how far it can go in lane - it goes as far as it SHOULD").
-- What remains owns each concern: tower_safe = don't stand in tower fire (kept here, not a
-- distance rule); the TETHER owns WHEN he is deep (arrival-timed visits, waits at anchors);
-- lane_unsafe/PathRisk/gank own enemies; the none-idle frontier retreat owns never-IDLE-deep.
-- The "when it SHOULDN'T go" question belongs to the Risk v2 POINT SYSTEM (task #11 direction:
-- cumulative depth points past the dead-T1 position, Keen shaves points, thresholds gate).
-- THE WALK-PATH CENSUS (v0.1.192) found the four walk producers; v0.1.193 (user, run-23) moved
-- the STAIRS line OFF them: clamping movement/stands at the line was a hard positional veto -
-- it parked the hero AT the line for 22-25s waits (the exact freeze the point-system doctrine
-- forbids). The line is now an EXCLUSION input: safe_stand_for composes the NATURAL stand and
-- reports covers=false when that stand sits past WALK_DEPTH_MAX (non-raid), so Schedule.Plan
-- routes the wave to jungle (no_safe_stand / gone_by_arrival). Movement itself is never
-- depth-clamped again - a committed stand is always legal or the commit never happened.
-- (lane_pos_ok deleted at v0.1.193: with the depth term gone it was a tower_safe alias.)

-- Rearm only where it is SAFE (Note 3): never channel Rearm into a gank/under-tower, but a 1v1 trade
-- is fine (a blanket enemy-proximity gate left him idle between Marches in lane). lane_unsafe gates it.
local function safe_rearm()
    if lane_unsafe(origin(State.hero)) then return false end
    return try_rearm()
end

-- ── blink dagger (escape + travel) ───────────────────────────────────────────
-- Hero-agnostic via NPC.GetItem: every path no-ops if the player did not buy a blink.
local function blink_item() return NPC.GetItem(State.hero, "item_blink", true) end

-- Blink-broken gate: the dagger is disabled ~3s after enemy damage. Damage.GetRecentDamage
-- is the proven idiom (Lina recent_damage); pcall-guarded -> not-broken if the API is absent.
local function blink_broken()
    if not (Damage and Damage.GetRecentDamage) then return false end
    local ok, d = pcall(Damage.GetRecentDamage, State.hero, 3.0)
    return ok and type(d) == "number" and d > 0
end

-- kind = "escape" | "travel": menu on + item present/ready + not broken + not channeling + debounce.
local function can_blink(kind)
    local sw = (kind == "travel") and State.menu.blinkTravel or State.menu.blinkEscape
    if not (sw and sw:Get()) then return false end
    local it = blink_item()
    if not (it and ready(it)) then return false end
    if blink_broken() or is_channeling() then return false end
    if now() - (State.lastBlinkT or -99) < K.BLINK_DEBOUNCE then return false end
    return true
end

-- Cast blink toward dest, clamped into range so it FIRES (a cast beyond cast_range is issued-not-fired).
-- Blink is instantaneous so cast-verify is light: the caller logs + debounces; a mis-fire degrades to
-- the walk/keen fallback next tick. Returns true if issued.
local function do_blink(dest)
    local it = blink_item(); if not (it and dest) then return false end
    local me = origin(State.hero)
    local dx, dy = dest.x - me.x, dest.y - me.y
    local d = math.sqrt(dx * dx + dy * dy)
    local maxr = K.BLINK_RANGE - 50
    local tgt = (d > maxr) and Vector(me.x + dx / d * maxr, me.y + dy / d * maxr, me.z) or Vector(dest.x, dest.y, me.z)
    if cast_pos(it, tgt) then State.lastBlinkT = now(); return true end
    return false
end

-- Walkable snap: try the point, then step toward `toward` until walkable (Note 1 root fix home;
-- shared by the stand composition, the cast points, and the tree-blink landing).
local function snap_walkable(p, toward)
    if not (Map.Walkable and Map.GroundPos) then return { x = p.x, y = p.y } end
    for i = 0, 5 do
        local f = 1 - i * 0.2                          -- the point first, then step toward `toward`
        local qx = toward.x + (p.x - toward.x) * f
        local qy = toward.y + (p.y - toward.y) * f
        local ok, walk = pcall(function() return Map.Walkable(Map.GroundPos(qx, qy)) end)
        if ok and walk then return { x = qx, y = qy } end
    end
    return { x = toward.x, y = toward.y }              -- fall back to `toward` (lane = walkable)
end

-- Proactive escape blink: flee to the safest walkable spot within blink clamp BEFORE the burst
-- (damage_cooldown 3 makes it useless once hit). Primary escape; the caller falls back to walk/keen.
-- Tree-blink (glue rebuild item 5): prefer hiding in the densest standing-tree cluster away from
-- the nearest threat (Nav.TreeHideSpot on Map.TreesInRadius) - breaks vision AND pathing; the open
-- safest-spot pick stays the fallback when no cluster qualifies.
local function try_escape_blink()
    if not can_blink("escape") then return false end
    State.fog = State.fog or enemy_snapshot()
    local me = origin(State.hero)
    local threat, bestd
    for _, h in ipairs((State.fog and State.fog.heroes) or {}) do
        if h.pos then
            local d = me:Distance(Vector(h.pos.x, h.pos.y, me.z))
            if not bestd or d < bestd then bestd, threat = d, { x = h.pos.x, y = h.pos.y } end
        end
    end
    -- v0.1.201 (run-29 t~796 "random blink on outpost"): NO enemy hero known near = nothing a
    -- 200u tree hop escapes (the panic was NEUTRAL damage at the ancient pair; the blink burned
    -- the dagger, hid nowhere, and the keen-home right after covers the actual escape). Blink
    -- only when a hero threat is plausibly in reach.
    if not threat or bestd > K.RISK_RADIUS then return false end
    local trees = {}
    for _, t in ipairs(Map.TreesInRadius(me, K.BLINK_CLAMP) or {}) do
        local tp = Entity.GetAbsOrigin(t)
        if tp then trees[#trees + 1] = { x = tp.x, y = tp.y } end
    end
    local hide = Nav.TreeHideSpot(trees, { x = me.x, y = me.y }, threat, { blink_max = K.BLINK_CLAMP })
    if hide then
        hide = snap_walkable(hide, { x = me.x, y = me.y })       -- land beside the cluster, not IN a tree
        if do_blink(Vector(hide.x, hide.y, me.z)) then
            logline(string.format("blink_escape tree dest=(%.0f,%.0f)", hide.x, hide.y))
            return true
        end
    end
    local dest = Escape.SafestSpotNear(State.hero, K.BLINK_CLAMP, { snapshot = State.fog, now = now })
    if dest and do_blink(dest) then
        logline(string.format("blink_escape dest=(%.0f,%.0f)", dest.x, dest.y))
        return true
    end
    return false
end

-- Travel blink: close a medium gap to the farm stand faster than walking, when SAFE (reserve the
-- dagger for escape if a threat is near). Uses Escape.BlinkInLanding for a safe landing toward the aim.
local function try_travel_blink(aim)
    -- v0.1.214 census instrument (the offlane-camp blink survived FOUR fixes because the failing
    -- gate was never NAMED in the log): every refusal logs blink_skip why=, throttled to 1/2s.
    local function skip(why)
        if now() - (State.lastBlinkSkipLog or -99) > 2.0 then
            State.lastBlinkSkipLog = now()
            logline("blink_skip why=" .. why)
        end
        return false
    end
    if not aim then return false end
    -- v0.1.216 (user: "checked, blink was NOT on cooldown"): cd_or_off conflated five gates; name
    -- the real one. blink_broken (damage in the last 3s - an ENGINE rule, invisible on the icon)
    -- is the expected culprit on camp legs: the neutrals hit him exactly as he leaves a camp.
    if not can_blink("travel") then
        local it = blink_item()
        local why = (not (State.menu.blinkTravel and State.menu.blinkTravel:Get())) and "menu_off"
            or (not it) and "no_item"
            or (not ready(it)) and "item_cd"
            or blink_broken() and "broken_damage"
            or is_channeling() and "channeling"
            or "debounce"
        return skip(why)
    end
    -- v0.1.213 (run-36, user: "farm side camp on offlane is not blinking into position", the
    -- 3-patch one): the hero-side gate was REARM_SAFE_RISK (0.20) - a rearm-exposure bar, not the
    -- blink doctrine. Mid-game ambient fog risk (enemies missing a few seconds anywhere near the
    -- offlane jungle) reads 0.2-0.3 CONSTANTLY, so offlane camp residuals never blinked (run-36:
    -- keened residual 1284-2242 then WALKED, 4+ trips). The doctrine bar = SHOVE_SAFE_RISK (0.35),
    -- the same fog-aware level every other jump-risk gate uses (landing, raid_safe, shove).
    if enemy_risk_at(origin(State.hero)) >= K.SHOVE_SAFE_RISK then return skip("risk_me") end   -- a real jump read: keep the dagger for the escape
    local me = origin(State.hero)
    local d = me:Distance(aim)
    -- v0.1.205 (user: "we are under-using blink... shaving even 3 seconds can mean one more camp"):
    -- the far cap is GONE - a dest beyond blink range gets a max-range hop TOWARD it (the landing
    -- checks below run on the clamped point) and the walk continues from there. Only the too-short
    -- floor remains (a <800u gap is ~2.7s walk = the user's "even 3 seconds" bar). The ONLY veto is
    -- jump risk: the fog-aware risk gates here + on the landing (Eureka refunds the cd fast, the
    -- dagger is not precious when no player can jump us).
    if d < K.BLINK_TRAVEL_MIN then return false end
    -- Blink STRAIGHT at the stand (do_blink clamps into range so it fires). The escape picker
    -- Escape.BlinkInLanding optimizes for SAFETY, not the destination, so it landed off-target
    -- (sometimes the WRONG direction) for a travel hop; we are already gated safe (enemy_risk <
    -- REARM_SAFE_RISK above), so a straight blink to the chosen (walkable) farm stand is right.
    local dest = Vector(aim.x, aim.y, me.z)
    -- Note 4: check the LANDING (clamped like do_blink), not just our current pos. A travel-blink
    -- is a committed teleport with no en-route abort, so it must not land UNDER the enemy tower
    -- (enemy_tower_risk) or into enemies (enemy_risk_at) or on unwalkable ground. Same gate as the
    -- keen landing (v0.1.85/86). If unsafe, skip the blink -> the caller keens/walks (safety-gated).
    local dx, dy = dest.x - me.x, dest.y - me.y
    local dl = math.sqrt(dx * dx + dy * dy)
    local maxr = K.BLINK_RANGE - 50
    local land = (dl > maxr) and { x = me.x + dx / dl * maxr, y = me.y + dy / dl * maxr }
                              or { x = dest.x, y = dest.y }
    if Map.Walkable and Map.GroundPos then
        local ok, walk = pcall(function() return Map.Walkable(Map.GroundPos(land.x, land.y)) end)
        if ok and not walk then
            -- v0.1.217 (user: the offlane trip comes FROM THE FOUNTAIN a couple of times - NOT
            -- broken_damage; the 8x land_unwalkable is the real one: the fixed anchor->stand line
            -- clips the TREELINE at the clamp point, deterministically, every trip): SNAP the
            -- landing back toward the hero onto walkable ground (castable by construction - a
            -- slightly shorter hop + a short walk) instead of refusing the whole blink.
            land = snap_walkable(land, { x = me.x, y = me.y })
            local ok2, walk2 = pcall(function() return Map.Walkable(Map.GroundPos(land.x, land.y)) end)
            if not (ok2 and walk2) then return skip("land_unwalkable") end
        end
    end
    -- v0.1.214 (run-37, the deterministic offlane-camp case: the clamped landing toward the dire
    -- bot camps passes near the LIVE enemy tower -> the old tower term refused every blink there):
    -- the WALK crosses the exact same ground, and a tower does not JUMP - blinking past it is
    -- strictly LESS exposure time. The travel landing gate is PLAYER risk only; tower safety is
    -- owned by the movement clamp + the tower-safe stand composition, as everywhere else.
    if enemy_risk_at(Vector(land.x, land.y, 0)) >= K.KEEN_LAND_SAFE_RISK then
        return skip("land_risk")
    end
    -- v0.1.217: blink to the CHECKED landing (the snapped point when snapping happened; identical
    -- to do_blink's own clamp otherwise) - the point we validated is the point we land on.
    if do_blink(Vector(land.x, land.y, me.z)) then
        logline(string.format("blink_travel d=%.0f dest=(%.0f,%.0f)", d, land.x, land.y))
        return true
    end
    return false
end

-- ── decision funnel (R1-R4) ──────────────────────────────────────────────────
-- Effective HP vs March (Magical): prefer the live per-unit magic damage
-- multiplier (= 1 - MR); fall back to the coarse per-tier table.
local function creep_eff_hp(c, camp_type)
    local hp = Entity.GetMaxHealth(c) or 0
    local mult
    if NPC.GetMagicalArmorDamageMultiplier then
        local ok, m = pcall(NPC.GetMagicalArmorDamageMultiplier, c)
        if ok and type(m) == "number" and m > 0 then mult = m end
    end
    if not mult then mult = 1 - (K.CAMP_MR[camp_type] or 0) end
    return hp / math.max(0.05, mult)
end

local function camp_creep_list(camp, camp_type, neutrals)
    local out = {}
    for _, c in ipairs(Map.CampCreeps(camp, neutrals)) do
        out[#out + 1] = { entity = c, pos = origin(c),
                          hp = creep_eff_hp(c, camp_type), gold = NPC.GetGoldBountyMax(c) or 0 }
    end
    return out
end

-- Per-March EFFECTIVE magic damage to a clustered target, LEVEL-AWARE. Liquipedia:
-- March spawns 144 robots over ~6s (0.4s intervals), each detonating 13/22/31/40 magic
-- by ability level; ROBOTS_EFFECTIVE = the ~count that actually detonate on a clustered
-- camp/wave over that sweep (the damage is delivered OVER TIME, not instantly). This is
-- the ONE damage model for both camp feasibility and the shove cast count - the old flat
-- MARCH_DMG_PER_CAST (level-blind ~450) under-counted late game (one March really does
-- ~960 at L4), inflating the cast count -> a wasteful extra W on a corpse (N5 follow-up).
local function effective_march_dmg()
    local lvl = (State.march and Ability.GetLevel(State.march)) or 0
    if lvl < 1 then return 0 end
    local per = K.PER_MARCH_DMG[lvl] or 0
    -- v0.1.187 (user: read the ACTUAL skill damage from the API): the per-robot damage live via
    -- Ability.GetLevelSpecialValueFor (gitbook-verified; -1 = current level). Patch-proof: a
    -- balance change flows in automatically. The KV special is expected under "damage"; 0/absent
    -- (our own KV dump had damage=0 for March, hence the table) -> the Liquipedia table stands.
    -- One-shot march_per_dmg log says which source won (in-client verification).
    local okv, live = pcall(function()
        return Ability.GetLevelSpecialValueFor and Ability.GetLevelSpecialValueFor(State.march, "damage", -1)
    end)
    if okv and type(live) == "number" and live > 0 then per = live end
    if State.marchPerLogged ~= per then
        State.marchPerLogged = per
        logline(string.format("march_per_dmg per=%d src=%s lvl=%d", per,
            (okv and type(live) == "number" and live > 0) and "live" or "table", lvl))
    end
    local d = per * K.ROBOTS_EFFECTIVE
    -- v0.1.186 (user: account magic-amp items): SPELL AMP (Kaya +10%, Y&K/K&S, talents) scales
    -- March. NPC.GetBaseSpellAmp is the only amp read the API exposes (gitbook-verified name);
    -- whether it aggregates ITEM amp is UNVERIFIED in-client - pcall-guarded, 0-fallback, and the
    -- ft.dmg trace shows the result (buy Kaya -> dmg= should read ~1056 at L4; if it stays 960 the
    -- read does not see items and this needs a modifier-property read instead). Percent-vs-
    -- fraction ambiguity handled (10 -> 0.10; 0.10 stays).
    local ok, amp = pcall(function() return NPC.GetBaseSpellAmp and NPC.GetBaseSpellAmp(State.hero) end)
    if ok and type(amp) == "number" and amp > 0 then
        d = d * (1 + (amp > 1 and amp / 100 or amp))
    end
    return d
end

-- ONE clear-cost model for candidacy + valuation (execution keeps its live ClearBudget cap + early
-- exit). v0.1.183 (USER DAMAGE MODEL, run-18 correction): March hits EVERY creep in the box AT
-- ONCE - each creep intercepts its own robots - so comparing total March damage to the SUM of camp
-- HP was the wrong constraint and INFLATED planning counts (a large pair read 3+ casts ~1005 mana =
-- the camp drought's real root). The EMPIRICAL counts are the model (user): pairs <= 3 W except
-- ancients; big camps 2 at most 3; ancients 3-4 (Dragon ~5 = the exception; the on-arrival live ehp
-- budget + the empty early-exit self-correct it). The tier FLOORS own the planning count; the
-- sum-ceil applies ONLY to STACKS (2x+ creep count is a genuine throughput constraint, v0.1.100).
local function clear_marches(camp_type, ehp, stacks)
    local m = marches_for(camp_type)
    if (stacks or 1) >= 2 then
        local emd = effective_march_dmg()
        if emd > 0 and (ehp or 0) > m * emd then m = math.ceil(ehp / emd) end
    end
    return math.min(K.MAX_CLEAR_MARCHES, m)
end
-- Is a camp clearable within the cap? ceil(ehp/dmg) <= MAX_CLEAR_MARCHES. No March yet (emd 0) -> assume yes.
local function camp_clearable(ehp)
    local emd = effective_march_dmg()
    return emd <= 0 or (ehp or 0) <= emd * K.MAX_CLEAR_MARCHES
end

-- Current Rearm channel time by the ability's LEARNED level (2.69/1.93/1.20 by level). The clear-time
-- model (camp clear_t + the shove cal) rearms BETWEEN Marches, so using the L1 channel (2.69s) at Rearm
-- L2/L3 overestimated every multi-March clear -> the planner rejected camps it could actually finish
-- before the wave, and the shove slack was off. Timing is the farm's backbone; a per-clear error this
-- size is re-applied every decide, so it compounds all game. lvl 0 (pre-6, no Rearm) keeps the L1 value.
local function rearm_channel()
    local lvl = (State.rearm and Ability.GetLevel and Ability.GetLevel(State.rearm)) or 0
    return K.REARM_CHANNEL[lvl] or K.REARM_CHANNEL[1] or 1.25
end

-- LADDER-AWARE teleport pricing (v0.1.230): the tp fed to EVERY InterceptETA / route leg.
-- InterceptETA prices a hop at tp.channel, but the ladder's REAL cost when Keen is on cd
-- is rearm-first (the v0.1.211 raid-transit formula, generalized): ready keen = the bare
-- channel; keen down + rearm ready = rearm channel + keen channel; neither = nil (walk
-- pricing - the decide re-runs every 0.4s and re-prices when a reset comes back). The old
-- flat { channel = KEEN_CHANNEL } underpriced trips whenever Keen was down (run-49 t=176:
-- a commit walked in on keen-priced travel, the wave resolved first, and the exit paid
-- the full rearm+keen it was never charged for). ONE producer - all feed sites use this.
local function keen_tp()
    local kl = (State.keen and Ability.GetLevel and Ability.GetLevel(State.keen)) or 0
    if kl < 1 then return { channel = 1e9 } end   -- unskilled: walking IS the only transport (honest)
    if ready(State.keen) then return { channel = K.KEEN_CHANNEL } end
    local rl = (State.rearm and Ability.GetLevel and Ability.GetLevel(State.rearm)) or 0
    if rl >= 1 and ready(State.rearm) then return { channel = rearm_channel() + K.KEEN_CHANNEL } end
    -- both on cd: the trip's real cost is the WAIT until the ladder can keen, not a walk
    -- (v0.1.230's 1e9 here walk-flipped the pricing world for the whole keen cd - the
    -- run-51 fountain-walk regression). cd read is in-code verified (verify_cast, ~:393).
    local kcd = (Ability.GetCooldownTimeRemaining and Ability.GetCooldownTimeRemaining(State.keen)) or 5
    local wait = kcd
    if rl >= 1 then
        local rcd = (Ability.GetCooldownTimeRemaining and Ability.GetCooldownTimeRemaining(State.rearm)) or 5
        wait = math.min(kcd, rcd + rearm_channel())
    end
    return { channel = wait + K.KEEN_CHANNEL }
end

-- v0.1.162 (schedule audit): the AT-FOUNTAIN refill duration from the ACTUAL deficit at the captured
-- regen rates (6% mana/s + 5% hp/s to REFILL_FRAC) + the rearm-reset-keen at base. Replaces the flat
-- REFILL_WAIT 4.0: at a 60% mana deficit the real wait is ~10s, near-full it is ~1s - the constant
-- skewed the planner's camp-vs-refill choice both ways. Travel to/from base is priced by the caller.
local function refill_wait()
    local h = State.hero
    local mmax = (NPC.GetMaxMana and NPC.GetMaxMana(h)) or 1
    local hmax = Entity.GetMaxHealth(h) or 1
    local tm = math.max(0, K.REFILL_FRAC * mmax - mana()) / math.max(1, K.FOUNTAIN_MANA_PCT_S * mmax)
    local th = math.max(0, K.REFILL_FRAC * hmax - (Entity.GetHealth(h) or 0)) / math.max(1, K.FOUNTAIN_HP_PCT_S * hmax)
    return math.max(tm, th) + rearm_channel()
end

-- F1: can OUR team see this camp centre right now? Distinguishes "fogged" (no
-- vision) from "in vision but empty" (someone cleared it). pcall-guarded: if the
-- FogOfWar API is absent, returns false so behaviour degrades to cache-or-estimate.
local function camp_visible(center)
    if not (FogOfWar and FogOfWar.IsPointVisible) then return false end
    local ok, v = pcall(FogOfWar.IsPointVisible, Vector(center.x, center.y, center.z or 0))
    return ok and v == true
end

-- F1: how many stacks a camp's value implies (real gold / one-stack tier gold).
local function camp_stacks(gold, ctype)
    local base = (TIER_EST[ctype] or TIER_EST[1]).gold or 1
    local n = math.floor((gold or 0) / base + 0.5)
    return (n < 1) and 1 or n
end

local function gather_candidates()
    local cands = {}
    local total, vis, est, seen, cleared = 0, 0, 0, 0, 0
    if not State.menu.kindJungle:Get() then State.funnel = {}; return cands end
    local neutrals = Map.AllNeutrals()                                      -- enumerate neutrals ONCE; box-filter per camp (was a full-map scan per camp)
    for _, cd in ipairs(Map.Camps()) do
        total = total + 1
        local key = camp_key(cd.center)
        if is_cleared(key) then                                            -- recently visited/cleared: skip until respawn
            cleared = cleared + 1
        else
            local creeps = camp_creep_list(cd.camp, cd.type, neutrals)     -- real creeps if in vision
            if #creeps == 0 and camp_visible(cd.center) then               -- F1: in vision + EMPTY -> someone cleared it
                mark_cleared(key); State.campSeen[key] = nil               -- Note 2: do not assume-occupy a camp we can SEE is empty
                cleared = cleared + 1
            else
                local gold, ehp, estimated, source
                if #creeps > 0 then                                        -- in vision + occupied: real value, cache it
                    vis = vis + 1; estimated, source = false, "live"
                    gold, ehp = Farm.GoldValue(creeps), Farm.EffectiveHP(creeps)
                    State.campSeen[key] = { gold = gold, ehp = ehp, seen_at = now() }
                else                                                       -- fogged: last-seen cache if fresh, else TIER_EST
                    local c = State.campSeen[key]
                    if c and (now() - c.seen_at) < K.CAMP_CACHE_S then
                        gold, ehp, estimated, source = c.gold, c.ehp, true, "seen"; seen = seen + 1
                    else
                        local e = TIER_EST[cd.type] or TIER_EST[1]
                        gold, ehp, estimated, source = e.gold, e.hp, true, "est"; est = est + 1
                    end
                end
                if camp_clearable(ehp) then                                -- clearable within MAX_CLEAR_MARCHES (same model as valuation + execution)
                    cands[#cands + 1] = { camp = cd.camp, center = cd.center, type = cd.type, box = cd.box,
                                          creeps = creeps, gold = gold, ehp = ehp, key = key,
                                          estimated = estimated, source = source }
                end
            end
        end
    end
    State.funnel = { total = total, vis = vis, est = est, seen = seen, cleared = cleared, cands = #cands }
    return cands
end

-- Snap a point onto walkable ground by stepping from it toward `toward` (returns {x,y}).
-- Used to keep a keen landing / shove stand off unwalkable terrain (a tower's high ground).
-- (snap_walkable was hoisted above try_escape_blink - glue rebuild item 5 - which now calls it.)

-- REBUILD: the safe stand for a wave MEETING. Start WAVE_STANDBACK back toward our fountain, then push
-- FURTHER back until OUTSIDE enemy tower range = the tower-border W-farm (Tinker takes no tower damage but
-- March still reaches the under-tower wave). Returns (stand, covers, safe):
--   covers = tower-safe AND March from the stand reaches the meeting (within MARCH_CAST_RANGE+HALFWIDTH).
--            covers=false means the wave is too deep to W from safety -> not farmable now (wait/jungle).
--   safe   = not lane_unsafe(stand) (no gank). A non-covering stand is still the safe place to WAIT.
-- (defined AFTER snap_walkable, which it calls - a local function is only in scope below its definition.)
local function safe_stand_for(meeting, forward, deep_ok, lane)
    local fp = friendly_fountain_pos()
    if not (fp and meeting) then return nil, false, false end
    local dx, dy = fp.x - meeting.x, fp.y - meeting.y
    local dl = math.sqrt(dx * dx + dy * dy); if dl < 1 then return nil, false, false end
    -- Glue rebuild item 2: ONE stand = lib composition. Farm.CrashCast places the back-toward-
    -- fountain offset (forward = anticipation: closer so March catches the wave early + lands on the
    -- trailing ranged; contested = the safe 900 back-off), Nav.SafeDest clamps it tower-safe (never
    -- sits in tower range), snap_walkable keeps it off ridges. Replaces the hand-rolled push-back
    -- loop; schedule_ctx's raw-offset duplicates route here too.
    local back = forward and K.ANTICIP_RANGED_REACH or K.WAVE_STANDBACK
    local g = Farm.CrashCast(meeting, nil, { standback = back, fountain = { x = fp.x, y = fp.y } })
    -- v0.1.193 (user, run-23): the stairs line is an EXCLUSION, not a clamp. v0.1.192 clamped the
    -- stand to the line BEFORE the covers test, which legalized commits to line-parked stands
    -- ~1000u short of the fight = the 22-25s stands in enemy territory. Now the stand composes
    -- NATURALLY (tower_safe only); a meeting whose natural stand sits past WALK_DEPTH_MAX is not
    -- walk-farmable -> covers=false -> Plan no_safe_stand/gone_by_arrival -> jungle (the exclusion
    -- lands in the SCHEDULE, per the point-system doctrine). deep_ok (raid-capable) exempts: that
    -- transit is a creep-keen, not a walk. tower_safe always holds.
    local stand = Nav.SafeDest(g.stand, { x = dx / dl, y = dy / dl }, tower_safe)
    stand = snap_walkable(stand, meeting)
    local reach  = (K.MARCH_CAST_RANGE or 300) + (K.MARCH_HALFWIDTH or 900)
    -- v0.1.201: the deep era leashes lane positions to our mid tower (T1DOWN_LEASH).
    -- v0.1.202 (user, run-30: "skipped an obvious keen on creep on a 5-6 creep wave, no way to get
    -- ganked"): an UNGANKABLE raid is exempt from the leash again - deep_ok (Keen L2 shove) + no
    -- gank read at the stand (count+HP-aware lane_unsafe + the fog-aware risk under the shove bar).
    -- Run-30 t=974-1100: visible e=5-6 waves (eff_hp up to 3500, enH=0) idled as no_safe_stand.
    -- The gankable deep case stays excluded (the run-29 148-mana walk-home cannot recur unfunded:
    -- the hop gate prices the entry, v0.1.200).
    local raid_safe = deep_ok and not lane_unsafe(stand) and enemy_risk_at(stand) < K.SHOVE_SAFE_RISK
    -- v0.1.203 (user, standing rule): leash-era anomalies must be ANALYZABLE, not inferred - the
    -- covers=false CAUSE is discriminated (cwhy) and surfaced in the farm trace, so a future
    -- "strange behavior around the leash" reads directly from the log instead of a guess chain
    -- (run-30's diagnosis had to infer which term killed covers).
    local covers, cwhy = false, nil
    if not tower_safe(stand) then cwhy = "tower"
    elseif not Farm.MarchCovers(stand, meeting, reach) then cwhy = "cover"
    elseif not (deep_ok or stand_depth(stand) <= K.WALK_DEPTH_MAX) then cwhy = "depth"
    elseif not (lane_leash_ok(stand, nil, lane) or raid_safe) then cwhy = "leash"
    else covers = true end
    return stand, covers, (not lane_unsafe(stand)), cwhy
end

-- note 3 (v0.1.160, user): any VISIBLE enemy hero within r of pt? (The wait-position check: a
-- forward hold next to a laner = free harass taken; the trade policy allows STAYING on the lane,
-- this only moves WHERE the waiting happens.)
local function enemy_hero_near(pt, r)
    local snap = State.fog or enemy_snapshot()
    local r2 = r * r
    for _, h in ipairs(snap.heroes or {}) do
        if h.visible and h.pos then
            local dx, dy = h.pos.x - pt.x, h.pos.y - pt.y
            if dx * dx + dy * dy <= r2 then return true end
        end
    end
    return false
end

-- note 3 (v0.1.160, user): the PROTECTED wait spot - when an enemy hero is on the lane, wait out
-- a hold near OUR tower (inside its cover, facing the lane) instead of tanking harass at the
-- forward stand. Nearest alive friendly structure to the stand (any distance), offset
-- WAIT_PROTECT_AHEAD toward the stand; no structure -> the stand pulled WAIT_BACKOFF toward our
-- fountain. The wave's arrival (live creeps) switches back to the normal approach automatically.
local function protected_wait_spot(stand)
    -- v0.1.175 (run-13): the WAIT_PROTECT_SCAN 2500 bound predates depth-free stands - a deep
    -- stand near their T2 found NO structure in range and fell back to stand-600 = a fake anchor
    -- DEEP in enemy territory (the tether then keened there, wasting the keen the raid needed).
    -- The wait spot is the nearest alive friendly structure, whatever the distance.
    local best, bestd
    for _, e in ipairs(NPCs.GetAll(Enum.UnitTypeFlags.TYPE_STRUCTURE) or {}) do
        if Entity.GetTeamNum(e) == State.team and Entity.IsAlive(e) then
            local p = Entity.GetAbsOrigin(e)
            if p then
                local d = p:Distance(Vector(stand.x, stand.y, p.z))
                if not bestd or d < bestd then best, bestd = p, d end
            end
        end
    end
    if best then
        local dx, dy = stand.x - best.x, stand.y - best.y
        local dl = math.sqrt(dx * dx + dy * dy)
        if dl > 1 then
            return snap_walkable({ x = best.x + dx / dl * K.WAIT_PROTECT_AHEAD,
                                   y = best.y + dy / dl * K.WAIT_PROTECT_AHEAD },
                                 { x = stand.x, y = stand.y })
        end
        return { x = best.x, y = best.y }
    end
    local fp = friendly_fountain_pos()
    if fp then
        local dx, dy = fp.x - stand.x, fp.y - stand.y
        local dl = math.sqrt(dx * dx + dy * dy)
        if dl > 1 then
            return snap_walkable({ x = stand.x + dx / dl * K.WAIT_BACKOFF,
                                   y = stand.y + dy / dl * K.WAIT_BACKOFF },
                                 { x = stand.x, y = stand.y })
        end
    end
    return { x = stand.x, y = stand.y }
end

-- Keen anchor candidates: friendly buildings (live) + friendly outposts (static,
-- map_data team-matched). Outposts are central and reach the mid camps no building
-- is near (Note 3: those were skipped when only buildings counted as anchors).
local function anchor_candidates(include_creeps)
    local out = {}
    for _, e in ipairs(NPCs.GetAll(Enum.UnitTypeFlags.TYPE_STRUCTURE) or {}) do
        if Entity.GetTeamNum(e) == State.team and Entity.IsAlive(e) then
            local p = Entity.GetAbsOrigin(e)
            if p then out[#out + 1] = { pos = p, r = K.KEEN_LAND_STRUCTURE, name = "bldg" } end
        end
    end
    for _, o in ipairs(MapData.OUTPOSTS or {}) do
        if o.team == State.team and o.pos then
            out[#out + 1] = { pos = Vector(o.pos[1], o.pos[2], o.pos[3]),
                              r = K.KEEN_LAND_OUTPOST, name = o.name or "outpost" }
        end
    end
    -- review #2 part 2: allied lane creeps as keen anchors ONLY for a DEEP DIVE (Keen L2, T1 dead) so
    -- Tinker teleports IN to the deep meeting instead of WALKING through enemy territory (user model).
    -- The v0.1.88 revert removed creeps GLOBALLY (they caused weird enemy-side routing during normal
    -- farming + a death); re-added SCOPED to the dive + still filtered by KEEN_LAND_SAFE_RISK in
    -- keen_to_anchor (the landing-safety gate = the death-scar fix). Off by default.
    if include_creeps then
        State.creepExcl = 0   -- v0.1.236: per-pass tower-drift exclusion count (cexcl= on the keen lines)
        -- v0.1.215 (user, run-38: "teleported on creep, ended up under the tower" + "lost keen to
        -- a dying creep... better to keen on ranged creeps since they are the last to die"): the
        -- anchor is chosen at CAST time but the creep moves/dies during the ~3s channel - a
        -- front-line melee walks INTO tower range and a low-HP one dies and cancels the keen.
        -- Prefer REAR units (ranged/siege: trail the wave, die last) and skip creeps too hurt to
        -- survive the channel; melee only when no rear unit qualifies.
        local rear, melee = {}, {}
        for _, c in ipairs(NPCs.GetAll(Enum.UnitTypeFlags.TYPE_LANE_CREEP) or {}) do
            if Entity.GetTeamNum(c) == State.team and Entity.IsAlive(c) and not Entity.IsDormant(c)
               and (Entity.GetHealth(c) or 0) >= K.KEEN_CREEP_MIN_HP then
                local p = Entity.GetAbsOrigin(c)
                -- v0.1.221 -> v0.1.228 -> v0.1.236 (user: "if we predict that a creep will be
                -- under the enemy tower or is under it, don't keen to it"): every gate in this
                -- chain is CAST-time, but Keen conveys to the UNIT ~3s later. v0.1.228 used the
                -- worst-case straight-at drift (325 x 3.5s, flat ~2050 exclusion) - CONFIRMED
                -- over-excluding in run-54: at a DEEP equilibrium the wave lives near their
                -- alive T2, so every creep (incl. the rear ranged) sat inside 2050 and 9 keens
                -- went to buildings with 1171-3799u residual walks (the user's "should be on
                -- creep, was on tower"). The drift is MOTION-AWARE now: the creep's lane's
                -- MEASURED ally-wave speed (State.laneScan, 2s cache) x KEEN_CREEP_DRIFT_S -
                -- a wave STALLED fighting at the tower exposes its rear creeps again; a
                -- marching wave (325) keeps the full exclusion; unknown speed = worst case.
                -- Floor 100: a stalled fight can break and surge during the ~3s channel.
                if p then
                    local spd = 325
                    local scan = State.laneScan and State.laneScan[Lane._assign_lane({ x = p.x, y = p.y })]
                    local aw = scan and scan.ally_wave
                    if aw then
                        local s2 = aw.speed
                        if not s2 then
                            for _, cc in ipairs(aw.creeps or {}) do
                                if cc.speed and (not s2 or cc.speed > s2) then s2 = cc.speed end
                            end
                        end
                        if s2 then spd = math.max(100, s2) end
                    end
                    local r = K.TOWER_RISK_RADIUS + spd * K.KEEN_CREEP_DRIFT_S
                    for _, tw in ipairs(Map.TowersInRadius(Vector(p.x, p.y, 0), r) or {}) do
                        if Entity.GetTeamNum(tw) ~= State.team and Entity.IsAlive(tw) then
                            State.creepExcl = (State.creepExcl or 0) + 1   -- v0.1.236: the exclusion names itself (cexcl= on the keen lines)
                            p = nil; break
                        end
                    end
                end
                if p then
                    local nm = (NPC.GetUnitName and NPC.GetUnitName(c)) or ""
                    local a = { pos = p, r = K.KEEN_LAND_STRUCTURE, name = "creep" }
                    if nm:find("ranged", 1, true) or nm:find("siege", 1, true) then
                        rear[#rear + 1] = a
                    else
                        melee[#melee + 1] = a
                    end
                end
            end
        end
        local pick = (#rear > 0) and rear or melee
        for i = 1, #pick do out[#out + 1] = pick[i] end
    end
    return out
end

-- Is (x,y) walkable ground? Coerces IsTraversable (may return a truthy INT, not a bool); API absent or a
-- read error -> treat as walkable (don't over-reject a real landing).
local function walkable_pt(x, y)
    if not (Map.Walkable and Map.GroundPos) then return true end
    local ok, w = pcall(function() return Map.Walkable(Map.GroundPos(x, y)) end)
    return (not ok) or (w ~= false)
end

-- Any ALLIED lane creep within `r` of (x,y)? Keen L2+ auto-conveys to the NEAREST ally, so an allied creep
-- near the cast point hijacks the landing and cancels when it moves/dies. Jungle has none; matters near lanes.
local function allied_lane_creep_near(x, y, r)
    local r2 = r * r
    for _, c in ipairs(NPCs.GetAll(Enum.UnitTypeFlags.TYPE_LANE_CREEP) or {}) do
        if Entity.GetTeamNum(c) == State.team and Entity.IsAlive(c) and not Entity.IsDormant(c) then
            local p = Entity.GetAbsOrigin(c)
            if p then local dx, dy = p.x - x, p.y - y; if dx * dx + dy * dy <= r2 then return true end end
        end
    end
    return false
end

-- Nudge a keen landing from (lx,ly) toward the anchor (ax,ay) onto WALKABLE + TREE-FREE (+ optionally
-- CREEP-CLEAR) ground: trees block a landing but GridNav.IsTraversable does NOT flag them, and at Keen
-- L2+ an allied lane creep near the cast point hijacks the convey. Steps from the point nearest the
-- stand toward the anchor (a tower = clear ground, away from the creep line) and returns the first
-- clear {x,y}, keeping the CLOSE tower (small residual bump) instead of falling back to a far anchor.
-- note 1 (v0.1.160): the creep check used to REJECT the whole anchor after the nudge - our own wave
-- marching through the near-anchor disc discarded T1 entirely, so Tinker keened to T2/T3 and walked
-- 1400-3400u to the lane. Folding it into the step loop keeps the near anchor. nil if all blocked.
local function clear_landing(lx, ly, ax, ay, avoid_creeps)
    for i = 0, 6 do
        local f = i / 6
        local x, y = lx + (ax - lx) * f, ly + (ay - ly) * f
        if walkable_pt(x, y)
           and not (avoid_creeps and allied_lane_creep_near(x, y, K.KEEN_CREEP_CLEAR)) then
            local ok, trees = pcall(function() return Map.TreesInRadius(Map.GroundPos(x, y), K.KEEN_TREE_CLEAR) end)
            if (not ok) or (not trees) or #trees == 0 then return { x = x, y = y } end
        end
    end
    return nil
end

-- Keen to the point in a friendly STRUCTURE's reach disc (tower r=700 / outpost r=250) NEAREST the stand.
-- Keen Conveyance is ground-targeted and drops us AT the cast point as long as a valid ally (a building at
-- L1) is within reach, so when a tower covers the stand we land ON the stand (travel ~= 0) instead of on
-- the building + a long walk (which shrinks the camp time budget). lib/geometry.BestReachLanding does the
-- pure disc geometry; the `accept` predicate carries the VALIDATED safety gates (enemy_risk / tower_safe /
-- depth - now checked on the REAL landing) + the allied-creep-clear. Structures only; the creep/BoT reach
-- landing is a later pass on the SAME picker (only the anchor list + accept differ). include_creeps keeps
-- the old deep-dive anchors (provisional under the structure disc until the dedicated creep pass lands).
local function keen_to_anchor(stand, include_creeps)
    local anchors = anchor_candidates(include_creeps)
    local me = origin(State.hero)
    local sdepth = stand_depth(stand)
    -- note 1 (v0.1.160): the creep-hijack only EXISTS at Keen L2+ (L1 conveys to buildings/outposts
    -- only), so L1 skips the creep avoidance entirely; L2+ nudges off creeps inside clear_landing.
    local kl = (State.keen and Ability.GetLevel and Ability.GetLevel(State.keen)) or 0
    local avoid_creeps = (not include_creeps) and kl >= 2
    -- v0.1.233 keen_skip instrument (TINKER_TRANSPORT_STUDY.md G1, the blink_skip lesson
    -- replayed): keen_to_anchor had FOUR silent return-false exits, and one silent refusal
    -- poisons keenedSpot into a full walk (run-52 t=238: a legal own-side dispatch walked
    -- 31.9s; every reconstructable gate passed on paper - the real gate is UNNAMED). Tally
    -- every rejection; name the exit. NAMING ONLY, zero behavior change.
    local rej = { clear = 0, unsafe = 0, tower = 0, overshoot = 0, walklaw = 0 }
    local accept = function(lx, ly, a)
        local cl = clear_landing(lx, ly, a.pos.x, a.pos.y, avoid_creeps)            -- nudge onto walkable + tree-free (+ creep-clear) ground
        if not cl then rej.clear = rej.clear + 1; return false end
        local land = Vector(cl.x, cl.y, 0)
        -- glue review F5 (v0.1.157): the landing danger gate is lane_unsafe - the SAME count+HP-aware
        -- policy that judges the stand itself (gank/fog/low-HP-1v1 reject; a healthy 1v1 trade does
        -- not force a walk to the lane anymore). The old raw enemy_risk_at >= 0.35 rejected every
        -- landing near a single laner (~0.5-0.7 at trade range). tower_safe + the depth cap keep the
        -- instant-teleport conservatism; KEEN_LAND_SAFE_RISK still gates the travel-blink landing.
        if lane_unsafe({ x = cl.x, y = cl.y }) then rej.unsafe = rej.unsafe + 1; return false end
        if not tower_safe({ x = cl.x, y = cl.y }) then rej.tower = rej.tower + 1; return false end   -- v0.1.193: landings are tower-gated only (the stairs line moved to the decide-time exclusion); the depth-vs-stand check below still caps enemy-side overshoot
        if stand_depth(land) > 0 and stand_depth(land) > sdepth + K.KEEN_DEPTH_MARGIN then rej.overshoot = rej.overshoot + 1; return false end  -- cap ENEMY-SIDE overshoot only (don't reject an our-side jungle landing just for being toward mid vs a deep-corner camp -> the "keen to far T3 instead of close T2" bug)
        if not include_creeps and stand_depth(land) > K.WALK_DEPTH_MAX then rej.walklaw = rej.walklaw + 1; return false end  -- v0.1.198 audit HOLE C: a non-raid hop obeys the walk law too - the stand+margin cap alone allowed landings ~700 deep at klvl=1 (legal stand 550 + margin 150)
        a._land = cl                                                                -- stash the cleared cast point for the pick (creep avoidance folded into clear_landing, note 1)
        return true
    end
    local function keen_skip(why, extra)
        logline(string.format("keen_skip why=%s anchors=%d cexcl=%d rej=clear:%d,unsafe:%d,tower:%d,over:%d,walklaw:%d%s",
            why, #anchors, State.creepExcl or 0, rej.clear, rej.unsafe, rej.tower, rej.overshoot, rej.walklaw, extra or ""))
        return false, why   -- v0.1.234: the caller latches (or not) by the NAMED reason
    end
    local best = Geometry.BestReachLanding(anchors, { x = stand.x, y = stand.y }, { accept = accept })
    if not best then return keen_skip("no_landing") end
    local cl = best.anchor._land or { x = best.lx, y = best.ly }                    -- the cleared (tree-free) landing
    local resid = math.sqrt((cl.x - stand.x) ^ 2 + (cl.y - stand.y) ^ 2)
    -- gain gate on the REAL residual (post-keen walk): only keen if it saves meaningful walk vs going direct.
    if me:Distance(Vector(stand.x, stand.y, me.z)) - resid < K.KEEN_GAIN_MIN then
        return keen_skip("gain", string.format(" d=%.0f resid=%.0f", me:Distance(Vector(stand.x, stand.y, me.z)), resid))
    end
    local finalPos = Vector(cl.x, cl.y, stand.z or me.z)
    if cast_pos(State.keen, finalPos) then
        State.channelUntil = now() + K.KEEN_CHANNEL + K.CHANNEL_PAD
        -- v0.1.216 (user: "when keen is lost due to a creep dying there is no process to
        -- recover... it tries to walk"): a canceled channel (the anchor died mid-cast) burns the
        -- cd WITHOUT teleporting, but keenedSpot stays true so the ladder never re-keens - the
        -- leg degrades to a deep walk. Stash the expected landing; keen_cancel_check() compares
        -- after the channel window and re-arms the ladder (rearm -> keen) on a miss.
        State.keenPending = { land = finalPos, origin = { x = me.x, y = me.y },
                              due = now() + K.KEEN_CHANNEL + K.CHANNEL_PAD + 0.3 }
        verify_cast("keen", State.keen)
        if not State.anchorsLogged then
            State.anchorsLogged = true
            local nb, no = 0, 0
            for _, a in ipairs(anchors) do if a.name == "bldg" then nb = nb + 1 else no = no + 1 end end
            logline(string.format("anchors buildings=%d outposts=%d", nb, no))
        end
        logline(string.format("keen_to_anchor anchor=%s land=(%.0f,%.0f) residual=%.0f cexcl=%d",
            best.anchor.name, cl.x, cl.y, resid, State.creepExcl or 0))
        return true
    end
    return keen_skip("cast_failed")   -- v0.1.233: the 4th silent exit (order not issued - channeling/silence/mana at fire time)
end

-- ── best March stand-spot ────────────────────────────────────────────────────
-- Two camps, one March. March's coverage is a rectangle CENTRED on the CAST POINT
-- (Liquipedia: the target point is the centre of the area; robots spawn at the back
-- edge BEHIND Tinker's facing and sweep forward), reaching ~MARCH_LEN/2 each way along
-- facing x ~MARCH_HALFWIDTH each side. So to clear an adjacent pair, cast at the
-- MIDPOINT: the centred rectangle then covers both camps (each ~d/2 from the centre,
-- within MARCH_LEN/2). Stand STAND_RING behind the cast on the A->B axis (in cast
-- range), facing the cast = facing along the axis; robots spawn behind the hero.
-- MARCH_PAIR_OFFSET nudges the cast along the axis; when the on-axis midpoint stand
-- lands on terrain (the river pairs), a PERPENDICULAR stand search (lib/farm
-- PairStandCandidates) finds walkable off-axis ground, tilting the coverage but
-- keeping both camps inside the half-width. nil -> single-camp ring search.
local function pair_spot_for(cand)
    State.pairSkip = nil   -- why pairing did NOT fire (read by the decide log when paired=false)
    local A = cand.center
    if not A then State.pairSkip = "no_center"; return nil end
    -- Scan the FULL static camp list, NOT Camps.InRadius: the latter is VISION-limited
    -- (the v0.1.5 occupancy lesson), so a fogged partner reads as no_partner - the Dire
    -- pair's partner (enemy side) was missed while the Radiant pairs' (own side) were
    -- found. gather_candidates already uses the full Map.Camps() (funnel total=28 every
    -- decide); pairing must too (assume-occupied unless is_cleared).
    -- Accept a partner only within the distance the centred March can actually cover:
    -- PAIR_RADIUS capped by the offset-shrunk reach MARCH_LEN-2*|MARCH_PAIR_OFFSET| (the
    -- lib's feasibility bound far_long=d/2+|off| <= MARCH_LEN/2). At offset 0 this is just
    -- PAIR_RADIUS; a nonzero offset (calibration) shrinks it so the gate never accepts a
    -- partner PairStandCandidates will always reject (which would log infeasible every decide).
    local pair_max = math.min(K.PAIR_RADIUS, K.MARCH_LEN - 2 * math.abs(K.MARCH_PAIR_OFFSET))
    local partner, pd = nil, math.huge   -- nearest assumed-occupied partner within pair_max
    for _, cd in ipairs(Map.Camps() or {}) do
        if cd.camp ~= cand.camp and cd.center then
            local d = A:Distance(cd.center)
            if d > 200 and d <= pair_max
               and not is_cleared(camp_key(cd.center)) and d < pd then
                partner, pd = cd, d
            end
        end
    end
    if not partner then State.pairSkip = "no_partner"; return nil end
    local B = partner.center
    local pc = Farm.PairClearClass(pd, { march_len = K.MARCH_LEN, disc = K.CREEP_DISC })  -- disc-model clear class (clean/clip) -> drives the lean-in budget
    -- PERPENDICULAR-cast model: ALWAYS stand at the MIDPOINT (aim = midpoint) and cast perpendicular to the
    -- camp line - the W's WIDTH (+/- MARCH_HALFWIDTH) spans BOTH camps regardless of terrain. The thin-box
    -- engage has perpendicular room, so a slightly-unwalkable midpoint still works from a nearby walkable
    -- spot; a truly-blocked one is skipped by the move watchdog. (Retired the along-axis PairStandCandidates
    -- + the walkable-midpoint/candidate fallback, which produced the inconsistent 'circle' fallback stand.)
    local mid = Vector((A.x + B.x) / 2, (A.y + B.y) / 2, A.z)
    if enemy_risk_at(mid) >= K.RISK_HARD then
        State.pairSkip = string.format("risk pd=%.0f pcamp=(%.0f,%.0f)", pd, B.x, B.y); return nil
    end
    return { stand = mid, aim = mid, paired = true, partner = B,
             partnerCamp = partner.camp, partnerType = partner.type, clear = pc.class, pd = pd }
end

-- Single-camp stand (pairing is decided upstream in gather_route_targets now, so this is single-only;
-- pair_spot_for is retained for the run_pair_test diagnostic). Stand WITHIN March's cast range of the
-- camp CENTRE and cast W onto it: neutrals cluster at the spawn point (~centre), so March's spawn covers
-- them and the hero has vision (valid engage occupancy read). Search a few small rings x angles for a
-- walkable, low-risk spot; ring order breaks ties toward the closest.
local function best_stand_spot(cand)
    local center = cand.center
    local best = nil
    for _, ring in ipairs({ K.STAND_RING, K.STAND_RING + 50, K.STAND_RING - 60 }) do
        for ang = 0, 360 - K.STAND_STEP, K.STAND_STEP do
            local rad = math.rad(ang)
            local s = Vector(center.x + ring * math.cos(rad),
                             center.y + ring * math.sin(rad), center.z)
            if Map.Walkable(s) then
                local score = -enemy_risk_at(s) * 5   -- safest spot; ring order prefers the closest on ties
                if not best or score > best.score then
                    best = { stand = s, aim = center, score = score }
                end
            end
        end
    end
    return best
end

-- (march_cast_point - the single-aim clamp - was deleted, glue review F3a: no callers,
-- march_cast_point_multi is the one cast-point builder.)

-- Standardized W cast: the March box is a ~1800 SQUARE centred on the cast point (no facing), so coverage
-- depends only on WHERE we cast. Successive casts ROTATE the offset 90 deg (a +/cross around the cluster
-- centre) to spread the robot-spawn area over the creeps for max hits, instead of stacking identical boxes.
-- The offset (MULTI_W_OFFSET << the 900 box half) keeps the cluster covered from every point; a wide pair
-- just gets each camp favoured on alternate casts + aggro pulls the rest in. Base axis: pair -> the camp
-- line (A->B), single -> perpendicular to hero->camp. Clamped to March cast range so the order fires.
local function march_cast_point_multi(s, idx)
    local ss = s.standSpot
    local me = origin(State.hero)
    local aim = ss.aim or s.center                                          -- the cluster (camp centre / pair midpoint)
    -- base direction: pair -> the camp line (A->B); single -> Tinker toward the camp.
    local ux, uy
    if ss.paired and ss.partner then
        ux, uy = ss.partner.x - aim.x, ss.partner.y - aim.y
    else
        ux, uy = aim.x - me.x, aim.y - me.y
    end
    local ul = math.sqrt(ux * ux + uy * uy)
    if ul < 1 then ux, uy = 1, 0 else ux, uy = ux / ul, uy / ul end
    local ang = math.rad(90 * idx)                                          -- rotate the direction 90 deg per cast (+/cross)
    local ca, sa = math.cos(ang), math.sin(ang)
    local rx, ry = ux * ca - uy * sa, ux * sa + uy * ca
    -- cast CLOSE to Tinker in that (rotated) direction: the ~1800 box covers the cluster from right next to
    -- Tinker, so a small offset is reliable (in cast range, robots sweep THROUGH the camp) vs a 300 off-centre push.
    local target = Vector(me.x + rx * K.MULTI_W_OFFSET, me.y + ry * K.MULTI_W_OFFSET, aim.z)
    local maxr = (K.MARCH_CAST_RANGE or 300) - 20
    if me:Distance(target) > maxr then return me + (target - me):Normalized() * maxr end
    return target
end

-- ── one-press pair test ──────────────────────────────────────────────────────
-- The funnel only visits ~3 high-value camps per run, so this evaluates EVERY camp's
-- pairing NOW (real walkability + the full-list partner search) and logs + overlays the
-- result, checking all pairs in one keypress. Ignores is_cleared (tests regardless of
-- recent farming); restores it after. pcall-guarded so one bad camp can't abort the pass.
local function run_pair_test()
    State.fog = enemy_snapshot()                       -- fresh risk snapshot for the test
    local saved = State.cleared; State.cleared = {}
    local results, nPair, nSkip, nClean, nClip = {}, 0, 0, 0, 0
    for _, cd in ipairs(Map.Camps() or {}) do
        local cand = { camp = cd.camp, center = cd.center, type = cd.type, box = cd.box }
        local ok, ps = pcall(pair_spot_for, cand)
        local r = { center = cd.center, tier = cd.type }
        if ok and ps then
            nPair = nPair + 1
            r.paired, r.partner, r.stand, r.cast = true, ps.partner, ps.stand, ps.aim
            local pd = cd.center:Distance(ps.partner)                              -- disc-model clear class (calibration readout)
            local pc = Farm.PairClearClass(pd, { march_len = K.MARCH_LEN, disc = K.CREEP_DISC })
            r.clear, r.fullm, r.pd = pc.class, pc.full_margin, pd
            if pc.class == "clean" then nClean = nClean + 1 else nClip = nClip + 1 end
            logline(string.format("pairtest %s (%.0f,%.0f) PAIR clear=%s fullm=%.0f d=%.0f pcamp=(%.0f,%.0f) stand=(%.0f,%.0f) cast=(%.0f,%.0f)",
                tostring(cd.type), cd.center.x, cd.center.y, pc.class, pc.full_margin, pd, ps.partner.x, ps.partner.y,
                ps.stand.x, ps.stand.y, ps.aim.x, ps.aim.y))
        else
            nSkip = nSkip + 1
            r.paired = false; r.reason = (not ok) and "error" or (State.pairSkip or "?")
            logline(string.format("pairtest %s (%.0f,%.0f) SKIP %s",
                tostring(cd.type), cd.center.x, cd.center.y, tostring(r.reason)))
        end
        results[#results + 1] = r
    end
    State.cleared = saved
    State.pairTestResults, State.pairTestUntil = results, now() + K.TEST_OVERLAY_SEC
    logline(string.format("pairtest SUMMARY camps=%d paired=%d (clean=%d clip=%d) skipped=%d", #results, nPair, nClean, nClip, nSkip))
end

-- Mark the CURRENT hero position as "a pair IS farmable from here" (for a camp pair the tool flags single).
-- Records the hero pos + the TWO nearest camps (the pair being asserted) + their inter-distance, logs it,
-- and drops a persistent magenta marker (draw_pair_marks). Feeds a pair_max / pairing recalibration.
local function mark_pairable()
    local me = origin(State.hero)
    local c1, d1, c2, d2 = nil, math.huge, nil, math.huge     -- two camps nearest the hero
    for _, cd in ipairs(Map.Camps() or {}) do
        if cd.center then
            local d = cd.center:Distance(me)
            if d < d1 then c2, d2, c1, d1 = c1, d1, cd, d
            elseif d < d2 then c2, d2 = cd, d end
        end
    end
    State.pairMarks = State.pairMarks or {}
    local d12 = (c1 and c2) and c1.center:Distance(c2.center) or -1
    State.pairMarks[#State.pairMarks + 1] = { pos = { x = me.x, y = me.y, z = me.z },
        c1 = c1 and c1.center, t1 = c1 and c1.type, c2 = c2 and c2.center, t2 = c2 and c2.type, d12 = d12 }
    local pair_max = math.min(K.PAIR_RADIUS, K.MARCH_LEN - 2 * math.abs(K.MARCH_PAIR_OFFSET))
    logline(string.format("pairmark #%d hero=(%.0f,%.0f) camp1=(%.0f,%.0f) t1=%s camp2=(%.0f,%.0f) t2=%s d12=%.0f pair_max=%.0f",
        #State.pairMarks, me.x, me.y,
        (c1 and c1.center.x) or 0, (c1 and c1.center.y) or 0, tostring(c1 and c1.type),
        (c2 and c2.center.x) or 0, (c2 and c2.center.y) or 0, tostring(c2 and c2.type), d12, pair_max))
end

-- ── lane scan (Wave-scan diagnostic; consumes lib/lane, no farm behaviour) ────
-- Keen Conveyance allowed teleport kinds by ability level (the only Tinker-specific gate;
-- user-stated lvl gates, confirm vs KV in-client). buildings/outposts always; +creep at L2;
-- +ally at L3. Isolated here so a wrong gate is a one-line fix, never a lib change.
local function keen_allowed_kinds()
    local lvl = (State.keen and Ability.GetLevel and Ability.GetLevel(State.keen)) or 0
    local kinds = { "building", "outpost" }
    if lvl >= 2 then kinds[#kinds + 1] = "creep" end
    if lvl >= 3 then kinds[#kinds + 1] = "ally" end
    return kinds
end

-- static teleport anchors: friendly buildings (live) + friendly outposts (map_data). lib/lane
-- augments these with creep/ally anchors from its own scan per allowed_kinds.
local function static_anchors()
    local out = {}
    for _, e in ipairs(NPCs.GetAll(Enum.UnitTypeFlags.TYPE_STRUCTURE) or {}) do
        if Entity.GetTeamNum(e) == State.team and Entity.IsAlive(e) then
            local p = Entity.GetAbsOrigin(e)
            if p then out[#out + 1] = { pos = { x = p.x, y = p.y }, ready = true, kind = "building" } end
        end
    end
    for _, o in ipairs(MapData.OUTPOSTS or {}) do
        if o.team == State.team and o.pos then
            out[#out + 1] = { pos = { x = o.pos[1], y = o.pos[2] }, ready = true, kind = "outpost" }
        end
    end
    return out
end

-- (keen_anchor_set - static anchors + allied creeps at Keen L2 for travel ETAs - was deleted,
-- glue review F3b: built for the creep-keen reach but never wired to a consumer. Re-add WITH
-- its consumer when the creep/BoT reach landing feature lands; the shape is in git history.)

-- push directions toward the enemy base (constant per team) from the static fountains.
local function lane_push_dirs()
    local ours, theirs
    for _, f in ipairs(MapData.FOUNTAINS or {}) do
        if f.team == State.team then ours = f.pos else theirs = f.pos end
    end
    if not (ours and theirs) then return { x = 1, y = 1 }, { x = -1, y = -1 } end
    local ally_push  = { x = theirs[1] - ours[1], y = theirs[2] - ours[2] }   -- our creeps push to the enemy base
    local enemy_push = { x = ours[1] - theirs[1], y = ours[2] - theirs[2] }   -- enemy creeps push to our base
    return enemy_push, ally_push
end

-- Piece 1.5: lane axis polylines (static towers + captured spawns), built ONCE (statics don't move).
-- Fed to ScanLanes for the arc-length fogged-wave mirror + drawn on the wavescan overlay.
local function lane_paths()
    State.lanePaths = State.lanePaths or Lane.BuildLanePaths(MapData.TOWERS, MapData.SPAWNS)
    return State.lanePaths
end

-- max live member speed of a wave (est waves carry .speed from the mirror; real waves from members).
local function wave_speed(w)
    if not w then return nil end
    if w.speed then return w.speed end
    local s
    for _, cc in ipairs(w.creeps or {}) do if cc.speed and (not s or cc.speed > s) then s = cc.speed end end
    return s
end

-- arm_overlay: true (from the bind) keeps the visual overlay up for TEST_OVERLAY_SEC; the automatic
-- caller passes false so it LOGS the all-lanes wavescan every tick-cadence without forcing the overlay on.
local function run_lane_scan(arm_overlay)
    local enemy_push, ally_push = lane_push_dirs()
    local me = origin(State.hero)
    local lanes = Lane.ScanLanes({
        team = State.team, enemy_push = enemy_push, ally_push = ally_push,
        anchors = static_anchors(), allowed_kinds = keen_allowed_kinds(),
        hero_pos = { x = me.x, y = me.y },
        move_speed = (NPC.GetMoveSpeed and NPC.GetMoveSpeed(State.hero)) or 320,
        tp = keen_tp(),   -- v0.1.230: ladder-aware (rearm-first when keen is down; nil = walk pricing)
        game_time = now(),   -- fog-fill: ExpectedWave estimate for unseen lanes. NOTE now()=GameRules.GetGameTime(); confirm it is the GAME CLOCK (0:00=first wave) vs engine time in-client (affects wave parity).
        paths = lane_paths(),   -- Piece 1.5: fogged enemy waves get position/speed via the arc-length mirror
    })
    State.laneScan = lanes
    if arm_overlay then State.laneScanUntil = now() + K.TEST_OVERLAY_SEC end
    -- Piece 1 (lane instruments, TINKER_LANE_NAV_DESIGN.md roadmap): CLEAN k=v rows + the truth
    -- fields (fronts/meeting/hp/prediction) so the offline `--lane-report` can measure each wave
    -- instrument against observed reality: arrival timing vs NextWaveArrival (+ the real spawn-grid
    -- phase), ExpectedWave hp truth at est->real transitions, and meeting drift. The old prose
    -- format was not machine-parseable (the analyzer splits strict k=v); the overlay is unaffected
    -- (it draws from State.laneScan).
    local pred = Schedule.NextWaveArrival(now(), K.WAVE_PERIOD, K.WAVE_PHASE, State.laneWaveT.mid)
    -- Piece 1.5: KINEMATIC arrival candidate on trial next to the spawn-grid pred. With the mirror,
    -- both mid fronts (real or mirrored) + live-read speeds exist, so the meeting ETA is pure
    -- kinematics - no spawn-clock guess. --lane-report judges pred vs kpred head-to-head; the
    -- decision input only switches after the data says so (Piece 2).
    local kpred = -1
    do
        local s = lanes.mid
        local ew, aw = s.enemy_wave, s.ally_wave
        local espd, aspd = wave_speed(ew), wave_speed(aw)
        if ew and ew.front and aw and aw.front and espd and aspd then
            local pm = Lane.PredictMeeting({ pos = ew.front, speed = espd }, { pos = aw.front, speed = aspd })
            if pm then kpred = now() + pm.eta end
        end
    end
    logline(string.format("wavescan SCAN t=%.1f wave=%d pred=%.1f kpred=%.1f lastw=%s",
        now(), math.floor(now() / 30) + 1, pred or -1, kpred,
        State.laneWaveT.mid and string.format("%.1f", State.laneWaveT.mid) or "-"))
    local function pt(p) return p and string.format("%.0f;%.0f", p.x, p.y) or "-" end
    for _, ln in ipairs({ "top", "mid", "bot" }) do
        local s = lanes[ln]
        local ew, aw = s.enemy_wave, s.ally_wave
        local comp = (ew and ew.estimated)
            and string.format("m%dr%ds%df%d", ew.melee or 0, ew.ranged or 0, ew.siege or 0, ew.flagbearer or 0)
            or "-"
        local push = s.clash and (s.clash.pushing .. (s.clash.moving and "" or "/hold")) or "none"
        local crash = "-"
        if s.clash and s.clash.crashing and s.clash.crash_tower then
            crash = (s.clash.crash_tower.team == State.team) and "allyTwr" or "enemyTwr"
        end
        -- Piece 1.5 push model: per-lane BALANCE from the attrition sim (bal = net survivors of the
        -- current fight, + = OUR lane pushes; peta = predicted fight-end time). Instrumentation on
        -- trial: --lane-report judges bal against the OBSERVED front movement in the same log.
        local bal, peta = "-", "-"
        if ew and aw then
            local pf = Lane.PushForecast(aw, ew, { cycle = math.min(30, math.floor(now() / 450)),
                                                   game_time = now(), rounds = 1 })
            bal  = string.format("%d", pf.bal or 0)
            peta = string.format("%.1f", now() + (pf.first_t or 0))
        end
        logline(string.format(
            "wavescan ln=%s e=%d est=%s src=%s comp=%s a=%d hp=%d gold=%d push=%s crash=%s bal=%s peta=%s eta=%s reach=%s enH=%d alH=%d ef=%s af=%s meet=%s",
            ln, ew and ew.count or 0, (ew and ew.estimated) and "y" or "n",
            (ew and ew.est_src) or "-", comp,
            aw and aw.count or 0, math.floor((ew and ew.hp) or 0), math.floor(s.gold or 0), push, crash, bal, peta,
            s.intercept and string.format("%.1f", s.intercept.eta) or "-",
            tostring(s.intercept and s.intercept.reachable), s.enemy_heroes, s.ally_heroes,
            pt(ew and ew.front), pt(aw and aw.front), pt(s.meeting)))
    end
end

-- ── route scan (Stage 0 diagnostic; consumes lib/route, NO farm behaviour) ────
-- Build the unified FarmTarget list (camps + visible lane waves) + run the planner, for the
-- "Route scan" overlay/log. The FSM is NOT touched: this only computes + shows the plan.
-- the hero's kinematic state for the planner (pos + move speed + Keen tp + static anchors).
-- live (level-scaled) ability mana cost with the Liquipedia fallback (mirrors the rearm-cost read).
local function abil_mana(abil, fb)
    local ok, c = pcall(function() return Ability.GetManaCost and Ability.GetManaCost(abil) end)
    return (ok and type(c) == "number" and c > 0) and c or fb
end
-- mana to ENGAGE the next target = reach (Keen) + one March (gets value). The opportunistic Rearm +
-- 2nd March are NOT gated here: gating the full 2-March+Rearm clear (~540) would exceed early Tinker's
-- whole mana pool (~459), so no hop would ever be affordable -> the planner would loop on the refill
-- node. Running out mid-clear is handled by the in-engage mana bail.
local function hop_mana_cost()
    local c = abil_mana(State.keen, K.KEEN_MANA_FB) + abil_mana(State.march, K.MARCH_MANA_FB)
    -- v0.1.200 (run-28 t=474.4): a shove committed right after a camp clear with March ON COOLDOWN
    -- at ~360 effective - the engage had to Rearm FIRST to get March back (225), landed at 48 mana,
    -- cast ZERO W and walked home; the wave waited ~25s for its Marches. When March is on cd the
    -- FIRST W costs a Rearm too, so the hop gate prices the true entry.
    -- v0.1.211: same for KEEN on cd (the ladder-aware raid transit rearms to reset it) - ONE
    -- Rearm resets both, so the term is added once.
    if (State.march and not ready(State.march)) or (State.keen and not ready(State.keen)) then
        c = c + abil_mana(State.rearm, K.REARM_MANA_FB)
    end
    return c
end
local function mana_regen_read()
    local ok, v = pcall(function() return NPC.GetManaRegen and NPC.GetManaRegen(State.hero) end)
    return (ok and type(v) == "number" and v > 0) and v or K.MANA_REGEN_FALLBACK
end
local function hp_regen_read()
    local ok, v = pcall(function() return NPC.GetHealthRegen and NPC.GetHealthRegen(State.hero) end)
    return (ok and type(v) == "number" and v > 0) and v or K.HP_REGEN_FALLBACK
end

local function route_hero_state()
    local me = origin(State.hero)
    local h  = State.hero
    return {
        pos = { x = me.x, y = me.y },
        move_speed = (NPC.GetMoveSpeed and NPC.GetMoveSpeed(State.hero)) or 320,
        tp = keen_tp(),   -- v0.1.230: ladder-aware (the old .ready field was never consumed by InterceptETA)
        anchors = static_anchors(),
        -- live resources for the predictive next-hop gate (Note 4).
        -- v0.1.181 (mana review): EFFECTIVE mana (raw + Bottle charges), same as the SHOVE gate -
        -- the glue rebuild made charges count for shoves but the camp pipeline stayed raw, so a
        -- camp could read unaffordable while 1-3 drinkable charges (+60-180) covered it.
        -- v0.1.199 (run-27 refill-churn census): UNCAPPED. The v0.1.181 min(effective, max) cap made
        -- charges/items invisible exactly at full pool - the whole 663-pool era read a8/ok0 at FULL
        -- mana while 3 charges (+180) covered the 2-March+Rearm price (~675+reserve), freezing the
        -- jungle for ~2 min and feeding the fountain loop. Charges spend fine across a multi-cast
        -- clear (cast below max, then drink), so the honest planner number is raw + headroom.
        -- max_mana carries the SAME headroom so lib/route's regen/refill-node caps don't strip it
        -- (the fountain refills charges too, so the post-refill ceiling is honest).
        mana = effective_mana(),
        max_mana = (NPC.GetMaxMana(h) or 1) + math.max(0, effective_mana() - mana()),
        hp = Entity.GetHealth(h) or 1, max_hp = Entity.GetMaxHealth(h) or 1,
        mana_regen = mana_regen_read(), hp_regen = hp_regen_read(),
        reserve_mana = abil_mana(State.keen, K.KEEN_MANA_FB),   -- always retain Keen-home escape/return mana
        hp_floor = (Entity.GetMaxHealth(h) or 1) * K.HP_FLOOR_FRAC,
    }
end

-- planner opts (calibratable; now() is the game clock for the target windows).
local function route_opts()
    return { now = now(), horizon_s = K.ROUTE_HORIZON_S, max_steps = K.ROUTE_MAX_STEPS,
             risk_weight = K.ROUTE_RISK_WEIGHT, risk_hard = K.RISK_HARD, refill_frac = K.REFILL_FRAC,
             pool_cap = K.ROUTE_POOL_CAP,        -- #3: raise the DFS candidate cap off the lib default 10
             step_decay = K.ROUTE_STEP_DECAY,    -- v0.1.212: front-load value (bank the pair FIRST; later steps execute with p<1)
             max_leg_s = K.MAX_CAMP_TRAVEL_S }   -- #2: reachability guard (drop unreachable far camps)
end

local function our_farm_priority()
    local peers = {}
    for _, e in ipairs(Heroes.GetAll() or {}) do peers[#peers + 1] = e end
    local v = HeroValue.of(State.hero, peers)
    return HeroValue.FarmPriority({ role = nil, value = v })   -- role read = later flagged verify
end

-- Allies for the contest: pos + a FarmPriority value (camp value-contest) + a CORE flag (carry/mid/
-- offlane via HeroValue.IsCore = role-first, role-tag-base fallback). The lane contest yields to a
-- core ally or 2+ allies (Note 2); a lone support no longer blocks Tinker's lane.
local function ally_farm_priorities()
    local out, peers = {}, {}
    for _, e in ipairs(Heroes.GetAll() or {}) do peers[#peers + 1] = e end
    for _, e in ipairs(Heroes.GetAll() or {}) do
        if e ~= State.hero and Entity.GetTeamNum(e) == State.team and Entity.IsAlive(e) then
            local p = (not Entity.IsDormant(e)) and origin(e) or Hero.GetLastMaphackPos(e)
            if p then
                local name = (NPC.GetUnitName and NPC.GetUnitName(e)) or nil
                out[#out + 1] = {
                    pos = p,
                    value = HeroValue.FarmPriority({ role = HeroValue.role(e), value = HeroValue.of(e, peers) }),
                    core = HeroValue.IsCore(e, name, K.CONTEST_CORE_BASE),
                }
            end
        end
    end
    return out
end

-- tally allies per lane region (Lane._assign_lane): n = all allies, c = CORE allies (carry/mid/offlane).
-- The wave contest yields a lane to a CORE ally (c>=1) OR 2+ allies (n>=2, XP split); a lone support
-- (not core, n<2) does NOT block the lane - fixes Tinker abandoning his own lane to a support (Note 2).
local function ally_lane_tally(allies)
    local t = { top = { n = 0, c = 0 }, mid = { n = 0, c = 0 }, bot = { n = 0, c = 0 } }
    for _, a in ipairs(allies or {}) do
        if a.pos then
            local e = t[Lane._assign_lane(a.pos)]
            if e then e.n = e.n + 1; if a.core then e.c = e.c + 1 end end
        end
    end
    return t
end

local function gather_route_targets(allies, our_pri)
    local out = {}
    local ropts = risk_opts()                                                    -- Note 3 structural risk (once per build)
    local camp_cands = gather_candidates()
    -- #4: a camp's REMAINING value = its live alive-creep bounty. c.gold already IS that: gather_candidates
    -- reads the box in vision (dead creeps excluded) and caches the last-seen alive bounty while fogged, and
    -- fsm_engage refreshes that cache THROUGH the clear. So no gold-delta subtraction (the old campGained
    -- double-subtracted dead creeps for an in-vision camp and was contaminated by passive/lane/kill gold).
    local function eff_gold(c) return c.gold or 0 end
    local function marches_life(tier, ehp, gold) return clear_marches(tier, ehp, camp_stacks(gold, tier)) end   -- shared capped clear-cost model (#1); stacks from the gold read (v0.1.183: the sum-ceil is stack-only)
    -- clear TIME + mana for `marches` casts. A PAIR clears with ONE perpendicular W spanning both camps,
    -- so a pair uses the TANKIER camp's count (MAX life), not the sum: two camps' gold for ~one camp's
    -- cost (v0.1.103). Real per-March time = cast + robot-kill + a level-aware Rearm channel between casts.
    local function clear_time(marches)
        -- CADENCE + one TAIL: casting the Marches (cast + Rearm channel between) is the sequential cost;
        -- the robots deliver over 6s and overlap the Rearm channel, so the kills happen DURING the cadence
        -- we already count - add only ONE tail for the last March's robots finishing (not per-March).
        return marches * K.MARCH_CAST_DUR + math.max(0, marches - 1) * rearm_channel() + K.ROBOT_TAIL
    end
    local function mana_for(marches)
        -- keen in + N Marches + the (N-1) REARMS between them (each Rearm resets March but costs ~225 mana).
        -- The old model omitted Rearm mana, so the planner under-costed a camp by ~half -> it committed to
        -- camps it could not afford -> mana-starved mid-clear and went home before finishing (no engage_done,
        -- the "mana starve without Bottle" bug). clear_t already counts the Rearm TIME; this counts its mana.
        return abil_mana(State.keen, K.KEEN_MANA_FB) + marches * abil_mana(State.march, K.MARCH_MANA_FB)
               + math.max(0, marches - 1) * abil_mana(State.rearm, K.REARM_MANA_FB)
    end
    local function emit_single(c)
        local marches = marches_life(c.type, c.ehp, c.gold)
        local crisk = math.min(1, enemy_risk_at(c.center) + Farm.StructuralRisk({ x = c.center.x, y = c.center.y }, ropts))
        out[#out + 1] = {
            kind = "camp", lane = "jungle", pos = { x = c.center.x, y = c.center.y },
            value = eff_gold(c), clear_t = clear_time(marches), risk = crisk,
            contested = Farm.IsContestedByAlly(c.center, allies, { radius = K.CONTEST_RADIUS, min_value = our_pri }),
            ref = c, mana_cost = mana_for(marches), hp_cost = crisk * K.HP_RISK_DMG,
        }
    end
    -- #2/#3: greedy-pair the CANDIDATES (clearable camps only) so a feasible pair is ONE planner node
    -- (value = SUM of both golds, cost = the TANKIER camp), decided ONCE here. Old code emitted BOTH camps
    -- of a pair, each carrying the pair bonus -> the multi-step plan double-counted a pair; and the
    -- execution-time partner search (pair_spot_for over ALL Map.Camps) could disagree with this valuation.
    -- Now one node = one farm action, and the pairing that is valued is exactly the one that executes.
    -- A pair whose MIDPOINT is unsafe (enemy_risk >= RISK_HARD) is split back to two singles, so each camp
    -- can still be farmed from its own safe stand (the single fallback the old pair_spot_for gave).
    local pts = {}
    for i = 1, #camp_cands do pts[i] = { x = camp_cands[i].center.x, y = camp_cands[i].center.y } end
    local pair_max = math.min(K.PAIR_RADIUS, K.MARCH_LEN - 2 * math.abs(K.MARCH_PAIR_OFFSET))
    local allow = function(i, j) return forced_pair(camp_cands[i].center, camp_cands[j].center) end   -- whitelist over-range pairs
    for _, g in ipairs(Farm.GreedyPairs(pts, pair_max, nil, allow)) do
        local a = camp_cands[g.a]
        local b = g.b and camp_cands[g.b] or nil
        local midv = b and Vector((a.center.x + b.center.x) / 2, (a.center.y + b.center.y) / 2, a.center.z) or nil
        local er = midv and enemy_risk_at(midv) or 1
        -- v0.1.189 (user economics, FINAL): a pair costs the TANKIER camp's marches = the SAME
        -- mana as clearing that camp alone, for TWO camps' gold - the pair STRICTLY DOMINATES.
        -- Never split one: the v0.1.182 fundable->singles degrade (obsolete since the v0.1.183
        -- floors made non-ancient pair cost == single cost) only ever fired on ANCIENT pairs,
        -- where clearing the cheap partner solo condemned the ancient to a full-price solo clear
        -- later. An unfundable pair now simply WAITS (both camps intact) for the refill chain /
        -- pool growth. Singles exist only for genuinely partnerless camps or an unsafe midpoint.
        if b and er < K.RISK_HARD then
            local mid = { x = midv.x, y = midv.y }
            local marches = math.max(marches_life(a.type, a.ehp, a.gold), marches_life(b.type, b.ehp, b.gold))
            local crisk = math.min(1, er + Farm.StructuralRisk(mid, ropts))
            local pc = Farm.PairClearClass(g.d, { march_len = K.MARCH_LEN, disc = K.CREEP_DISC })
            out[#out + 1] = {
                kind = "camp", lane = "jungle", pos = mid, value = eff_gold(a) + eff_gold(b),
                clear_t = clear_time(marches), risk = crisk,
                contested = Farm.IsContestedByAlly(mid, allies, { radius = K.CONTEST_RADIUS, min_value = our_pri }),
                ref = a, partnerRef = b, pairClass = pc.class, pairPd = g.d,
                mana_cost = mana_for(marches), hp_cost = crisk * K.HP_RISK_DMG,
            }
        else
            emit_single(a); if b then emit_single(b) end
        end
    end
    -- v0.1.224 STACKING (user: GPM-first, LARGE camps only, cap 2x): a large camp gets a
    -- timed-aggro node in the ~:54 window - the maneuver walks the old creeps across the :00
    -- respawn and DOUBLES the camp; the stack-aware clear model (camp_stacks + the sum-ceil)
    -- already prices and clears the result next cycle for ~the same mana = the pair economics
    -- again. The window's to-deadline makes a late start uncollectable (timeline-exact); the
    -- wave's Tier-1 dispatch + leave_by preempt outrank the maneuver (waves always win).
    if State.menu.stackLarge and State.menu.stackLarge:Get() then
        local win = Schedule.StackWindow(now(), { aggro_sec = K.STACK_AGGRO_SEC })
        for _, c in ipairs(camp_cands) do
            if c.type == 2 and camp_stacks(c.gold, c.type) < 2 then
                local crisk = math.min(1, enemy_risk_at(c.center) + Farm.StructuralRisk({ x = c.center.x, y = c.center.y }, ropts))
                out[#out + 1] = {
                    kind = "stack", lane = "jungle", pos = { x = c.center.x, y = c.center.y },
                    value = eff_gold(c) * K.STACK_VALUE_FRAC, clear_t = win.clear_t,
                    risk = crisk, window = { from = win.from, to = win.to },
                    contested = Farm.IsContestedByAlly(c.center, allies, { radius = K.CONTEST_RADIUS, min_value = our_pri }),
                    ref = c, stackWin = win, mana_cost = 0,
                }
            end
        end
    end
    -- Note 4: the fountain refill as an optimised routed node (the planner inserts it only when it
    -- unlocks enough downstream gold). _timeline restores mana/hp to refill_frac*max on this step.
    local fpos = friendly_fountain_pos()
    if fpos then
        out[#out + 1] = { kind = "refill", lane = "base", pos = { x = fpos.x, y = fpos.y },
                          value = 0, clear_t = refill_wait(), risk = 0, restore = true }
    end
    return out
end

-- live enemy lane creeps within `radius` of `pos` (for the wave March aim + the cleared check).
-- Mirrors lib/lane's lane-creep read; returns the minimal { pos } the engage needs.
local function enemy_lane_creeps_near(pos, radius)
    local out, r2 = {}, radius * radius
    for _, n in ipairs(NPCs.GetAll(Enum.UnitTypeFlags.TYPE_LANE_CREEP) or {}) do
        if Entity.GetTeamNum(n) ~= State.team and Entity.IsAlive(n) and not Entity.IsDormant(n)
           and not (NPC.IsWaitingToSpawn and NPC.IsWaitingToSpawn(n)) then
            local p = Entity.GetAbsOrigin(n)
            if p then
                local dx, dy = p.x - pos.x, p.y - pos.y
                if dx * dx + dy * dy <= r2 then out[#out + 1] = { pos = p } end
            end
        end
    end
    return out
end

local function run_route_scan()
    State.fog = enemy_snapshot()                  -- fresh risk snapshot
    local allies = ally_farm_priorities()          -- FarmPriority-scaled (matches our_pri)
    local our_pri = our_farm_priority()
    local targets = gather_route_targets(allies, our_pri)
    local plan = Route.Plan(targets, route_hero_state(), route_opts())
    State.routeScan = { plan = plan, targets = targets, our_pri = our_pri }
    State.routeScanUntil = now() + K.TEST_OVERLAY_SEC
    logline(string.format("routescan our_pri=%.2f cands=%d steps=%d gold=%.0f time=%.1f",
        our_pri, #targets, #plan.steps, plan.gold or 0, plan.time or 0))
    for i, s in ipairs(plan.steps) do
        logline(string.format("routestep %d kind=%s pos=(%.0f,%.0f) value=%.0f clear=%.1f risk=%.2f",
            i, s.kind, s.pos.x, s.pos.y, s.value or 0, s.clear_t or 0, s.risk or 0))
    end
    -- dump EVERY candidate (not just chosen steps) + the reason it was/wasn't picked, so a skipped
    -- lane is explained in text without the overlay (Note 2): CHOSEN, skip=contested, skip=risk
    -- (>= RISK_HARD veto), or not-picked (eligible but the planner found a better sequence).
    local chosen = {}
    for _, st in ipairs(plan.steps) do chosen[st] = true end
    for _, t in ipairs(targets) do
        local why = chosen[t] and "CHOSEN"
            or (t.contested and "skip=contested")
            or (((t.risk or 0) >= K.RISK_HARD) and "skip=risk")
            or "not-picked"
        logline(string.format("routecand kind=%s lane=%s pos=(%.0f,%.0f) value=%.0f risk=%.2f contested=%s %s",
            t.kind, t.lane or "-", t.pos.x, t.pos.y, t.value or 0, t.risk or 0, tostring(t.contested or false), why))
    end
end

-- ── FSM ──────────────────────────────────────────────────────────────────────
-- Loop-guard + diagnostic, run on EVERY engage exit. We Marched the camp, so it is empty now: ALWAYS mark
-- it cleared until the next respawn (the cleared flag, tied to next_respawn, is the re-pick gate - a
-- fogged camp we cannot see is not re-picked). Waves are not is_cleared-tracked (they respawn every 30s),
-- so camps only.
local function mark_engage_result()
    local s = State.spot
    if s and s.kind == "camp" and (State.marchCasts or 0) > 0 then
        mark_spot_cleared(s)
        -- v0.1.212 COST-TRUTH CENSUS (run-35: plans price ~2 casts, execution ran casts=3 budget=3
        -- everywhere -> the real spend ~2x the planned mana_cost -> every multi-step plan's tail
        -- broke at the replan and the PAIR step never executed = the recurring lonely-single).
        -- real= is the raw mana delta over the clear (bottle drinks make it read LOW, never high),
        -- so real >> plan on this line is the model gap, measured. Feeds the pricing recalibration.
        local real = State.engageMana and math.max(0, State.engageMana - mana()) or -1
        logline(string.format("camp_value key=%s gold=%d cleared=true(eng) casts=%d plan=%d real=%d",
            tostring(s.key), math.floor(s.gold or 0), State.marchCasts or 0,
            math.floor(s.planCost or -1), math.floor(real)))
        State.marchCasts = 0   -- once-per-engage: panic calls go_return every tick; without this the
                               -- loop-guard + camp_value log re-fire ~45x per panic episode.
    end
end

-- return to the fountain to refill (mana-bail / panic / the planner's refill node).
local function go_return()
    mark_engage_result()
    State.fsm = "RETURN"
end

-- Note 4: a farm target finished and we may be able to chain - re-plan instead of always returning to
-- base. The resource-aware planner decides the next step: another farm target (chain), or its refill
-- node when nothing is affordable (-> the refill branch in fsm_decide sets RETURN).
local function engage_replan()
    mark_engage_result()
    State.spot = nil
    State.fsm  = "DECIDE"
end

local function handle_panic()
    local h = State.hero
    local frac = (Entity.GetHealth(h) or 1) / math.max(1, Entity.GetMaxHealth(h) or 1)
    if frac < K.PANIC_HP then
        State.lowHpSince = State.lowHpSince or now()
        if now() - State.lowHpSince >= K.PANIC_ARM then
            State.panicUntil = now() + 1.0
            try_escape_blink()                          -- best-effort (usually broken once bursted); keen_home is the panic fallback
            go_return()
            return true
        end
    else
        State.lowHpSince = nil
    end
    return now() < State.panicUntil
end

-- Build the Schedule.Plan ctx for the HOME lane from a lib/lane lanes table. crash/shove point (visible
-- centroid -> clash contact -> stable mid ref), wave eff-HP, wave arrival (visible -> now; fogged ->
-- measured cadence lastWaveT + WAVE_PERIOD), travel-to-mid via InterceptETA (Keen), safety/mana gates.
-- Returns { plan, crash_pos, stand, aim, visible, risk } or nil if no home lane / no reference point.
-- Note 1 root: the standback toward our fountain (below) can land the shove stand on a
-- backline tower's HIGH GROUND (unwalkable) -> the keen+walk gets stuck (the v0.1.64
-- watchdog then only recovers). Pull the stand in toward the (walkable, lane) crash point
-- until it sits on walkable ground, so the shove stand is reachable in the first place.
local function schedule_ctx(lanes)
    local s = lanes and lanes[K.HOME_LANE]
    if not s then return nil end
    local cl = s.clash or {}
    local ew = s.enemy_wave
    local visible = (ew and not ew.estimated and ew.centroid) and true or false

    -- AIM at the wave MEETING point: the midpoint of the two ENGAGED fronts (lib/lane.MeetingPoint,
    -- fog-aware). Replaces the old enemy-wave-centroid / clash-contact aim, which chased the
    -- freshly-spawned wave back near a tower -> deep-own (fogged) or deep-enemy (visible) stands (notes
    -- 1/2/3). lib/lane now also selects the engaged (most-advanced) wave, not the biggest cluster.
    -- Piece 2 (TINKER_LANE_STAND_DESIGN.md): the KINEMATIC meeting is the anchor. PredictMeeting from
    -- the current fronts + LIVE speeds (real, or MIRRORED when fogged - Piece 1.5) gives WHERE the
    -- fronts collide (.point -> crash_pos) and WHEN (now + .eta -> arrival). Measured: kpred within
    -- ~1s over 2 runs; the old current-fronts-midpoint anchor drifted 1430u median per approach.
    local awv = s.ally_wave
    local pm
    do
        local espd, aspd = wave_speed(ew), wave_speed(awv)
        if ew and ew.front and awv and awv.front and espd and aspd then
            pm = Lane.PredictMeeting({ pos = ew.front, speed = espd }, { pos = awv.front, speed = aspd })
        end
    end
    local crash_pos = (pm and pm.point) or s.meeting
    if not crash_pos then return nil end
    -- CRASH CLAMP (user model): the meeting is BOUNDED by the enemy T1. If the estimate lands at/behind
    -- the (alive) enemy mid T1, our wave crashes the TOWER - aim AT the tower (Tinker stands WAVE_STANDBACK
    -- in front of it), never PAST it. This crashes the tower (the goal) AND stops the deep dives (note 2:
    -- walking under/past the tower). T1 dead -> no clamp; the depth/time gate (rule 2) decides the dive.
    local deep_era = false
    do
        local t1, t1alive = enemy_lane_t1(K.HOME_LANE)
        if t1alive and t1 and stand_depth(crash_pos) > stand_depth(t1) then
            crash_pos = { x = t1.x, y = t1.y }
        end
        deep_era = not t1alive          -- v0.1.196: the DEEP-FARM era = their mid T1 DOWN. While it stands the lane phase owns everything (crash clamp, thin 400) - 100% untouched, per the user.
    end
    local eff_hp = (ew and ew.hp) or 0
    local present = visible

    -- arrival, CLOCK-INDEPENDENT (now + relative ETA so now cancels in slack): a VISIBLE wave is
    -- here (~now) -> shove it. Fogged -> Schedule.NextWaveArrival predicts the next wave on the
    -- period grid: the MEASURED phase when lastWaveT is fresh, else the spawn-clock WAVE_PHASE - so
    -- anticipation stays reliable even after a missed wave (smart-laning: stop losing imminent waves).
    -- Piece 2 arrival: kpred primary (also fixes the visible-but-FAR wave, which used to read
    -- arrival=now() -> lying slack); grid at the MEASURED phase 14 only when fronts/speeds missing.
    local arrival, asrc
    if pm and visible then
        arrival, asrc = now() + pm.eta, "kin"
    elseif visible then
        arrival, asrc = now(), "vis"          -- visible but front/speed incomplete: it is here
    elseif State.laneWaveT.mid then
        -- fogged + stamped rhythm: the measured cadence beats the MIRROR kinematics (run-8,
        -- TINKER_ANCHOR_REACH_STUDY.md root cause B: mirror-kin ran 8-12s early on every fogged
        -- decide; the stamped grid err ~0 once lastWaveT existed).
        arrival, asrc = Schedule.NextWaveArrival(now(), K.WAVE_PERIOD, K.WAVE_PHASE, State.laneWaveT.mid), "stamp"
    elseif pm then
        arrival, asrc = now() + pm.eta, "kinest"   -- mirror kinematics, unstamped: scheduling only (the tether refuses to walk out on it)
    else
        arrival, asrc = Schedule.NextWaveArrival(now(), K.WAVE_PERIOD, K.WAVE_PHASE, State.laneWaveT.mid), "grid"
    end

    -- item 7 REWORKED (user, v0.1.154): the push sim is a TIMING input, not a veto. bal +
    -- first_t (round-1 fight duration) predict WHEN the current creep fight resolves = when
    -- the lane MOVES. Losing fight (bal < 0): the farmable moment is the fight END - the
    -- enemy remnant emerges at the meeting - so arrival pushes out to it; the scheduler
    -- jungles the exact slack and the frozen waveEta makes the timed W fire on the remnant
    -- the moment it resolves (farm the lane perfectly, no idle watching creeps whittle).
    -- Winning / no data: farm at the meeting as before (the wave dies to creeps + W during
    -- the fight = fastest clear). REAL waves only (the mirrored fogged estimate reads
    -- bal=-4 every between-waves lull - the v0.1.152-run misfire).
    local bal, gone_fight_rel
    if awv and ew and not ew.estimated then
        local pf = Lane.PushForecast(awv, ew, { cycle = math.min(30, math.floor(now() / 450)),
                                                game_time = now(), rounds = 1 })
        bal = pf and pf.bal
        if bal and bal < 0 and pf.first_t then
            local fight_end = now() + math.max(0, (pm and pm.eta) or 0) + pf.first_t
            if fight_end > arrival then arrival, asrc = fight_end, "sim" end
        end
        -- gone-by-arrival capture (v0.1.191): OUR wave clearly wins -> their wave dies at
        -- ~meeting + fight time; the COMPARISON against travel happens below, AFTER the raid
        -- cap (a creep-keen arriving in ~4s beats the fight ending = the wave is NOT gone).
        if bal and bal >= K.GONE_BAL_MIN and pf.first_t and pm then
            gone_fight_rel = pm.eta + pf.first_t
        end
    end

    -- F2 (forward-meeting / next-wave defer) REVERTED at v0.1.83: every variant
    -- (v0.1.78 strength ratio, v0.1.80 crashing-only, v0.1.81 pushing-forward,
    -- v0.1.82 regen wait) regressed lane handling (skipped / then missed all lanes:
    -- deferring the shove to a future wave lowers presence + self-feeds via stale
    -- lastWaveT). Back to the validated v0.1.76 behavior: always target the CURRENT
    -- wave (shove when due, jungle the slack). Revisit smart-lane-farming from here.

    local me = origin(State.hero)
    local ms = (NPC.GetMoveSpeed and NPC.GetMoveSpeed(State.hero)) or 320
    local itc = Lane.InterceptETA({ x = me.x, y = me.y }, static_anchors(), ms,
                                  { channel = K.KEEN_CHANNEL }, crash_pos, nil)   -- v0.1.231: the SCHEDULER's transit is keen-calibrated ON PURPOSE (leave_by/near_due were validated on keen-class transit runs 44-50; ladder-aware pricing here made near_due dispatch ~12s early and WALK from the fountain onto fogged predictions - run-51's two sightings). Economy sites (route legs/returns/window fits) keep keen_tp().
    local travel_to_mid = (itc and itc.eta) or (me:Distance(Vector(crash_pos.x, crash_pos.y, me.z)) / math.max(150, ms))
    -- Risk v2 axis 2 rider: the anchor-based ETA reads ~20s for a deep meeting the L2 creep-keen
    -- crosses in ~4s. Cap the fed travel when raid-capable so leave_by AND the far_wave rule price
    -- the REAL transit (deep waves re-qualify at L2 by the math, per the doctrine). v0.1.191: the
    -- cap also requires OUR WAVE to be ALIVE (awv creeps > 0) - the raid keens onto OUR creeps;
    -- pricing the creep transit with no creep on the lane committed walks the raid could not save
    -- (the user's structural point: our prior wave dies at their tower before the next exists).
    -- v0.1.192: raid-capable ONCE per decide (keen L2 + ready + OUR wave alive to ride) - drives
    -- the travel cap here AND the stairs-cap exemption on the stand below.
    -- v0.1.211 (user GPM-FIRST doctrine: "if we know our wave will meet their wave and we can
    -- keen before it meets in a way that GPM don't go down and we are under the safe rules, we
    -- totally should - lanes = fast gold + enemies must come back to their tower"): raid
    -- capability is LADDER-aware, not ready(keen)-only. Keen L2's ~40s cd meant keen was almost
    -- always down at the 0.4s decide, raidcap read false, travel fell back to WALK (15-20s) and
    -- gone_by_arrival wrote off every pre-emptable wave (run-34: zero klvl2 engages). A ready
    -- Rearm resets Keen in ~1.2-1.9s, so the true raid transit = (rearm channel if keen down) +
    -- keen channel + landing. The GPM guard is the DEEP_THIN_EFFHP bar (bad remnants = nono);
    -- the safety rules are unchanged (raid_safe / lane_unsafe / landing gates).
    local raidcap = ((State.keen and Ability.GetLevel and Ability.GetLevel(State.keen)) or 0) >= 2
                    and (ready(State.keen) or ready(State.rearm)) and awv and (awv.count or 0) > 0
    if raidcap then
        local transit = (ready(State.keen) and 0 or rearm_channel()) + K.KEEN_CHANNEL + 1.5
        travel_to_mid = math.min(travel_to_mid, transit)
    end
    -- (gone-by-arrival moved BELOW the stand block at v0.1.193: it needs the FINAL covers value.)

    -- stand: ONE composition for both toggle branches (glue rebuild item 2). ON = adaptive
    -- forward/back (lane anticipation: forward when the lane is clear so March W's the wave early,
    -- back on a contested lane); OFF = the baseline 900-back through the SAME path, now also
    -- tower-clamped at DECIDE time (deliberate delta: lane_go clamped it at movement time anyway,
    -- so decide and execution finally agree; every removed "lane_go clamp" line = a bad stand
    -- fixed at the source).
    local stand, covers, cwhy
    do
        -- T0 COLLAPSED (v0.1.177): the "Lane anticipation (A/B)" toggle is gone - ON was the only
        -- tested path through the whole v0.1.152-176 arc. Forward on a clear lane, back contested.
        local fwd = not lane_unsafe({ x = crash_pos.x, y = crash_pos.y })   -- 0 enemies in gank radius -> forward; contested -> back
        local _safe
        stand, covers, _safe, cwhy = safe_stand_for(crash_pos, fwd, raidcap, K.HOME_LANE)
        if not stand then stand = snap_walkable({ x = crash_pos.x, y = crash_pos.y }, crash_pos) end
    end
    -- Risk v2 axis 1 (task #11, user POINT SYSTEM): graded depth points for the STAND, consumed
    -- HERE at decide time only - a busted budget reads covers=false -> Plan no_safe_stand ->
    -- jungle. Movement/tether/landings never check points (hard positional vetoes froze/idled).
    local dpts = 0
    do
        local info = stand and enemy_t1_points_info(stand)
        if info then
            local kl = (State.keen and Ability.GetLevel and Ability.GetLevel(State.keen)) or 0
            dpts = Farm.DepthPoints(info.depth_past, {
                line_alive = info.line_alive, side_t1_up = info.others_up,
                shave = (kl >= 2 and ready(State.keen)) and K.DEPTH_KEEN_SHAVE or 0,
            })
            if dpts > K.DEPTH_POINT_BUDGET then covers = false; cwhy = "dpts" end
        end
    end

    -- gone-by-arrival BIDIRECTIONAL (v0.1.193, user: "the fight sim should calculate on either
    -- direction"). bal < 0 pushed arrival to fight-end above (asrc=sim, their remnant emerges);
    -- the WINNING direction was incomplete: bal >= GONE_BAL_MIN means their wave DIES at the
    -- meeting and never reaches a stand, so it is farmable ONLY by legally covering the fight
    -- itself before it resolves. The old travel-only test (fight_rel < travel) could not fire
    -- once the hero already stood near the line (run-23 t=207: travel 3.4s vs fight ~10s ->
    -- "not gone" -> commit -> 25s stand-and-wait for a wave that never came). Now: gone unless
    -- a legal covering stand exists AND we get there before the fight ends.
    local gone = (gone_fight_rel and not (covers and travel_to_mid < gone_fight_rel)) and true or false

    -- v0.1.76: the shove gate = enemy HEROES (fog-aware) + enemy-TOWER range ONLY.
    -- StructuralRisk (depth) was REMOVED here: a winning mid shove stands forward at the
    -- same depth as an under-tower dive, so depth vetoed EVERY legit shove (v0.1.75
    -- fountain-stuck). enemy_tower_risk catches the genuine under-tower / deep-dive case
    -- (incl. the v0.1.73 death stand at 791u -> 0.38); enemy_risk_at catches ganks.
    local srisk = enemy_risk_at(Vector(stand.x, stand.y, 0)) + enemy_tower_risk(stand)
    if srisk > 1 then srisk = 1 end
    -- glue rebuild item 6 (Farm.PathRisk): a stand can read safe while the only route to it walks a
    -- gank corridor; sample the straight hero->stand route and treat a hot corridor as unsafe too.
    local prisk = Farm.PathRisk({ x = me.x, y = me.y }, stand,
        function(pt) return enemy_risk_at(Vector(pt.x, pt.y, 0)) end)
    local shove_safe = (not lane_unsafe(stand)) and prisk < K.PATH_RISK_MAX   -- v0.1.94 count+HP aware point check + the corridor
    local emd = effective_march_dmg()                       -- N5: live LEVEL-AWARE per-March damage (not the flat MARCH_DMG_PER_CAST)
    local cal = { march_dmg_per_cast = (emd > 0 and emd) or K.MARCH_DMG_PER_CAST, cast_dur = K.MARCH_CAST_DUR,
                  robot_kill = K.ROBOT_KILL, rearm_channel = rearm_channel(), lead = K.SCHED_LEAD }
    -- shove mana gate = one hop (Keen + 1 March). DELIBERATELY low: gating on the full ceil'd clear
    -- (Keen + N Marches) would make Tinker REFILL instead of shoving a big wave at moderate mana ->
    -- the wave goes unshoved (stolen) + an extra fountain trip, both worse than half-clearing it (a
    -- farm bot still banks 3 of 4 last-hits). The ceil'd cast count kills the trailing ranged WHEN
    -- mana allows (engage_bail=0 historically = there is usually headroom); if not, the in-engage mana
    -- bail degrades to the prior half-clear, no worse. So: better clear, no steal/refill regression.
    -- v2 rich ctx (TINKER_LANE_GLUE_DESIGN.md item 1): the whole veto cascade + lane-first filler
    -- live in Schedule.Plan now; the glue only feeds facts. Deliberate deltas (lib-test-pinned):
    -- defend_crash never overrides unsafe, the mana gate is regen-aware (mana AT leave_by), and
    -- mana is EFFECTIVE (raw + Bottle charges) so charges count before a fountain trek.
    local hh = State.hero
    local hpf  = (Entity.GetHealth(hh) or 1) / math.max(1, Entity.GetMaxHealth(hh) or 1)
    local mmax = (NPC.GetMaxMana and NPC.GetMaxMana(hh)) or 0
    local mpf  = (mmax > 0) and (mana() / mmax) or 1
    local covers_ctx = (covers == true)                     -- T0 collapsed: the no_safe_stand rule is always live
    return {
        plan = { now = now(),
                 wave = { arrival = arrival, eff_hp = eff_hp, present = present, visible = visible },
                 cal = cal, travel_to_mid = travel_to_mid,
                 mana = effective_mana(), shove_cost = hop_mana_cost() + K.SHOVE_MANA_RESERVE,
                 safe = shove_safe,
                 mana_regen = mana_regen_read(),
                 recover_s = refill_wait() + K.KEEN_CHANNEL + travel_to_mid,   -- refill_wait includes the base rearm (v0.1.162)
                 far_travel_s = K.SHOVE_FAR_TRAVEL, min_wave_ehp = K.SHOVE_MIN_EFFHP,
                 camp_alt_s = K.WAVE_CAMP_ALT_S,     -- Risk v2 axis 2: RT walk vs ~2 camp clears (raid-aware travel above)
                 gone = gone,                        -- v0.1.191: their wave dies to ours before we can arrive -> jungle
                 -- v0.1.195/196 (user, ~3rd ask): the DEEP-FARM era works like the lane phase -
                 -- predict the meetings, take FULL waves (safe creep-keen in-and-out at L2),
                 -- jungle the rest. STRICTLY the T1-DEAD era (v0.1.196 review: the lane phase
                 -- is perfect and stays 100% untouched - the depth-only gate would have caught
                 -- the T1-alive crash clamp, whose crash_pos sits AT the alive T1 ~876 deep):
                 -- their mid T1 down AND the meeting past the stairs line raises the visible
                 -- thin bar to DEEP_THIN_EFFHP - a 1-2-creep remnant is never worth the trip,
                 -- while the fogged ExpectedWave estimate (a FULL predicted wave) passes and
                 -- gets the timed raid. thin_wave -> jungle; the stamped grid owns the timing.
                 thin_ehp = (deep_era and stand_depth(crash_pos) > K.WALK_DEPTH_MAX)
                            and K.DEEP_THIN_EFFHP or K.SHOVE_THIN_EFFHP,
                 covers = covers_ctx,
                 -- (bal/bal_min deliberately NOT fed: the losing_fight veto was the wrong shape for
                 -- the push sim - it is a TIMING input, folded into `arrival` above. Plan's rule
                 -- stays lib-side, inactive, for a consumer that wants a genuine go/no-go.)
                 -- v0.1.180 (run-16: 4 false "defenses" walked 20s to THEIR T2, reason=defend_crash
                 -- bypassing far_wave/points): a defense happens at OUR tower - the crash projection
                 -- (sim horizon) can flag our tower while the CURRENT meeting/stand still reads deep
                 -- enemy-side. Qualify on the stand being our-side (dpts == 0); when the wave really
                 -- approaches, the meeting recomputes near our tower and the defense fires there.
                 defend_crash = (cl.crashing and cl.crash_tower and cl.crash_tower.team == State.team
                                 and dpts == 0) and true or false,
                 suppressed = shove_suppressed(K.HOME_LANE),
                 filler = { min_camp_slack = K.MIN_CAMP_SLACK, min_fountain_slack = K.MIN_FOUNTAIN_SLACK,
                            need_recharge = hpf < K.REFILL_FRAC or mpf < K.REFILL_FRAC } },
        crash_pos = crash_pos, stand = stand, aim = crash_pos, visible = visible, risk = srisk,
        deep_era = deep_era,                                -- INCREMENT 2 (v0.1.229): their mid T1 down = the deep-era priority-flattening trigger
        dpts = dpts,                                        -- Risk v2 axis 1: the stand's depth points (ft.dpts calibration)
        path_risk = prisk,                                  -- item 6: worst enemy risk along hero->stand (calibrate PATH_RISK_MAX)
        bal = bal,                                          -- item 7: push-sim balance (trace only; timing folded into arrival/asrc=sim)
        covers = covers,                                    -- ON (anticipation): safe_stand_for found a covering stand; nil when OFF
        cwhy = cwhy,                                        -- v0.1.203: WHY covers failed (tower|cover|depth|leash|dpts) - the leash-era analyzability rule
        wave_eta = arrival, asrc = asrc,                    -- Piece 2: the kinematic deadline + its source (kin|vis|grid)
        -- v0.1.213 TIMED MEETING RAID: when THEIR wave reaches the meeting (fight start) = the
        -- pre-empt target. v0.1.216 (run-39 t=890: a bal=-4 commit stepped out at meet=0.1 while
        -- the scheduler had pushed arrival to the fight END (+12s, asrc=sim) -> landed mid-fight,
        -- 1 W of scraps = the user's "went to farm nothing on mid"): the pre-empt applies only
        -- when OUR side would eat their wave (bal >= 0); a LOSING fight's farmable moment is the
        -- fight end (their remnant emerges) - the arrival the scheduler already set.
        meet_eta = (pm and (bal or 0) >= 0) and (now() + math.max(0, pm.eta)) or nil,
        clash = cl,                                         -- v0.1.105: settle = the wave MEETING point for the tower-aware veto
    }
end

-- ALL-LANES Tier-1.5 (TINKER_ALLLANES_DESIGN.md): slim per-lane ctx for the SAME pure
-- Schedule.Plan. Phase-1 rules: a side wave must be VISIBLE or mirror-kinematic (no
-- fogged anticipation - no stamp/grid arrivals, no blind side keens); stands own-side/
-- equilibrium (crash clamp at the lane's T1 + the depth budget); distance-ruled pre-L2
-- (camp_alt_s vs per-lane raid-aware travel). Returns (ctx_bundle, nil) or (nil, verdict)
-- where verdict names the snub for the swave trace.
local function side_wave_ctx(lane, s)
    if not s then return nil, "off" end
    if shove_suppressed(lane) then return nil, "suppressed" end
    local ew, awv = s.enemy_wave, s.ally_wave
    local visible = (ew and not ew.estimated and ew.centroid) and true or false
    local pm
    do
        local espd, aspd = wave_speed(ew), wave_speed(awv)
        if ew and ew.front and awv and awv.front and espd and aspd then
            pm = Lane.PredictMeeting({ pos = ew.front, speed = espd }, { pos = awv.front, speed = aspd })
        end
    end
    -- PHASE 2: a FRESH lane cadence stamp makes a fogged side lane dispatchable like mid
    -- (asrc=stamp; run-8: the stamped grid beats mirror kinematics). Stale stamp = named snub.
    local stampT = State.laneWaveT[lane]
    local stamp_fresh = (stampT and (now() - stampT) <= K.SIDE_STAMP_MAX_S) and true or false
    if not (visible or pm or stamp_fresh) then
        return nil, (stampT and "stale" or "fogged")
    end
    local crash_pos = (pm and pm.point) or s.meeting
    if not crash_pos then return nil, "fogged" end
    do  -- crash clamp at THIS lane's alive enemy T1 (same rule as mid)
        local t1, t1alive = enemy_lane_t1(lane)
        if t1alive and t1 and stand_depth(crash_pos) > stand_depth(t1) then
            crash_pos = { x = t1.x, y = t1.y }
        end
    end
    local eff_hp = (ew and ew.hp) or 0
    -- PHASE 2: thin fires on REAL reads only (Schedule.Plan's own thin rule is already
    -- visible-gated). A mirror estimate copies OUR paired lane's composition - a remnant
    -- there must not veto a possibly-healthy fogged wave here; estimates never veto.
    if visible and eff_hp < K.SHOVE_THIN_EFFHP then return nil, "thin" end
    local arrival, asrc
    if pm and visible then arrival, asrc = now() + pm.eta, "kin"
    elseif visible then arrival, asrc = now(), "vis"
    elseif stamp_fresh then                                  -- PHASE 2: measured cadence beats the unstamped mirror (mid ladder parity, run-8)
        arrival, asrc = Schedule.NextWaveArrival(now(), K.WAVE_PERIOD, K.WAVE_PHASE, stampT), "stamp"
    else arrival, asrc = now() + pm.eta, "kinest" end        -- unstamped mirror kinematics (commit allowed, phase-1 semantics; source is live by construction)
    local bal, gone_fight_rel
    if awv and ew and not ew.estimated then                  -- REAL waves only (the mirrored-estimate bal misfire, v0.1.153)
        local pf = Lane.PushForecast(awv, ew, { cycle = math.min(30, math.floor(now() / 450)),
                                                game_time = now(), rounds = 1 })
        bal = pf and pf.bal
        if bal and bal < 0 and pf.first_t then
            local fight_end = now() + math.max(0, (pm and pm.eta) or 0) + pf.first_t
            if fight_end > arrival then arrival, asrc = fight_end, "sim" end
        end
        if bal and bal >= K.GONE_BAL_MIN and pf.first_t and pm then
            gone_fight_rel = pm.eta + pf.first_t
        end
    end
    -- travel: keen-aware ETA; the v0.1.211 ladder-aware raid cap requires OUR wave alive ON THIS LANE
    local me = origin(State.hero)
    local ms = (NPC.GetMoveSpeed and NPC.GetMoveSpeed(State.hero)) or 320
    local itc = Lane.InterceptETA({ x = me.x, y = me.y }, static_anchors(), ms,
                                  { channel = K.KEEN_CHANNEL }, crash_pos, nil)   -- v0.1.231: the SCHEDULER's transit is keen-calibrated ON PURPOSE (leave_by/near_due were validated on keen-class transit runs 44-50; ladder-aware pricing here made near_due dispatch ~12s early and WALK from the fountain onto fogged predictions - run-51's two sightings). Economy sites (route legs/returns/window fits) keep keen_tp().
    local travel = (itc and itc.eta) or (me:Distance(Vector(crash_pos.x, crash_pos.y, me.z)) / math.max(150, ms))
    local raidcap = ((State.keen and Ability.GetLevel and Ability.GetLevel(State.keen)) or 0) >= 2
                    and (ready(State.keen) or ready(State.rearm)) and awv and (awv.count or 0) > 0
    if raidcap then
        local transit = (ready(State.keen) and 0 or rearm_channel()) + K.KEEN_CHANNEL + 1.5
        travel = math.min(travel, transit)
    end
    -- stand: the SAME safe composition, leash keyed to this lane; per-lane depth points
    local fwd = not lane_unsafe({ x = crash_pos.x, y = crash_pos.y })
    local stand, covers, _safe, cwhy = safe_stand_for(crash_pos, fwd, raidcap, lane)
    if not stand then return nil, "no_stand" end
    local dpts = 0
    do
        local info = enemy_t1_points_info(stand)   -- nearest enemy T1 = this lane's, by construction
        if info then
            local kl = (State.keen and Ability.GetLevel and Ability.GetLevel(State.keen)) or 0
            dpts = Farm.DepthPoints(info.depth_past, {
                line_alive = info.line_alive, side_t1_up = info.others_up,
                shave = (kl >= 2 and ready(State.keen)) and K.DEPTH_KEEN_SHAVE or 0,
            })
            if dpts > K.DEPTH_POINT_BUDGET then covers = false; cwhy = "dpts" end
        end
    end
    local gone = (gone_fight_rel and not (covers and travel < gone_fight_rel)) and true or false
    local srisk = enemy_risk_at(Vector(stand.x, stand.y, 0)) + enemy_tower_risk(stand)
    if srisk > 1 then srisk = 1 end
    local prisk = Farm.PathRisk({ x = me.x, y = me.y }, stand,
        function(pt) return enemy_risk_at(Vector(pt.x, pt.y, 0)) end)
    local shove_safe = (not lane_unsafe(stand)) and prisk < K.PATH_RISK_MAX
    local emd = effective_march_dmg()
    local cal = { march_dmg_per_cast = (emd > 0 and emd) or K.MARCH_DMG_PER_CAST, cast_dur = K.MARCH_CAST_DUR,
                  robot_kill = K.ROBOT_KILL, rearm_channel = rearm_channel(), lead = K.SCHED_LEAD }
    return {
        plan = { now = now(),
                 wave = { arrival = arrival, eff_hp = eff_hp, present = visible, visible = visible },
                 cal = cal, travel_to_mid = travel,
                 mana = effective_mana(), shove_cost = hop_mana_cost() + K.SHOVE_MANA_RESERVE,
                 safe = shove_safe,
                 mana_regen = mana_regen_read(),
                 far_travel_s = K.SHOVE_FAR_TRAVEL, min_wave_ehp = K.SHOVE_MIN_EFFHP,
                 camp_alt_s = K.WAVE_CAMP_ALT_S,   -- THE pre-L2 distance rule: RT walk vs ~2 camps; the raid cap collapses it at L2
                 gone = gone,
                 thin_ehp = K.SHOVE_THIN_EFFHP,    -- phase 1: no deep-era side farming, plain bar
                 covers = (covers == true),
                 -- v0.1.240 (run-55, user: "big waves crashing into our tower on top, 242-300
                 -- gold... easy and safe... happened several times" - 18 episodes counted, up
                 -- to 410g, missed on slack/no_fit verdicts): SIDE defends are live now, same
                 -- qualification as mid (our tower + our-side stand = dpts 0). Plan's defend
                 -- rule outranks slack/far/gone but never unsafe/covers=false, unchanged.
                 defend_crash = (s.clash and s.clash.crashing and s.clash.crash_tower
                                 and s.clash.crash_tower.team == State.team and dpts == 0) and true or false,
                 -- deliberately NOT fed (nil = rule inactive): filler (mid's lane-first
                 -- filler must not convert a SIDE near_due / force fountain trips),
                 -- suppressed (checked above, per-lane), recover_s (a side lane never owns
                 -- the recover decision).
               },
        crash_pos = crash_pos, stand = stand, aim = crash_pos, visible = visible,
        risk = srisk, dpts = dpts, wave_eta = arrival, asrc = asrc,
        meet_eta = (pm and (bal or 0) >= 0) and (now() + math.max(0, pm.eta)) or nil,
        travel = travel, gold = (ew and ew.gold) or 0, cwhy = cwhy,
        defend = (s.clash and s.clash.crashing and s.clash.crash_tower
                  and s.clash.crash_tower.team == State.team and dpts == 0) and true or false,
    }
end

-- ONE shove-spot producer for all lanes (ALL-LANES v0.1.226; the v0.1.207 twin-producer
-- lesson: a fix must sweep all producers - prevented by having exactly one).
-- sc must carry { aim, stand, wave_eta, meet_eta, asrc }; ref = the lane's scan state.
local function dispatch_shove(lane, sc, casts, ref)
    local z = origin(State.hero).z
    State.spot = {
        kind = "wave", shove = true, lane = lane, ref = ref,
        center = Vector(sc.aim.x, sc.aim.y, z), refPoint = Vector(sc.aim.x, sc.aim.y, z),
        standSpot = { stand = Vector(sc.stand.x, sc.stand.y, z),
                      aim = Vector(sc.aim.x, sc.aim.y, z), paired = false },
        shoveCasts = casts,                           -- casts-bounded engage (replaces SHOVE_MARCH_CAP)
        waveEta = sc.wave_eta,                        -- Piece 2: the kinematic deadline (frozen with the stand)
        meetEta = sc.meet_eta,                        -- v0.1.213: the meeting/fight-start time (pre-empt raids fire for THIS, not stand-closing)
        waveAsrc = sc.asrc,                           -- v0.1.218: the arrival's source - asrc=sim means waveEta IS the fight end (the bal<0 farmable moment)
    }
    State.marchCasts, State.fsm = 0, "MOVE"
    State.moveSince = now(); State.moveTrack = nil
    State.keenedSpot = false; State.marchPending = nil; State.emptySince = nil
end

-- ALL-LANES side-lane evaluation (extracted v0.1.229 - ONE producer for the Tier-1.5
-- slack window AND the deep-era compete): evaluates top/bot through side_wave_ctx ->
-- contest -> Schedule.Plan -> the `window` fit, writes the swave verdicts into ft, and
-- returns (best {lane, risk, gold, casts}, bestCtx) or nil. Selection = lowest composed
-- stand risk, gold tiebreak (the validated v0.1.227 rule).
local function eval_side_lanes(lanes, allies, window, ft)
    local tally = ally_lane_tally(allies)       -- core-or-2+ yield (reused; dormant since the mid contest)
    local best, bestCtx = nil, nil
    local sw = { top = { v = "off", r = -1 }, bot = { v = "off", r = -1 } }
    for _, ln in ipairs({ "top", "bot" }) do
        local verdict
        local sctx, why = side_wave_ctx(ln, lanes[ln])
        if not sctx then verdict = why
        elseif tally[ln] and (tally[ln].c >= 1 or tally[ln].n >= 2) then verdict = "contested"
        else
            local sd = Schedule.Plan(sctx.plan)
            if sd.action ~= "shove" then
                verdict = (sd.reason == "far_wave" and "far")
                       or (sd.reason == "gone_by_arrival" and "gone")
                       or (sd.reason == "thin_wave" and "thin")
                       or (sd.reason == "no_safe_stand" and "no_stand")
                       or sd.reason               -- unsafe/mana/deep_skip pass through named
            else
                -- the window bound: round trip (travel + clear + return) must fit
                local ret = Lane.InterceptETA(sctx.stand, static_anchors(),
                    (NPC.GetMoveSpeed and NPC.GetMoveSpeed(State.hero)) or 320,
                    keen_tp(),   -- v0.1.230: ladder-aware pricing
                    State.shoveReturnPos or sctx.stand, nil)
                local trip = sctx.travel + (sd.t_clear or 0) + ((ret and ret.eta) or 0)
                -- v0.1.240: a DEFEND (their wave crashing OUR tower) bypasses the window fit -
                -- the tower does half the clear, the stand is the safest on the map, and the
                -- run-55 no_fit verdicts left 250g+ crashes unfarmed. Mid's leave_by preempt
                -- still yanks the engage if mid is genuinely due.
                if trip > window and sd.reason ~= "defend_crash" then verdict = "no_fit"
                elseif best and best.risk <= sctx.risk
                       and not (best.risk == sctx.risk and sctx.gold > best.gold) then
                    verdict = "risk_lost"       -- both eligible: lowest risk wins, gold tiebreak
                else
                    if best then sw[best.lane].v = "risk_lost" end   -- displaced winner named too
                    best, bestCtx, verdict = { lane = ln, risk = sctx.risk, gold = sctx.gold,
                                               casts = sd.casts }, sctx,
                                             (sd.reason == "defend_crash") and "defend" or "ok"
                end
            end
        end
        sw[ln] = { v = verdict, r = (sctx and sctx.risk) or -1 }
    end
    ft.swtop = string.format("%s:%.2f", sw.top.v, sw.top.r)   -- written AFTER the loop: a
    ft.swbot = string.format("%s:%.2f", sw.bot.v, sw.bot.r)   -- displaced winner reads risk_lost
    return best, bestCtx
end

local function fsm_decide()
    if now() < State.nextDecide then return end
    State.nextDecide = now() + K.DECIDE_GAP
    State.fog = enemy_snapshot()             -- snapshot enemies ONCE per decide (enemy_risk_at reads it)
    State.refillNeed = nil                   -- cost-aware refill: valid only for the trip its dispatch starts (re-set below when the pick is refill; a stale need must never inflate an unrelated RETURN)

    -- v0.1.91 instrument: ONE consolidated `farm` trace per decide. Supersedes the piecemeal
    -- sched/jungle/funnel/decide-pick string logs - this single event ALONE explains each choice and
    -- feeds the offline per-wave accounting (tools/parse_debuglog.lua --farm-report). Logging-only.
    local ft = { t = string.format("%.1f", now()) }
    -- (ft.fb A/B tag retired with the T0 collapse - one engine now)
    local function emit_farm(pick) ft.pick = pick; tlog(1, "farm", ft) end
    local stuckWindow = false   -- v0.1.158: a suppressed shove falls through to the planner with a capped horizon

    -- Tier-1 timing scheduler: decide shove / jungle(slack) / recover before the jungle planner.
    -- (allies/our_pri hoisted above the Tier-1 block at v0.1.227: the Tier-1.5 side-lane
    -- cascade needs ally_lane_tally; the jungle planner below reuses them unchanged.)
    local allies  = ally_farm_priorities()
    local our_pri = our_farm_priority()
    State.schedSlack, State.shoveLeaveBy, State.shoveTravel = nil, nil, nil
    if State.menu.kindLane:Get() then   -- lane/shove farming; toggle OFF = jungle-only (skip the whole shove decision, schedSlack stays nil -> jungle runs full-horizon)
        local me0 = origin(State.hero)
        local enemy_push, ally_push = lane_push_dirs()       -- correct front detection per team (Radiant/Dire)
        local lanes = Lane.ScanLanes({
            team = State.team, enemy_push = enemy_push, ally_push = ally_push,
            anchors = static_anchors(), allowed_kinds = keen_allowed_kinds(),
            hero_pos = { x = me0.x, y = me0.y },
            move_speed = (NPC.GetMoveSpeed and NPC.GetMoveSpeed(State.hero)) or 320,
            tp = keen_tp(), game_time = now(),   -- v0.1.230: ladder-aware pricing
            paths = lane_paths(),   -- Piece 1.5: mirrored fogged waves (position/speed) for the meeting/decide reads
        })
        local sc = schedule_ctx(lanes)
        local d = sc and Schedule.Plan(sc.plan) or nil
        -- (the old near_due flip - jungle when slack<travel_to_mid -> shove - is folded into the
        -- v0.1.108 lane-first filler gate below, which also handles the medium-window fountain trip.)
        if d and d.action == "shove" and shove_suppressed(K.HOME_LANE) then
            d.action, d.reason = "recover", "shove_stuck"   -- Note 1: the crash stand just proved unreachable; recover briefly instead of re-keening it
        end
        -- capture the scheduler decision + HOME-lane wave state into the consolidated trace.
        do
            local s = lanes[K.HOME_LANE]
            local ew, aw, cl = s and s.enemy_wave, s and s.ally_wave, s and s.clash
            local push = "none"
            if cl then
                push = cl.pushing .. (cl.moving and "" or "/hold")
                if cl.crashing and cl.crash_tower then
                    push = push .. (cl.crash_tower.team == State.team and ">allyTwr" or ">enemyTwr")
                end
            end
            ft.e, ft.a = ew and ew.count or 0, aw and aw.count or 0
            ft.push, ft.enH, ft.alH = push, s and s.enemy_heroes or 0, s and s.ally_heroes or 0
            ft.mana = string.format("%.0f", mana())
            ft.gpm  = string.format("%.0f", gpm())          -- A/B metric (both paths log it)
            ft.klvl = (State.keen and Ability.GetLevel and Ability.GetLevel(State.keen)) or 0   -- v0.1.173: raid-gate diagnosis (run-11 fired ONE raid keen all game - was Keen even L2?)
            if d then
                ft.act, ft.reason = d.action, d.reason
                ft.slack   = string.format("%.1f", d.slack)
                ft.leaveby = string.format("%.0f", d.leave_by)
                ft.dl      = string.format("%.0f", d.deadline)
                ft.casts   = d.casts
                ft.eff_hp  = string.format("%.0f", sc.plan.wave.eff_hp)
                ft.dmg     = string.format("%.0f", (sc.plan.cal and sc.plan.cal.march_dmg_per_cast) or 0)
                ft.travel  = string.format("%.1f", sc.plan.travel_to_mid)
                ft.vis     = sc.visible and "y" or "n"
                ft.asrc    = sc.asrc or "-"                 -- Piece 2: arrival source (kin|vis|grid)
                ft.risk    = string.format("%.2f", sc.risk)
                ft.dpts    = string.format("%.0f", sc.dpts or 0)   -- Risk v2 axis 1: depth points (calibrate DEPTH_POINT_BUDGET/KEEN_SHAVE)
                ft.cwhy    = sc.cwhy                               -- v0.1.203: covers-fail cause (leash-era analyzability)
                ft.recfits = d.recover_fits and "y" or "n"  -- Plan v2 recover fit (calibration only)
                ft.prisk   = string.format("%.2f", sc.path_risk or 0)   -- item 6: corridor risk
                if sc.bal then ft.bal = string.format("%d", sc.bal) end   -- item 7: push-sim balance (asrc=sim when it set the deadline)
            end
        end
        -- The veto cascade (far_dead/deep_skip, thin_wave, no_safe_stand, the lane-first filler,
        -- defend_crash) lives in Schedule.Plan v2 now - ordered lib rules with the hard-won
        -- invariants PINNED BY TESTS (BUG-1: a vetoed jungle never resurrects through the filler;
        -- the defer LAW: the deadline is always the CURRENT wave). schedule_ctx feeds the facts.
        -- History/rationale: TINKER_LANE_GLUE_DESIGN.md item 1 + the pre-rebuild git history.
        if d and d.action == "shove" then
            -- INCREMENT 2 (v0.1.229, user: "not prioritizing mid after their T1 fell - lane
            -- phase is over"): in the DEEP ERA a farmable mid wave no longer auto-wins - it
            -- competes against the side lanes under the same risk-then-gold rule (run-49:
            -- deep-era side waves earned 456-593 g/min vs mid's 307). defend_crash stays
            -- ABSOLUTE (a defense is not a farm choice). Pre-deep: byte-identical dispatch.
            if sc.deep_era and d.reason ~= "defend_crash"
               and State.menu.sideLanes and State.menu.sideLanes:Get() then
                local best, bestCtx = eval_side_lanes(lanes, allies, K.ROUTE_HORIZON_S, ft)
                local mid_gold = (lanes[K.HOME_LANE] and lanes[K.HOME_LANE].enemy_wave
                                  and lanes[K.HOME_LANE].enemy_wave.gold) or 0
                if best and (best.risk < sc.risk
                             or (best.risk == sc.risk and best.gold > mid_gold)) then
                    dispatch_shove(best.lane, bestCtx, math.min(best.casts or 2, 2), lanes[best.lane])
                    ft.lane, ft.dpick = best.lane, string.format("%s:%.2f", best.lane, best.risk)
                    ft.seff, ft.sgold, ft.ssrc = string.format("%.0f", bestCtx.plan.wave.eff_hp or 0), string.format("%.0f", bestCtx.gold or 0), bestCtx.asrc or "?"   -- v0.1.240 seff/sgold; PHASE 2 ssrc=vis|kin|kinest|stamp
                    ft.sx, ft.sy = string.format("%.0f", bestCtx.stand.x), string.format("%.0f", bestCtx.stand.y)
                    ft.ax, ft.ay = string.format("%.0f", bestCtx.aim.x), string.format("%.0f", bestCtx.aim.y)
                    emit_farm("shove")
                    return
                end
                if best or ft.swtop then ft.dpick = string.format("mid:%.2f", sc.risk) end   -- the compete ran, mid won
            end
            dispatch_shove(K.HOME_LANE, sc, d.casts, lanes[K.HOME_LANE])
            ft.lane = K.HOME_LANE                             -- ALL-LANES: every shove pick names its lane (analyzer symmetry)
            ft.sx, ft.sy = string.format("%.0f", sc.stand.x), string.format("%.0f", sc.stand.y)
            ft.ax, ft.ay = string.format("%.0f", sc.aim.x), string.format("%.0f", sc.aim.y)
            emit_farm("shove")
            return
        elseif d and d.action == "recover" and d.reason ~= "unsafe" and d.reason ~= "shove_stuck" then
            State.spot = nil; State.fsm = "RETURN"          -- reason=mana/recharge: genuinely go home
            emit_farm("recover")
            return
        end
        -- jungle, OR an UNSAFE/SUPPRESSED shove: fall through to the jungle planner and farm a
        -- SAFE camp instead of idling home. unsafe = Note 2 (fountain-stuck fix). shove_stuck =
        -- v0.1.158: a 6s stand-suppression used to dispatch RETURN, so every 0.4s decide in the
        -- window keened Tinker HOME (one abort at t=535 kept 217+ mana walking to base; 61 of 139
        -- decides churned recover/shove_stuck + the fountain DECIDE<->RETURN bounce = the slow
        -- teleports / walk-from-fountain / long-wait notes). Neither carries the shove leave-by:
        -- the shove is abandoned; the next decide re-checks and shoves once the window clears.
        if d and d.action == "recover" then
            State.schedSlack, State.shoveLeaveBy, State.shoveTravel, State.shoveReturnPos = nil, nil, nil, nil
            stuckWindow = (d.reason == "shove_stuck")
            -- act=recover reason=unsafe/shove_stuck stays in ft; the eventual pick shows where the fallback landed.
        else
            -- v0.1.210 (run-34 single-camp ROOT CAUSE, the okp= instrument paid off): the slack
            -- cap + return-leg reservation applied to EVERY act=jungle, including VETOED waves
            -- (gone_by_arrival / thin_wave / deep_skip / far_wave / no_safe_stand). A dead wave's
            -- slack squeezed the planner horizon and reserved a return leg FOR A SHOVE THAT DOES
            -- NOT EXIST - pairs (clear + return would not fit) dropped out and the nearest lonely
            -- SINGLE won (run-34: paired=false picks with okp=2-4 affordable pairs, all on
            -- gone_by_arrival decides). Only a GENUINE slack-jungle (reason=slack) carries the
            -- window; vetoed waves get the full ROUTE_HORIZON_S like any pure jungle decide.
            State.schedSlack   = (d and d.reason == "slack") and d.slack or nil
            -- v0.1.127 (Notes 2/4/5 stuck-at-camp churn): carry the shove leave-by ONLY for a GENUINE
            -- slack-jungle (d.reason=="slack") - then the camp engage is correctly preempted to return and
            -- shove the NEXT wave. A VETOED shove (dive_infeasible / too_deep / deep_skip / thin_wave) is
            -- ABANDONED; its leave_by is the CURRENT overdue wave's, already in the PAST, so carrying it
            -- made the camp engage preempt INSTANTLY at casts=0 EVERY decide -> Tinker keened to a (deep)
            -- camp, never farmed it (138x casts=0 this game), re-vetoed, and churned at a deep outpost
            -- (stuck + death). Clearing it lets the vetoed-jungle camp actually farm; next decide (every
            -- DECIDE_GAP) re-evaluates the wave and shoves once it is feasible.
            State.shoveLeaveBy = (d and d.reason == "slack") and d.leave_by or nil
            State.shoveTravel  = d and sc.plan.travel_to_mid or nil   -- to-mid ETA; folds into the horizon (BUG 2)
            State.shoveReturnPos = sc and sc.crash_pos or nil          -- BUG 2: where the camp planner must return to (mid meeting)

            -- ALL-LANES Tier-1.5 (v0.1.227, TINKER_ALLLANES_DESIGN.md; mid > SIDE > jungle):
            -- mid said jungle (slack or vetoed wave) - offer the window to the side lanes
            -- before camps. An eligible side shove must fit ITS window: mid's leave_by on a
            -- genuine slack-jungle, else the same 30s horizon camps get (a side trip must
            -- never eat the NEXT mid wave). Selection is risk-ruled: lowest composed stand
            -- risk wins, gold breaks ties. The recover branch (unsafe/shove_stuck) never
            -- reaches here - live pressure falls back to safe camps, not another lane.
            -- INCREMENT 2 (v0.1.229, deep era): the window is the generic 30s and a side
            -- dispatch drops mid's leave_by - full flattening, no mid preempt; the next
            -- decide re-runs the competition and mid re-wins when genuinely best.
            if State.menu.sideLanes and State.menu.sideLanes:Get() then
                local deep = sc and sc.deep_era or false     -- sc can be nil (no home-lane scan state)
                local window = (not deep and State.shoveLeaveBy and (State.shoveLeaveBy - now()))
                               or K.ROUTE_HORIZON_S
                local best, bestCtx = eval_side_lanes(lanes, allies, window, ft)
                if best then
                    dispatch_shove(best.lane, bestCtx, math.min(best.casts or 2, 2), lanes[best.lane])
                    if deep then State.shoveLeaveBy = nil end   -- full flattening: no mid preempt on a deep-era side win
                    ft.lane = best.lane
                    ft.seff, ft.sgold, ft.ssrc = string.format("%.0f", bestCtx.plan.wave.eff_hp or 0), string.format("%.0f", bestCtx.gold or 0), bestCtx.asrc or "?"   -- v0.1.240: the SIDE wave's own numbers (ft.eff_hp is mid's); PHASE 2 ssrc
                    ft.sx, ft.sy = string.format("%.0f", bestCtx.stand.x), string.format("%.0f", bestCtx.stand.y)
                    ft.ax, ft.ay = string.format("%.0f", bestCtx.aim.x), string.format("%.0f", bestCtx.aim.y)
                    emit_farm("shove")
                    return
                end
            end
        end
    end

    -- unified candidates (camps + visible waves) + the plan (same builder as the Route-scan diag).
    -- (allies/our_pri computed above the Tier-1 block since v0.1.227.)
    local targets = gather_route_targets(allies, our_pri)
    local ropts = route_opts()
    if stuckWindow then
        -- v0.1.158: a suppressed shove only frees the suppression window - cap the horizon so
        -- only what FITS it is picked; never a far keen-to-camp trek. v0.1.208: the window is
        -- the ACTUAL remaining suppression (a tether release suppresses for up to ~25s = a real
        -- camp window), floored at the old SHOVE_STUCK_S for the classic 6s stuck cases.
        local win = math.max(K.SHOVE_STUCK_S, (State.shoveSuppress[K.HOME_LANE] or 0) - now())
        ropts.horizon_s = math.min(ropts.horizon_s, win)
    end
    if State.schedSlack and State.schedSlack > 0 then    -- jungle only in the slack before the next shove
        -- v0.1.125 (BUG 2): the horizon is the time until the wave ARRIVES at mid = schedSlack + the
        -- to-mid travel (leave_by already subtracted travel, so schedSlack alone undercounts the window by
        -- one trip). The per-camp RETURN to mid is reserved INSIDE Route via return_pos (KEEN-aware
        -- InterceptETA over the same static anchors as the outbound ETA), so a far camp whose camp->mid
        -- return won't fit before the wave is dropped - the RIGHT leg (camp->mid), per-camp. Replaces the
        -- old wrong-leg double-subtract (budget = slack - hero->mid travel, which counted the to-mid trip
        -- twice and reserved the hero's distance, not the camp's). The keen-aware return avoids the v0.1.93
        -- pure-walk over-exclusion; the leave_by preempt (fsm_engage) bounds any return under-estimate.
        local horizon = State.schedSlack + (State.shoveTravel or 0)
        ropts.horizon_s = math.min(ropts.horizon_s, math.max(0, horizon))
        if State.shoveReturnPos then
            ropts.return_pos     = State.shoveReturnPos
            ropts.return_anchors = static_anchors()
            ropts.return_speed   = (NPC.GetMoveSpeed and NPC.GetMoveSpeed(State.hero)) or 320
            ropts.return_tp      = keen_tp()   -- v0.1.230: ladder-aware pricing
        end
        ft.reserve = string.format("%.1f", State.shoveTravel or 0)
        ft.horizon = string.format("%.1f", ropts.horizon_s)
    end
    State.routePlan = Route.Plan(targets, route_hero_state(), ropts)
    -- v0.1.181 camp-drought instrument (run-16: plan=0 at FULL mana from base, 37 none-idles, the
    -- killer stage invisible): tally WHERE camp targets die, mirroring Route.Plan's pool filter +
    -- the afford gate. ft.rej = contested / risk-veto / leg-cap / afford / ok. Remove once the
    -- drought is root-caused off one run.
    do
        local hs = route_hero_state()
        local nC, nR, nL, nA, nF, nFp, need = 0, 0, 0, 0, 0, 0, nil
        for _, tg in ipairs(targets) do
            if tg.kind == "camp" then
                if tg.contested then nC = nC + 1
                elseif (tg.risk or 0) >= K.RISK_HARD then nR = nR + 1
                elseif K.MAX_CAMP_TRAVEL_S and Route._leg_time(hs.pos, tg, hs) > K.MAX_CAMP_TRAVEL_S then nL = nL + 1
                else
                    -- v0.1.199: track the CHEAPEST price among camps that reach the afford stage, so
                    -- --farm-audit can machine-check the gate (ok>0 <=> pm >= need) and flag refills
                    -- that cannot unlock any camp even at the ceiling (need > cap).
                    local price = (tg.mana_cost or 0) + (hs.reserve_mana or 0)
                    if not need or price < need then need = price end
                    if hs.mana < price then nA = nA + 1
                    else
                        nF = nF + 1
                        if tg.partnerRef then nFp = nFp + 1 end   -- v0.1.205: pair nodes among ok (singles-vs-pairs analyzability)
                    end
                end
            end
        end
        ft.rej = string.format("c%d/r%d/l%d/a%d/ok%d", nC, nR, nL, nA, nF)
        ft.okp = string.format("%d", nFp)                          -- v0.1.205: how many of ok are PAIR nodes
        ft.need = need and string.format("%.0f", need) or nil
        ft.pm   = string.format("%.0f", hs.mana)
        ft.cap  = string.format("%.0f", hs.max_mana)
    end
    if #State.routePlan.steps == 0 then
        -- Run-6 fix (user: kept re-trying the mid pair with ~1 March of mana): the old resource-FREE
        -- re-plan committed him to pairs he could afford ONE cast of - march once, the escape floor
        -- yanked him home, mark_engage_result marked the PAIR cleared half-done (the outpost partner
        -- untouched), the :00 respawn re-opened it, repeat. When nothing is affordable the right
        -- move IS the refill (the gated plan often cannot fit refill + camp inside a slack-capped
        -- horizon, so it comes back empty rather than proposing the trip). Resources genuinely fine
        -- but nothing fits -> fall through to the none-idle (wait out the window).
        local h = State.hero
        local mmax = (NPC.GetMaxMana and NPC.GetMaxMana(h)) or 1
        local hmax = Entity.GetMaxHealth(h) or 1
        if mana() < mmax * K.REFILL_FRAC or (Entity.GetHealth(h) or hmax) < hmax * K.REFILL_FRAC then
            State.spot = nil
            State.fsm  = "RETURN"
            emit_farm("refill")
            return
        end
    end
    -- keep the camp candidates for the debug overlay (draw_debug reads c.type/c.ehp/c.gold).
    local camps = {}
    for _, t in ipairs(targets) do if t.kind == "camp" then camps[#camps + 1] = t.ref end end
    State.cands = camps
    local f = State.funnel or {}   -- funnel breakdown: vis=in-sight, est=fogged-assumed, cleared=skipped
    ft.total, ft.fvis, ft.est, ft.fseen, ft.fcleared = f.total, f.vis, f.est, f.seen, f.cleared
    ft.plan, ft.gpm = #State.routePlan.steps, string.format("%.0f", gpm())
    -- v0.1.205 (singles-vs-pairs analyzability): the plan's first two steps, kind:value:paired -
    -- a lonely-single pick is machine-distinguishable from a pair snub without guessing.
    for i = 1, 2 do
        local st = State.routePlan.steps[i]
        ft["p" .. i] = st and string.format("%s:%.0f:%s", st.kind, st.value or 0,
                                            st.partnerRef and "y" or "n") or nil
    end

    local first = State.routePlan.steps[1]
    if not first then
        -- v0.1.210 (run-34 t=956-964: a tether release at wait=10.1 suppressed into an EMPTY
        -- window = 18 none-flutter decides in 8s, strictly worse than holding): a suppressed
        -- window the planner cannot fill is USELESS - cancel the suppression so the next decide
        -- re-commits the shove and tethers properly, and block re-releasing for one hold period
        -- (else release->empty->cancel would ping-pong at decide cadence).
        if stuckWindow and shove_suppressed(K.HOME_LANE) then
            State.shoveSuppress[K.HOME_LANE] = 0
            State.releaseBlockUntil = now() + K.TETHER_MAX_HOLD_S
            logline("release_cancel empty_window -> re-tether")
            State.spot = nil; emit_farm("none"); return
        end
        -- notes 3/4 (v0.1.160): a none pick used to idle wherever the abort left Tinker - next to
        -- the harassing hero (the suppress/unsafe windows are exactly when one is around). Step to
        -- the protected wait spot instead; the hold-still epsilon stops the move-order twitch.
        -- Phase 2 R2 (never linger at the meeting): also retreat when IDLING past the structure
        -- front - a raid's exit is the next action, and when that action is "nothing fits" the
        -- wait must happen at an anchor, never in enemy territory (user doctrine, task #12).
        local me = origin(State.hero)
        if enemy_hero_near({ x = me.x, y = me.y }, K.GANK_RADIUS)
           or frontier_excess({ x = me.x, y = me.y }) > 0 then
            local w = protected_wait_spot({ x = me.x, y = me.y })
            if me:Distance(Vector(w.x, w.y, me.z)) > K.WAVE_HOLD_EPS then
                move_to(Vector(w.x, w.y, me.z), "idle_retreat")
            end
        end
        -- v0.1.163 (user): the none-idle is a deliberate wait too (suppression / no target fits)
        State.waitInfo = { why = stuckWindow and "suppressed" or "window", t = now() }
        State.spot = nil; emit_farm("none"); return
    end

    if first.kind == "stack" then               -- v0.1.224: the timed-aggro maneuver (large camps, 2x cap)
        local c = first.ref
        local fp = friendly_fountain_pos()
        local sx, sy = c.center.x, c.center.y
        if fp then
            local dx, dy = fp.x - c.center.x, fp.y - c.center.y
            local dl = math.sqrt(dx * dx + dy * dy); if dl < 1 then dl = 1 end
            sx, sy = c.center.x + dx / dl * K.STACK_STAND_DIST, c.center.y + dy / dl * K.STACK_STAND_DIST
        end
        local st = snap_walkable({ x = sx, y = sy }, { x = c.center.x, y = c.center.y })
        c.kind = "stack"
        c.standSpot = { stand = Vector(st.x, st.y, c.center.z), aim = Vector(st.x, st.y, c.center.z) }
        c.aggroAt, c.fleeUntil, c.aggroed = first.stackWin.aggro_at, first.stackWin.done, false
        c.clearEst, c.planCost = first.clear_t or 0, 0
        State.spot, State.marchCasts, State.fsm = c, 0, "MOVE"
        State.moveSince = now()
        ft.ctype, ft.cgold = c.type, math.floor(c.gold or 0)
        ft.sx, ft.sy = string.format("%.0f", st.x), string.format("%.0f", st.y)
        emit_farm("stack")
        return
    end
    if first.restore then                       -- Note 4: the planner chose to refill -> hand off to RETURN
        -- COST-AWARE refill (ancient arc): remember what the NEXT planned step needs so the
        -- fountain wait fills to it (mana_cost + keen reserve, capped in fsm_return). Without
        -- this the 0.70 leave un-funds the exact target the refill was inserted to enable.
        local nxt = State.routePlan.steps[2]
        State.refillNeed = (nxt and not nxt.restore and nxt.mana_cost)
            and (nxt.mana_cost + abil_mana(State.keen, K.KEEN_MANA_FB)) or nil
        if State.refillNeed then ft.rneed = string.format("%.0f", State.refillNeed) end
        State.spot = nil
        State.fsm  = "RETURN"
        emit_farm("refill")
        return
    end

    -- first.kind is always "camp" here: gather_route_targets emits camps + the refill node only
    -- (handled above). The old non-shove route-wave branch was DELETED (glue review F2) - waves
    -- are owned by the Tier-1 shove dispatch above.
    local c = first.ref                                   -- the camp candidate (gather_candidates record)
    if first.partnerRef then                              -- #2/#3: pairing decided at valuation; build the pair stand directly (no re-search)
        local A, B = c.center, first.partnerRef.center
        c.standSpot = { stand = Vector((A.x + B.x) / 2, (A.y + B.y) / 2, A.z),
                        aim   = Vector((A.x + B.x) / 2, (A.y + B.y) / 2, A.z),
                        paired = true, partner = B,
                        partnerCamp = first.partnerRef.camp, partnerType = first.partnerRef.type,
                        clear = first.pairClass, pd = first.pairPd }
    else
        c.standSpot = best_stand_spot(c)                  -- single-camp ring search
        -- v0.1.189 instrument (user: "we shouldn't get singles from pairs"): a SINGLE pick logs
        -- its nearest live candidate's distance - nnd <= PAIR_RADIUS on a single = a pairable
        -- partner existed and GreedyPairs/the cleared-flag left it out -> dig that. nnd above =
        -- genuinely partnerless (isolated / partner cleared this cycle). Read it off pick=camp
        -- paired=false lines next run.
        local nnd
        for _, o in ipairs(State.cands or {}) do
            if o ~= c and o.center then
                local d = c.center:Distance(o.center)
                if not nnd or d < nnd then nnd = d end
            end
        end
        ft.nnd = nnd and string.format("%.0f", nnd) or "-"
    end
    if not c.standSpot then State.spot = nil; emit_farm("none"); return end
    c.kind = "camp"
    c.clearEst = first.clear_t or 0                       -- timing calib: the planner's clear_t estimate for this camp/pair
    c.planCost = first.mana_cost or 0                     -- v0.1.212 cost-truth census: planned mana vs the real clear (logged at engage exit)
    local spot = c

    State.spot, State.marchCasts, State.fsm = spot, 0, "MOVE"
    State.moveSince = now()
    State.moveTrack = nil   -- reset the P0 no-progress watchdog for the new spot
    State.keenedSpot = false
    State.marchPending = nil
    State.emptySince = nil

    local ss = spot.standSpot
    ft.ctype, ft.cgold, ft.cstk = spot.type, math.floor(spot.gold or 0), camp_stacks(spot.gold, spot.type)
    ft.csrc, ft.cval = spot.source or "est", math.floor(first.value or 0)
    ft.crisk = string.format("%.2f", first.risk or 0)
    ft.ncreep, ft.paired = #(spot.creeps or {}), tostring(ss.paired or false)
    ft.cx, ft.cy = math.floor(spot.center.x), math.floor(spot.center.y)
    ft.sx, ft.sy = math.floor(ss.stand.x), math.floor(ss.stand.y)
    if ss.partner then ft.pcx, ft.pcy = math.floor(ss.partner.x), math.floor(ss.partner.y)
    elseif State.pairSkip then ft.pairskip = State.pairSkip end
    emit_farm("camp")
end

-- Track the LIVE wave: read enemy lane creeps near the wave's last-known point, advance s.refPoint (the
-- count centroid, for distance/engage-range), re-aim s.standSpot.aim at the moving wave so the March
-- lands on it, AND re-derive s.standSpot.stand from the live wave through the SAFE stand composition
-- (v0.1.155). History: T4a froze the stand because the old recompute was an UNCLAMPED raw offset that
-- slid under towers on a deep wave; the composed stand (CrashCast + Nav.SafeDest(tower_safe) + snap)
-- cannot, and the freeze itself proved to be a stuck-bug (a fogged decide's estimate froze a stand
-- outside both engage triggers -> the hero stood at it forever while the real wave fought 1240u away).
-- Returns { cx, cy, n } of the live cluster, or nil when the wave is gone (no enemy creeps near).
local function update_wave_spot(s)
    local creeps = enemy_lane_creeps_near(s.refPoint, K.WAVE_TRACK_RADIUS)
    if #creeps == 0 then return nil end
    local cx, cy = 0, 0
    for _, c in ipairs(creeps) do cx = cx + c.pos.x; cy = cy + c.pos.y end
    cx, cy = cx / #creeps, cy / #creeps
    local z = origin(State.hero).z
    s.refPoint = Vector(cx, cy, z)                 -- live tracker = count centroid (distance/stand math)
    -- ON (anticipation): anchor the AIM on the TRAILING RANGED creep (the deepest enemy creep = furthest
    -- from our fountain), so the March footprint lands on it (Note 1) instead of falling short of the
    -- melee-front centroid. The STAND stays frozen (decide-time safe_stand_for is already tower-safe +
    -- depth-capped); this fn only re-aims.
    do   -- T0 collapsed: the ranged-anchored live aim/stand is the only path (span-center below stays as the fallback)
        local fp0 = friendly_fountain_pos()
        local ranged, bestd = nil, -1
        if fp0 then
            for _, c in ipairs(creeps) do
                local dx, dy = c.pos.x - fp0.x, c.pos.y - fp0.y
                local dd = dx * dx + dy * dy
                if dd > bestd then bestd, ranged = dd, c.pos end
            end
        end
        if ranged then
            -- ON: anchor the AIM on the trailing ranged creep (the cast lands on it) AND re-derive the
            -- STAND from the LIVE wave through the SAFE composition (v0.1.155): the decide-time stand
            -- froze 900-back of a possibly-lying estimate (fogged mirror ~400u off), leaving the hero
            -- outside BOTH engage triggers forever (dref ~1240 > 950/1150 = the completely-stuck lane).
            -- The freeze existed because the OLD recompute was an unclamped raw offset that slid under
            -- towers; safe_stand_for is CrashCast + Nav.SafeDest(tower_safe) + snap now, so live
            -- tracking is safe. Not coverable -> fall through to the OFF span-center aim.
            -- glue review F19 (v0.1.157): forward is CONTESTED-AWARE, same as the decide-time stand
            -- (forward 850 only on a clear lane; a live-appearing enemy backs the stand to 900).
            -- v0.1.192: mid-commit deep_ok = shove + Keen L2 (NO ready requirement - after the raid
            -- keen lands deep, keen is on cd; requiring ready would clamp the live stand back to
            -- the stairs and walk him out of his own engage).
            local dok = s.shove and ((State.keen and Ability.GetLevel and Ability.GetLevel(State.keen)) or 0) >= 2
            local st, cov = safe_stand_for(ranged, not lane_unsafe({ x = ranged.x, y = ranged.y }), dok, s.lane)
            if st and cov then
                s.standSpot.aim = Vector(ranged.x, ranged.y, z)
                s.standSpot.stand = Vector(st.x, st.y, z)
                return { cx = cx, cy = cy, n = #creeps }
            end
        end
        -- no fountain / not coverable: fall through to the OFF logic
    end
    -- along-lane axis = centroid -> our fountain (the dir enemy creeps push; melee lead, ranged trail).
    local fp = friendly_fountain_pos()
    local ax, ay = 0, 0
    if fp then
        local dx, dy = fp.x - cx, fp.y - cy
        local dl = math.sqrt(dx * dx + dy * dy)
        if dl > 1 then ax, ay = dx / dl, dy / dl end
    end
    -- AIM at the along-lane SPAN CENTER (covers melee front + ranged back), not the melee-weighted
    -- count centroid -> the March clears the trailing ranged creep instead of leaving it for an extra W.
    local pts = {}
    for _, c in ipairs(creeps) do pts[#pts + 1] = { x = c.pos.x, y = c.pos.y } end
    local aimc = ((ax ~= 0 or ay ~= 0) and Farm.WaveAimCenter(pts, ax, ay)) or { x = cx, y = cy }
    if (ax ~= 0 or ay ~= 0) and K.WAVE_LEAD ~= 0 then    -- Note 5: lead toward the trailing ranged creep (-axis = away from our fountain), so the footprint spans it
        aimc = { x = aimc.x - ax * K.WAVE_LEAD, y = aimc.y - ay * K.WAVE_LEAD }
    end
    s.standSpot.aim = Vector(aimc.x, aimc.y, z)
    -- v0.1.155: the STAND tracks the live wave through the SAFE composition too (see the ON-branch
    -- note). The old T4 freeze guarded against the UNCLAMPED raw offset sliding under towers; the
    -- composed stand is tower-clamped + walkable, so live tracking is safe and the engage triggers
    -- stay geometrically reachable when the decide-time meeting estimate was off.
    local st, cov = safe_stand_for({ x = aimc.x, y = aimc.y }, false,
        s.shove and ((State.keen and Ability.GetLevel and Ability.GetLevel(State.keen)) or 0) >= 2, s.lane)   -- v0.1.192: same mid-commit deep_ok
    -- v0.1.193: NO illegal live stands. Both branches failing legality (past the stairs line /
    -- tower-blocked, non-raid) = the live wave is not walk-farmable from here -> flag it so the
    -- MOVE layer bails to a redecide NOW instead of holding the frozen stand until MOVE_TIMEOUT
    -- (the run-23 22-25s waits). The frozen decide-time stand stays for the ENGAGE aim clamp.
    if st and cov then s.standSpot.stand = Vector(st.x, st.y, z) end
    return { cx = cx, cy = cy, n = #creeps, nocover = (st and not cov) or nil }
end

-- Shared no-progress watchdog (Note 1): a Keen can land on terrain we cannot path to the stand
-- from (e.g. a tower's high ground), so move_to spins forever and never times out. True when
-- distance-to-target has not improved by PROGRESS_EPS within NO_PROGRESS_S (Nav.Stuck, the lib
-- home of the watchdog family). Caller decides the recovery (camp marks cleared; a shove just
-- re-decides). State.moveTrack resets per committed spot. Only for STATIC stands; the live-wave
-- stand moves with the cluster (use MOVE_TIMEOUT there).
local function no_progress(d)
    local stuck
    State.moveTrack, stuck = Nav.Stuck(State.moveTrack, d, now(),
        { eps = K.PROGRESS_EPS, window = K.NO_PROGRESS_S })
    return stuck
end

-- v0.1.216: did the last keen actually TELEPORT? A channel canceled by its dying anchor leaves
-- the hero in place with the cd burned; reset keenedSpot so the movement ladder recovers via
-- rearm -> keen instead of walking the whole leg. Called at the MOVE fsm heads (camp + wave).
local function keen_cancel_check()
    local kp = State.keenPending
    if not kp or now() < kp.due then return end
    State.keenPending = nil
    -- v0.1.219 (run-42: 17 keen_canceled, most FALSE POSITIVES - e.g. t=504 fired 2s after a
    -- fresh cast, i.e. judging a STALE pending from an earlier SUCCESSFUL keen; the fsm had gone
    -- MOVE->ENGAGE before due so the check never ran, and the next MOVE trip read the hero far
    -- from the old landing -> phantom cancel -> a re-keen+rearm burned ~375 mana each, 17x =
    -- the run's fountain/coverage regression): the walked-away-vs-canceled judgment is only
    -- valid FRESH - a genuine cancel keeps the hero parked at the cast spot with MOVE ticking
    -- every 0.4s, so the check runs within a tick of due. Anything older just clears.
    if now() > kp.due + 1.5 then return end
    -- v0.1.221 (run-44: 14 keen_canceled remained, mostly CREEP keens - the teleport arrives at
    -- the creep's CURRENT position, which moved during the ~3s channel, so the landing-distance
    -- test misfires on fast waves): the true cancel signature is STILL STANDING AT THE CAST
    -- ORIGIN with the channel over - a rooted channel cannot walk away, and any teleport (to the
    -- planned landing OR the moved creep) leaves the origin.
    local me = origin(State.hero)
    if kp.origin and me:Distance(Vector(kp.origin.x, kp.origin.y, me.z)) < 600 then
        State.keenedSpot = false
        logline("keen_canceled -> re-ladder")
    end
end

-- Piece 0 (TINKER_LANE_NAV_DESIGN.md): the LANE movement chokepoint. Every lane move routes here:
-- ONE structural safety policy (Nav.SafeDest clamp toward our fountain + report) + ONE transport
-- ladder (Nav.Ladder: keen -> rearm-reset -> blink -> walk, executed via the existing gated
-- primitives, falling through on primitive failure). Jungle keeps its own paths (separate layer);
-- dynamic danger (enemies) stays with the FSM live aborts. The clamp log is the Piece-1 instrument:
-- every "lane_go clamp" line is evidence of an upstream bad-stand bug.
-- `raid` (Phase 2, TINKER_ANCHOR_TETHER_DESIGN.md R1): allow allied lane CREEPS as keen anchors
-- for this leg - the L2 in-and-out. Only the shove STAND approaches pass it (holds/tether waits
-- stay structure-anchored); every landing still runs the full gate set in keen_to_anchor
-- (lane_unsafe + tower_safe + depth-vs-stand cap + clear_landing), so an unsafe creep landing degrades
-- to a building anchor = the tether path (R3: no gate relaxed). The user's risk POINT SYSTEM
-- (2026-07-03 directive) slots here when it lands: points gate the raid instead of the L2 binary.
local function lane_go(dest, raid)
    if not dest then return nil end
    local me = origin(State.hero)
    local fp = friendly_fountain_pos()
    local retreat = { x = 0, y = 0 }
    if fp then
        local dx, dy = fp.x - dest.x, fp.y - dest.y
        local dl = math.sqrt(dx * dx + dy * dy)
        if dl > 1 then retreat = { x = dx / dl, y = dy / dl } end
    end
    -- v0.1.198 audit HOLE D - THE DEEP TRIPWIRE (assertion, not a clamp): after the census every
    -- legit caller feeds a legal destination (decide covers-exclusion, gated live re-stand,
    -- structure-anchored holds, gated step-in, capped landings), so a non-raid dest past the
    -- walk line here is BY DEFINITION an upstream producer bug. Do NOT walk it and do NOT park
    -- at the line (the v0.1.192 freeze): reject the whole action, force a redecide (Plan then
    -- excludes the target properly), suppress the flutter, and log LOUDLY - every deep_reject
    -- line in a log is a bug report with the caller's coordinates in it.
    if not raid and (stand_depth(dest) > K.WALK_DEPTH_MAX + 50 or not lane_leash_ok(dest, 50, State.spot and State.spot.lane)) then   -- v0.1.202: raid legs exempt from the leash too (ungankable raids re-sanctioned; the dispatch is covers-gated upstream)
        logline(string.format("lane_go deep_reject (%.0f,%.0f) depth=%.0f -> redecide (UPSTREAM BUG)",
            dest.x, dest.y, stand_depth(dest)))
        suppress_shove(State.spot and State.spot.lane, now() + K.SHOVE_STUCK_S)
        State.spot = nil; State.fsm = "DECIDE"; State.moveSince = nil
        return nil
    end
    local sdest, clamped = Nav.SafeDest({ x = dest.x, y = dest.y }, retreat, tower_safe)   -- v0.1.193: movement is tower-clamped ONLY; the stairs line is a decide-time exclusion (covers/gone), never a movement clamp
    if clamped then
        logline(string.format("lane_go clamp (%.0f,%.0f) -> (%.0f,%.0f)", dest.x, dest.y, sdest.x, sdest.y))
    end
    sdest = snap_walkable(sdest, dest)
    local sv = Vector(sdest.x, sdest.y, me.z)
    -- v0.1.205 (user directive, REVERSES the v0.1.158 note 6 "no blink in lane"): blink IS a lane
    -- travel rung now - the walking-distance-only usage under-used the dagger ("shaving even 3
    -- seconds can mean one more camp or clear the lane"). The jump-risk veto lives INSIDE
    -- try_travel_blink (fog-aware risk on hero + landing + tower); with a player threat around the
    -- dagger stays reserved for the escape, which was the whole v0.1.158 concern. Keen still
    -- outranks it (full teleport); blink fires when keen can't.
    -- v0.1.232 WAIT-FOR-KEEN rung (run-52, user: "still walking back to the lane"): at
    -- Keen L1 there is no Rearm to reset it, so a just-used keen left the ladder WALKING
    -- 30s+ lane returns while the cd came back in seconds (t=238: walked ~32s from base
    -- with keen due in ~9s). When waiting out the cd + channel clearly beats the walk,
    -- HOLD in place (watchdogs fed; the fsm's live risk re-checks keep running; at base
    -- the hold is regen time) and let a later tick take the keen rung. Mana-short keen
    -- reads cd 0 -> walks (no deadlock); the margin keeps short walks walking.
    local function walk_or_wait()
        if not State.keenedSpot and State.keen and not ready(State.keen)
           and ((Ability.GetLevel and Ability.GetLevel(State.keen)) or 0) >= 1 then
            local kcd = (Ability.GetCooldownTimeRemaining and Ability.GetCooldownTimeRemaining(State.keen)) or 0
            local ms = (NPC.GetMoveSpeed and NPC.GetMoveSpeed(State.hero)) or 320
            local walk_s = me:Distance(sv) / math.max(150, ms)
            if kcd > 0 and kcd + K.KEEN_CHANNEL + K.KEEN_WAIT_MARGIN < walk_s then
                State.waitInfo = { why = string.format("keen cd %ds", math.ceil(kcd)), t = now() }
                State.moveSince = now(); State.moveTrack = nil   -- intentional hold: feed the watchdogs
                if now() - (State.waitKeenLogT or 0) > 2 then
                    State.waitKeenLogT = now()
                    logline(string.format("lane_go wait_keen cd=%.1f walk=%.0fs", kcd, walk_s))
                end
                return "wait_keen"
            end
        end
        -- v0.1.244 THE AT-DESTINATION SHUFFLE FIX (run-61, named by the .242/.243 instruments +
        -- the platform order log): already within the arrival epsilon = issue NOTHING. The old
        -- 0.5s same-target re-assert kept a stale MOVE order alive at the stand (51 identical
        -- orders to one spot, mv gap=0 age=0.53 drumbeats), and the engine RESUMES that stale
        -- order after every cast completes (ext_move ages 2.87-3.2s = the rearm+cast cycle) -
        -- the user's ~1Hz "issue a movement and cancel it" while waiting in lane.
        if me:Distance(sv) <= K.WAVE_HOLD_EPS then return "walk" end
        move_to(sv, "lane_walk"); return "walk"
    end
    local rungs = Nav.Ladder(me:Distance(sv), {
        keened = State.keenedSpot, keen_ready = ready(State.keen), keen_min_gain = K.KEEN_TRAVEL_MIN,
    })
    for _, r in ipairs(rungs) do
        if r == "keen" then
            local kok, kwhy = keen_to_anchor(sv, raid)
            if kok then State.keenedSpot = true; logline(raid and "lane_go keen raid" or "lane_go keen"); return "keen" end
            -- v0.1.234 (run-53: keen_skip NAMED it - why=cast_failed, all gates clean): the
            -- issue() ORDER_GAP rate guard swallowed the keen when the fountain chain-drink
            -- bottle order shared the tick. PURELY TRANSIENT (retries fine 0.05s later), but
            -- the unconditional don't-retry latch turned it into a cross-map walk (runs
            -- 52+53). Only geometry-stable refusals (no_landing / gain) latch now.
            if kwhy ~= "cast_failed" then State.keenedSpot = true end   -- no safe landing: don't retry this spot
        elseif r == "rearm" then
            -- v0.1.209 (user FINAL: safe = blink, no distance gate): a NON-raid leg blinks before
            -- any rearm-reset. A RAID leg stays blink-free - the creep hop at step-out IS the
            -- transport (global keen), and a partial blink toward a deep stand would walk him
            -- forward into the lane (never-wait-forward).
            -- v0.1.212 (run-35: a raid keen landed residual=2242 at the far allied bldg and WALKED
            -- it, 4x - the user's "keen to T2 did not blink on position"): the raid blink-exclusion
            -- applies only BEFORE the leg's keen (the creep hop IS the transport); once the keen is
            -- spent (State.keenedSpot) the residual is an ordinary sanctioned walk - blink it.
            if (not raid or (State.keenedSpot and me:Distance(sv) >= 800)) and try_travel_blink(sv) then logline("lane_go blink"); return "blink" end
            if safe_rearm() then logline("lane_go rearm_reset_keen"); return "rearm" end
        else
            -- v0.1.209 review fix + v0.1.212: same raid rule (pre-keen only) as the rearm rung.
            if (not raid or (State.keenedSpot and me:Distance(sv) >= 800)) and try_travel_blink(sv) then logline("lane_go blink"); return "blink" end
            return walk_or_wait()
        end
    end
    if (not raid or (State.keenedSpot and me:Distance(sv) >= 800)) and try_travel_blink(sv) then logline("lane_go blink"); return "blink" end
    return walk_or_wait()
end

-- Wave MOVE: track the live wave (re-aim the stand at the moving cluster), close the distance via
-- Keen/walk, and switch to ENGAGE as soon as the hero is within WAVE_ENGAGE_RANGE of the LIVE centroid
-- (close enough to cover it with March), NOT a fixed stand the wave has since left. Bails to re-decide
-- if the wave is gone or unreachable in time. Rearm-to-reset-Keen is SAFE-gated (Note 3).
local function fsm_move_wave(s)
    keen_cancel_check()   -- v0.1.216: a canceled keen re-arms the ladder (rearm -> keen), never a deep walk
    State.fog = enemy_snapshot()                       -- fresh risk for safe_rearm + the reposition check
    -- Note 3: a committed shove/wave walk had NO live risk re-check (Part A was camp-only), so it kept
    -- walking forward into a gank as risk rose (death at a decide-gate stand risk 0.31 that climbed past
    -- 0.42 during the long keen-to-mid-T1 + 1936u walk). Re-check the HERO's live fog-aware risk each
    -- tick and bail+recover when it turns dangerous; suppress re-shoving the same spot briefly.
    local hrisk = enemy_risk_at(origin(State.hero))
    -- (the v0.1.123 live too_deep abort was REMOVED 2026-07-01 with the depth-veto patch family.)
    if lane_unsafe(origin(State.hero)) then             -- v0.1.94: 2+ enemies / under-tower / low-HP 1v1 (not a healthy 1v1 trade)
        try_escape_blink()                              -- primary: flee by blink BEFORE the burst; recover regardless
        suppress_shove(s.lane, now() + K.SHOVE_STUCK_S)
        State.spot = nil; State.fsm = "DECIDE"; State.moveSince = nil
        logline(string.format("wave_move abort reason=unsafe risk=%.2f", hrisk)); return
    end
    local live = update_wave_spot(s)
    -- note 2 (v0.1.160): the wave OBSERVED arriving after an empty wait = the REAL arrival - stamp it
    -- for the cadence anchor. waveEta alone lied on fogged anticipatory shoves (the mirror reads "due
    -- now" up to ~13s early), so lastWaveT inherited the bias and the measured rhythm scheduled camp
    -- keens right into real arrivals. A commit with the remnant already present never sets emptySince
    -- and keeps the (accurate, kin-from-real-fronts) waveEta stamp.
    if live and State.emptySince and not s.waveLiveT then s.waveLiveT = now() end
    -- RAID (Phase 2, spec R1): at Keen L2+ a shove-stand approach may keen onto an allied CREEP
    -- near the stand (the in-and-out; landing fully gated in keen_to_anchor, degrades to a
    -- building anchor when unsafe = the tether path). Shared by both branches (v0.1.173).
    local raidok = s.shove and ((State.keen and Ability.GetLevel and Ability.GetLevel(State.keen)) or 0) >= 2
    if not live then
        -- A shove heads toward the predicted crash point even while fogged, but NEVER waits forward
        -- (task #12, TINKER_ANCHOR_TETHER_DESIGN.md): hold TETHERED at the protected spot (nearest
        -- alive friendly structure toward the stand) and step out arrival-timed on the STAMPED
        -- cadence, so the walk arrives as the wave does. No stamp (first wave / lost rhythm) -> no
        -- walk-out on a guess; the wave walks into vision and the live branch engages near the
        -- anchor (which also stamps lastWaveT for the next cycle).
        local me0 = origin(State.hero)
        local d0 = me0:Distance(s.standSpot.stand)
        State.emptySince = State.emptySince or now()   -- fogged wait started (also arms the waveLiveT observed-arrival stamp)
        -- Piece 2 hold expiry (runs tethered OR at the stand): the committed waveEta can lie by
        -- seconds (fogged = the mirrored-front estimate). On expiry, re-ask the MEASURED rhythm
        -- (NextWaveArrival on the arrival-stamped lastWaveT): next wave within WAVE_HOLD_NEXT ->
        -- extend the deadline (this also CORRECTS s.waveEta to the stamped value); genuinely far
        -- -> redecide, and the scheduler fills the real window.
        -- v0.1.222 (user, run-45: two ~20s stand-waits for PHANTOM waves - t=756 step_out ->
        -- t=776 no_wave): standing AT the stand gives ~1200-1800 vision up-lane, so a genuinely
        -- arriving wave is VISIBLE ~4s before eta. At the stand, an INVISIBLE wave past
        -- eta + WAVE_WAIT_GRACE_VIS is a phantom (died deep / never spawned as predicted) - bail
        -- to the planner early. Tethered/far holds keep the full grace (no vision claim there).
        local grace = (d0 <= K.WAVE_ENGAGE_RANGE) and K.WAVE_WAIT_GRACE_VIS or K.WAVE_WAIT_GRACE
        local due = (s.waveEta and (s.waveEta + grace)) or (State.emptySince + K.WAVE_WAIT_GRACE)
        if now() > due then
            local nxt = Schedule.NextWaveArrival(now(), K.WAVE_PERIOD, K.WAVE_PHASE, State.laneWaveT[s.lane or K.HOME_LANE])   -- PHASE 2: the hold's own lane cadence (side holds used MID's stamp before - wrong lane phase)
            if nxt and (nxt - now()) <= K.WAVE_HOLD_NEXT then
                s.waveEta = nxt
                logline(string.format("wave_wait extend eta=%.1f", nxt))
            else
                State.spot = nil; State.fsm = "DECIDE"; State.moveSince = nil
                logline("shove_move no_wave -> redecide"); return
            end
        end
        -- TETHER: latch on step-out (s.steppedOut) - once out, stay out; a late wave rolls eta_live
        -- +30s and re-tethering would walk him back just as it shows. The expiry above owns lateness.
        if not s.steppedOut then
            local eta_live = State.laneWaveT[s.lane or K.HOME_LANE]
                and Schedule.NextWaveArrival(now(), K.WAVE_PERIOD, K.WAVE_PHASE, State.laneWaveT[s.lane or K.HOME_LANE]) or nil   -- PHASE 2: per-lane
            -- v0.1.213 TIMED MEETING RAID: the pre-empt target is the EARLIER of the cadence eta
            -- and the sim's meeting time (fight start) - land as the waves collide.
            if s.meetEta then eta_live = eta_live and math.min(eta_live, s.meetEta) or s.meetEta end
            local ms = (NPC.GetMoveSpeed and NPC.GetMoveSpeed(State.hero)) or 320
            local walk_s = d0 / math.max(150, ms)
            -- R1 timing: a raid transits by keen (~channel + a short landing walk), not the full
            -- d0 walk - stepping out on the walk estimate would land him at the deep stand seconds
            -- early = waiting in enemy territory, the exact doctrine violation.
            -- v0.1.211: ladder-aware (keen down + rearm ready = rearm channel + keen channel).
            if raidok then
                local tr = ready(State.keen) and (K.KEEN_CHANNEL + 1.0)
                           or (ready(State.rearm) and rearm_channel() + K.KEEN_CHANNEL + 1.0 or nil)
                if tr then walk_s = math.min(walk_s, tr) end
            end
            if d0 <= K.WAVE_ENGAGE_RANGE then
                s.steppedOut = true                        -- committed already near the stand: no tether leg
            elseif eta_live and now() >= eta_live - walk_s - K.STEP_OUT_LEAD then
                s.steppedOut = true
                State.keenedSpot = false                   -- v0.1.175: the tether leg may have SPENT the keen reaching the anchor; re-arm the ladder (rearm-reset -> keen) so the step-out leg can RAID (run-13: keenedSpot=true made every deep step-out walk 3000u+)
                logline(string.format("step_out eta=%.1f walk=%.1f d=%.0f", eta_live, walk_s, d0))
            else
                -- v0.1.208 (run-33 "eternal waiting"): a LONG wait until step-out is a JUNGLE
                -- WINDOW, not a hold - the v0.1.207 local holds parked him at the fountain-side
                -- spot for 30s+ (the raid keen transit ~4s pushes step-out to the last seconds).
                -- Release to the planner with the shove suppressed for the wait; the re-decide
                -- after suppression re-commits the shove in time to step out.
                local wait_s = eta_live and (eta_live - now() - walk_s - K.STEP_OUT_LEAD) or nil
                if wait_s and wait_s > K.TETHER_MAX_HOLD_S and now() >= (State.releaseBlockUntil or 0) then
                    suppress_shove(s.lane, now() + math.min(wait_s - 2, 25))
                    State.spot = nil; State.fsm = "DECIDE"; State.moveSince = nil
                    logline(string.format("tether release wait=%.1f -> jungle window", wait_s))
                    return
                end
                -- (review v0.1.178: tether spot cached per commit, same as the live branch)
                if not s.tetherSpot then
                    s.tetherSpot = protected_wait_spot({ x = s.standSpot.stand.x, y = s.standSpot.stand.y })
                    -- v0.1.206 (user: "if we are raiding, just keen direct on the creep"): the raid
                    -- keen is GLOBAL - transiting to a far hold buys NOTHING, and the v0.1.194 keen
                    -- ladder on far raid legs re-created keen->structure -> rearm -> keen->creep
                    -- (~375 mana + the T1 trip, the run-30/31 sightings). A far hold on a
                    -- raid-capable shove is replaced by a protected spot near the HERO; the
                    -- step-out keens straight onto the creep from wherever he waited.
                    local msT = (NPC.GetMoveSpeed and NPC.GetMoveSpeed(State.hero)) or 320
                    if raidok and me0:Distance(Vector(s.tetherSpot.x, s.tetherSpot.y, me0.z))
                                  / math.max(150, msT) > K.TETHER_WALK_MAX_S then
                        s.tetherSpot = protected_wait_spot({ x = me0.x, y = me0.y })
                    end
                end
                local hv = Vector(s.tetherSpot.x, s.tetherSpot.y, me0.z)
                if not s.tetherLogged then
                    s.tetherLogged = true
                    logline(string.format("tether hold=(%.0f,%.0f) d=%.0f eta=%s", s.tetherSpot.x, s.tetherSpot.y, d0,
                        eta_live and string.format("%.1f", eta_live) or "-"))
                end
                State.waitInfo = { why = string.format("tether %s", eta_live
                    and string.format("%ds", math.max(0, math.floor(eta_live - now()))) or "wave?"), t = now() }
                -- v0.1.214 (run-37 t=764: a wave committed with Keen down WALKED ~6000 from the
                -- outpost - the exposed field rearm is risk-blocked at 0.20, correctly): the tether
                -- hold IS the protected low-risk window, so pre-arm Keen HERE; the step-out then
                -- always has the hop ready and never falls to the walk rung.
                if raidok and not ready(State.keen) and safe_rearm() then
                    logline("tether prearm_rearm"); return
                end
                -- v0.1.188 (run-20 user note: keen->structure->rearm->keen->creep): when the RAID
                -- will spend the keen at step-out, the tether leg must WALK - the raid keen
                -- teleports to the creep from ANYWHERE, so reaching the wait anchor buys nothing
                -- and the structure hop burned keen+rearm AND corrupted the step-out pricing
                -- (keen on cd -> walk_s read 11s instead of ~4).
                if me0:Distance(hv) > K.WAVE_HOLD_EPS then
                    -- v0.1.206: a raid-capable leg ALWAYS walks (the hold is local by construction
                    -- above; the keen is preserved for the direct creep hop). Non-raid legs keep
                    -- the ladder (their engage is a walk-in, the keen is not needed later).
                    if raidok then move_to(hv, "tether_hold") else lane_go(hv) end
                end
                return
            end
        end
        if d0 > K.WAVE_ENGAGE_RANGE then
            if no_progress(d0) then                    -- Note 1: keen landed where the stand is unreachable (tower high ground) -> recover, and suppress re-shoving the same spot
                suppress_shove(s.lane, now() + K.SHOVE_STUCK_S)
                State.spot = nil; State.fsm = "DECIDE"; State.moveSince = nil
                logline(string.format("shove_move stuck d=%.0f -> recover (suppress shove %ds)", d0, K.SHOVE_STUCK_S)); return
            end
            lane_go(s.standSpot.stand, raidok); return -- Piece 0: clamp + keen/rearm/blink/walk ladder (+ creep anchors on a raid)
        end
        -- at the stand, waiting for the wave to close (post step-out this window is ~STEP_OUT_LEAD).
        -- note 3 (v0.1.160, user): an enemy hero on the lane harasses a forward wait - hold the
        -- fogged wait NEAR OUR TOWER instead; the wave's arrival (live creeps) switches to the
        -- live branch, which re-approaches the stand as normal.
        local hold = s.standSpot.stand
        local prot = enemy_hero_near({ x = hold.x, y = hold.y }, K.WAIT_ENEMY_R)
        if prot then
            local w = protected_wait_spot({ x = hold.x, y = hold.y })
            hold = Vector(w.x, w.y, me0.z)
        end
        -- v0.1.163 (user): this IS a deliberate wait - say so (HUD reads WAIT, not MOVE).
        State.waitInfo = { why = string.format("wave %ds%s", math.max(0, math.floor((s.waveEta or now()) - now())),
                                               prot and " @tower" or ""), t = now() }
        -- Piece 0 clamp + ladder; HOLD-STILL (v0.1.153): at the hold spot, stop re-issuing orders
        -- v0.1.235 (run-53 t=842, the deep-dive's corrected verdict): the hold IS the raid
        -- stand on a raid commit, but this caller DROPPED the raid flag - a legally-deep
        -- drifted hold hit the non-raid tripwire (deep_reject "UPSTREAM BUG", the one false
        -- positive). Pass raidok like the approach leg above; the tripwire label is honest again.
        if me0:Distance(hold) > K.WAVE_HOLD_EPS then lane_go(hold, raidok) end
        return
    end
    local me = origin(State.hero)
    local dWave = me:Distance(s.refPoint)
    -- v0.1.193: the live wave's legal stand no longer covers it (drifted past the stairs line or
    -- tower-blocked, and this commit cannot raid it) - standing here is the run-23 22-25s wait.
    -- v0.1.195 (run-25 t=63): bail only when the wave is NOT CLOSING - nocover fired on an
    -- INBOUND wave (their push crashing our tower) whose CURRENT position read deep, and the
    -- abort+suppress+none-idle walked him back to our T1 exactly as the full wave arrived. A
    -- closing wave keeps the frozen (legal) stand and engages normally; a held/receding deep
    -- wave bails after NC_GRACE_S and Plan's covers/gone exclusion jungles the window.
    if live.nocover then
        if not s.ncT then s.ncT, s.ncD = now(), dWave
        elseif dWave < s.ncD - K.NC_CLOSE_EPS then s.ncT, s.ncD = now(), dWave   -- closing: re-arm the grace
        elseif now() - s.ncT > K.NC_GRACE_S then
            suppress_shove(s.lane, now() + K.SHOVE_STUCK_S)
            State.spot = nil; State.fsm = "DECIDE"; State.moveSince = nil
            logline("wave_move abort reason=nocover"); return
        end
    else
        s.ncT, s.ncD = nil, nil
    end
    -- v0.1.121 REVERTED the v0.1.119 preemptive engage: it fired when the wave was MARCH_LEAD from the
    -- MEETING but still ~1600 from TINKER (he stands 900 back), so the engage immediately repositioned
    -- (dWave > 1200) -> MOVE -> preempt again = a CHASE LOOP that walked Tinker under the tower (note 1)
    -- + set shove_stuck (notes 3/4). The reactive engage below already casts March at the aim (meeting)
    -- as the wave arrives within range, which is near-preemptive without the chase. A correct preemptive
    -- W needs a stand-still cast that does NOT trigger the reposition - deferred to a careful redesign.
    -- ON (anticipation): engage when the hero is within W-reach of the AIM = the TRAILING RANGED creep we
    -- anchor on, so the cast (clamped to hero + MARCH_CAST_RANGE) from the ~850-back stand LANDS on the
    -- ranged. The old reach(1200)-on-the-CENTROID trig engaged ~1160 from the wave, where the clamped cast
    -- fell ~900 short -> the ranged miss. OFF: the baseline centroid trig. Both use WAVE_ENGAGE_RANGE.
    local eref = s.standSpot.aim                            -- T0 collapsed: engage measures to the AIM (the trailing ranged)
    local dref = me:Distance(eref)
    -- Piece 2 TIME-SCHEDULED first W: also engage when the wave is DUE (waveEta) and Tinker is holding
    -- at the frozen stand with the live wave already inside March's reach. Strictly EARLIER than the
    -- distance trigger and whiff/chase-safe by construction: dWave <= MARCH_REACH (1150) sits under
    -- fsm_engage_wave's reposition bound (WAVE_ENGAGE_RANGE + 250 = 1200), and the clamped cast
    -- (~280 ahead + ~900 sweep) covers the wave from here. The distance trigger stays as base/fallback.
    -- (The spec's ENGAGE_LEAD is already realized by SCHED_LEAD - the scheduler leaves early; no new const.)
    local timed = s.waveEta and now() >= s.waveEta - K.MARCH_CAST_DUR
                  and me:Distance(s.standSpot.stand) <= K.ARRIVE_DIST + 180
                  and dWave <= K.MARCH_REACH
    if dref <= K.WAVE_ENGAGE_RANGE or timed then
        State.fsm = "ENGAGE"; State.moveSince = nil; State.emptySince = nil
        logline(string.format("wave_engage_arrived dWave=%.0f dref=%.0f creeps=%d trig=%s eta_err=%s",
            dWave, dref, live.n, timed and "time" or "dist",
            s.waveEta and string.format("%+.1f", now() - s.waveEta) or "-")); return
    end
    if State.moveSince and now() - State.moveSince > K.MOVE_TIMEOUT then
        -- v0.1.194 F3 (run-24 t=707/769): a tether with a CONCRETE step-out shortly ahead is not
        -- a stall - the 25s guillotine kept killing ~21s scheduled holds right at their step-out.
        -- Extend to the committed wave eta + grace, HARD-CAPPED one wave period past the normal
        -- timeout so a rolling eta can never re-create the v0.1.178 idle trap.
        local eta = (not s.steppedOut) and s.tetherSpot and s.waveEta or nil
        local cap = State.moveSince + K.MOVE_TIMEOUT + K.WAVE_PERIOD
        if not (eta and now() < math.min(eta + K.WAVE_WAIT_GRACE, cap)) then
            State.spot = nil; State.fsm = "DECIDE"; State.moveSince = nil
            logline("wave_move timeout -> redecide"); return
        end
    end
    -- LIVE TETHER (v0.1.173, run-11 "stuck high in the lane waiting for the next waves"): parked
    -- at a deep stand Tinker SELF-PROVIDES vision, so the next wave is always visible, the fogged
    -- tether never engages, and the at-stand hold waited 25s+ per wave in enemy territory. Same
    -- doctrine here: when the wave needs longer to close to engage range than the walk to the
    -- stand, wait at the protected spot and step out arrival-timed. 325 = base lane-creep speed
    -- (Liquipedia); ignoring our own approach speed errs a touch early, bounded by STEP_OUT_LEAD.
    if not s.steppedOut then
        local ms0 = (NPC.GetMoveSpeed and NPC.GetMoveSpeed(State.hero)) or 320
        local walk_s = me:Distance(s.standSpot.stand) / math.max(150, ms0)
        -- v0.1.211: ladder-aware raid transit (see the fogged twin above).
        if raidok then
            local tr = ready(State.keen) and (K.KEEN_CHANNEL + 1.0)
                       or (ready(State.rearm) and rearm_channel() + K.KEEN_CHANNEL + 1.0 or nil)
            if tr then walk_s = math.min(walk_s, tr) end
        end
        local close_s = math.max(0, dref - K.WAVE_ENGAGE_RANGE) / 325
        -- v0.1.213 THE TIMED MEETING RAID (3-patch klvl2 lane starvation, run-36 census): close_s
        -- models THEIR wave walking to OUR stand at 325, but at the deep meeting the fight STALLS
        -- it (measured advance ~130) - it never "closes", the tether releases forever, and the wave
        -- dies unseen to our creeps during the windows. The sim's meeting time (s.meetEta = when
        -- their wave reaches the collision point = fight start) is the GPM-first pre-empt target:
        -- step out for the EARLIER of close-to-stand or the meeting, so the raid keen lands as the
        -- waves collide, before our creeps eat the farm.
        local meet_s = s.meetEta and math.max(0, s.meetEta - now()) or nil
        -- v0.1.218 (run-41 tail t=760-796: releases with NO raids after, all commits bal<0 - the
        -- v0.1.216 gate correctly dropped meet_s for LOSING fights, but close_s STALLS during the
        -- fight and the scheduler's own fight-end arrival [asrc=sim = the bal<0 farmable moment,
        -- their remnant emerges] was never consulted by the live tether): eff_s = the earliest of
        -- close-to-stand / the meeting (winning) / the fight end (losing).
        local sim_s = (s.waveAsrc == "sim") and s.waveEta and math.max(0, s.waveEta - now()) or nil
        local eff_s = math.min(close_s, meet_s or math.huge, sim_s or math.huge)
        if eff_s > walk_s + K.STEP_OUT_LEAD then
            -- v0.1.208: same release as the fogged tether (run-33: the last log event was THIS
            -- hold at the fountain with eta=live+32.8 - an eternal wait; the window fits a camp).
            -- v0.1.213: the wait is against the PRE-EMPT time (eff_s), so a release window always
            -- ends before the meeting step-out, not before the (stalling) close-to-stand.
            local wait_s = eff_s - walk_s - K.STEP_OUT_LEAD
            if wait_s > K.TETHER_MAX_HOLD_S and now() >= (State.releaseBlockUntil or 0) then
                suppress_shove(s.lane, now() + math.min(wait_s - 2, 25))
                State.spot = nil; State.fsm = "DECIDE"; State.moveSince = nil
                logline(string.format("tether release wait=%.1f -> jungle window", wait_s))
                return
            end
            -- (review v0.1.178: tether spot cached per commit - the nearest friendly structure
            -- cannot change within one; the per-tick full-structure scan was pure waste. And NO
            -- moveSince refresh here: MOVE_TIMEOUT is the live branch's only long-stall exit - a
            -- far stalemate creep fight held close_s high FOREVER, and refreshing moveSince made
            -- the tether an idle trap; after 25s the redecide re-plans the window (maybe a camp).)
            if not s.tetherSpot then
                s.tetherSpot = protected_wait_spot({ x = s.standSpot.stand.x, y = s.standSpot.stand.y })
                -- v0.1.207 (run-32 t=828: the keen->structure->rearm->keen->creep chain SURVIVED
                -- v0.1.206 because only the FOGGED tether was fixed - this LIVE tether is its twin
                -- and kept the v0.1.194 far-leg keen ladder): same cure - the raid keen is GLOBAL,
                -- a far hold buys nothing; wait at a protected spot near the HERO and keen straight
                -- onto the creep at step-out.
                local msT = (NPC.GetMoveSpeed and NPC.GetMoveSpeed(State.hero)) or 320
                if raidok and me:Distance(Vector(s.tetherSpot.x, s.tetherSpot.y, me.z))
                              / math.max(150, msT) > K.TETHER_WALK_MAX_S then
                    s.tetherSpot = protected_wait_spot({ x = me.x, y = me.y })
                end
            end
            local hv = Vector(s.tetherSpot.x, s.tetherSpot.y, me.z)
            if not s.tetherLogged then
                s.tetherLogged = true
                logline(string.format("tether hold=(%.0f,%.0f) d=%.0f eta=live+%.1f", s.tetherSpot.x, s.tetherSpot.y,
                    me:Distance(s.standSpot.stand), close_s))
            end
            -- v0.1.223 (user overlay sighting): the label showed close_s (~36s) for holds that
            -- step out in ~5s on the meeting/fight-end clock - display the EFFECTIVE wait.
            State.waitInfo = { why = string.format("tether %ds", math.floor(eff_s)), t = now() }
            -- v0.1.214: same pre-arm as the fogged twin (the hold is the protected rearm window).
            if raidok and not ready(State.keen) and safe_rearm() then
                logline("tether prearm_rearm"); return
            end
            -- v0.1.188: same as the fogged tether - a raid-capable hold WALKS (preserve keen+rearm
            -- for the creep hop at step-out; the teleport goes there from anywhere).
            if me:Distance(hv) > K.WAVE_HOLD_EPS then
                -- v0.1.207: raid legs ALWAYS walk (local by construction above; keen preserved
                -- for the direct creep hop). Non-raid legs keep the ladder.
                if raidok then move_to(hv, "tether_hold_live") else lane_go(hv) end
            end
            return
        end
        s.steppedOut = true
        State.keenedSpot = false                             -- v0.1.175: same re-arm as the fogged step-out (the tether leg may have spent the keen)
        logline(string.format("step_out live close=%.1f meet=%s sim=%s walk=%.1f", close_s,
            meet_s and string.format("%.1f", meet_s) or "-",
            sim_s and string.format("%.1f", sim_s) or "-", walk_s))
    end
    -- Piece 0: clamp + ladder own the whole leg. HOLD-STILL (v0.1.153): once AT the stand
    -- (watching the wave close), issue NO more movement - re-ordering move_to every tick
    -- twitched Tinker in place (move, cancel, move).
    if me:Distance(s.standSpot.stand) > K.WAVE_HOLD_EPS then
        -- RAID (Phase 2 R1): the LIVE-wave approach is where the run-10 deep walks lived (visible
        -- commits, travel 15-19s, residual 2300+) - at Keen L2 keen onto a creep near the stand.
        lane_go(s.standSpot.stand, raidok)
    else
        State.waitInfo = { why = string.format("wave closing %d", math.floor(dref)), t = now() }   -- v0.1.163: at the stand, waiting for reach
    end
end

-- Part A (N3): a committed camp trip does not re-check enemy risk en route, so an
-- enemy rotating onto a normally-safe camp could catch Tinker (HP panic is too late
-- vs burst). Refresh the LIVE fog-aware snapshot and bail+skip if the stand turned
-- dangerous. Only camps: the wave/shove paths are gated by the schedule (COR-1).
local function camp_unsafe_abort(s, where)
    local ss = s.standSpot
    local pt = (ss and ss.stand) or s.center
    if not pt then return false end
    State.fog = enemy_snapshot()                            -- live (the decide-time snapshot is stale by now)
    local r = enemy_risk_at(pt)
    if r >= K.FARM_SAFE_RISK then
        try_escape_blink()                              -- primary: flee by blink BEFORE the burst; recover regardless
        mark_spot_cleared(s); go_return()
        logline(string.format("%s abort reason=unsafe risk=%.2f", where, r))
        return true
    end
    return false
end

local function fsm_move()
    keen_cancel_check()   -- v0.1.216: a canceled keen re-arms the ladder (rearm -> keen), never a deep walk
    local s = State.spot
    if not s then State.fsm = "DECIDE"; State.moveSince = nil; return end
    if s.kind == "wave" then return fsm_move_wave(s) end
    if camp_unsafe_abort(s, "move") then return end
    local ss = s.standSpot
    local stand = ss.stand
    local me0 = origin(State.hero)
    local d = me0:Distance(stand)
    local aim = ss.aim or s.center                           -- the March cast point (pair midpoint / camp centre)
    local dCast = me0:Distance(aim)
    -- AREA, not a point: the valid stand is the whole zone from which March's square covers the camp. ENGAGE
    -- as soon as that holds (no exact-point requirement - that was the "stuck" cause). For a PAIR, require
    -- BOTH camps within March reach (R1) so standing in the MIDDLE covers both, not just the near one.
    local engage_ok
    if ss.paired and ss.partner then
        -- THE BOX = a THIN RECTANGLE aligned to the camp axis (A->B), centred on the midpoint: tight ALONG
        -- the axis (moving there shifts the perpendicular W's width off a camp), roomy PERPENDICULAR (the
        -- cast direction; both camps stay covered). Same for every pair now (no walkable/fallback split).
        local ux, uy = ss.partner.x - s.center.x, ss.partner.y - s.center.y
        local ul = math.sqrt(ux * ux + uy * uy); if ul < 1 then ul = 1 end
        ux, uy = ux / ul, uy / ul
        local ox, oy = me0.x - aim.x, me0.y - aim.y
        local along = math.abs(ox * ux + oy * uy)
        local perp  = math.abs(-ox * uy + oy * ux)
        engage_ok = d <= K.ARRIVE_DIST or (along <= K.BOX_ALONG and perp <= K.BOX_PERP)
    else
        engage_ok = d <= K.ARRIVE_DIST or dCast <= K.ENGAGE_COVER_DIST
    end
    if engage_ok then
        State.fsm = "ENGAGE"; State.moveSince = nil
        State.emptySince = nil
        State.engageStart = now()                   -- timing calib: mark the clear start (vs clearEst)
        State.engageMana  = mana()                  -- v0.1.212 cost-truth census: raw mana at clear start
        logline(string.format("engage_arrived d=%.0f dCast=%.0f", d, dCast)); return
    end
    -- P0 watchdog: are we actually closing toward the stand? A far keen landing (d2stand large) onto
    -- terrain we cannot path through leaves the hero walking in place -> never arrives, never times out
    -- in time. If distance has not improved for NO_PROGRESS_S, treat the stand as unreachable: mark the
    -- camp cleared (skip until respawn) and re-decide.
    if no_progress(d) then
        mark_spot_cleared(s)
        State.spot = nil; State.fsm = "DECIDE"; State.moveSince = nil
        logline(string.format("move stuck d=%.0f -> redecide+cleared", d)); return
    end
    if State.moveSince and now() - State.moveSince > K.MOVE_TIMEOUT then  -- can't reach: re-decide
        State.spot = nil; State.fsm = "DECIDE"; State.moveSince = nil; return
    end
    -- ONE Keen hop toward the camp (if a closer anchor exists), THEN walk the rest.
    if d > K.KEEN_TRAVEL_MIN and not State.keenedSpot then
        if ready(State.keen) then
            if keen_to_anchor(stand) then
                State.keenedSpot = true; logline("move keen_to_anchor"); return
            end
            State.keenedSpot = true            -- no useful anchor hop: just walk from here
        elseif try_travel_blink(stand) then
            -- v0.1.209 (user FINAL: "use blink whenever it is safe"): NO distance gate - Keen on
            -- cd means blink NOW (shaves ~1150 instantly); if the trek is still long the next
            -- tick's rearm-reset continues it, and for gaps under ~3500 the blink+walk REPLACES
            -- the whole rearm(~375 mana)+keen transit outright.
            return
        elseif safe_rearm() then               -- Keen on cd: Rearm once to reset it (safe: not under enemy pressure)
            logline("move rearm_reset_keen"); return
        end
    end
    if try_travel_blink(stand) then return end   -- blink the remaining gap when safe + ready
    if origin(State.hero):Distance(stand) <= K.WAVE_HOLD_EPS then return end   -- v0.1.244: at the stand = no order (the at-destination shuffle fix, same as lane_walk)
    move_to(stand, "move_stand")
end

-- Wave ENGAGE: Tinker Marches the LIVE creep cluster from the safe stand. Re-track the wave each tick
-- (it moves); if it drifts out of March reach go back to MOVE to reposition; if it is gone, bail after
-- a brief grace. Same fire-gated March budget as camps, but Rearm is SAFE-gated (Note 3) and the aim
-- follows the live centroid clamped to cast range (Note 2). (Notes 1-3.)
local function fsm_engage_wave(s)
    State.fog = enemy_snapshot()                       -- fresh risk for safe_rearm
    local live = update_wave_spot(s)
    if not live then                                    -- wave gone (cleared / left): brief grace then done
        -- v0.1.242 W-CANCEL (user feature): a March still WINDING UP (order issued, cast not
        -- fired - the turn + 0.53s cast point window) would land on nothing now that the last
        -- creep died. Cancel the order (a move to self interrupts the wind-up) and keep the
        -- ~160-190 mana. Already-fired = uncancelable (robots out): resolve the count as usual.
        -- issue() swallowed by ORDER_GAP -> pending stays, retry next tick (the .234 lesson).
        local mp0 = State.marchPending
        if mp0 then
            if (not ready(State.march)) or cd_remaining(State.march) > mp0.cdBefore + 0.05 then
                State.marchCasts = State.marchCasts + 1; State.marchPending = nil
                logline("march cast=" .. State.marchCasts)
            else
                local me0 = origin(State.hero)
                if issue(UO.DOTA_UNIT_ORDER_MOVE_TO_POSITION, nil, nil, me0) then   -- bypass move_to: the dedup must not eat the cancel
                    State.marchPending = nil
                    logline("march_cancel reason=empty src=wave")
                end
            end
        end
        State.emptySince = State.emptySince or now()
        if now() - State.emptySince > K.ENGAGE_EMPTY_GRACE then
            -- cadence anchor: NextWaveArrival treats this as the ARRIVAL phase. Best source first:
            -- the OBSERVED arrival (waveLiveT, note 2) > the frozen kinematic estimate (waveEta;
            -- accurate for real fronts, ~13s early for fogged mirrors) > the death time (F1 bias).
            if s.shove then State.laneWaveT[s.lane or K.HOME_LANE] = s.waveLiveT or s.waveEta or now() end   -- PHASE 2: every lane stamps ITS OWN cadence anchor (the .225 shared-slot corruption is gone - lanes no longer share one slot)
            logline("engage_done reason=wave_clear casts=" .. tostring(State.marchCasts))
            engage_replan()
            return
        end
        return
    end
    State.emptySince = nil
    local me = origin(State.hero)
    -- Note 5: live-risk ABORT in the ENGAGE (the MOVE path got this in v0.1.67; the engage did not).
    -- When March is on cd AND an enemy collapses, safe_rearm is blocked by proximity, so Tinker would
    -- stand in ENGAGE doing nothing until killed. Flee by blink BEFORE the burst, then recover.
    local erisk = enemy_risk_at(me)
    -- (the v0.1.123 live too_deep abort was REMOVED 2026-07-01 with the depth-veto patch family.)
    if lane_unsafe(me) then                             -- v0.1.94: count+HP aware (a healthy 1v1 keeps farming, not flees)
        logline(string.format("wave_engage abort reason=unsafe risk=%.2f", erisk))
        try_escape_blink()
        if s.shove then suppress_shove(s.lane, now() + K.SHOVE_STUCK_S) end
        go_return(); return
    end
    if me:Distance(s.refPoint) > K.WAVE_ENGAGE_RANGE + 250 then   -- wave drifted out of reach: reposition
        State.fsm = "MOVE"; State.moveSince = now(); State.keenedSpot = false
        logline("wave_engage reposition dWave=" .. math.floor(me:Distance(s.refPoint))); return
    end
    if mana() < State.menu.escapeMana:Get() then
        logline("engage_bail reason=mana mana=" .. math.floor(mana())); go_return(); return
    end
    local mp = State.marchPending                       -- resolve a March in flight (fire-gate, as camps)
    if mp then
        if (not ready(State.march)) or cd_remaining(State.march) > mp.cdBefore + 0.05 then
            State.marchCasts = State.marchCasts + 1; State.marchPending = nil
            logline("march cast=" .. State.marchCasts)
        elseif now() > mp.expire then
            State.marchPending = nil; logline("march issued_NOT_fired_retry")
        else
            return
        end
    end
    -- D3: a shove exits at its computed casts (Schedule.ClearTime); the wave-clear exit above covers dead.
    -- "Marches: lane wave (max W)" HUD slider caps the per-clear W count so a big / over-estimated lane
    -- wave can't burn endless March. Live-read; falls back to K.WAVE_MAX_W if the menu isn't ready.
    local maxw = (State.menu and State.menu.waveMaxW and State.menu.waveMaxW:Get()) or K.WAVE_MAX_W
    -- v0.1.190 (user HARD RULE): waves cap at 2 casts ABSOLUTE - a 3rd W was observed killing
    -- nothing (per the per-creep model, 2 casts + the rear sweep + allied creeps finish any wave).
    -- Clamped in code so a stale persisted slider value can never exceed it.
    local wbudget = math.min(s.shoveCasts or maxw, maxw, 2)
    if State.marchCasts >= wbudget then
        -- cadence anchor on the BUDGET exit too (v0.1.171): our creeps finish the remnant, so a
        -- healthy game can end EVERY shove on budget and never reach the wave_clear stamp below -
        -- run-9 had 17/17 budget exits, lastWaveT stayed nil all game, and the whole tether chain
        -- (asrc=stamp accurate slack -> camps fit; step_out) never armed. Same source order.
        if s.shove then State.laneWaveT[s.lane or K.HOME_LANE] = s.waveLiveT or s.waveEta or now() end   -- PHASE 2: every lane stamps ITS OWN cadence anchor (the .225 shared-slot corruption is gone - lanes no longer share one slot)
        -- v0.1.197 (run-26 t=21.9, user: "you broke the hard limit for 2 W on waves"): the robots
        -- from the 2 budget casts deliver over ~6s, so at the instant redecide the SAME wave still
        -- reads near-full (eff_hp 1461) -> re-picked -> Rearm resets March -> a 3rd W + a ~225
        -- rearm burned on a wave already paid for (mana hit 44 -> fountain). Suppress the re-shove
        -- for the delivery window; the wave dies to the in-flight robots + allied creeps, and the
        -- planner farms the gap. The 2-cast clamp is per-WAVE now, not per-engage.
        if s.shove then suppress_shove(s.lane, now() + K.SHOVE_STUCK_S) end
        logline(string.format("engage_done reason=budget casts=%d lane=%s shove",
            State.marchCasts, tostring(s.lane)))
        engage_replan()
        return
    end
    if ready(State.march) then
        local aim = s.standSpot.aim
        local maxr = (K.MARCH_CAST_RANGE or 300) - 20
        -- THE lane W pattern (v0.1.166 user design; v0.1.173 fixed after the run-11 report "both
        -- marches in the same direction"): ONE cast builder, two placements, alternating per cast.
        --   FRONT  (even casts): the box AT the wave - tgt = aim (the span-center/ranged from
        --     update_wave_spot) +- a perp wiggle whose SIDE alternates across successive front
        --     casts. Robots spawn on OUR side and sweep INTO the wave's front line.
        --   BEHIND (odd casts): tgt = W_BEHIND_BACKSTEP BEHIND the hero (opposite the wave) -
        --     the facing FLIPS, so the robots spawn at the box's far edge (beyond the wave) and
        --     sweep BACK through it: the enemy REAR (the ranged) eats them first. (v0.1.166-172
        --     targeted aim+350 PAST the wave, but the cast-range clamp collapsed that onto the
        --     same forward ray as the front cast = two identical casts, the run-11 sighting.)
        --     Only when the spawn edge clears the wave (dref + CREEP_DISC <= 900 - backstep),
        --     else this cast falls back to the front placement.
        local ldir = Lane.PathTangent((lane_paths() or {})[s.lane or K.HOME_LANE], { x = aim.x, y = aim.y })
                     or lane_push_dirs()                         -- fallback: enemy creeps' travel dir
        -- v0.1.176 (run-14 census: 20 front / 2 behind, "some casts still only forward"): the
        -- alternation is a GLOBAL latch now (State.wantBehind), not marchCasts parity - the parity
        -- reset to FRONT on every commit (the far timed cast + the near re-commit = two fronts in a
        -- row every wave), and an ineligible behind LOST its turn. Now: an ineligible behind casts
        -- front but KEEPS wanting behind, so the rear sweep fires on the first eligible cast.
        local behind = State.wantBehind and true or false
        if behind and me:Distance(aim) + K.W_BEHIND_CLEAR > K.MARCH_LEN / 2 - K.W_BEHIND_BACKSTEP then
            -- v0.1.195 (user, run-25: "at center meetings ALL W cast front" - 30F/5B): from the
            -- 850-forward stand the rear sweep is GEOMETRICALLY impossible (spawn edge = me +
            -- 900 - backstep ~ 840 < aim ~850+), and a wave HELD at the meeting never closes,
            -- so the wantBehind latch starved. A due-but-ineligible behind now STEPS IN to the
            -- eligibility edge and casts from there next tick, instead of burning the turn on
            -- another front. Bounded: near shortfall only (aim <= STEPIN_MAX), safe point only,
            -- single-direction nudge inside ENGAGE - the v0.1.119 chase loop cannot re-form.
            local dref0 = me:Distance(aim)
            local stepped = false
            if dref0 <= K.W_BEHIND_STEPIN_MAX then
                local need = dref0 - (K.MARCH_LEN / 2 - K.W_BEHIND_BACKSTEP - K.W_BEHIND_CLEAR) + 40
                local dxs, dys = aim.x - me.x, aim.y - me.y
                local dls = math.sqrt(dxs * dxs + dys * dys)
                if dls > 1 and need > 0 then
                    local sp = { x = me.x + dxs / dls * need, y = me.y + dys / dls * need }
                    -- v0.1.198 audit HOLE A: the step-in obeys the walk law like every other
                    -- lane destination - a deep aim must never nudge him past the line.
                    local dok2 = s.shove and ((State.keen and Ability.GetLevel and Ability.GetLevel(State.keen)) or 0) >= 2
                    if not lane_unsafe(sp) and (dok2 or (stand_depth(sp) <= K.WALK_DEPTH_MAX and lane_leash_ok(sp))) then   -- v0.1.202: dok2 (raid-capable shove) exempts the leash for the in-engage nudge too
                        move_to(Vector(sp.x, sp.y, me.z), "stepin_w")
                        State.waitInfo = { why = "step-in W", t = now() }
                        stepped = true
                    end
                end
            end
            if stepped then return end
            behind = false                                       -- can't step in (far / unsafe): front now, retry behind next cast
        end
        -- v0.1.221 (user: "moved mid... to farm nothing - most likely the creeps being at the
        -- edge of march"): the 950 arrival trigger casts immediately at the ~300 clamp, putting
        -- the wave at the W's FAR EDGE (run-44: dWave 936-966 at cast = partial/zero kills).
        -- Hold the FRONT cast until the wave closes to W_FRONT_MAX, bounded by W_EDGE_DELAY_S so
        -- a stalling/retreating wave still gets served rather than out-waited.
        if not behind then
            local dWaveNow = me:Distance(s.refPoint)
            if dWaveNow > K.W_FRONT_MAX then
                s.castDelayUntil = s.castDelayUntil or (now() + K.W_EDGE_DELAY_S)
                if now() < s.castDelayUntil then
                    State.waitInfo = { why = string.format("W edge %d", math.floor(dWaveNow)), t = now() }
                    return
                end
            end
        end
        local tgt
        if behind then
            local dx, dy = aim.x - me.x, aim.y - me.y
            local dl = math.sqrt(dx * dx + dy * dy)
            if dl > 1 then
                tgt = Vector(me.x - dx / dl * K.W_BEHIND_BACKSTEP, me.y - dy / dl * K.W_BEHIND_BACKSTEP, aim.z)
            else
                tgt = Vector(aim.x, aim.y, aim.z)
            end
        else
            local lx, ly = ldir.x or 0, ldir.y or 0
            local ll = math.sqrt(lx * lx + ly * ly)
            local px, py = 0, 0
            if ll >= 1e-6 then px, py = -ly / ll, lx / ll end
            local side = ((math.floor(State.marchCasts / 2) % 2) == 0) and 1 or -1   -- alternate the wiggle side across FRONT casts
            tgt = Vector(aim.x + px * K.MULTI_W_OFFSET * side, aim.y + py * K.MULTI_W_OFFSET * side, aim.z)
        end
        local cp = (me:Distance(tgt) > maxr) and (me + (tgt - me):Normalized() * maxr) or tgt
        if cast_pos(State.march, cp) then
            State.marchPending = { cdBefore = cd_remaining(State.march), expire = now() + 1.5 }
            -- flip the latch: behind fired -> want front; front fired AS INTENDED -> want behind;
            -- front fired as an ineligible-behind FALLBACK -> keep wanting behind (retry next cast).
            if behind then State.wantBehind = false
            elseif not State.wantBehind then State.wantBehind = true end
            logline(string.format("march_aim src=shove pat=%s lane=%s wave=(%.0f,%.0f) cast=(%.0f,%.0f) creeps=%d dWave=%.0f",
                behind and "behind" or "front", tostring(s.lane), live.cx, live.cy, cp.x, cp.y, live.n, me:Distance(s.refPoint)))
        end
    elseif effective_mana() < abil_mana(State.rearm, K.REARM_MANA_FB) + abil_mana(State.march, K.MARCH_MANA_FB) then
        -- v0.1.200 guard (run-28 t=483, belt to the hop-gate fix): in a WAVE engage Rearm exists
        -- only to reset March, so rearming when the FOLLOW-UP March is not fundable (even with
        -- charges) burns ~225 and strands him castless. Bail with the trip home still funded.
        logline(string.format("engage_bail reason=rearm_unfundable mana=%.0f", effective_mana()))
        if s.shove then suppress_shove(s.lane, now() + K.SHOVE_STUCK_S) end
        go_return()
    elseif safe_rearm() then
        logline("rearm")
    end
end

-- F1: live effective HP of the engaged camp (+ its pair partner) for the stack-
-- aware budget. Summed from the in-vision creeps, so stacks are included.
local function live_camp_ehp(s, neutrals)
    local e = Farm.EffectiveHP(camp_creep_list(s.camp, s.type, neutrals))
    local ss = s.standSpot
    if ss and ss.paired and ss.partnerCamp then
        -- one perpendicular W spans BOTH camps, so the clear budget is the TANKIER camp (MAX), NOT the sum
        -- (the v0.1.103 pair model, which the valuation already uses). Summing over-budgeted the execution
        -- -> extra Marches = wasted mana + time (bug: more marches than needed / mana starve without Bottle).
        -- The clip lean-in (CLIP_EXTRA_MARCHES on `base`) still covers a far camp whose outer creeps spill.
        local ep = Farm.EffectiveHP(camp_creep_list(ss.partnerCamp, ss.partnerType or s.type, neutrals))
        e = math.max(e, ep)
    end
    return e
end

-- Is this engage an ANCIENT camp (itself or its pair partner)? Ancients = tier 3.
local function ancient_engage(s)
    if s.type == 3 then return true end
    local ss = s.standSpot
    return ss and ss.paired and ss.partnerType == 3 or false
end

-- Laser target (v0.1.201, user): ONLY the ancient camp's TOUGHEST creep (highest MAX HP - the one
-- that outlives the March budget), and only as a FINISHER (current hp <= killhp = one-shot range).
-- The old any-killable-creep last-hit fired 33x on 104-216hp small fry in run-29 (~4k mana across
-- the game) - March's sweep kills those for free; the laser saved nothing and drained every
-- ancient clear. Pure damage -> killhp is the flat per-level value, no armor/MR adjust.
local function laser_lasthit_target(s, neutrals, killhp)
    local best, bestmax = nil, -1
    local function scan(camp)
        for _, c in ipairs(Map.CampCreeps(camp, neutrals) or {}) do
            local hp = (Entity.GetHealth and Entity.GetHealth(c)) or 0
            local mhp = (Entity.GetMaxHealth and Entity.GetMaxHealth(c)) or 0
            if hp > 0 and mhp > bestmax then bestmax, best = mhp, c end
        end
    end
    if s.type == 3 then scan(s.camp) end
    if s.standSpot.paired and s.standSpot.partnerType == 3 and s.standSpot.partnerCamp then
        scan(s.standSpot.partnerCamp)
    end
    local hp = best and ((Entity.GetHealth and Entity.GetHealth(best)) or 0) or 0
    return (best and hp > 0 and hp <= killhp) and best or nil
end

-- v0.1.224 STACK engage (user: large camps, 2x, GPM-first): hold at the stand until the aggro
-- second, ATTACK one camp creep (they chase), drag them toward our fountain until just past the
-- :00 respawn, then release to the planner. No mark_cleared (the camp respawns STACKED; the
-- stack-aware budget clears it next visit). The fsm_engage leave_by preempt runs BEFORE this
-- (waves always win); camp_unsafe_abort covers live danger.
local function fsm_engage_stack(s)
    State.fog = enemy_snapshot()
    if camp_unsafe_abort(s, "stack") then return end
    local me = origin(State.hero)
    if now() >= s.fleeUntil then
        logline(string.format("stack_done key=%s", tostring(s.key)))
        State.spot = nil; State.fsm = "DECIDE"; State.moveSince = nil
        return
    end
    if now() < s.aggroAt then
        State.waitInfo = { why = string.format("stack %ds", math.max(0, math.floor(s.aggroAt - now()))), t = now() }
        if me:Distance(s.standSpot.stand) > K.WAVE_HOLD_EPS then move_to(s.standSpot.stand, "engage_hold") end
        return
    end
    if not s.aggroed then
        local tgt
        for _, c in ipairs(Map.CampCreeps(s.camp, Map.AllNeutrals()) or {}) do tgt = c; break end
        if not tgt then
            logline("stack_abort empty")
            State.spot = nil; State.fsm = "DECIDE"; State.moveSince = nil
            return
        end
        if issue(UO.DOTA_UNIT_ORDER_ATTACK_TARGET, nil, tgt, nil) then
            s.aggroed = true
            logline(string.format("stack_aggro key=%s sec=%.1f", tostring(s.key), now() % 60))
        end
        return
    end
    -- dragging: away from the camp toward our fountain until the respawn tick passes
    local fp = friendly_fountain_pos()
    if fp then
        local dx, dy = fp.x - s.center.x, fp.y - s.center.y
        local dl = math.sqrt(dx * dx + dy * dy); if dl < 1 then dl = 1 end
        local r = K.STACK_STAND_DIST + K.STACK_FLEE_DIST
        move_to(Vector(s.center.x + dx / dl * r, s.center.y + dy / dl * r, me.z), "stack_drag")
    end
    State.waitInfo = { why = "stack drag", t = now() }
end

local function fsm_engage()
    local s = State.spot
    if not s then go_return(); return end
    if s.kind == "wave" then return fsm_engage_wave(s) end
    -- Note 3: preempt to mid the moment the shove leave-by passes - UNCONDITIONAL (was only checked
    -- after a March resolved, so a stalled/long camp never bailed -> Tinker missed the wave / lost
    -- the lane). Heading to mid on time keeps the lane served.
    if State.shoveLeaveBy and now() >= State.shoveLeaveBy then
        logline("engage_preempt reason=leave_by casts=" .. tostring(State.marchCasts or 0))
        engage_replan(); return
    end
    if s.kind == "stack" then return fsm_engage_stack(s) end   -- v0.1.224 (after the leave_by preempt: waves always win)
    if camp_unsafe_abort(s, "engage") then return end
    -- Occupancy debounce: do NOT abandon the camp the instant occupancy reads false.
    -- The hero now stands ~STAND_RING from the centre (in vision), but creeps move
    -- and die so occupancy still flickers; bail only on SUSTAINED emptiness (really
    -- cleared / gone), low mana, or the budget being done. Log the bail reason.
    -- Pair-aware occupancy: enumerate neutrals ONCE, then box-check both camps. A pair is
    -- "done empty" only when BOTH camps are empty (from the midpoint both centres are in
    -- vision, so the reads are valid); a single spot just checks s.camp. This keeps the lean-in
    -- clip Marches firing instead of bailing the instant the near camp empties first.
    local neutrals = Map.AllNeutrals()
    -- #4: refresh the value cache from the LIVE box each tick, so a camp left partially farmed then fogged
    -- carries its true remaining bounty (alive creeps) with NO contaminated gold-delta. gather_candidates
    -- only reads at DECIDE; this closes the DURING-engage gap (kill 2 creeps -> keen home -> fog before the
    -- next decide would leave the cache at the pre-engage value).
    local function refresh_value(camp, ctype, center)
        local list = camp_creep_list(camp, ctype, neutrals)
        State.campSeen[camp_key(center)] = { gold = Farm.GoldValue(list), ehp = Farm.EffectiveHP(list), seen_at = now() }
    end
    refresh_value(s.camp, s.type, s.center)
    if s.standSpot.paired and s.standSpot.partnerCamp then
        refresh_value(s.standSpot.partnerCamp, s.standSpot.partnerType or s.type, s.standSpot.partner)
    end
    local occupied = #Map.CampCreeps(s.camp, neutrals) > 0
    if s.standSpot.paired and s.standSpot.partnerCamp then
        occupied = occupied or #Map.CampCreeps(s.standSpot.partnerCamp, neutrals) > 0
    end
    if occupied then
        State.emptySince = nil
        s.campEhp = s.campEhp or live_camp_ehp(s, neutrals)   -- F1: snapshot the FULL (stacked) ehp once for the stack-aware budget
    else
        State.emptySince = State.emptySince or now()
        -- v0.1.242 W-CANCEL (camps, user feature): same as the wave cancel, but only past the
        -- MIN_CASTS_BEFORE_EMPTY debounce - creeps aggro OUT of the box after the first cast
        -- (the A-flicker below), and canceling on that false empty would drop a real W.
        local mp0 = State.marchPending
        if mp0 and (State.marchCasts or 0) >= K.MIN_CASTS_BEFORE_EMPTY then
            if (not ready(State.march)) or cd_remaining(State.march) > mp0.cdBefore + 0.05 then
                State.marchCasts = State.marchCasts + 1; State.marchPending = nil
                logline("march cast=" .. State.marchCasts)
            else
                local me0 = origin(State.hero)
                if issue(UO.DOTA_UNIT_ORDER_MOVE_TO_POSITION, nil, nil, me0) then   -- bypass move_to: the dedup must not eat the cancel
                    State.marchPending = nil
                    logline("march_cancel reason=empty src=camp")
                end
            end
        end
        -- A: don't abort on the FIRST occupancy flicker. Creeps aggro out of the camp box right after the
        -- first March, so a 1-cast read=empty bailed with the creeps still alive (got=6). Require at least
        -- MIN_CASTS_BEFORE_EMPTY fired Marches before honouring "empty" (a genuinely empty camp just wastes
        -- one extra cast, then clears out as before).
        if now() - State.emptySince > K.ENGAGE_EMPTY_GRACE and (State.marchCasts or 0) >= K.MIN_CASTS_BEFORE_EMPTY then
            mark_spot_cleared(s)   -- verified empty: skip until the next respawn so we spread, not loop
            logline(string.format("engage_done reason=empty casts=%d dur=%.1f est=%.1f", State.marchCasts or 0,
                now() - (State.engageStart or now()), s.clearEst or 0)); engage_replan(); return
        end
    end
    if mana() < State.menu.escapeMana:Get() then
        logline("engage_bail reason=mana mana=" .. math.floor(mana())); go_return(); return
    end
    -- Resolve a March in flight: count it ONLY when it verifiably FIRED (cooldown
    -- jump / no longer ready), and never re-issue mid-wind-up (a re-issue restarts
    -- March's cast point and can cancel it). The scope-A loop incremented on ISSUE
    -- and re-issued every ~0.05s, so the budget raced ahead of the real casts (3
    -- phantom marches before one fired) and the camp was abandoned to RETURN before
    -- Rearm ever fired. With fire-gating, Rearm fires between Marches.
    local mp = State.marchPending
    if mp then
        if (not ready(State.march)) or cd_remaining(State.march) > mp.cdBefore + 0.05 then
            State.marchCasts = State.marchCasts + 1
            State.marchPending = nil
            logline("march cast=" .. State.marchCasts)
            -- (leave-by preempt now checked unconditionally at the top of fsm_engage, note 3)
        elseif now() > mp.expire then
            State.marchPending = nil
            logline("march issued_NOT_fired_retry")
        else
            return   -- still winding up: wait, do not re-issue
        end
    end
    -- N4 (COR-03 remaining half): budget on the TANKIER of the two camps. The pair midpoint
    -- cast covers both, but a tanky ANCIENT partner needs more Marches than the near camp's
    -- tier; keying to s.type alone under-budgeted it, so the ancient never cleared (got~0).
    local btype = s.type
    if s.standSpot.paired and s.standSpot.partnerType and s.standSpot.partnerType > btype then
        btype = s.standSpot.partnerType
    end
    local base = marches_for(btype)
    if s.standSpot.paired and s.standSpot.clear == "clip" then
        base = base + K.CLIP_EXTRA_MARCHES   -- lean-in: extra Marches to finish a clip pair's spilled outer creeps
    end
    -- F1: stack-aware. The pair's live ehp (stacks included) can need more Marches than
    -- the per-tier base; ClearBudget raises the count for a stacked camp but NEVER below
    -- `base` (no regression on a normal camp).
    -- #1: cap the clear at MAX_CLEAR_MARCHES (+ the clip lean-in) so a huge live stack can't grind forever
    -- (candidacy already gated est-ehp within the cap; a bigger live ehp part-clears then re-opens at respawn).
    local budget = math.min(K.MAX_CLEAR_MARCHES + K.CLIP_EXTRA_MARCHES, Farm.ClearBudget(base, s.campEhp or 0, effective_march_dmg()))
    if State.marchCasts >= budget then
        mark_spot_cleared(s)   -- did the budget here: move on (re-open at the next respawn), do not re-pick it
        logline(string.format("engage_done reason=budget casts=%d budget=%d dur=%.1f est=%.1f%s", State.marchCasts, budget,
            now() - (State.engageStart or now()), s.clearEst or 0,
            (s.standSpot.paired and (" pair=" .. tostring(s.standSpot.clear))) or "")); engage_replan(); return
    end
    -- ANCIENT: LAST-HIT ONLY (user). March AoEs the whole camp; Laser is single-target, so only fire it to
    -- FINISH a creep already in one-shot range (hp <= LASER_DMG) rather than spamming a full-HP tank. On a
    -- tanky ancient March leaves creeps low, so this still saves Marches, without the wasted early casts.
    if ancient_engage(s) and ready(State.laser)
       and mana() >= State.menu.escapeMana:Get() + abil_mana(State.laser, K.LASER_MANA_FB) then
        local killhp = K.LASER_DMG[(State.laser and Ability.GetLevel(State.laser)) or 0] or 0
        -- v0.1.187: live KV read (special "laser_damage", gitbook GetLevelSpecialValueFor) beats
        -- the table when present - patch-proof, same pattern as the March per-robot read.
        local okv, lv = pcall(function()
            return Ability.GetLevelSpecialValueFor and Ability.GetLevelSpecialValueFor(State.laser, "laser_damage", -1)
        end)
        if okv and type(lv) == "number" and lv > 0 then killhp = lv end
        local tgt = killhp > 0 and laser_lasthit_target(s, neutrals, killhp) or nil
        if tgt and cast_target(State.laser, tgt) then
            logline(string.format("laser lasthit hp=%.0f", (Entity.GetHealth and Entity.GetHealth(tgt)) or 0)); return
        end
    end
    if ready(State.march) then
        local cp = march_cast_point_multi(s, State.marchCasts)   -- multi-W: alternate sides for even coverage
        if cast_pos(State.march, cp) then
            State.marchPending = { cdBefore = cd_remaining(State.march), expire = now() + 1.5 }
            local me = origin(State.hero)
            logline(string.format("march_aim src=%s stand=(%.0f,%.0f) cast=(%.0f,%.0f) hero=(%.0f,%.0f) camp=(%.0f,%.0f)%s",
                (s.standSpot.paired and "pair" or "single"),
                s.standSpot.stand.x, s.standSpot.stand.y, cp.x, cp.y, me.x, me.y, s.center.x, s.center.y,
                s.standSpot.partner and string.format(" pcamp=(%.0f,%.0f)", s.standSpot.partner.x, s.standSpot.partner.y) or ""))
        end
    elseif try_rearm() then                                                       -- March on cd -> Rearm to reset it, then March again
        logline("rearm")
    end
end

local function has_fountain_buff()
    local m = NPC.GetModifier(State.hero, "modifier_fountain_aura_buff")  -- V2-confirmed
    return m ~= nil
end

local function fsm_return()   -- REFILL: Keen home -> Rearm to reset Keen -> wait HP+mana >= REFILL_FRAC -> DECIDE
    local h = State.hero
    if has_fountain_buff() then
        -- v0.1.202/212 (the EXTERNAL 2_ItemsManager.lua auto-bottle cancels our Rearm channel at
        -- the fountain; .202 moved the rearm AFTER the fill, run-35 still showed occasional
        -- cancels at the mthresh level = the manager's bar is above ours). v0.1.212 (user's idea):
        -- rearm attempts start AT LANDING and run DURING the fill - the fill is the critical path,
        -- a canceled channel's mana refills concurrently - capped at 2 attempts, and refill_done
        -- NEVER waits on keen: a failed reset degrades to the field ladder (rearm away from the
        -- manager's bottle) or the natural cd.
        if not ready(State.keen) and (State.fountainRearms or 0) < 2 then
            if try_rearm() then
                State.fountainRearms = (State.fountainRearms or 0) + 1
                return
            end
        end
        local mmax = NPC.GetMaxMana(h) or 1
        -- refill at least to REFILL_FRAC, but never below the escape floor (else tick() bounces us
        -- straight back to RETURN -> a refill loop if the user sets escape mana above 0.70*max). Clamp
        -- to max so an escape floor > max mana can still complete (waits for full instead of forever).
        local esc = (State.menu and State.menu.escapeMana and State.menu.escapeMana:Get()) or K.ESCAPE_MANA
        -- COST-AWARE refill (ancient arc): the planner's refill step may be ENABLING a big-ticket
        -- next target (State.refillNeed = its mana_cost + keen reserve, set at dispatch) - wait for
        -- that level, capped at max. Otherwise the 0.70 tempo leave stands.
        local mthresh = math.min(mmax, math.max(mmax * K.REFILL_FRAC, esc, State.refillNeed or 0))
        local hpFull = (Entity.GetHealth(h) or 0) >= (Entity.GetMaxHealth(h) or 1) * K.REFILL_FRAC
        local mpFull = mana() >= mthresh
        if hpFull and mpFull then
            State.fsm = "DECIDE"; State.refillNeed = nil; State.fountainRearms = nil
            logline("refill_done")
        end
        return
    end
    State.fountainRearms = nil   -- v0.1.212: en route (not in the buff yet) = a fresh visit's counter
    -- Note 2 (over-return): resources often recover EN ROUTE (passive regen + Bottle), so ABORT the
    -- trip home and resume farming instead of walking/teleporting all the way to base (we were
    -- teleporting in at ~70% mana with a wave up). Only when SAFE - never abort a threat retreat.
    local mmax, hpmax = NPC.GetMaxMana(h) or 1, Entity.GetMaxHealth(h) or 1
    -- cost-aware refill: a big-ticket trip (refillNeed above the resume level) must reach the
    -- fountain - the 0.70 en-route resume would strand the ancient plan under-funded forever.
    if (not State.refillNeed or State.refillNeed <= mmax * K.RETURN_RESUME_FRAC)
       and mana() >= mmax * K.RETURN_RESUME_FRAC
       and (Entity.GetHealth(h) or 0) >= hpmax * K.RETURN_RESUME_FRAC
       and enemy_risk_at(origin(h)) < K.FARM_SAFE_RISK then
        State.fsm, State.spot = "DECIDE", nil
        if now() - (State.lastResumeLog or -99) > 2.0 then State.lastResumeLog = now(); logline("return resume mana_ok") end
        return
    end
    local fpf = friendly_fountain_pos()
    -- Note 5: keen lands 70-800u NEAR the fountain, often OUTSIDE the regen zone, so re-keening
    -- re-teleports him outside again ("teleported outside the fountain"). When already close,
    -- WALK the last bit into the fountain instead of re-keening.
    if fpf and origin(h):Distance2D(fpf) <= K.FOUNTAIN_WALK_IN then
        move_to(Vector(fpf.x, fpf.y, origin(h).z), "fountain_walkin")
        if now() - (State.lastWalkHomeLog or -99) > 2.0 then State.lastWalkHomeLog = now(); logline("return walk_in_fountain") end
        return
    end
    -- self-cast Keen auto-conveys to fountain when >1500 away (V2-confirmed idiom).
    if ready(State.keen) then
        if keen_home() then logline("return keen_base") end
    elseif try_rearm() then                                     -- Keen on cd in the field: Rearm to reset it
        logline("return rearm_reset_keen")
    else
        -- Note 2: Keen on cd AND can't Rearm (low mana after a shove) -> Tinker stood IDLE in the field
        -- with no walk-home fallback and no watchdog = the silent stuck. Walk toward the fountain instead.
        local fp = friendly_fountain_pos()
        if fp then
            -- v0.1.222 (user, run-45 t=346-360: walked home 14s with the dagger in the bag while
            -- mana climbed 85->227 - Keen was on CD and Rearm unaffordable, but the BLINK doctrine
            -- says a safe walk is a blinkable walk): hop toward the fountain, walk the rest.
            if not try_travel_blink(Vector(fp.x, fp.y, origin(h).z)) then
                move_to(Vector(fp.x, fp.y, origin(h).z), "walk_home")
            end
            if now() - (State.lastWalkHomeLog or -99) > 2.0 then   -- throttle: was logged every tick (632x); the over-return root is a separate (designed) fix
                State.lastWalkHomeLog = now()
                -- note 2 diag: why walk home instead of bottle-sustain? log mana + bottle charges + risk.
                local bt = NPC.GetItem(State.hero, "item_bottle", true)
                local bch = (bt and Item.GetCurrentCharges and Item.GetCurrentCharges(bt)) or -1
                logline(string.format("return walk_home mana=%.0f bottle=%d risk=%.2f", mana(), bch,
                    enemy_risk_at(origin(h))))
            end
        end
    end
end

-- Bottle sustain: drink when low + safe + NOT channeling, so it never interrupts a Rearm/Keen channel.
-- API idioms verified from deployed prior-art scripts (NPC.GetItem by-name, CanBeExecuted==-1 = castable,
-- Item.GetCurrentCharges, no_target cast). Bottle regen breaks on enemy hero/tower damage -> safe-gated.
local function bottle_tick()
    local bottle = NPC.GetItem(State.hero, "item_bottle", true)
    if not bottle or Ability.CanBeExecuted(bottle) ~= -1 or Item.GetCurrentCharges(bottle) <= 0 then return end
    if NPC.HasModifier(State.hero, "modifier_bottle_regeneration") then return end   -- already drinking: don't waste charges
    if is_channeling() then return end                                       -- HARD RULE: never interrupt Rearm/Keen
    local h = State.hero
    -- v0.1.220 (user: THE Tinker item function = a fully automatic Bottle - life, mana, channel
    -- aware, and FOUNTAIN-ACCELERATED): at the fountain the charges refill instantly, so
    -- CHAIN-DRINKING stacks the bottle's regen ON TOP of the fountain's = measurably shorter
    -- visits (the #1 non-engage time sink), at zero charge cost. Any real hp/mana deficit
    -- qualifies there (the modifier gate above paces one drink per regen window). Field
    -- drinking keeps the low thresholds + the risk gate (bottle regen breaks on enemy damage).
    -- With this owning the bottle end-to-end, the external ItemsManager's auto-bottle (the old
    -- Rearm-cancel source) can be disabled by the user.
    if has_fountain_buff() then
        local needm = mana() < ((NPC.GetMaxMana and NPC.GetMaxMana(h)) or 1) - 5
        local needh = (Entity.GetHealth(h) or 0) < (Entity.GetMaxHealth(h) or 1) - 5
        if (needm or needh) and cast_no_target(bottle) then logline("bottle drink fountain") end
        return
    end
    local lowm = mana() < K.BOTTLE_MANA
    local lowh = (Entity.GetHealth(h) or 1) < (Entity.GetMaxHealth(h) or 1) * K.BOTTLE_HP_FRAC
    if not (lowm or lowh) then return end
    if enemy_risk_at(origin(State.hero)) >= K.SHOVE_SAFE_RISK then return end -- bottle breaks on enemy damage
    if cast_no_target(bottle) then logline("bottle drink") end
end

-- Mana engine part 3 (2026-07-04, Liquipedia-verified): pump the pool from ITEMS before the
-- deficit forces a fountain trip. Arcane Replenish is free (+150, cd 55): pop on any real
-- deficit. Soul Ring Sacrifice (+170 for 10s, -170 HP, cd 30): only when casts are IMMINENT
-- (ENGAGE - the temp mana must be spent inside its window) and HP is healthy. Inventory-driven:
-- no purchase logic, the brain exploits whatever the build carries (item choice = the user's).
local function mana_items_tick()
    local h = State.hero
    if is_channeling() then return end                                       -- never clip a Rearm/Keen channel
    local mmax = NPC.GetMaxMana(h) or 0
    local deficit = mmax - mana()
    if deficit >= K.ARCANE_MANA then
        local ab = NPC.GetItem(h, "item_arcane_boots", true)
        if ab and Ability.CanBeExecuted(ab) == -1 then
            if cast_no_target(ab) then logline("arcane replenish"); return end
        end
    end
    if State.fsm == "ENGAGE" and deficit >= K.SOUL_RING_MANA
       and (Entity.GetHealth(h) or 0) >= (Entity.GetMaxHealth(h) or 1) * K.SR_HP_FRAC_MIN then
        local sr = NPC.GetItem(h, "item_soul_ring", true)
        if sr and Ability.CanBeExecuted(sr) == -1 then
            if cast_no_target(sr) then logline("soul_ring sacrifice") end
        end
    end
end

local function tick()
    process_verify()
    gold_tick()
    if handle_panic() then
        if has_fountain_buff() then State.panicUntil = 0 end
        -- only issue keen_home if not already conveying: panic runs every tick, and re-issuing the
        -- Keen channel each tick CANCELS the in-flight teleport (the hero never gets home).
        if ready(State.keen) and not has_fountain_buff() and not is_channeling() then keen_home() end
        return
    end
    if is_channeling() then return end   -- hold orders during the Rearm/Keen channel (panic above may break it)
    -- v0.1.121 (note 3, user-requested repeatedly): GLOBAL stuck-breaker. While moving toward a target
    -- (MOVE/RETURN) and FAR from it, if the distance to it has not improved for STUCK_TELEPORT_S he is
    -- blocked -> TELEPORT (keen home; rearm-reset-keen if on cd) to unstick + re-decide. Only when FAR
    -- from the target, so legitimately STANDING at the stand/fountain (waiting for a wave, etc.) never
    -- triggers it. A last-resort backstop over the per-state no_progress / MOVE_TIMEOUT watchdogs.
    -- Glue rebuild item 4: Nav.Stuck (signal upgrade from position-frozen to no-distance-improvement:
    -- orbiting without approaching now counts as stuck, which is correct).
    -- v0.1.194 F1 (run-24): a DELIBERATE wait (tether hold / protected wait / hold-still) is
    -- frozen-far-from-target BY DESIGN - the watchdog read it as stuck and keened him home mid-
    -- tether (STUCK at our T1 d=3287 -> teleport unstick, 2x). waitInfo is stamped fresh every
    -- waiting tick (the HUD uses the same 1s recency), so it is the exact "intentional" signal.
    local deliberate_wait = State.waitInfo and now() - (State.waitInfo.t or 0) < 1.0
    if (State.fsm == "MOVE" or State.fsm == "RETURN") and not has_fountain_buff()
       and not deliberate_wait then
        local p = origin(State.hero)
        local tgt = (State.fsm == "RETURN") and friendly_fountain_pos()
                    or (State.spot and State.spot.standSpot and State.spot.standSpot.stand)
        local dist = tgt and p:Distance(Vector(tgt.x, tgt.y, p.z))
        if dist and dist > K.STUCK_FAR_DIST then
            local stuck
            State.stuckTrack, stuck = Nav.Stuck(State.stuckTrack, dist, now(),
                { eps = K.STUCK_FROZEN_DIST, window = K.STUCK_TELEPORT_S })
            if stuck then
                logline(string.format("STUCK at (%.0f,%.0f) d=%.0f -> teleport unstick", p.x, p.y, dist))
                if ready(State.keen) then keen_home() elseif ready(State.rearm) then try_rearm() end
                State.spot = nil; State.fsm = "DECIDE"; State.nextDecide = 0; State.stuckTrack = nil
            end
        else
            State.stuckTrack = nil                     -- at target / no target: not a stuck candidate
        end
    else
        State.stuckTrack = nil
    end
    bottle_tick()                        -- sustain (only when not channeling, per the guard above)
    mana_items_tick()                    -- mana engine part 3: Arcane/Soul Ring pump the pool before a fountain trip
    if mana() < State.menu.escapeMana:Get() and State.fsm ~= "RETURN" then go_return() end
    if     State.fsm == "DECIDE" then fsm_decide()
    elseif State.fsm == "MOVE"   then fsm_move()
    elseif State.fsm == "ENGAGE" then fsm_engage()
    elseif State.fsm == "RETURN" then fsm_return() end
end

-- ── debug overlay (calibration view) ─────────────────────────────────────────
local DBG = { font = nil }
local function dbg_font()
    if not DBG.font then DBG.font = Render.LoadFont("Tahoma", 0, 500) end
    return DBG.font
end
local function w2s(p) return Render.WorldToScreen(p) end
local function dbg_text(sp, text, col) Render.Text(dbg_font(), 14, text, sp, col) end
local function world_text(wp, text, col, dx, dy)
    local sp, vis = w2s(wp)
    if vis then dbg_text(Vec2(sp.x + (dx or 6), sp.y + (dy or 0)), text, col) end
end
local function world_ring(center, radius, col, thickness)
    -- draw arc-by-arc so a ring that is partly off-screen still shows its visible part (the old version
    -- bailed the WHOLE ring if any single point was off-screen -> large rings never drew).
    local seg = 36
    local prev, pvis
    for i = 0, seg do
        local a = (i / seg) * math.pi * 2
        local sp, vis = w2s(Vector(center.x + math.cos(a) * radius,
                                   center.y + math.sin(a) * radius, center.z))
        if i > 0 and pvis and vis then Render.Line(prev, sp, col, thickness or 1.6) end
        prev, pvis = sp, vis
    end
end
local function world_line(a, b, col, thickness)
    local sa, va = w2s(a)
    local sb, vb = w2s(b)
    if va and vb then Render.Line(sa, sb, col, thickness or 1.5) end
end
-- draw a rectangle from a start corner, `length` forward along `dir`, width 2*hw (callers
-- pass the back edge = cast point - dir*length/2 so it renders centred on the cast point).
local function world_rect(stand, dir, length, hw, col)
    local px, py = -dir.y, dir.x
    local fx, fy = dir.x * length, dir.y * length
    local ox, oy, z = px * hw, py * hw, stand.z
    local c1 = Vector(stand.x + ox,      stand.y + oy,      z)
    local c2 = Vector(stand.x - ox,      stand.y - oy,      z)
    local c3 = Vector(stand.x - ox + fx, stand.y - oy + fy, z)
    local c4 = Vector(stand.x + ox + fx, stand.y + oy + fy, z)
    world_line(c1, c2, col); world_line(c2, c3, col)
    world_line(c3, c4, col); world_line(c4, c1, col)
end

-- draw a world-space segment subdivided, so the ON-screen part of a long edge still shows even when an
-- endpoint is off-screen (world_line alone skips the whole edge if either end is off-screen).
local function world_seg(a, b, col, n)
    n = n or 10
    local prev, pvis
    for i = 0, n do
        local t = i / n
        local sp, vis = w2s(Vector(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t, a.z))
        if i > 0 and pvis and vis then Render.Line(prev, sp, col, 1.6) end
        prev, pvis = sp, vis
    end
end
-- axis-aligned square of side 2*half centred on `center` (the W coverage box over a camp).
local function world_square(center, half, col)
    local z = center.z
    local a = Vector(center.x - half, center.y - half, z)
    local b = Vector(center.x + half, center.y - half, z)
    local c = Vector(center.x + half, center.y + half, z)
    local d = Vector(center.x - half, center.y + half, z)
    world_seg(a, b, col); world_seg(b, c, col); world_seg(c, d, col); world_seg(d, a, col)
end

-- oriented rectangle centred on `center`: half-extent `ha` along (ux,uy), `hp` along the perpendicular.
local function world_obox(center, ux, uy, ha, hp, col)
    local px, py, z = -uy, ux, center.z
    local c1 = Vector(center.x + ux * ha + px * hp, center.y + uy * ha + py * hp, z)
    local c2 = Vector(center.x + ux * ha - px * hp, center.y + uy * ha - py * hp, z)
    local c3 = Vector(center.x - ux * ha - px * hp, center.y - uy * ha - py * hp, z)
    local c4 = Vector(center.x - ux * ha + px * hp, center.y - uy * ha + py * hp, z)
    world_seg(c1, c2, col); world_seg(c2, c3, col); world_seg(c3, c4, col); world_seg(c4, c1, col)
end

-- one-press pair-test overlay: green ring = camp pairs (line to partner + yellow cast dot),
-- red ring + reason = camp does not pair. Shows for K.TEST_OVERLAY_SEC after the Test key.
local function draw_pair_test()
    if not State.pairTestResults or now() > (State.pairTestUntil or 0) then return end
    local sz  = Render.ScreenSize()
    local hdr = "PAIR TEST  (green=clean  amber=clip  red=skip)"
    local hw  = Render.TextSize(dbg_font(), 18, hdr)
    Render.Text(dbg_font(), 18, hdr, Vec2(sz.x * 0.5 - hw.x * 0.5, sz.y * 0.12), Color(255, 230, 120, 255))
    for _, r in ipairs(State.pairTestResults) do
        if r.paired then
            local clean = (r.clear == "clean")                       -- disc-model clear class -> ring colour
            local ringC = clean and Color(120, 255, 150, 255) or Color(255, 200, 80, 255)
            local lineC = clean and Color(120, 255, 150, 150) or Color(255, 200, 80, 150)
            world_ring(r.center, 120, ringC, 2.2)
            if r.partner then world_line(r.center, r.partner, lineC, 1.6) end
            local cp = r.cast and w2s(r.cast)
            if cp then Render.FilledCircle(cp, 5, Color(255, 200, 0, 255)) end
            world_text(r.center, string.format("%s %d", r.clear or "?", math.floor(r.fullm or 0)), ringC, 8, -10)
        else
            world_ring(r.center, 120, Color(255, 110, 110, 255), 2.0)
            world_text(r.center, r.reason or "skip", Color(255, 150, 150, 255), 8, -10)
        end
    end
end

-- LIVE merged-pair debug (toggle "Pair debug"). Runs the ACTUAL new pairing (Farm.GreedyPairs over
-- non-cleared camps) each frame so it works with auto-farm off: MERGED pair = green rings + line +
-- midpoint; a pair whose midpoint is unsafe (would split back to singles) = amber; a camp with no
-- partner in range = red single. The camp NEAREST the hero is ringed WHITE and its verdict is logged
-- (throttled) - walk Tinker to a camp to confirm an unpaired one is genuinely unpairable (its true
-- nearest_neighbor > pair_max) or only split by midpoint risk.
local function draw_pair_debug()
    if not (State.menu.pairDbg and State.menu.pairDbg:Get()) then return end
    State.fog = enemy_snapshot()                       -- live risk for the merged/split test (works with auto-farm off)
    local camps = {}
    for _, cd in ipairs(Map.Camps() or {}) do
        if cd.center and not is_cleared(camp_key(cd.center)) then camps[#camps + 1] = cd end
    end
    local pts = {}
    for i = 1, #camps do pts[i] = { x = camps[i].center.x, y = camps[i].center.y } end
    local pair_max = math.min(K.PAIR_RADIUS, K.MARCH_LEN - 2 * math.abs(K.MARCH_PAIR_OFFSET))
    local allow = function(i, j) return forced_pair(camps[i].center, camps[j].center) end   -- whitelist over-range pairs (overlay reflects the live logic)
    local groups = Farm.GreedyPairs(pts, pair_max, nil, allow)

    local sz  = Render.ScreenSize()
    local hdr = string.format("PAIR DEBUG  green=merged  amber=split(unsafe mid)  red=single  magenta=your marks   pair_max=%d", math.floor(pair_max))
    local hw  = Render.TextSize(dbg_font(), 18, hdr)
    Render.Text(dbg_font(), 18, hdr, Vec2(sz.x * 0.5 - hw.x * 0.5, sz.y * 0.12), Color(255, 230, 120, 255))

    local me = origin(State.hero)
    local nearest, nd = nil, math.huge
    for i = 1, #camps do local d = camps[i].center:Distance(me); if d < nd then nd, nearest = d, i end end

    for _, g in ipairs(groups) do
        local A = camps[g.a].center
        if g.b then
            local B = camps[g.b].center
            local mid = Vector((A.x + B.x) / 2, (A.y + B.y) / 2, A.z)
            local merged = enemy_risk_at(mid) < K.RISK_HARD
            local col = merged and Color(120, 255, 150, 255) or Color(255, 200, 80, 255)
            world_ring(A, 110, col, 2.0); world_ring(B, 110, col, 2.0)
            world_line(A, B, col, 1.8); world_ring(mid, 26, col, 2.0)
            world_text(mid, string.format("%s d=%.0f", merged and "MERGED" or "split", g.d), col, 8, -10)
        else
            world_ring(A, 110, Color(255, 110, 110, 255), 2.0)
            world_text(A, "single", Color(255, 150, 150, 255), 8, -10)
        end
    end

    if not nearest then return end
    world_ring(camps[nearest].center, 150, Color(255, 255, 255, 255), 2.6)   -- the camp you are inspecting
    local c   = camps[nearest].center
    local key = camp_key(c)
    if key == State.pairDbgKey and now() - (State.pairDbgT or 0) < 2.0 then return end   -- throttle: log on approach / every 2s
    State.pairDbgKey, State.pairDbgT = key, now()
    local verdict = "single reason=no_partner_in_range"
    for _, g in ipairs(groups) do
        if g.a == nearest or g.b == nearest then
            if g.b then
                local other = camps[(g.a == nearest) and g.b or g.a].center
                local mid  = Vector((c.x + other.x) / 2, (c.y + other.y) / 2, c.z)
                local risk = enemy_risk_at(mid)
                verdict = string.format("%s pcamp=(%.0f,%.0f) d=%.0f mid_risk=%.2f%s",
                    (risk < K.RISK_HARD) and "PAIRED" or "split_unsafe_mid(risk>=RISK_HARD)", other.x, other.y, g.d, risk,
                    forced_pair(c, other) and " [forced]" or "")
            end
            break
        end
    end
    if verdict:find("no_partner") then                    -- show the TRUE nearest neighbor so you can see it exceeds pair_max
        local nn = math.huge
        for i = 1, #camps do if i ~= nearest then local d = camps[i].center:Distance(c); if d < nn then nn = d end end end
        verdict = string.format("%s nearest_neighbor=%.0f pair_max=%.0f", verdict, (nn < math.huge) and nn or -1, pair_max)
    end
    logline(string.format("pairdbg hero=(%.0f,%.0f) camp=(%.0f,%.0f) tier=%s verdict=%s",
        me.x, me.y, c.x, c.y, tostring(camps[nearest].type), verdict))
end

-- Persistent user "pairable here" markers (the Mark bind). Magenta ring at the marked hero pos + lines to
-- the two nearest camps it recorded, labelled with the index + their inter-distance. Always drawn (even
-- with the Pair-debug toggle off) so marks stay visible; cleared on script reload.
local function draw_pair_marks()
    local marks = State.pairMarks
    if not marks or #marks == 0 then return end
    local col = Color(255, 90, 255, 255)
    for i, m in ipairs(marks) do
        local p = Vector(m.pos.x, m.pos.y, m.pos.z)
        world_ring(p, 60, col, 2.4)
        if m.c1 then world_line(p, m.c1, col, 1.4) end
        if m.c2 then world_line(p, m.c2, col, 1.4) end
        world_text(p, string.format("MARK#%d d12=%.0f", i, m.d12 or -1), col, 8, 12)
    end
end

-- one-press wave-scan overlay: per lane, blue ring = enemy wave, green ring = ally wave (count +
-- gold), yellow dot = predicted clash settle (+ drift line when moving), with pushing/eta/reach.
local LANE_SCAN_NAMES = { "top", "mid", "bot" }
local function draw_lane_scan()
    if not State.laneScan or now() > (State.laneScanUntil or 0) then return end
    local sz  = Render.ScreenSize()
    local hdr = "WAVE SCAN  (blue=enemy wave  green=ally wave  orange=MIRRORED est  yellow=clash)"
    local hw  = Render.TextSize(dbg_font(), 18, hdr)
    Render.Text(dbg_font(), 18, hdr, Vec2(sz.x * 0.5 - hw.x * 0.5, sz.y * 0.16), Color(255, 230, 120, 255))
    -- Piece 1.5: draw the lane polylines (dim) so the mirrored estimates can be eyeballed ON the lane.
    for _, path in pairs(lane_paths()) do
        for i = 2, #path do
            world_seg(Vector(path[i - 1].x, path[i - 1].y, 0), Vector(path[i].x, path[i].y, 0),
                      Color(150, 150, 170, 90))
        end
    end
    for _, ln in ipairs(LANE_SCAN_NAMES) do
        local s = State.laneScan[ln]
        if s then
            local function wave_ring(w, col)
                if not (w and w.centroid) then return end
                -- a MIRRORED estimate draws ORANGE with its source tag, so estimate-vs-real is visible
                local c = w.estimated and Color(255, 165, 60, 255) or col
                world_ring(Vector(w.centroid.x, w.centroid.y, 0), 130, c, 2.0)
                world_text(Vector(w.centroid.x, w.centroid.y, 0),
                    string.format("%s x%d  g%d%s", ln, w.count, math.floor(w.gold or 0),
                        w.estimated and (" ~" .. (w.est_src or "est")) or ""), c, 8, -10)
            end
            wave_ring(s.enemy_wave, Color(120, 190, 255, 255))
            wave_ring(s.ally_wave, Color(120, 255, 150, 255))
            if s.clash and s.clash.contact then
                local cw = Vector(s.clash.settle.x, s.clash.settle.y, 0)
                local crash = s.clash.crashing
                local cp, cvis = w2s(cw)
                if cvis then Render.FilledCircle(cp, 6, crash and Color(255, 80, 80, 255) or Color(255, 210, 0, 255)) end
                if s.clash.moving then   -- drift arrow contact -> settle
                    world_line(Vector(s.clash.contact.x, s.clash.contact.y, 0), cw, Color(255, 210, 0, 200), 2.0)
                end
                if crash and s.clash.crash_tower then   -- red line to the tower the wave crashes into
                    world_line(cw, Vector(s.clash.crash_tower.pos.x, s.clash.crash_tower.pos.y, 0), Color(255, 80, 80, 220), 2.0)
                end
                local reach = s.intercept and s.intercept.reachable
                world_text(cw, string.format("%s%s%s eta=%s %s",
                    s.clash.pushing, s.clash.moving and "" or "/hold", crash and " CRASH" or "",
                    s.intercept and string.format("%.1f", s.intercept.eta) or "-",
                    reach and "OK" or "x"),
                    reach and Color(120, 255, 150, 255) or Color(255, 150, 150, 255), 8, 10)
            end
        end
    end
end

-- one-press route-scan overlay: every candidate as a ring (kind/value/risk, dimmed if
-- contested/risk-vetoed), and the chosen plan as a numbered path 1->2->3 (leg-1 highlighted).
local function draw_route_scan()
    if not State.routeScan or now() > (State.routeScanUntil or 0) then return end
    local sz  = Render.ScreenSize()
    local hdr = "ROUTE SCAN  (cyan=camp  blue=wave  green=plan path; dim=skipped)"
    local hw  = Render.TextSize(dbg_font(), 18, hdr)
    Render.Text(dbg_font(), 18, hdr, Vec2(sz.x * 0.5 - hw.x * 0.5, sz.y * 0.20), Color(255, 230, 120, 255))
    for _, t in ipairs(State.routeScan.targets or {}) do
        local skipped = t.contested or (t.risk or 0) >= K.RISK_HARD
        local base = (t.kind == "wave") and Color(120, 190, 255, 255) or Color(120, 230, 230, 255)
        local col  = skipped and Color(150, 150, 150, 160) or base
        world_ring(Vector(t.pos.x, t.pos.y, 0), 120, col, 1.8)
        world_text(Vector(t.pos.x, t.pos.y, 0),
            string.format("%s g%.0f r%.2f%s", t.kind, t.value or 0, t.risk or 0, t.contested and " owned" or ""),
            col, 8, -10)
    end
    local steps = State.routeScan.plan and State.routeScan.plan.steps or {}
    local prev = origin(State.hero)
    for i, s in ipairs(steps) do
        local hereW = Vector(s.pos.x, s.pos.y, 0)
        world_line(prev, hereW, Color(120, 255, 150, 220), i == 1 and 3.0 or 2.0)
        world_ring(hereW, 135, Color(120, 255, 150, 255), i == 1 and 3.0 or 1.8)
        world_text(hereW, string.format("#%d", i), Color(120, 255, 150, 255), -16, -12)
        prev = hereW
    end
end

local DBG_TIER = { [0] = "small", [1] = "med", [2] = "large", [3] = "ancient" }
local function draw_debug()
    if not State.menu.debug:Get() or not State.hero then return end
    local chosen = State.spot
    for _, c in ipairs(State.cands or {}) do
        local isChosen = chosen and c.camp == chosen.camp
        local col = isChosen and Color(120, 255, 150, 255) or Color(255, 210, 120, 215)
        world_ring(c.center, 110, col, isChosen and 2.4 or 1.3)
        world_text(c.center, string.format("%s  ehp %d  g %d  x%d %s",
            DBG_TIER[c.type] or "?", math.floor(c.ehp or 0), math.floor(c.gold or 0),
            camp_stacks(c.gold, c.type), c.source or "est"), col, 8, -10)
    end
    if chosen and chosen.standSpot and chosen.kind ~= "wave" then
        local ss = chosen.standSpot
        local z  = ss.stand.z
        -- THE STAND BOX (green): a THIN RECTANGLE aligned to the camp axis for a pair (tight along, roomy
        -- perpendicular); a disc for a single camp. This is the region Tinker must be inside to cast W well.
        if ss.paired and ss.partner then
            local ux, uy = ss.partner.x - chosen.center.x, ss.partner.y - chosen.center.y
            local ul = math.sqrt(ux * ux + uy * uy); if ul < 1 then ul = 1 end
            world_obox(ss.aim, ux / ul, uy / ul, K.BOX_ALONG, K.BOX_PERP, Color(60, 230, 120, 235))
        else
            world_ring(ss.aim, K.ENGAGE_COVER_DIST, Color(60, 230, 120, 235), 2.6)
        end
        world_text(ss.aim, "STAND BOX", Color(60, 230, 120, 255), 8, -8)
        -- ACTUAL W coverage: the 1800x1800 square is CENTRED ON THE REAL CAST POINT (clamped 280 ahead of
        -- the hero), NOT on the camp - so you can SEE whether a camp ends up at the square's far edge (a
        -- miss). One square per cast (multi-W: near + far). Yellow dot = the real cast point.
        local hpos = origin(State.hero)
        for idx = 0, 1 do
            local cp = march_cast_point_multi(chosen, idx)
            local dx, dy = cp.x - hpos.x, cp.y - hpos.y                       -- the W sweeps along hero->cast
            local dl = math.sqrt(dx * dx + dy * dy); if dl < 1 then dl = 1 end
            world_obox(cp, dx / dl, dy / dl, K.MARCH_LEN * 0.5, K.MARCH_HALFWIDTH, Color(120, 200, 255, 150))
            local sp = w2s(cp); if sp then Render.FilledCircle(sp, 4, Color(255, 200, 0, 255)) end
        end
        -- camp markers (orange): the targets the W must actually cover
        local ca = w2s(chosen.center); if ca then Render.FilledCircle(ca, 6, Color(255, 140, 60, 255)) end
        if ss.paired and ss.partner then
            local cb = w2s(Vector(ss.partner.x, ss.partner.y, z)); if cb then Render.FilledCircle(cb, 6, Color(255, 140, 60, 255)) end
        end
        local st = w2s(ss.stand); if st then Render.FilledCircle(st, 6, Color(60, 230, 60, 255)) end
    end
    local hs, vis = w2s(origin(State.hero))
    if vis then
        local txt = string.format("%s | mana %d/%d (esc %d)%s",
            State.fsm, math.floor(mana()), math.floor(NPC.GetMaxMana(State.hero) or 0),
            State.menu.escapeMana:Get(), is_channeling() and " [CHANNEL]" or "")
        dbg_text(Vec2(hs.x + 12, hs.y - 26), txt, Color(255, 255, 255, 255))
    end
end

-- ── status text: on-screen indicator while auto farm is ON ───────────────────
local function draw_status()
    if not State.menu.enable:IsToggled() or not State.hero or not Engine.IsInGame() then return end
    local ss   = Render.ScreenSize()
    -- v0.1.163 (user): a deliberate WAIT must READ as a wait, not as MOVE. State.waitInfo is set by
    -- the hold paths (wave hold / protected wait / suppression idle) and cleared when stale (>1s).
    local st = State.fsm
    if State.waitInfo and now() - (State.waitInfo.t or 0) < 1.0 then
        st = "WAIT " .. State.waitInfo.why
    end
    local txt  = string.format("TINKER FARM: ON  [%s]", st)
    local ts   = Render.TextSize(dbg_font(), 18, txt)
    local x, y = ss.x * 0.5 - ts.x * 0.5, ss.y * 0.085
    Render.FilledRect(Vec2(x - 10, y - 5), Vec2(x + ts.x + 10, y + ts.y + 5), Color(0, 0, 0, 150), 6)
    Render.Text(dbg_font(), 18, txt, Vec2(x, y), Color(120, 255, 150, 255))
end

-- ── camp-population diagnostic (answers "do camps populate?" via debug.log) ────
local dbgScanAt = 0
local function debug_camp_scan()
    local t = now()
    if t < dbgScanAt + 2.0 then return end
    dbgScanAt = t
    local all = Map.Camps()
    local neutrals = Map.AllNeutrals()
    local occ, first = 0, nil
    for _, cd in ipairs(all) do
        if #Map.CampCreeps(cd.camp, neutrals) > 0 then occ = occ + 1 end
        if not first and cd.center then first = cd end
    end
    local detail = ""
    if first then
        detail = string.format(" first=(%.0f,%.0f) type=%s",
            first.center.x, first.center.y, tostring(first.type))
    end
    logline(string.format("camp_scan camps=%d occupied=%d%s", #all, occ, detail))
end

-- ── one-shot position dump (build the static fallback table from debug.log) ────
local function dump_uname(e)
    local ok, n = pcall(function() return Entity.GetUnitName and Entity.GetUnitName(e) end)
    if ok and type(n) == "string" then return n end
    local ok2, n2 = pcall(function() return NPC.GetUnitName and NPC.GetUnitName(e) end)
    if ok2 and type(n2) == "string" then return n2 end
    return "?"
end
local function dump_positions()
    local camps = Map.Camps()
    logline("=== DUMP BEGIN camps=" .. #camps .. " ===")
    for i, cd in ipairs(camps) do
        local c = cd.center
        local mnx, mny, mxx, mxy = 0, 0, 0, 0
        if cd.box and cd.box.min and cd.box.max then
            mnx, mny, mxx, mxy = cd.box.min.x, cd.box.min.y, cd.box.max.x, cd.box.max.y
        end
        logline(string.format("camp i=%d type=%s center=(%.0f,%.0f,%.0f) box=(%.0f,%.0f)..(%.0f,%.0f)",
            i, tostring(cd.type), c and c.x or 0, c and c.y or 0, c and c.z or 0, mnx, mny, mxx, mxy))
    end
    local structs = NPCs.GetAll(Enum.UnitTypeFlags.TYPE_STRUCTURE) or {}
    logline("=== DUMP structures=" .. #structs .. " ===")
    for i, e in ipairs(structs) do
        local p = Entity.GetAbsOrigin(e)
        logline(string.format("struct i=%d team=%s name=%s pos=(%.0f,%.0f,%.0f)",
            i, tostring(Entity.GetTeamNum(e)), dump_uname(e),
            p and p.x or 0, p and p.y or 0, p and p.z or 0))
    end
    logline("=== DUMP END ===")
end

-- v0.1.113 (temporary, diagnostic-only): validate the wave-meeting MATH vs REALITY. Logs a mid ally
-- creep's ENGINE move/base speed (NPC.GetMoveSpeed / GetBaseSpeed - gitbook-confirmed for any unit incl.
-- lane creeps) + the MEASURED centroid velocity (delta-pos / delta-t) + distance to the enemy mid T1.
-- Expectation while the wave MARCHES freely (before it meets the enemy): measured ~ api ~ base ~ 325 and
-- d_eT1 falls at that rate -> confirms 325 + the spawn->meeting timing. Once confirmed, the model uses
-- the ENGINE base speed (not a hardcoded 325). Run with all-vision + Debug on from early game.
local function sample_creep_speed()
    if now() < (State.nextSpeedSample or 0) then return end
    State.nextSpeedSample = now() + 0.5
    -- LANE-AGNOSTIC: bucket every lane creep by lib/lane's classifier, per team. Logs our/enemy
    -- centroid + C=midpoint + the engine speed PER LANE, so the mirror (C constant) and the speed
    -- (incl. top/bot's first-15-wave +30%/-35% split) are validated on all three lanes the same way.
    local L = { top = {}, mid = {}, bot = {} }
    for _, ln in pairs(L) do ln.ox, ln.oy, ln.on, ln.ex, ln.ey, ln.en = 0, 0, 0, 0, 0, 0 end
    for _, c in ipairs(NPCs.GetAll(Enum.UnitTypeFlags.TYPE_LANE_CREEP) or {}) do
        if Entity.IsAlive(c) and not Entity.IsDormant(c) then
            local p = Entity.GetAbsOrigin(c)
            if p then
                local ln = L[Lane._assign_lane({ x = p.x, y = p.y })]            -- same lane classifier as lib/lane
                if Entity.GetTeamNum(c) == State.team then
                    ln.ox, ln.oy, ln.on = ln.ox + p.x, ln.oy + p.y, ln.on + 1
                    if not ln.base then                                          -- one our-creep's engine speed per lane (catches the side-lane modifiers)
                        local ok, v = pcall(function() return NPC.GetMoveSpeed and NPC.GetMoveSpeed(c) end); if ok and type(v) == "number" then ln.api = v end
                        local ok2, b = pcall(function() return NPC.GetBaseSpeed and NPC.GetBaseSpeed(c) end); if ok2 and type(b) == "number" then ln.base = b end
                    end
                else
                    ln.ex, ln.ey, ln.en = ln.ex + p.x, ln.ey + p.y, ln.en + 1
                end
            end
        end
    end
    -- ROLE-MIRROR pairing (team-aware): a wave mirrors the enemy wave of the SAME ROLE, which sits on
    -- the OPPOSITE side of the map. Radiant safe=bot/off=top; Dire safe=top/off=bot. So mid<->mid,
    -- our safe<->enemy safe (opposite lane), our off<->enemy off. C=midpoint(our, role-paired enemy)
    -- should be the per-role symmetry center if the mirror holds (enemy wave = reflect(our role wave)).
    local rad = (State.team == 2)
    local roles = {
        { role = "mid",  ours = "mid",                  theirs = "mid" },
        { role = "safe", ours = rad and "bot" or "top", theirs = rad and "top" or "bot" },
        { role = "off",  ours = rad and "top" or "bot", theirs = rad and "bot" or "top" },
    }
    State.lastSpd = State.lastSpd or {}
    for _, r in ipairs(roles) do
        local o, e = L[r.ours], L[r.theirs]
        if o.on > 0 then
            local ocx, ocy = o.ox / o.on, o.oy / o.on
            local measured, last = nil, State.lastSpd[r.role]
            if last then local dt = now() - last.t; if dt > 0 then measured = math.sqrt((ocx - last.x) ^ 2 + (ocy - last.y) ^ 2) / dt end end
            State.lastSpd[r.role] = { x = ocx, y = ocy, t = now() }
            local line = string.format("creepspd t=%.1f role=%s ourlane=%s on=%d our=(%.0f,%.0f) api=%s base=%s measured=%s",
                now(), r.role, r.ours, o.on, ocx, ocy, o.api and string.format("%.0f", o.api) or "nil",
                o.base and string.format("%.0f", o.base) or "nil", measured and string.format("%.0f", measured) or "nil")
            if e.en > 0 then
                local ecx, ecy = e.ex / e.en, e.ey / e.en
                line = line .. string.format(" enlane=%s en=%d enemy=(%.0f,%.0f) C=(%.0f,%.0f)", r.theirs, e.en, ecx, ecy, (ocx + ecx) / 2, (ocy + ecy) / 2)
            end
            logline(line)
        else
            State.lastSpd[r.role] = nil
        end
    end
end


------------------------------------------------------------------ menu ------
local function setup_menu()
    local m = {}
    -- Menu.Find-then-Create so a script reload reuses the existing tabs instead
    -- of erroring on a duplicate Create.
    local function group(name)
        return Menu.Find("Heroes", "Hero List", "Tinker", "Brain", name)
            or Menu.Create("Heroes", "Hero List", "Tinker", "Brain", name)
    end
    local gFarm = group("Farm")
    local gDiag = group("Diagnostics")

    m.enable     = gFarm:Bind("Auto farm", Enum.ButtonCode.BUTTON_CODE_NONE, "\u{f11c}")
    m.kindJungle = gFarm:Switch("Farm jungle camps", true, "\u{f1bb}")
    m.kindLane   = gFarm:Switch("Farm lane (shove)", true, "\u{f0e7}")   -- OFF = never shove/farm the lane, jungle only
    -- ("Prioritize high-value camps" was deleted, glue review F3d: the switch was read nowhere -
    -- value priority lives in the planner objective.)
    m.mSmall     = gFarm:Slider("Marches: small", 1, 5, K.MARCHES[0], "%d")
    m.mMedium    = gFarm:Slider("Marches: medium", 1, 5, K.MARCHES[1], "%d")
    m.mLarge     = gFarm:Slider("Marches: large", 1, 5, K.MARCHES[2], "%d")
    m.mAncient   = gFarm:Slider("Marches: ancient", 1, 5, K.MARCHES[3], "%d")
    m.waveMaxW   = gFarm:Slider("Marches: lane wave (max W)", 1, 2, K.WAVE_MAX_W, "%d")   -- cap on W casts per lane-wave clear (v0.1.190 user hard rule: 2 absolute - the 3rd W killed nothing; code clamps too)
    m.escapeMana = gFarm:Slider("Escape mana reserve", 0, 400, K.ESCAPE_MANA, "%d")
    m.blinkEscape= gFarm:Switch("Use Blink: escape", true, "\u{f0e7}")   -- proactive flee blink (no-op without a dagger)
    m.blinkTravel= gFarm:Switch("Use Blink: travel", true, "\u{f124}")   -- blink to close farm-stand gaps when safe
    m.stackLarge = gFarm:Switch("Stack large camps", true)   -- v0.1.224: timed ~:54 aggro on route-near LARGE camps (2x cap; waves always win the window)
    m.sideLanes  = gFarm:Switch("Side-lane waves", true)   -- ALL-LANES v0.1.227 phase 1: top/bot waves fill the slack (mid > side > jungle); the swave trace names every snub

    m.diag       = gDiag:Slider("Verbosity (0=err 1=key 2=info 3=trace)", 0, 3, 1, "%d")
    m.debug      = gDiag:Switch("Debug overlay", true, "\u{f108}")   -- default ON during calibration: draws the STAND BOX + W coverage squares
    m.timeCap    = gDiag:Switch("Timing capture (log)", false, "\u{f017}")   -- measure REAL keen/rearm channel + cd + mana + fountain regen for the rebuild; default OFF
    -- ("Lane anticipation (A/B)" Switch RETIRED at v0.1.177: the T0 collapse - ON was the only
    -- tested path since the glue rebuild; the OFF branches are deleted from the code.)
    m.pairDbg    = gDiag:Switch("Pair debug (merged, live)", false, "\u{f0e8}")   -- live merged-pair overlay (new GreedyPairs logic) + logs the camp nearest the hero; walk Tinker to a camp to verify its pairing verdict
    m.markPair   = gDiag:Bind("Mark pairable here (key)", Enum.ButtonCode.BUTTON_CODE_NONE, "\u{f05b}")   -- press where a pair IS farmable but flagged single: logs hero pos + 2 nearest camps + drops a magenta marker
    m.testPairs  = gDiag:Bind("Test all pairs (overlay+log)", Enum.ButtonCode.BUTTON_CODE_NONE, "\u{f0c3}")
    m.scanLanes  = gDiag:Bind("Wave scan (overlay+log)", Enum.ButtonCode.BUTTON_CODE_NONE, "\u{f041}")
    m.scanRoute  = gDiag:Bind("Route scan (overlay+log)", Enum.ButtonCode.BUTTON_CODE_NONE, "\u{f018}")

    State.menu = m
    return m
end

-- TIMING CAPTURE (diagnostic, default OFF). Measures the REAL per-cast channel/cooldown/mana on this
-- patch + the fountain regen rate, so the rebuild's timing math uses ground truth instead of the flaky
-- web-summarized values. Run ~6 cast cycles (keen + rearm) + sit in the fountain, then read the
-- `timecap` + `fountregen` log lines (median the ~6 samples). Pure observation; no farm behaviour change.
local function tcap_sample()
    if not State.tcapArmed then State.tcapArmed = true; tlog(1, "timecap", { ARMED = "cast Keen/Rearm (manual or bot); sit in fountain not-full for regen" }) end
    local me = origin(State.hero)
    -- CHANNEL-transition detector: cooldown-INDEPENDENT (works in a no-cooldown demo AND for manual casts).
    -- Keen + Rearm are channeled; measure each channel (false -> true -> false) directly. Identify the
    -- ability by EFFECT: Keen teleports (a big position jump at channel end), Rearm does not.
    local chan = NPC.IsChannellingAbility and NPC.IsChannellingAbility(State.hero) == true
    local st = State.tcapChan
    if chan and not (st and st.active) then
        State.tcapChan = { active = true, t0 = now(), last = now(), p0 = { x = me.x, y = me.y } }
    elseif chan and st and st.active then
        st.last = now()
    elseif (not chan) and st and st.active then
        local dur   = (st.last or now()) - st.t0
        local moved = math.sqrt((me.x - st.p0.x) ^ 2 + (me.y - st.p0.y) ^ 2)
        local name  = (moved > 400) and "keen" or "rearm"          -- Keen teleports; Rearm channels in place
        local ab    = (name == "keen") and State.keen or State.rearm
        tlog(1, "timecap", { ab = name,
            lvl   = (ab and Ability.GetLevel and Ability.GetLevel(ab)) or 0,
            chan  = string.format("%.2f", dur),
            mana  = string.format("%.0f", (ab and Ability.GetManaCost and Ability.GetManaCost(ab)) or 0),
            moved = string.format("%.0f", moved) })
        st.active = false
    end
    -- fountain regen rate (per second + % of max) while inside the fountain aura (radius 1200).
    local fp = friendly_fountain_pos()
    if fp then
        local me = origin(State.hero)
        local dx, dy = me.x - fp.x, me.y - fp.y
        if dx * dx + dy * dy < 1200 * 1200 then
            local mn, hn = mana(), Entity.GetHealth(State.hero) or 0
            local s = State.fountSamp
            if s and (now() - s.t) >= 1.0 then
                local dt = now() - s.t
                local dm, dh = mn - s.m, hn - s.h
                if dm > 0 or dh > 0 then
                    local maxm = (NPC.GetMaxMana and NPC.GetMaxMana(State.hero)) or 1
                    local maxh = (Entity.GetMaxHealth and Entity.GetMaxHealth(State.hero)) or 1
                    tlog(1, "fountregen", {
                        dmana_s = string.format("%.0f", dm / dt), dhp_s = string.format("%.0f", dh / dt),
                        pct_m = string.format("%.2f", 100 * dm / maxm / dt),
                        pct_h = string.format("%.2f", 100 * dh / maxh / dt),
                        maxm = string.format("%.0f", maxm), maxh = string.format("%.0f", maxh) })
                end
                State.fountSamp = { t = now(), m = mn, h = hn }
            elseif not s then
                State.fountSamp = { t = now(), m = mn, h = hn }
            end
        else
            State.fountSamp = nil
        end
    end
end

--------------------------------------------------------------- callbacks ----
local callbacks = {}

function callbacks.OnUpdateEx()
    State.frame_t = now()   -- per-frame clock sample (skeleton idiom; tick fns read now())
    if not Engine.IsInGame() then return end
    if not State.hero then
        local h = Heroes.GetLocal()
        if h then
            State.hero = h
            State.player = Players.GetLocal()
            State.team = Entity.GetTeamNum(h)
            tlog(1, "self_acquired", { team = State.team })
        end
    end
    if not State.hero then return end
    if not (State.march and State.rearm and State.keen and State.laser) then
        refresh_handles(State.hero)   -- bind ability handles only until all present (stable after)
    end
    if State.menu.timeCap:Get() then tcap_sample() end                       -- timing-capture diagnostic (default off; no creepspd spam)
    debug_camp_scan()                                                        -- occupancy scan at level 1 (throttled 2s); no Debug toggle needed
    if State.menu.debug:Get() then
        if not State.dumped then dump_positions(); State.dumped = true end   -- full structure dump (needs the Debug switch)
        sample_creep_speed()                                                 -- v0.1.113: validate creep speed/distance/timing vs the math
    end
    if State.menu.testPairs:IsToggled() then                                 -- one-press "test all pairs" (works whether or not auto-farm is on)
        if not State.testKeyDown then State.testKeyDown = true; run_pair_test() end
    else
        State.testKeyDown = false
    end
    if State.menu.markPair:IsToggled() then                                  -- one-press "mark pairable here" (log the hero pos + 2 nearest camps; drop a marker)
        if not State.markKeyDown then State.markKeyDown = true; mark_pairable() end
    else
        State.markKeyDown = false
    end
    if now() >= (State.nextAutoScan or 0) then                               -- v0.1.92: automatic all-lanes wavescan LOG (no overlay; whether or not auto-farm is on)
        State.nextAutoScan = now() + K.AUTO_WAVESCAN_S
        run_lane_scan(false)
    end
    if State.menu.scanLanes:IsToggled() then                                 -- the bind now just ARMS the visual overlay (the log is automatic above)
        if not State.scanKeyDown then State.scanKeyDown = true; run_lane_scan(true) end
    else
        State.scanKeyDown = false
    end
    if State.menu.scanRoute:IsToggled() then                                 -- one-press "route scan" (planner diagnostic; no farm behaviour)
        if not State.routeKeyDown then State.routeKeyDown = true; run_route_scan() end
    else
        State.routeKeyDown = false
    end
    if not State.menu.enable:IsToggled() then                               -- on (re)enable, start by refilling
        State.fsm = "RETURN"; State.spot = nil; return
    end
    if not Entity.IsAlive(State.hero) then State.fsm = "RETURN"; State.spot = nil; return end
    tick()
end

function callbacks.OnDraw()
    draw_status()
    draw_debug()
    draw_pair_test()
    draw_pair_debug()
    draw_pair_marks()
    draw_lane_scan()
    draw_route_scan()
end

----------------------------------------------------------------- wiring -----
setup_menu()

-- Hero gate: UCZone loads every scripts/*.lua for every match regardless of the
-- picked hero. Wrap every callback so it no-ops on non-Tinker heroes.
State.is_our_hero = function()
    local h = Heroes.GetLocal()
    if not h or not Entity.IsEntity(h) or not Entity.IsNPC(h) then return false end
    return NPC.GetUnitName(h) == "npc_dota_hero_" .. HERO_KEY
end
for cb_name, cb_fn in pairs(callbacks) do
    callbacks[cb_name] = function(...)
        if not State.is_our_hero() then return end
        return cb_fn(...)
    end
end

if LOG then LOG:info("Tinker brain v0.1.245 (INSTRUMENT CLEANUP after the flicker arc closed: run-62 + user confirm [flicker GONE visually; ext_move 0, gap=0 drumbeat 1 benign line, audits clean]. REMOVED the one-run diagnostic scaffolding: the mv src= issue log, the mv_intr cast-interrupt log, the ext_move rising-edge detector + State.wasRunning/lastOrderT. KEPT: move_to's src param [producer names ride State.lastMove.src for any future move-level diagnosis] and the two v0.1.244 arrival-epsilon guards [lane_go walk rung + move_stand: no order within WAVE_HOLD_EPS of the destination - THE fix]. W-CANCEL [v0.1.242] stays live [march_cancel, validated run-60]. NO behavior change vs .244. Suite 706/0.") end

return callbacks
