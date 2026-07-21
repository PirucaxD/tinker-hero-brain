#!/usr/bin/env lua
-- tools/parse_debuglog.lua - turn debug.log into a per-frame timeline.
--
-- Usage (from a terminal with Lua 5.1+ available):
--   lua tools/parse_debuglog.lua C:\Umbrella\debug.log
--   lua tools/parse_debuglog.lua C:\Umbrella\debug.log --hero=Sniper
--   lua tools/parse_debuglog.lua C:\Umbrella\debug.log --grep=layer1_dispatch
--   lua tools/parse_debuglog.lua C:\Umbrella\debug.log --since=120 --until=180
--   lua tools/parse_debuglog.lua C:\Umbrella\debug.log --summary
--
-- Output: one event per line, formatted as a compact timeline. Events with
-- a `_t` or `t=` field are sorted by that timestamp; lines without are kept
-- in source order.
--
-- This is a READ-ONLY tool - no game-state mutation. Safe to run while
-- a match is in progress (file is read-locked briefly).

local function usage()
    io.stderr:write([[
parse_debuglog.lua <path-to-debug.log> [options]

Options:
  --hero=Name            Filter to one hero's events (default: all)
  --grep=substring       Filter to events whose name matches
  --since=N              Skip events before relative-time N seconds
  --until=N              Skip events after relative-time N seconds
  --summary              Print event-name → count summary instead of timeline
  --modseen              Print modseen_summary + first 50 unique modifiers
  --postmortem           Print death_postmortem lines + surrounding context
  --aggression-report    Parse cast_outcome → R-kill rate, damage-per-R, false-positive commits
  --defense-report       Parse save_outcome → survival rate per threat, HP nadir, save latency
  --farm-report          Parse `farm` trace → per-wave coverage, prediction accuracy, risk/veto/cadence
  --lane-report          Parse the 2s `wavescan` series → arrival timing vs NextWaveArrival + real
                         spawn-grid phase, ExpectedWave hp truth (est->real), meeting drift (Piece 1)
  --cycle-report         Per-shove-cycle timeline (decide -> keen -> tether -> step_out -> engage):
                         transit share, tether/idle time, early timed casts. Task #12 instrument.
  --time-report          Full-run TIME accounting (every second classified per decide segment:
                         engage/walk/wait/tether/fountain/idle) + GOLD accounting per pick type
                         (from the cumulative gpm field) + all holds > 10s. GPM-study instrument.
  --depth-audit          THE WALK-LAW VERIFIER: flags every positional event (stand commit, keen
                         landing, tether hold, W cast) past the stairs line while Keen < L2.
                         Zero violations = the invariant held. Run after EVERY session.
  --farm-audit           THE CAMP-ECONOMICS VERIFIER (v0.1.199): per farm decide, checks the afford
                         gate against its own numbers (ok>0 <=> pm >= need), flags refill picks that
                         cannot unlock any camp even at the mana ceiling (need > cap), and flags
                         illegal singles (paired=false pick with a partner in pair range, nnd<=1800).
                         Zero violations = the gate + pair rule held. Run after EVERY session.
  --keen-report          THE KEEN-EFFICIENCY LEDGER: every keen (keen_to_anchor + keen_home)
                         classified by outcome - bounce (re-keen <15s, nothing farmed), long-walk
                         (residual > 1000), home-cycle (keen_home outside a refill/recover pick),
                         home-refill, raid, productive (cast/farm followed), short-hop (rest) -
                         with caller (lane_go variant), nearest decide's pick/mana/klvl, and
                         estimated keen mana per class (Keen 75 flat; rearm_reset rungs +~225).

]])
end

-- Brain log format from `tlog()`:
--   [LEVEL] [Hero] event_name | k=v k2=v2 k3=v3
-- LEVEL is one of [INFO] [WARN] [ERROR]. Hero is the brain name. Parse with
-- a permissive regex so future hero names just work.
local function parse_line(line)
    local level, hero, body = line:match("^%[(%w+)%]%s*%[([^%]]+)%]%s*(.+)$")
    if not level or not hero then return nil end
    local event, kvs = body:match("^(%S+)%s*|?%s*(.*)$")
    if not event then return nil end
    local kv = {}
    for k, v in kvs:gmatch("(%S+)=(%S+)") do
        kv[k] = v
    end
    return { level = level, hero = hero, event = event, kv = kv, raw = line }
end

-- ---- arg parsing ----
local path
local opt_hero, opt_grep, opt_since, opt_until = nil, nil, nil, nil
local mode = "timeline"  -- timeline | summary | modseen | postmortem
local mode_count = 0     -- v6.15.2 M7: warn on multiple mode flags
for i = 1, #arg do
    local a = arg[i]
    if not path and not a:match("^%-%-") then
        path = a
    elseif a:match("^%-%-hero=") then opt_hero = a:sub(8)
    elseif a:match("^%-%-grep=") then opt_grep = a:sub(8)
    elseif a:match("^%-%-since=") then opt_since = tonumber(a:sub(9))
    elseif a:match("^%-%-until=") then opt_until = tonumber(a:sub(9))
    elseif a == "--summary" then mode = "summary"; mode_count = mode_count + 1
    elseif a == "--modseen" then mode = "modseen"; mode_count = mode_count + 1
    elseif a == "--postmortem" then mode = "postmortem"; mode_count = mode_count + 1
    elseif a == "--aggression-report" then mode = "aggression_report"; mode_count = mode_count + 1
    elseif a == "--defense-report" then mode = "defense_report"; mode_count = mode_count + 1
    elseif a == "--farm-report" then mode = "farm_report"; mode_count = mode_count + 1
    elseif a == "--lane-report" then mode = "lane_report"; mode_count = mode_count + 1
    elseif a == "--cycle-report" then mode = "cycle_report"; mode_count = mode_count + 1
    elseif a == "--time-report" then mode = "time_report"; mode_count = mode_count + 1
    elseif a == "--depth-audit" then mode = "depth_audit"; mode_count = mode_count + 1
    elseif a == "--cast-report" then mode = "cast_report"; mode_count = mode_count + 1
    elseif a == "--convert-report" then mode = "convert_report"; mode_count = mode_count + 1
    elseif a == "--farm-audit" then mode = "farm_audit"; mode_count = mode_count + 1
    elseif a == "--keen-report" then mode = "keen_report"; mode_count = mode_count + 1
    elseif a == "--help" or a == "-h" then usage(); os.exit(0)
    end
end
if not path then usage(); os.exit(1) end
if mode_count > 1 then
    io.stderr:write("warning: multiple mode flags passed; using --" .. mode .. "\n")
end

-- ---- read ----
local f = io.open(path, "r")
if not f then io.stderr:write("cannot open " .. path .. "\n"); os.exit(2) end

-- v6.15.2 H7: --since / --until previously dead options. Wire them in.
-- Events expose a relative timestamp via `t=` or `_t=` kv field set by tlog().
-- Filter inclusively: keep if (no since OR ts >= since) AND (no until OR ts <= until).
local events = {}
local summary_counts = {}
for line in f:lines() do
    local e = parse_line(line)
    if e then
        local ts = tonumber(e.kv.t or e.kv._t)
        local time_ok = (not opt_since or (ts and ts >= opt_since))
                    and (not opt_until or (ts and ts <= opt_until))
        if (not opt_hero or e.hero == opt_hero)
           and (not opt_grep or e.event:find(opt_grep, 1, true))
           and time_ok then
            events[#events + 1] = e
            summary_counts[e.event] = (summary_counts[e.event] or 0) + 1
        end
    end
end
f:close()

-- ---- render ----
if mode == "summary" then
    -- sort by count desc
    local pairs_arr = {}
    for k, v in pairs(summary_counts) do pairs_arr[#pairs_arr + 1] = { k, v } end
    table.sort(pairs_arr, function(a, b) return a[2] > b[2] end)
    print("event\tcount")
    for i = 1, #pairs_arr do
        print(pairs_arr[i][1] .. "\t" .. pairs_arr[i][2])
    end
    os.exit(0)
elseif mode == "modseen" then
    print("--- modseen_summary (unique modifier names observed) ---")
    local seen = {}
    for i = 1, #events do
        local e = events[i]
        if e.event == "modseen" or e.event == "modseen_entry" then
            local key = (e.kv.unit or "?") .. ":" .. (e.kv.mod or e.kv.key or "?")
            if not seen[key] then
                seen[key] = e.kv.caster or "-"
                print(key .. "\tcaster=" .. (e.kv.caster or "-"))
            end
        end
    end
    os.exit(0)
elseif mode == "postmortem" then
    print("--- death_postmortem entries ---")
    for i = 1, #events do
        local e = events[i]
        if e.event == "death_postmortem" then
            print(e.raw)
            -- context: previous 5 events
            for j = math.max(1, i - 5), i - 1 do
                print("  ctx -" .. (i - j) .. ": " .. events[j].raw)
            end
        end
    end
    os.exit(0)
elseif mode == "aggression_report" then
    -- v6.15.58 (G15): aggression report.
    -- v6.15.86 (CRITICAL fix - user feedback): the prior report counted
    -- cast_outcome events as "R casts" - that's WRONG. cast_outcome tracks
    -- target HP delta in a 5s window after `issued`, but doesn't verify
    -- R actually fired. In the v6.15.85 log, EVERY R cast_verify showed
    -- fired=n (engine cancelled R via native interference) - yet the
    -- report claimed 75% kill rate because the cast_outcome window caught
    -- damage from autos/Q that landed independently. Ground truth must be
    -- cast_verify fired=y. Now:
    --   1. First pass: build per-intent map of LATEST cast_verify fired status
    --   2. Second pass: cast_outcome only counts when verified fired=y
    --   3. Report shows BOTH verified count and raw count so the user can
    --      see the gap if cast cancellation is happening.
    print("--- aggression report ---")
    local last_verify = {}        -- intent → latest fired status ("y"/"n")
    local fire_count_per_intent = {}  -- intent → count of fired=y verifies
    local double_fail_per_intent = {} -- intent → count of double_fail events
    for i = 1, #events do
        local e = events[i]
        if e.event == "cast_verify" then
            local intent = e.kv.intent or "?"
            last_verify[intent] = e.kv.fired
            if e.kv.fired == "y" then
                fire_count_per_intent[intent] = (fire_count_per_intent[intent] or 0) + 1
            end
        elseif e.event == "cast_verify_double_fail" then
            local intent = e.kv.intent or "?"
            double_fail_per_intent[intent] = (double_fail_per_intent[intent] or 0) + 1
            last_verify[intent] = "n"  -- explicit fail
        end
    end
    local n_total, n_kill, n_alive, n_respawn = 0, 0, 0, 0
    local n_raw_outcome, n_bogus_outcome = 0, 0
    local sum_hp_delta_pct = 0
    local per_intent = {}        -- intent → {casts, kills}
    local per_target = {}        -- target → {casts, kills}
    local hp_delta_buckets = { [0]=0, [25]=0, [50]=0, [75]=0, [100]=0 }
    -- Track per-intent last verify dynamically as we iterate (events are
    -- in source order; cast_verify precedes cast_outcome for any one issue).
    local rolling_verify = {}
    for i = 1, #events do
        local e = events[i]
        if e.event == "cast_verify" then
            rolling_verify[e.kv.intent or "?"] = e.kv.fired
        elseif e.event == "cast_verify_double_fail" then
            rolling_verify[e.kv.intent or "?"] = "n"
        elseif e.event == "cast_outcome" then
            n_raw_outcome = n_raw_outcome + 1
            local intent = e.kv.intent or "?"
            -- v6.15.86: REJECT if the most recent cast_verify for this
            -- intent shows R didn't actually fire. The cast_outcome HP
            -- delta is then attributable to autos/Q/headshot, not R.
            if rolling_verify[intent] ~= "y" then
                n_bogus_outcome = n_bogus_outcome + 1
                goto continue
            end
            n_total = n_total + 1
            local alive = e.kv.alive == "y"
            local respawn = e.kv.respawn == "y"
            local target = e.kv.target or "?"
            local hp_dp = tonumber(e.kv.hp_delta_pct) or 0
            sum_hp_delta_pct = sum_hp_delta_pct + (hp_dp > 0 and hp_dp or 0)
            per_intent[intent] = per_intent[intent] or { casts = 0, kills = 0 }
            per_intent[intent].casts = per_intent[intent].casts + 1
            per_target[target] = per_target[target] or { casts = 0, kills = 0 }
            per_target[target].casts = per_target[target].casts + 1
            if respawn then
                n_respawn = n_respawn + 1
                n_kill = n_kill + 1
                per_intent[intent].kills = per_intent[intent].kills + 1
                per_target[target].kills = per_target[target].kills + 1
            elseif not alive then
                n_kill = n_kill + 1
                per_intent[intent].kills = per_intent[intent].kills + 1
                per_target[target].kills = per_target[target].kills + 1
            else
                n_alive = n_alive + 1
            end
            -- HP delta bucket
            local b = 0
            if hp_dp >= 100 then b = 100
            elseif hp_dp >= 75 then b = 75
            elseif hp_dp >= 50 then b = 50
            elseif hp_dp >= 25 then b = 25 end
            hp_delta_buckets[b] = hp_delta_buckets[b] + 1
            ::continue::
        end
    end
    -- v6.15.86: surface verified R fires and double-fails specifically for
    -- R steps (intent ending in "_r" - snipe_e_r_r, snipe_q_r_r, etc.).
    -- Counts Q/E/D fires don't help diagnose "did R actually go off".
    local verified_R = 0
    local double_fail_R = 0
    for intent, n in pairs(fire_count_per_intent) do
        if intent:sub(-2) == "_r" then verified_R = verified_R + n end
    end
    for intent, n in pairs(double_fail_per_intent) do
        if intent:sub(-2) == "_r" then double_fail_R = double_fail_R + n end
    end
    print(string.format("  cast_outcome events (raw):       %d", n_raw_outcome))
    print(string.format("  bogus outcomes (R never fired):  %d  ← cast_verify fired=n",
                        n_bogus_outcome))
    print(string.format("  verified R fires (fired=y on _r intents):  %d", verified_R))
    print(string.format("  R double-fails (engine cancelled cast):    %d", double_fail_R))
    if verified_R == 0 and n_raw_outcome > 0 then
        print("")
        print("  ** WARNING: R never actually fired in this session.")
        print("  ** All cast_outcome 'kills' are autos/Q/headshot - bogus attribution.")
        print("  ** Investigate cast_verify_double_fail events + r_cast_protect_veto.")
    end
    print("")
    if n_total == 0 then
        print("  (no verified R fires - see above warning)")
        os.exit(0)
    end
    local kill_rate = (n_kill / n_total) * 100
    local avg_dmg = sum_hp_delta_pct / n_total
    print(string.format("  verified R casts:   %d", n_total))
    print(string.format("  kills:              %d (%.1f%%)", n_kill, kill_rate))
    print(string.format("  alive after (FP):   %d", n_alive))
    print(string.format("  respawn-attributed: %d", n_respawn))
    print(string.format("  avg damage per R:   %.1f%% of target max HP", avg_dmg))
    print("")
    print("  hp_delta_pct distribution:")
    for _, b in ipairs({0, 25, 50, 75, 100}) do
        local label = (b == 100) and ">=100%" or string.format("%d-%d%%", b, b + 24)
        if b == 0 then label = "0-24%" end
        print(string.format("    %-9s %d", label, hp_delta_buckets[b] or 0))
    end
    print("")
    print("  per-intent kill rates:")
    local intent_keys = {}
    for k in pairs(per_intent) do intent_keys[#intent_keys + 1] = k end
    table.sort(intent_keys)
    for _, k in ipairs(intent_keys) do
        local v = per_intent[k]
        local r = v.casts > 0 and (v.kills / v.casts * 100) or 0
        print(string.format("    %-30s %d casts, %d kills (%.0f%%)",
            k, v.casts, v.kills, r))
    end
    print("")
    print("  per-target kill rates:")
    local target_keys = {}
    for k in pairs(per_target) do target_keys[#target_keys + 1] = k end
    table.sort(target_keys)
    for _, k in ipairs(target_keys) do
        local v = per_target[k]
        local r = v.casts > 0 and (v.kills / v.casts * 100) or 0
        print(string.format("    %-20s %d casts, %d kills (%.0f%%)",
            k, v.casts, v.kills, r))
    end
    os.exit(0)
elseif mode == "defense_report" then
    -- v6.15.58 (G15): defense report. Parse save_outcome events into
    -- survival rate per threat, HP nadir distribution, save latency.
    print("--- defense report ---")
    local n_total, n_alive, n_no_save = 0, 0, 0
    local per_threat = {}        -- threat → {events, alive, no_save, sum_hp_pct_min, sum_latency}
    local per_save = {}          -- save → count
    local latency_buckets = { [0]=0, [100]=0, [250]=0, [500]=0, [1000]=0 }
    local hp_nadir_buckets = { [0]=0, [25]=0, [50]=0, [75]=0, [100]=0 }
    for i = 1, #events do
        local e = events[i]
        if e.event == "save_outcome" then
            n_total = n_total + 1
            local alive = e.kv.alive == "y"
            local save_fired = e.kv.save and e.kv.save ~= "-"
            local threat = e.kv.threat or "?"
            local lat = tonumber(e.kv.latency_ms) or -1
            local hp_pct = tonumber(e.kv.hp_pct_min) or 100
            if alive then n_alive = n_alive + 1 end
            if not save_fired then n_no_save = n_no_save + 1 end
            per_threat[threat] = per_threat[threat] or {
                events = 0, alive = 0, no_save = 0,
                sum_hp_pct_min = 0, sum_latency = 0, lat_count = 0,
            }
            local t = per_threat[threat]
            t.events = t.events + 1
            if alive then t.alive = t.alive + 1 end
            if not save_fired then t.no_save = t.no_save + 1 end
            t.sum_hp_pct_min = t.sum_hp_pct_min + hp_pct
            if lat >= 0 then
                t.sum_latency = t.sum_latency + lat
                t.lat_count = t.lat_count + 1
            end
            if save_fired then
                per_save[e.kv.save] = (per_save[e.kv.save] or 0) + 1
            end
            -- Latency bucket (only if save fired)
            if lat >= 0 then
                local b = 0
                if lat >= 1000 then b = 1000
                elseif lat >= 500 then b = 500
                elseif lat >= 250 then b = 250
                elseif lat >= 100 then b = 100 end
                latency_buckets[b] = latency_buckets[b] + 1
            end
            -- HP nadir bucket
            local hb = 0
            if hp_pct >= 100 then hb = 100
            elseif hp_pct >= 75 then hb = 75
            elseif hp_pct >= 50 then hb = 50
            elseif hp_pct >= 25 then hb = 25 end
            hp_nadir_buckets[hb] = hp_nadir_buckets[hb] + 1
        end
    end
    if n_total == 0 then
        print("  (no save_outcome events found)")
        os.exit(0)
    end
    local survive = (n_alive / n_total) * 100
    print(string.format("  total threats:      %d", n_total))
    print(string.format("  survived:           %d (%.1f%%)", n_alive, survive))
    print(string.format("  no save fired:      %d", n_no_save))
    print("")
    print("  per-threat outcomes:")
    local threat_keys = {}
    for k in pairs(per_threat) do threat_keys[#threat_keys + 1] = k end
    table.sort(threat_keys)
    for _, k in ipairs(threat_keys) do
        local t = per_threat[k]
        local s = t.events > 0 and (t.alive / t.events * 100) or 0
        local avg_hp = t.events > 0 and (t.sum_hp_pct_min / t.events) or 100
        local avg_lat = t.lat_count > 0 and (t.sum_latency / t.lat_count) or -1
        print(string.format(
            "    %-50s %d events, %d alive (%.0f%%), %d no-save, avg hp_min %.0f%%, avg lat %d ms",
            k, t.events, t.alive, s, t.no_save, avg_hp, avg_lat))
    end
    print("")
    print("  per-save usage:")
    local save_keys = {}
    for k in pairs(per_save) do save_keys[#save_keys + 1] = k end
    table.sort(save_keys)
    for _, k in ipairs(save_keys) do
        print(string.format("    %-25s %d", k, per_save[k]))
    end
    print("")
    print("  save latency distribution (ms, only fired saves):")
    local lat_labels = {
        [0]    = "0-99ms",
        [100]  = "100-249ms",
        [250]  = "250-499ms",
        [500]  = "500-999ms",
        [1000] = ">=1000ms",
    }
    for _, b in ipairs({0, 100, 250, 500, 1000}) do
        print(string.format("    %-12s %d", lat_labels[b], latency_buckets[b] or 0))
    end
    print("")
    print("  HP nadir distribution (% of max HP at lowest point during threat):")
    for _, b in ipairs({0, 25, 50, 75, 100}) do
        local label = (b == 100) and ">=100%" or string.format("%d-%d%%", b, b + 24)
        if b == 0 then label = "0-24% (NEAR DEATH)" end
        print(string.format("    %-22s %d", label, hp_nadir_buckets[b] or 0))
    end
    os.exit(0)
elseif mode == "farm_report" then
    -- v0.1.91: per-wave accounting + scheduler diagnostics from the consolidated `farm` trace.
    -- Answers the bug-hunt KEY QUESTIONS: lane coverage (of N waves, how many shoved + where the
    -- misses went), prediction accuracy (NextWaveArrival vs actual), risk abandonment, camp veto,
    -- decide cadence (rearm holds). Each number is log-backed - the point is to stop eyeballing.
    local WAVE_PERIOD, WAVE_PHASE = 30, 14   -- mirror Tinker K (Piece 1: measured 14.2 via the cycle-gated --lane-report; was the 22 guess)
    local farm = {}
    for i = 1, #events do
        if events[i].event == "farm" then farm[#farm + 1] = events[i] end
    end
    if #farm == 0 then
        print("  (no `farm` events found - need a v0.1.91+ log with diag verbosity >= 1)")
        os.exit(0)
    end
    table.sort(farm, function(a, b) return (tonumber(a.kv.t) or 0) < (tonumber(b.kv.t) or 0) end)
    local function med(t) return #t > 0 and t[math.ceil(#t / 2)] or 0 end  -- t must be pre-sorted
    local t0, t1 = tonumber(farm[1].kv.t) or 0, tonumber(farm[#farm].kv.t) or 0
    print(string.format("--- farm report --- %d decides over %.0fs (t %.1f .. %.1f)", #farm, t1 - t0, t0, t1))
    print("")

    -- 1) pick + scheduler-action distribution
    local pick_n, act_n, recover_reason = {}, {}, {}
    for _, e in ipairs(farm) do
        pick_n[e.kv.pick or "?"] = (pick_n[e.kv.pick or "?"] or 0) + 1
        act_n[e.kv.act or "?"] = (act_n[e.kv.act or "?"] or 0) + 1
        if e.kv.act == "recover" then recover_reason[e.kv.reason or "?"] = (recover_reason[e.kv.reason or "?"] or 0) + 1 end
    end
    local function dump(title, tbl, indent)
        print(title)
        local ks = {}; for k in pairs(tbl) do ks[#ks + 1] = k end; table.sort(ks)
        for _, k in ipairs(ks) do print(string.format("%s%-14s %d", indent, k, tbl[k])) end
    end
    dump("pick distribution (final FSM action per decide):", pick_n, "    ")
    dump("scheduler action (Tier-1 Schedule.Plan):", act_n, "    ")
    if next(recover_reason) then dump("  recover reasons:", recover_reason, "      ") end
    print("")

    -- 2) per-wave coverage (spawn grid): for each predicted mid arrival, was there a shove near it?
    local first_wave = WAVE_PHASE + math.ceil((t0 - WAVE_PHASE) / WAVE_PERIOD) * WAVE_PERIOD
    local n_wave, n_shoved, miss = 0, 0, {}
    for A = first_wave, t1, WAVE_PERIOD do
        n_wave = n_wave + 1
        local lo, hi = A - WAVE_PERIOD / 2, A + WAVE_PERIOD / 2
        local shoved, pc = false, {}
        for _, e in ipairs(farm) do
            local t = tonumber(e.kv.t) or -1
            if t >= lo and t < hi then
                -- ALL-LANES: only a MID shove counts as mid-wave coverage; a side-lane
                -- shove is a miss destination for the mid grid (it farmed elsewhere).
                if e.kv.pick == "shove" and (e.kv.lane or "mid") == "mid" then shoved = true
                else
                    local key = e.kv.pick or "?"
                    if key == "shove" then key = "side:" .. (e.kv.lane or "?")
                    elseif key == "camp" or key == "wave" then key = "jungle"
                    elseif key == "recover" then key = "recover:" .. (e.kv.reason or "?") end
                    pc[key] = (pc[key] or 0) + 1
                end
            end
        end
        if shoved then n_shoved = n_shoved + 1
        else
            local best, bn = "none", -1
            for k, c in pairs(pc) do if c > bn then best, bn = k, c end end
            miss[best] = (miss[best] or 0) + 1
        end
    end
    print(string.format("per-wave coverage (spawn grid phase=%d period=%d - CALIBRATION ASSUMPTION):", WAVE_PHASE, WAVE_PERIOD))
    print(string.format("    waves in window:  %d", n_wave))
    print(string.format("    shoved:           %d (%.0f%%)", n_shoved, n_wave > 0 and n_shoved / n_wave * 100 or 0))
    print(string.format("    missed:           %d", n_wave - n_shoved))
    if next(miss) then dump("    miss destinations:", miss, "        ") end
    print("")

    -- 3) prediction accuracy: on a vis n->y rising edge (mid wave appears), actual t vs last predicted dl.
    local errs, prev_vis, prev_dl = {}, nil, nil
    for _, e in ipairs(farm) do
        if e.kv.vis == "y" and prev_vis == "n" and prev_dl then
            local actual = tonumber(e.kv.t)
            if actual then errs[#errs + 1] = actual - prev_dl end
        end
        if e.kv.vis == "n" then prev_dl = tonumber(e.kv.dl) end
        prev_vis = e.kv.vis
    end
    print("prediction accuracy (actual mid-wave appearance vs predicted NextWaveArrival dl):")
    if #errs == 0 then print("    (no vis n->y transitions captured)")
    else
        table.sort(errs)
        local sum = 0; for _, x in ipairs(errs) do sum = sum + x end
        print(string.format("    samples: %d  median: %.1fs  mean: %.1fs  min: %.1f  max: %.1f",
            #errs, med(errs), sum / #errs, errs[1], errs[#errs]))
        print("    (positive = wave appeared LATER than predicted; negative = EARLIER)")
    end
    local shove_blind = 0
    for _, e in ipairs(farm) do if e.kv.pick == "shove" and e.kv.vis == "n" and (e.kv.lane or "mid") == "mid" then shove_blind = shove_blind + 1 end end
    print(string.format("    shoves toward a FOGGED (predicted) wave (pick=shove vis=n): %d", shove_blind))

    -- ALL-LANES: side-lane picks + swave verdict tallies (phase-1 validation view)
    local spick, sverd = { top = 0, bot = 0 }, {}
    for _, e in ipairs(farm) do
        local ln = e.kv.lane
        if e.kv.pick == "shove" and (ln == "top" or ln == "bot") then spick[ln] = spick[ln] + 1 end
        for _, k in ipairs({ "swtop", "swbot" }) do
            local v = e.kv[k]
            if v then
                local verdict = v:match("^([^:]+)")
                if verdict then sverd[verdict] = (sverd[verdict] or 0) + 1 end
            end
        end
    end
    print("")
    print(string.format("side-lane picks: top=%d bot=%d", spick.top, spick.bot))
    if next(sverd) then dump("side-lane swave verdicts:", sverd, "    ") end

    -- v0.1.230 WASTED-TRIP instrument (the run-49 t=176 signature): a pick=shove decide
    -- with real travel that never cast a single W before the next decide = the trip's
    -- transport was pure loss. Evidence base for the deferred gone-by-STAND-arrival rule.
    local wasted, wtravel, cur_shove, cast_seen = {}, 0, nil, false
    for _, e in ipairs(events) do
        if e.event == "farm" then
            if cur_shove and not cast_seen and (tonumber(cur_shove.kv.travel) or 0) > 2 then
                local ln = cur_shove.kv.lane or "mid"
                wasted[ln] = (wasted[ln] or 0) + 1
                wtravel = wtravel + (tonumber(cur_shove.kv.travel) or 0)
            end
            cur_shove = (e.kv.pick == "shove") and e or nil
            cast_seen = false
        elseif e.event == "march_aim" and e.kv.src == "shove" then
            cast_seen = true
        end
    end
    local wn = 0
    for _, c in pairs(wasted) do wn = wn + c end
    if wn > 0 then
        local parts = {}
        for ln, c in pairs(wasted) do parts[#parts + 1] = string.format("%s=%d", ln, c) end
        print(string.format("wasted shove trips (travel>2s, zero W before redecide): %d (%s, est travel %.0fs)",
            wn, table.concat(parts, " "), wtravel))
    else
        print("wasted shove trips (travel>2s, zero W before redecide): 0")
    end
    print("")

    -- 4) mid abandonment on risk
    local urisk = {}
    for _, e in ipairs(farm) do
        if e.kv.act == "recover" and e.kv.reason == "unsafe" then
            local r = tonumber(e.kv.risk); if r then urisk[#urisk + 1] = r end
        end
    end
    print("mid abandonment on risk (act=recover reason=unsafe):")
    if #urisk == 0 then print("    (none)")
    else
        table.sort(urisk)
        print(string.format("    count: %d  median risk: %.2f  min: %.2f  max: %.2f  (SHOVE_SAFE_RISK gate ~0.35)",
            #urisk, med(urisk), urisk[1], urisk[#urisk]))
    end
    print("")

    -- 5) camp veto proximity + reserve-vs-budget (lost-lane)
    local crisks, under_reserve, camp_n = {}, 0, 0
    for _, e in ipairs(farm) do
        if e.kv.pick == "camp" then
            camp_n = camp_n + 1
            local r = tonumber(e.kv.crisk); if r then crisks[#crisks + 1] = r end
            local b, rsv = tonumber(e.kv.budget), tonumber(e.kv.reserve)
            if b and rsv and b < rsv then under_reserve = under_reserve + 1 end
        end
    end
    print(string.format("camp picks: %d", camp_n))
    if #crisks > 0 then
        table.sort(crisks)
        print(string.format("    crisk median: %.2f  max: %.2f  (RISK_HARD veto = 0.34)", med(crisks), crisks[#crisks]))
        local near = 0; for _, x in ipairs(crisks) do if x >= 0.30 then near = near + 1 end end
        print(string.format("    camps picked at crisk >= 0.30 (near veto): %d", near))
    end
    print(string.format("    camps taken with camp-time budget < return reserve (lost-lane risk): %d", under_reserve))
    print("")

    -- 6) decide cadence (rearm holds) + gpm trend
    local gaps = {}
    for i = 2, #farm do
        local d = (tonumber(farm[i].kv.t) or 0) - (tonumber(farm[i - 1].kv.t) or 0)
        if d >= 0 then gaps[#gaps + 1] = d end
    end
    table.sort(gaps)
    -- NOTE: fsm_decide only re-decides when the FSM needs a NEW target (after a shove/camp
    -- finishes), so a "gap" is the DURATION of one farm action, NOT a stall. A burst of < 0.6s
    -- gaps means plan=0 flutter (no affordable spot) or a same-wave shove follow-up, not a hang.
    local flutter = 0; for _, g in ipairs(gaps) do if g < 0.6 then flutter = flutter + 1 end end
    print("decide cadence (gap = duration of one farm action; NOT a per-tick stall):")
    if #gaps > 0 then
        local span = t1 - t0
        print(string.format("    decides: %d over %.0fs (%.1f/min)  median action: %.1fs  max: %.1fs  rapid re-decides (<0.6s, plan=0 flutter / same-wave): %d",
            #farm, span, span > 0 and #farm / span * 60 or 0, med(gaps), gaps[#gaps], flutter))
    end
    local first_gpm, last_gpm
    for _, e in ipairs(farm) do if e.kv.gpm then first_gpm = first_gpm or e.kv.gpm; last_gpm = e.kv.gpm end end
    if first_gpm then print(string.format("    gpm: %s -> %s", first_gpm, last_gpm)) end
    os.exit(0)
elseif mode == "lane_report" then
    -- Piece 1 (lane foundation): measure the WAVE INSTRUMENTS against observed reality, from the 2s
    -- auto-wavescan series (clean k=v format). Every number is log-backed: arrival timing vs
    -- NextWaveArrival + the REAL spawn-grid phase (the WAVE_PHASE calibration), ExpectedWave hp truth
    -- at est->real transitions, and meeting drift (how far the early meeting estimate moved by arrival).
    local function pt(s)
        if not s or s == "-" then return nil end
        local x, y = s:match("^(%-?%d+);(%-?%d+)$")
        return x and { x = tonumber(x), y = tonumber(y) } or nil
    end
    local function dist(p, q)
        if not (p and q) then return nil end
        local dx, dy = p.x - q.x, p.y - q.y
        return math.sqrt(dx * dx + dy * dy)
    end
    local scans, hdr = {}, nil
    for i = 1, #events do
        local e = events[i]
        if e.event == "wavescan" then
            if e.kv.t and not e.kv.ln then
                hdr = e.kv
            elseif e.kv.ln == "mid" and hdr then
                local kp = tonumber(hdr.kpred)
                scans[#scans + 1] = {
                    t = tonumber(hdr.t) or 0, pred = tonumber(hdr.pred),
                    kpred = (kp and kp >= 0) and kp or nil,   -- Piece 1.5: kinematic candidate (-1 = unavailable)
                    e = tonumber(e.kv.e) or 0, est = e.kv.est == "y",
                    src = e.kv.src, hp = tonumber(e.kv.hp) or 0,
                    bal = tonumber(e.kv.bal),                 -- Piece 1.5: sim balance (+ = our lane pushes)
                    ef = pt(e.kv.ef), af = pt(e.kv.af), meet = pt(e.kv.meet),
                }
            end
        end
    end
    if #scans == 0 then
        print("  (no k=v wavescan events - need the Piece-1 format + diag verbosity >= 1)")
        os.exit(0)
    end
    table.sort(scans, function(a, b) return a.t < b.t end)
    local function med(t) table.sort(t); return #t > 0 and t[math.ceil(#t / 2)] or 0 end
    print(string.format("--- lane instruments report --- %d mid scans over %.0fs (t %.1f .. %.1f)",
        #scans, scans[#scans].t - scans[1].t, scans[1].t, scans[#scans].t))
    local real = 0
    for _, s in ipairs(scans) do if s.e > 0 and not s.est then real = real + 1 end end
    print(string.format("  vision coverage: %d/%d scans see a REAL enemy mid wave (rest fogged-est/empty)", real, #scans))
    print("")

    -- 1) ARRIVALS: a REAL enemy front within ARRIVE_D of the meeting = an observed arrival.
    --    CYCLE GATE (v2): in a continuous lane battle the enemy front sits near the meeting the whole
    --    time, so a naive proximity+dedup trigger re-fires every dedup window (the first run showed
    --    impossible ~22s inter-arrivals on a 30s spawn grid = engagement re-detections). A NEW arrival
    --    only counts after the front has first RETREATED beyond RESET_D from the meeting (the fresh
    --    wave spawning far) - one event per genuine approach cycle.
    --    err = pred (from the scan just before) - actual t. Median observed PHASE = the true WAVE_PHASE.
    local ARRIVE_D, RESET_D = 400, 1200
    local arrivals, armed = {}, true
    for i = 1, #scans do
        local s = scans[i]
        local d = (not s.est) and s.e > 0 and dist(s.ef, s.meet) or nil
        if d and d > RESET_D then armed = true end
        if armed and d and d <= ARRIVE_D then
            local prev = scans[i - 1]
            arrivals[#arrivals + 1] = { t = s.t, phase = s.t % 30, i = i,
                                        pred = (prev and prev.pred) or s.pred,
                                        kpred = (prev and prev.kpred) or s.kpred }
            armed = false
        end
    end
    print(string.format("wave ARRIVALS observed (real enemy front within %du of the meeting): %d", ARRIVE_D, #arrivals))
    local errs, kerrs, phases = {}, {}, {}
    for _, a in ipairs(arrivals) do
        local err  = a.pred and (a.pred - a.t) or nil
        local kerr = a.kpred and (a.kpred - a.t) or nil
        if err  then errs[#errs + 1] = err end
        if kerr then kerrs[#kerrs + 1] = kerr end
        phases[#phases + 1] = a.phase
        print(string.format("    t=%.1f phase=%.1f pred=%s err=%s kpred=%s kerr=%s", a.t, a.phase,
            a.pred and string.format("%.1f", a.pred) or "-",
            err and string.format("%+.1f", err) or "-",
            a.kpred and string.format("%.1f", a.kpred) or "-",
            kerr and string.format("%+.1f", kerr) or "-"))
    end
    if #phases > 0 then
        print(string.format("  observed spawn-grid phase: median %.1f (K.WAVE_PHASE calibration; current 17)", med(phases)))
    end
    if #errs > 0 then
        print(string.format("  grid pred error (pred-actual): median %+.1fs over %d arrivals (+late/-early; ~+25 means the phase is ~5s EARLY, grid rolled)", med(errs), #errs))
    end
    if #kerrs > 0 then
        print(string.format("  KINEMATIC kpred error: median %+.1fs over %d arrivals (Piece 1.5 candidate; wins -> replaces the grid in Piece 2)", med(kerrs), #kerrs))
    end
    print("")

    -- 2) estimate truth at est->real transitions (<=6s apart): hp (ExpectedWave clock model) and,
    --    when the estimate carried a MIRRORED front, position error (the Piece 1.5 mirror on trial).
    local pairs_n, hp_errs, pos_errs = 0, {}, {}
    for i = 2, #scans do
        local p, s = scans[i - 1], scans[i]
        if p.est and p.hp > 0 and (not s.est) and s.e > 0 and s.hp > 0 and (s.t - p.t) <= 6 then
            pairs_n = pairs_n + 1
            hp_errs[#hp_errs + 1] = (p.hp - s.hp) / s.hp * 100
            local pe = dist(p.ef, s.ef)
            if pe then pos_errs[#pos_errs + 1] = pe end
        end
    end
    print(string.format("estimate truth (est->real transitions <=6s apart): %d pairs", pairs_n))
    if pairs_n > 0 then
        print(string.format("  est-vs-real hp error: median %+.0f%% (positive = estimate runs HIGH)", med(hp_errs)))
    end
    if #pos_errs > 0 then
        local mx = 0
        for _, d in ipairs(pos_errs) do if d > mx then mx = d end end
        print(string.format("  MIRROR position error (mirrored front vs first real front): median %.0fu, max %.0fu over %d", med(pos_errs), mx, #pos_errs))
    else
        print("  (no mirrored-front transitions captured - mirror position unjudged this run)")
    end
    print("")

    -- 3) MEETING DRIFT: the meeting estimate at the START of each approach cycle vs at arrival - how
    --    far the aim (and so the stand computed from it) moved while the wave closed.
    local drifts = {}
    for _, a in ipairs(arrivals) do
        local firstMeet
        for j = a.i - 1, 1, -1 do
            local s = scans[j]
            if a.t - s.t > 25 then break end
            if s.e > 0 and s.meet then firstMeet = s.meet end   -- keep walking back to the cycle start
        end
        local d = dist(firstMeet, scans[a.i].meet)
        if d then drifts[#drifts + 1] = d end
    end
    print(string.format("meeting drift (estimate at cycle start vs at arrival): %d cycles", #drifts))
    if #drifts > 0 then
        local mx = 0
        for _, d in ipairs(drifts) do if d > mx then mx = d end end
        print(string.format("  drift: median %.0fu, max %.0fu (large = the early aim/stand was computed from a lying meeting)", med(drifts), mx))
    end
    print("")

    -- 4) PUSH BALANCE judge (Piece 1.5 sim on trial): a scan's bal (net survivors, + = our lane
    --    pushes) should predict the direction the front MIDPOINT moves over the next ~8-14s. dir =
    --    unit(ef - af) (toward the enemy side); delta = (mid_later - mid_now) . dir; bal > 0 should
    --    give delta > 0. Sign-match rate over all judgeable samples, DEAD_D deadband on tiny moves.
    local DEAD_D, match, miss, nsamp = 60, 0, 0, 0
    for i = 1, #scans do
        local s = scans[i]
        if s.bal and s.bal ~= 0 and (not s.est) and s.ef and s.af then
            for j = i + 1, #scans do
                local u = scans[j]
                if u.t - s.t > 14 then break end
                if u.t - s.t >= 8 and (not u.est) and u.ef and u.af then
                    local dx, dy = s.ef.x - s.af.x, s.ef.y - s.af.y
                    local dl = math.sqrt(dx * dx + dy * dy)
                    if dl > 1 then
                        local mx0, my0 = (s.ef.x + s.af.x) / 2, (s.ef.y + s.af.y) / 2
                        local mx1, my1 = (u.ef.x + u.af.x) / 2, (u.ef.y + u.af.y) / 2
                        local delta = ((mx1 - mx0) * dx + (my1 - my0) * dy) / dl
                        if math.abs(delta) > DEAD_D then
                            nsamp = nsamp + 1
                            if (s.bal > 0) == (delta > 0) then match = match + 1 else miss = miss + 1 end
                        end
                    end
                    break
                end
            end
        end
    end
    print(string.format("push-balance judge (sim bal sign vs observed front-midpoint movement 8-14s later): %d samples", nsamp))
    if nsamp > 0 then
        print(string.format("  sign-match rate: %d%% (%d match / %d miss; >70%% = the sim earns decision duty)",
            math.floor(match / nsamp * 100 + 0.5), match, miss))
    end
    os.exit(0)
elseif mode == "cycle_report" then
    -- Task #12 (TINKER_ANCHOR_REACH_STUDY.md): per-shove-cycle walk/wait accounting. Reconstructs
    -- decide -> keen -> tether -> step_out -> engage from the ordered stream; `now` interpolates
    -- from any event with kv.t (farm decides + the 2s wavescan SCAN series).
    local now_t = 0
    local cyc, cycles = nil, {}
    for _, e in ipairs(events) do
        local ts = tonumber(e.kv.t)
        if ts then now_t = ts end
        if e.event == "farm" and e.kv.pick == "shove" then
            cyc = { t0 = now_t, sx = e.kv.sx or "?", sy = e.kv.sy or "?",
                    travel = e.kv.travel, asrc = e.kv.asrc }
            cycles[#cycles + 1] = cyc
        elseif cyc then
            if e.event == "lane_go" and e.raw:find("lane_go keen") then
                cyc.keen_t = cyc.keen_t or now_t
            elseif e.event == "keen_to_anchor" then
                cyc.residual = tonumber(e.kv.residual)
                cyc.anchor = e.kv.anchor              -- Phase 2: anchor=creep marks a RAID keen
            elseif e.event == "tether" then
                cyc.tether_t = cyc.tether_t or now_t
            elseif e.event == "step_out" then
                cyc.out_t = now_t; cyc.out_eta = e.kv.eta; cyc.out_walk = e.kv.walk
            elseif e.event == "wave_engage_arrived" and not cyc.arr_t then
                cyc.arr_t = now_t
                cyc.trig, cyc.dwave = e.kv.trig, tonumber(e.kv.dWave)
                cyc.eta_err = e.kv.eta_err
            end
        end
    end
    print(string.format("--- cycle report --- %d shove cycles", #cycles))
    print(string.format("%-7s %-16s %-6s %-7s %-7s %-8s %-8s %-7s %-7s %-7s %-6s %-7s",
        "t0", "stand", "asrc", "travel", "anchor", "residual", "tether_s", "out_t", "arr_t", "dWave", "trig", "eta_err"))
    local transit, tether_s, n, early = 0, 0, 0, 0
    for _, c in ipairs(cycles) do
        local walk = (c.arr_t and c.keen_t) and (c.arr_t - c.keen_t) or nil
        local teth = (c.tether_t and (c.out_t or c.arr_t)) and ((c.out_t or c.arr_t) - c.tether_t) or nil
        if walk then transit = transit + walk; n = n + 1 end
        if teth then tether_s = tether_s + teth end
        -- run-10 lesson: a timed cast at dWave ~1140 with eta_err ~0 is the DESIGNED sweep of an
        -- arriving wave (robots deliver over 6s); true earliness = the cast firing well before eta.
        local ee = tonumber(c.eta_err)
        if c.trig == "time" and ee and ee > 3 then early = early + 1 end
        print(string.format("%-7s %-16s %-6s %-7s %-7s %-8s %-8s %-7s %-7s %-7s %-6s %-7s",
            c.t0, "(" .. c.sx .. "," .. c.sy .. ")", c.asrc or "-", c.travel or "-",
            c.anchor or "-", c.residual or "-", teth and string.format("%.1f", teth) or "-",
            c.out_t or "-", c.arr_t or "-", c.dwave or "-", c.trig or "-", c.eta_err or "-"))
    end
    local t0 = tonumber(cycles[1] and cycles[1].t0) or 0
    local t1 = now_t
    local span = math.max(1, t1 - t0)
    print(string.format("\nkeen->engage transit: %.0fs over %d cycles (%.1fs avg, %.0f%% of %.0fs span)",
        transit, n, n > 0 and transit / n or 0, 100 * transit / span, span))
    print(string.format("tether time: %.0fs   early timed casts (trig=time eta_err>+3s): %d", tether_s, early))
    print("targets: transit share < 10%, early timed casts = 0, tether lines present on fogged cycles")
    os.exit(0)
elseif mode == "keen_report" then
    -- Keen-efficiency arc STEP 1 (bridge 2026-07-20): every keen classified by outcome.
    -- Events: keen_to_anchor (fields: anchor/land/residual) + keen_home (bare). The lane_go
    -- line logs AFTER the keen helper returns -> stamp it onto the latest unstamped anchor.
    -- Clock interpolates from kv.t (decides + 2s wavescan), same as cycle_report.
    -- Known log gaps (instrumentation candidates if the classes look wrong): no from-position
    -- on any keen (jump length unknowable -> "walk was comparable" is judged by residual only),
    -- keen_home has no coords/purpose, no mana on cast lines (nearest decide's mana= stands in).
    local now_t, t_first = 0, nil
    local keens, acts, dec, pending = {}, {}, nil, nil
    for seq, e in ipairs(events) do
        local ts = tonumber(e.kv.t); if ts then now_t = ts end
        if e.event == "farm" and e.kv.pick then
            t_first = t_first or now_t
            dec = { t = now_t, pick = e.kv.pick, mana = e.kv.mana, klvl = e.kv.klvl,
                    reason = e.kv.reason, act = e.kv.act }
        elseif e.event == "keen_to_anchor" then
            local k = { t = now_t, seq = seq, kind = "anchor", anchor = e.kv.anchor,
                residual = tonumber(e.kv.residual), dec = dec,
                jump = tonumber(e.kv.jump), cmana = e.kv.mana }   -- v0.1.331 instrumentation
            -- rearm_reset_keen logs BEFORE its keen (the rearm channel sits between) and is a
            -- mana fact (rearm burned on top), not the purpose: flag it, let lane_go name the purpose
            if pending and now_t - pending.t <= 8 then k.rearm = true end
            pending = nil
            keens[#keens + 1] = k
        elseif e.event == "keen_home" then
            keens[#keens + 1] = { t = now_t, seq = seq, kind = "home", dec = dec,
                purpose = e.kv.purpose, cmana = e.kv.mana }       -- v0.1.331 instrumentation
            pending = nil
        elseif e.event == "lane_go" then
            local variant = e.raw:match("lane_go%s+(.+)$")
            local k = keens[#keens]
            if variant and variant:find("keen") then
                if k and k.kind == "anchor" and not k.caller and now_t - k.t <= 5 then
                    k.caller = variant          -- lane_go keen / keen raid log AFTER the cast
                else
                    pending = { variant = variant, t = now_t }
                end
            end
        elseif e.event == "march_aim" or e.event == "engage_done" or e.event == "refill_done" then
            acts[#acts + 1] = { t = now_t, seq = seq, what = e.event }
        end
    end
    -- stream order (seq), not clock, decides before/after: the 2s interpolated clock ties a
    -- same-window cast to its keen (raids cast ~2s after landing) and a > test dropped them;
    -- seq1 (the next keen) bounds the other side so a tied-clock act never double-attributes
    local function farmed_between(seq0, t1, seq1)
        for _, a in ipairs(acts) do
            if a.seq > seq0 and a.t <= t1 and (not seq1 or a.seq < seq1) then return a.what end
        end
        return nil
    end
    local BOUNCE_S, PROD_S, LONGWALK_R = 15, 25, 1000
    local order = { "bounce", "home-cycle", "long-walk", "short-hop", "home-refill", "raid", "productive" }
    local classes = {}
    for _, c in ipairs(order) do classes[c] = { n = 0, resid = 0, residn = 0, mana = 0 } end
    local callers = {}
    for i, k in ipairs(keens) do
        local nxt = keens[i + 1]
        k.ndt = nxt and (nxt.t - k.t) or nil
        local horizon = math.min(k.t + PROD_S, nxt and nxt.t or (k.t + PROD_S))
        k.farmed = farmed_between(k.seq, horizon, nxt and nxt.seq)
        if k.kind == "home" then
            local genuine = k.dec and (k.dec.pick == "refill" or k.dec.act == "recover")
            k.class = genuine and "home-refill" or "home-cycle"
        elseif k.caller and k.caller:find("raid") then
            k.class = "raid"
        elseif k.ndt and k.ndt <= BOUNCE_S and not farmed_between(k.seq, nxt.t, nxt.seq) then
            k.class = "bounce"
        elseif k.residual and k.residual > LONGWALK_R then
            k.class = "long-walk"
        elseif k.farmed then
            k.class = "productive"
        else
            k.class = "short-hop"
        end
        local c = classes[k.class]
        c.n = c.n + 1
        c.mana = c.mana + 75 + (k.rearm and 225 or 0)
        if k.residual then c.resid = c.resid + k.residual; c.residn = c.residn + 1 end
        local cal = k.kind == "home" and "home" or ((k.rearm and "rearm+" or "") .. (k.caller or "-"))
        callers[cal] = (callers[cal] or 0) + 1
    end
    local span = math.max(1, now_t - (t_first or 0))
    print(string.format("--- keen report --- %d keens in %.0fs of farm (one every %.1fs)", #keens, span, span / math.max(1, #keens)))
    print(string.format("%-7s %-7s %-17s %-6s %-6s %-6s %-12s %-11s %s",
        "t", "kind", "caller/purpose", "resid", "jump", "next", "farmed", "class", "decide[pick mana klvl reason]"))
    for _, k in ipairs(keens) do
        local d = k.dec or {}
        print(string.format("%-7.1f %-7s %-17s %-6s %-6s %-6s %-12s %-11s %s %s klvl=%s %s%s",
            k.t, k.kind == "home" and "home" or ("a=" .. tostring(k.anchor)),
            k.kind == "home" and (k.purpose or "-") or ((k.rearm and "rearm+" or "") .. (k.caller or "-")),
            k.residual and string.format("%d", k.residual) or "-",
            k.jump and string.format("%d", k.jump) or "-",
            k.ndt and string.format("%.0fs", k.ndt) or "-",
            k.farmed or "-", k.class,
            d.pick or "?", d.mana and ("mana=" .. d.mana) or "mana=?", d.klvl or "?", d.reason or "",
            k.cmana and (" castmana=" .. k.cmana) or ""))
    end
    print("\nclass                n   est_mana  avg_resid")
    local tot_mana = 0
    for _, cname in ipairs(order) do
        local c = classes[cname]
        tot_mana = tot_mana + c.mana
        if c.n > 0 then
            print(string.format("%-18s %3d   %6d    %s", cname, c.n, c.mana,
                c.residn > 0 and string.format("%.0f", c.resid / c.residn) or "-"))
        end
    end
    print(string.format("total est keen mana: %d (Keen 75 flat; +225 per rearm_reset rung, level estimate)", tot_mana))
    local cal_parts = {}
    for cal, n in pairs(callers) do cal_parts[#cal_parts + 1] = cal .. "=" .. n end
    table.sort(cal_parts)
    print("callers: " .. table.concat(cal_parts, " "))
    print("classes: bounce = re-keen <" .. BOUNCE_S .. "s with nothing farmed | home-cycle = fountain TP outside a refill/recover pick")
    print("         long-walk = residual >" .. LONGWALK_R .. " (the keen bought a long walk anyway) | short-hop = no farm evidence within " .. PROD_S .. "s")
    print("         home-refill / raid / productive = the designed uses")
    os.exit(0)
elseif mode == "time_report" then
    -- GPM study instrument: classify the WHOLE run. A segment = one farm decide's action
    -- (decide -> next decide); the clock interpolates from any kv.t event (farm decides + the
    -- 2s wavescan series), same as cycle_report. Sub-phases from ordered markers:
    --   shove/camp: walk (capped at the planner's travel estimate) / wait (excess stillness
    --   before engage) / tether / engage (arrived -> engage_done) / post (done -> next decide)
    --   refill -> fountain, recover -> recover, none/hold -> idle.
    -- GOLD: farm's gpm field is a cumulative average -> cum_gold = gpm*t/60; the delta between
    -- consecutive decide boundaries is attributed to the earlier segment's pick.
    local now_t = 0
    local segs, cur = {}, nil
    local function close(t)
        if cur then cur.t1 = t; segs[#segs + 1] = cur; cur = nil end
    end
    local last_scan = nil  -- pre-position diagnosis: most-recent wavescan SCAN (grid pred vs kin kpred)
    for _, e in ipairs(events) do
        local ts = tonumber(e.kv.t); if ts then now_t = ts end
        if e.event == "wavescan" and e.kv.pred and not e.kv.ln then
            last_scan = { pred = tonumber(e.kv.pred), kpred = tonumber(e.kv.kpred),
                          lastw = tonumber(e.kv.lastw), t = ts }
        elseif e.event == "farm" then
            close(now_t)
            cur = { t0 = now_t, pick = e.kv.pick or "?", reason = e.kv.reason or "-",
                    travel = tonumber(e.kv.travel) or 0, gpm = tonumber(e.kv.gpm),
                    -- pre-position fog-timing capture (near_due idle diagnosis): the decide's own
                    -- predicted arrival + slack, and the grid/kin estimates in force at decide time
                    dl = tonumber(e.kv.dl), slack = tonumber(e.kv.slack), asrc = e.kv.asrc, scan = last_scan,
                    -- ALL-LANES: a side shove segment keys its time/gold as shove:top|bot
                    key = (e.kv.pick == "shove" and e.kv.lane and e.kv.lane ~= "mid")
                          and ("shove:" .. e.kv.lane) or (e.kv.pick or "?") }
        elseif cur then
            if e.event == "tether" then cur.teth0 = cur.teth0 or now_t
            elseif e.event == "step_out" or e.event == "wave_engage_arrived" or e.event == "engage_arrived" then
                if cur.teth0 then cur.teth = (cur.teth or 0) + (now_t - cur.teth0); cur.teth0 = nil end
                if e.event ~= "step_out" then cur.arr = cur.arr or now_t
                elseif e.kv.eta then  -- keen/anchor step_out (has eta/walk/d), not the "live" close/meet form
                    cur.eta = tonumber(e.kv.eta); cur.walk_s = tonumber(e.kv.walk); cur.dstep = tonumber(e.kv.d)
                end
            elseif e.event == "keen_to_anchor" then cur.residual = tonumber(e.kv.residual)
            elseif e.event == "engage_done" or e.event == "refill_done" then
                cur.done = cur.done and math.max(cur.done, now_t) or now_t
            end
        end
    end
    close(now_t)
    if #segs == 0 then print("  (no `farm` events found)"); os.exit(0) end

    local B, order = {}, { "engage", "walk", "wait", "tether", "post", "fountain", "recover", "idle" }
    local function add(k, v) B[k] = (B[k] or 0) + v end
    local gold_by, time_by = {}, {}
    local holds = {}
    for i, s in ipairs(segs) do
        local dur = math.max(0, s.t1 - s.t0)
        local hold_s = 0
        if s.pick == "shove" or s.pick == "camp" or s.pick == "wave" then
            local teth = s.teth or 0
            local pre = math.max(0, (s.arr or s.t1) - s.t0)
            local walk = math.min(s.travel, math.max(0, pre - teth))
            local wait = math.max(0, pre - teth - walk)
            local eng = s.arr and math.max(0, (s.done or s.t1) - s.arr) or 0
            local post = s.arr and math.max(0, s.t1 - math.max(s.arr, s.done or s.arr)) or 0
            add("walk", walk); add("wait", wait); add("tether", teth)
            add("engage", eng); add("post", post)
            hold_s = wait + teth
            s.phases = string.format("walk=%.0f wait=%.0f tether=%.0f engage=%.0f post=%.0f",
                walk, wait, teth, eng, post)
        elseif s.pick == "refill" then add("fountain", dur); hold_s = dur
        elseif s.pick == "recover" then add("recover", dur); hold_s = dur
        elseif s.pick == "none" or s.pick == "hold" then add("idle", dur); hold_s = dur
        else add(s.pick, dur); if not B[s.pick] then order[#order + 1] = s.pick end
        end
        local gkey = s.key or s.pick   -- ALL-LANES: shove:top/shove:bot split; time buckets (B) stay pick-shaped
        time_by[gkey] = (time_by[gkey] or 0) + dur
        -- gold delta: this segment's cum vs the next decide's cum
        local nxt = segs[i + 1]
        if s.gpm and nxt and nxt.gpm then
            local d = nxt.gpm * nxt.t0 / 60 - s.gpm * s.t0 / 60
            if d > -50 then gold_by[gkey] = (gold_by[gkey] or 0) + math.max(0, d) end
        end
        if hold_s > 10 then
            holds[#holds + 1] = { t0 = s.t0, pick = s.pick, reason = s.reason, dur = dur,
                hold = hold_s, phases = s.phases,
                eta = s.eta, walk_s = s.walk_s, residual = s.residual,
                dl = s.dl, slack = s.slack, dtravel = s.travel, scan = s.scan }
        end
    end
    local t0, t1 = segs[1].t0, segs[#segs].t1
    local span = math.max(1, t1 - t0)
    print(string.format("--- time report --- %d segments over %.0fs (t %.1f .. %.1f)", #segs, span, t0, t1))
    print("\ntime buckets (every second of the run classified):")
    local acc = 0
    for _, k in ipairs(order) do
        if B[k] then
            print(string.format("    %-10s %6.0fs  (%4.1f%%)", k, B[k], 100 * B[k] / span))
            acc = acc + B[k]
        end
    end
    print(string.format("    %-10s %6.0fs  (%4.1f%%)  (clock gaps / pre-arrival redecides)",
        "unattrib", span - acc, 100 * (span - acc) / span))

    print("\ngold accounting (cum gpm deltas attributed to the running segment's pick):")
    local picks = {}
    for k in pairs(time_by) do picks[#picks + 1] = k end
    table.sort(picks, function(a, b) return (gold_by[a] or 0) > (gold_by[b] or 0) end)
    local gtot = 0; for _, g in pairs(gold_by) do gtot = gtot + g end
    for _, k in ipairs(picks) do
        local g, tt = gold_by[k] or 0, time_by[k] or 0
        print(string.format("    %-8s %5.0fg (%4.1f%%)  over %5.0fs  = %5.1f g/min",
            k, g, gtot > 0 and 100 * g / gtot or 0, tt, tt > 0 and g / tt * 60 or 0))
    end
    print(string.format("    total attributed: %.0fg over the span (end gpm %s)", gtot,
        tostring(segs[#segs].gpm or "?")))

    print(string.format("\nholds > 10s (stillness that is not engage/walk): %d", #holds))
    table.sort(holds, function(a, b) return a.hold > b.hold end)
    for i = 1, math.min(15, #holds) do
        local h = holds[i]
        print(string.format("    t=%-6.1f %-7s hold=%5.1fs seg=%5.1fs reason=%-14s %s",
            h.t0, h.pick, h.hold, h.dur, h.reason, h.phases or ""))
        if h.eta then  -- pre-position fog-timing: mechanically pair step_out eta vs decide dl vs wavescan pred/kpred
            local sc = h.scan or {}
            local idle = h.dl and (h.dl - h.eta) or nil
            print(string.format("             fog-timing: eta=%.1f (out+%.1f, keen resid=%s) walk_s=%s | decide[dl=%s slack=%s trav=%s] wavescan[pred=%s kpred=%s] -> idle(dl-eta)=%s",
                h.eta, h.eta - h.t0, tostring(h.residual or "?"), tostring(h.walk_s or "?"),
                tostring(h.dl or "?"), tostring(h.slack or "?"), tostring(h.dtravel or "?"),
                tostring(sc.pred or "?"), tostring(sc.kpred or "?"),
                idle and string.format("%.1f", idle) or "?"))
        end
    end
    os.exit(0)
elseif mode == "convert_report" then
    -- THE CONVERT-CONTEXT INSTRUMENT (churn arc entry, 2026-07-20): per overdue_convert,
    -- reconstruct what every clock believed at the abandon - the committed deadline (the
    -- decide's dl + the frozen kinematic s.waveEta family), the live scanner (SCAN
    -- pred/kpred + the per-lane ln eta), casts already spent - and when the real wave
    -- materialized AFTER the bail (the abandon error). Resolves the over~15-17 mystery
    -- (which quantity `over` measures) and sizes the false-abandon rate for the fix.
    local now_t, ev_t = 0, {}
    for i, e in ipairs(events) do
        local ts = tonumber(e.kv.t); if ts then now_t = ts end
        ev_t[i] = now_t
    end
    local n, errs = 0, {}
    for i, e in ipairs(events) do
        if e.event == "overdue_convert" then
            n = n + 1
            local lane = e.kv.lane or "mid"
            local tc = ev_t[i]
            -- backward: last same-lane shove commit, last SCAN, last ln= scan, casts since commit
            local commit, scan, lscan, casts = nil, nil, nil, 0
            for j = i - 1, 1, -1 do
                local p = events[j]
                if not commit and p.event == "farm" and p.kv.pick == "shove" and (p.kv.lane or "mid") == lane then
                    commit = { t = ev_t[j], dl = tonumber(p.kv.dl), asrc = p.kv.asrc,
                               slack = p.kv.slack, vis = p.kv.vis }
                end
                if not scan and p.event == "wavescan" and p.kv.pred and not p.kv.ln then
                    scan = { pred = tonumber(p.kv.pred), kpred = tonumber(p.kv.kpred) }
                end
                if not lscan and p.event == "wavescan" and p.kv.ln == lane then
                    lscan = { eta = tonumber(p.kv.eta), est = p.kv.est, reach = p.kv.reach }
                end
                if not commit and p.event == "march_aim"
                   and (p.kv.src == "shove" or p.kv.src == "shove_pre" or p.kv.src == "shove_w2") then
                    casts = casts + 1
                end
                if commit and scan and lscan then break end
                if tc - ev_t[j] > 60 then break end
            end
            -- forward: when did the real wave show (arrival event, real ln scan, or vis=y decide)
            local treal = nil
            for j = i + 1, #events do
                local p = events[j]
                if p.event == "wave_engage_arrived" or p.event == "engage_arrived"
                   or (p.event == "wavescan" and p.kv.ln == lane and p.kv.est == "n")
                   or (p.event == "farm" and (p.kv.lane or "mid") == lane and p.kv.vis == "y") then
                    treal = ev_t[j]; break
                end
                if ev_t[j] - tc > 40 then break end
            end
            print(string.format("convert #%d t=%.1f lane=%s over=%s", n, tc, lane, e.kv.over or "?"))
            if commit then
                print(string.format("    commit t=%.1f dl=%s asrc=%s slack=%s vis=%s | conv-commit=%.1f conv-dl=%s casts_since=%d",
                    commit.t, tostring(commit.dl), tostring(commit.asrc), tostring(commit.slack), tostring(commit.vis),
                    tc - commit.t, commit.dl and string.format("%+.1f", tc - commit.dl) or "?", casts))
            end
            if scan or lscan then
                print(string.format("    scanner: SCAN kpred%s pred%s | ln eta=%s est=%s reach=%s",
                    scan and scan.kpred and string.format("=now%+.1f", scan.kpred - tc) or "=?",
                    scan and scan.pred and string.format("=now%+.1f", scan.pred - tc) or "=?",
                    lscan and tostring(lscan.eta) or "?", lscan and tostring(lscan.est) or "?",
                    lscan and tostring(lscan.reach) or "?"))
            end
            if treal then
                errs[#errs + 1] = treal - tc
                print(string.format("    real wave materialized %+.1fs after the abandon", treal - tc))
            else
                print("    no wave materialized within 40s (a TRUE phantom)")
            end
        end
    end
    if n == 0 then print("(no overdue_convert events)") end
    if #errs > 0 then
        table.sort(errs)
        print(string.format("\nconverts: %d | wave materialized after: %d (median %+.1fs) | true phantoms: %d",
            n, #errs, errs[math.ceil(#errs / 2)], n - #errs))
    end
    os.exit(0)
elseif mode == "cast_report" then
    -- THE CAST-OUTCOME INSTRUMENT (step-2 brainstorm 2026-07-20): pair every lane W cast
    -- with what the wave actually did next, so "the pre-casts whiff" is a MEASURED rate,
    -- not an impression (the .322 mirror-misattribution lesson). Classes:
    --   shove_pre live (tarr=)  - the W-GEOM-3 lead cast on a VISIBLE closing wave
    --   shove_pre/w2 fog (teta=) - the stamp-timed fog preempt (fog=y)
    --   shove_w2 (dref=)        - the consecutive W2 (judged by reach, MARCH_REACH 1150)
    --   shove (dWave=)          - the at-arrival cast (baseline, always on the wave)
    -- Outcome scan (+25s or the next farm decide): first arrival event vs the cast's own
    -- lead -> HIT (arr <= lead+2), PARTIAL (<= lead+6, robots still sweeping), LATE, or
    -- GONE (convert/no_wave/nothing = the wave never came). Timestamps interpolate from
    -- the 2s wavescan cadence (+-2s is fine for a 6s robot sweep).
    -- Ends with the wasted-trip recount so the whiff cost sizes against the churn.
    local now_t, ev_t, casts = 0, {}, {}
    for i, e in ipairs(events) do
        local ts = tonumber(e.kv.t); if ts then now_t = ts end
        ev_t[i] = now_t
        if e.event == "march_aim" then
            local src = e.kv.src
            if src == "shove_pre" or src == "shove_w2" or src == "shove" then
                casts[#casts + 1] = { i = i, t = now_t, src = src, fog = (e.kv.fog == "y"),
                    lead = tonumber(e.kv.tarr) or tonumber(e.kv.teta),
                    dw = tonumber(e.kv.dWave) or tonumber(e.kv.dref) }
            end
        end
    end
    for _, c in ipairs(casts) do
        local lead = math.max(c.lead or 0, 0)
        for j = c.i + 1, #events do
            local e, te = events[j], ev_t[j]
            if te > c.t + 25 or (e.event == "farm" and te > c.t + 1) then break end
            if e.event == "wave_engage_arrived" or e.event == "engage_arrived" then
                c.arr = c.arr or te
            elseif e.event == "engage_done" then c.done = te; break
            elseif e.event == "overdue_convert" or (e.event == "shove_move" and (e.raw or ""):find("no_wave", 1, true)) then
                c.gone = te; break
            end
        end
        if c.src == "shove" then c.class = "arrival"
        elseif c.src == "shove_w2" then
            c.class = (not c.fog) and ((c.dw or 0) <= 1150 and "w2_in_reach" or "w2_BEYOND") or "w2_fog"
        elseif c.arr and c.arr <= c.t + lead + 2 then c.class = "HIT"
        elseif c.arr and c.arr <= c.t + lead + 6 then c.class = "PARTIAL"
        elseif c.arr then c.class = "LATE"
        else c.class = "GONE" end
    end
    local function med(t) table.sort(t); return #t > 0 and t[math.ceil(#t / 2)] or 0 end
    print(string.format("--- cast report --- %d lane W casts", #casts))
    local groups = {}
    for _, c in ipairs(casts) do
        local g = (c.src == "shove_pre") and (c.fog and "fog_pre" or "live_pre") or c.src
        groups[g] = groups[g] or {}
        table.insert(groups[g], c)
    end
    for _, gname in ipairs({ "live_pre", "fog_pre", "shove_w2", "shove" }) do
        local list = groups[gname]
        if list then
            local cls, dws, lags = {}, {}, {}
            for _, c in ipairs(list) do
                cls[c.class] = (cls[c.class] or 0) + 1
                if c.dw then dws[#dws + 1] = c.dw end
                if c.arr and c.lead then lags[#lags + 1] = c.arr - (c.t + c.lead) end
            end
            local parts = {}
            for k, v in pairs(cls) do parts[#parts + 1] = string.format("%s=%d", k, v) end
            table.sort(parts)
            print(string.format("  %-9s n=%-3d dW/dref med=%-5.0f arr-lag med=%+.1fs  [%s]",
                gname, #list, med(dws), med(lags), table.concat(parts, " ")))
        end
    end
    -- wasted-trip recount (same rule as farm-report) for the size comparison
    local wasted, wtravel, cur, cast_seen = 0, 0, nil, false
    for _, e in ipairs(events) do
        if e.event == "farm" then
            if cur and not cast_seen and (tonumber(cur.kv.travel) or 0) > 2 then
                wasted = wasted + 1; wtravel = wtravel + (tonumber(cur.kv.travel) or 0)
            end
            cur = (e.kv.pick == "shove") and e or nil
            cast_seen = false
        elseif e.event == "march_aim" and (e.kv.src == "shove" or e.kv.src == "shove_pre" or e.kv.src == "shove_w2") then
            cast_seen = true
        end
    end
    print(string.format("  vs churn: wasted shove trips %d (est travel %.0fs)", wasted, wtravel))
    os.exit(0)
elseif mode == "depth_audit" then
    -- THE WALK-LAW VERIFIER (v0.1.198, after 5+ hours of manual deep-walk hunting): the invariant
    -- is "no lane position past the stairs line (stand_depth > WALK_DEPTH_MAX) without Keen L2".
    -- Reconstructs the klvl timeline from farm decides and checks every positional event against
    -- the line. Team read from self_acquired; fountains from map_data (mirrored). Thresholds:
    --   stands / keen landings / tether holds:  depth > 600  (line 550 + 50 slop)
    --   W casts (cast point <= ~300 ahead of the hero): depth > 910 (550 + 300 + 60)
    -- klvl >= 2 events are reported separately (raid-era; legal by the keen rule).
    -- v0.1.327 S2 PER-LANE DEPTH: the audit consumes THE SAME lib ruler as the brain
    -- (Lane.DepthRuler/Lane.Depth, zero = each lane's T1 midpoint) so auditor-brain drift is
    -- impossible. WALK_MAX re-zeroed 550 -> 1100 with the frame (preserves the .324 Radiant
    -- reference; Dire gains the identical band). Events carry no lane -> nearest-zero pick.
    local LN, MD = require("lib.lane"), require("lib.map_data")
    local WALK_MAX = 1100
    -- v0.1.258: LAST self_acquired wins - debug.log can hold several script loads (run-73:
    -- a team-2 setup session before the team-3 real game); the first one mis-teamed the audit.
    local team = 2
    for _, e in ipairs(events) do
        if e.event == "self_acquired" then team = tonumber(e.kv.team) or team end
    end
    local ruler = LN.DepthRuler(MD.TOWERS, MD.FOUNTAINS, team)
    if not ruler then io.stderr:write("depth-audit: no ruler (map_data)\n"); os.exit(2) end
    local zlist = {}
    for ln, z in pairs(ruler.zero) do zlist[#zlist + 1] = { ln = ln, x = z.x, y = z.y } end
    local function depth(x, y)
        local best, bd
        for _, z in ipairs(zlist) do
            local dd = (x - z.x) * (x - z.x) + (y - z.y) * (y - z.y)
            if not bd or dd < bd then bd, best = dd, z.ln end
        end
        return LN.Depth(ruler, { x = x, y = y }, best)
    end

    local now_t, klvl = 0, 1
    local viol, raid_deep, checked = {}, {}, 0
    local function check(kind, x, y, bar, extra)
        x, y = tonumber(x), tonumber(y)
        if not (x and y) then return end
        checked = checked + 1
        local d = depth(x, y)
        if d > bar then
            local row = { t = now_t, kind = kind, x = x, y = y, d = d, klvl = klvl, extra = extra or "" }
            if klvl >= 2 then raid_deep[#raid_deep + 1] = row else viol[#viol + 1] = row end
        end
    end
    for _, e in ipairs(events) do
        local ts = tonumber(e.kv.t); if ts then now_t = ts end
        if e.event == "farm" then
            klvl = tonumber(e.kv.klvl) or klvl
            if e.kv.pick == "shove" then check("stand", e.kv.sx, e.kv.sy, WALK_MAX + 50) end
        elseif e.event == "keen_to_anchor" then
            local lx, ly = (e.raw or ""):match("land=%((%-?%d+),(%-?%d+)%)")
            check("keen_land", lx, ly, WALK_MAX + 50, "anchor=" .. tostring(e.kv.anchor))
        elseif e.event == "tether" then
            local hx, hy = (e.raw or ""):match("hold=%((%-?%d+),(%-?%d+)%)")
            check("tether_hold", hx, hy, WALK_MAX + 50)
        elseif e.event == "march_aim" and e.kv.src == "shove" then
            local cx2, cy2 = (e.raw or ""):match("cast=%((%-?%d+),(%-?%d+)%)")
            check("w_cast", cx2, cy2, WALK_MAX + 360, "pat=" .. tostring(e.kv.pat))
        elseif e.event == "lane_go" and (e.raw or ""):find("deep_reject") then
            viol[#viol + 1] = { t = now_t, kind = "TRIPWIRE", x = 0, y = 0, d = 0, klvl = klvl,
                                extra = e.raw:match("deep_reject.*") or "" }
        end
    end
    print(string.format("--- depth audit --- team=%d  line=%d  events checked: %d", team, WALK_MAX, checked))
    print(string.format("\nVIOLATIONS (deep without Keen L2): %d %s", #viol,
        #viol == 0 and "- THE INVARIANT HELD" or "<<< BUGS, each row names the producer"))
    for _, v in ipairs(viol) do
        print(string.format("    t=%-7.1f %-11s (%.0f,%.0f) depth=%-5.0f klvl=%d %s",
            v.t, v.kind, v.x, v.y, v.d, v.klvl, v.extra))
    end
    print(string.format("\nraid-era deep events (klvl>=2, legal by the keen rule): %d", #raid_deep))
    for i = 1, math.min(10, #raid_deep) do
        local v = raid_deep[i]
        print(string.format("    t=%-7.1f %-11s (%.0f,%.0f) depth=%-5.0f %s",
            v.t, v.kind, v.x, v.y, v.d, v.extra))
    end
    os.exit(0)
elseif mode == "farm_audit" then
    -- THE CAMP-ECONOMICS VERIFIER (v0.1.199, run-27 refill-churn census). Three machine checks
    -- over the farm trace's own numbers (need = cheapest camp price incl. reserve among camps
    -- that reached the afford stage; pm = planner mana incl. Bottle/item headroom; cap = pool +
    -- headroom; fields ship at v0.1.199 - older logs degrade to the nnd check only):
    --   1. GATE CONSISTENCY: rej okN>0 <=> pm >= need. A mismatch = the rej mirror or the gate
    --      drifted (the run-27 lesson: a wrong mirror hides the real gate for a whole session).
    --   2. POINTLESS REFILL: pick=refill while need > cap - the fountain cannot unlock ANY camp
    --      (unfundable at the ceiling), so the trip serves waves at best. Informational count +
    --      rows; a sustained band of these = the pool/price crossing (mana item / price model).
    --   3. ILLEGAL SINGLE: pick=camp paired=false with nnd <= 1800 (a partner IS in pair range;
    --      v0.1.189 pair-dominance says a single may appear only when partnerless/unsafe).
    local PAIR_RANGE = 1800
    local mism, pointless, illegal = {}, {}, {}
    local n_farm, n_fielded = 0, 0
    for _, e in ipairs(events) do
        if e.event == "farm" then
            n_farm = n_farm + 1
            local t = tonumber(e.kv.t) or 0
            local ok = tonumber((e.kv.rej or ""):match("ok(%d+)"))
            local need, pm, cap = tonumber(e.kv.need), tonumber(e.kv.pm), tonumber(e.kv.cap)
            if ok and need and pm then
                n_fielded = n_fielded + 1
                local should = (pm >= need)
                if should ~= (ok > 0) then
                    mism[#mism + 1] = { t = t, rej = e.kv.rej, need = need, pm = pm }
                end
                if e.kv.pick == "refill" and cap and need > cap then
                    pointless[#pointless + 1] = { t = t, need = need, cap = cap }
                end
            end
            local nnd = tonumber(e.kv.nnd)
            if e.kv.pick == "camp" and e.kv.paired == "false" and nnd and nnd <= PAIR_RANGE then
                illegal[#illegal + 1] = { t = t, nnd = nnd, cval = e.kv.cval }
            end
        end
    end
    print(string.format("--- farm audit --- decides: %d  with need/pm/cap fields: %d%s",
        n_farm, n_fielded, n_fielded == 0 and "  (pre-v0.1.199 log: gate checks skipped)" or ""))
    print(string.format("\nGATE MISMATCHES (ok>0 <=> pm>=need violated): %d %s", #mism,
        #mism == 0 and "- THE GATE HELD" or "<<< mirror/gate drift, fix before trusting rej"))
    for i = 1, math.min(15, #mism) do
        local v = mism[i]
        print(string.format("    t=%-7.1f rej=%s need=%d pm=%d", v.t, v.rej, v.need, v.pm))
    end
    print(string.format("\nPOINTLESS REFILLS (pick=refill with need > cap): %d %s", #pointless,
        #pointless == 0 and "- every refill could fund a camp"
        or "<<< fountain cannot unlock camps here (pool/price crossing - mana item or price model)"))
    for i = 1, math.min(15, #pointless) do
        local v = pointless[i]
        print(string.format("    t=%-7.1f need=%d cap=%d", v.t, v.need, v.cap))
    end
    print(string.format("\nILLEGAL SINGLES (paired=false pick with nnd <= %d): %d %s", PAIR_RANGE,
        #illegal, #illegal == 0 and "- pair dominance held" or "<<< v0.1.189 rule violated"))
    for _, v in ipairs(illegal) do
        print(string.format("    t=%-7.1f nnd=%d cval=%s", v.t, v.nnd, tostring(v.cval)))
    end
    os.exit(0)
else
    -- timeline mode. v6.15.2 low: sort kv keys deterministically per-line
    -- so diff-tooling output is stable between runs.
    for i = 1, #events do
        local e = events[i]
        local s_t = e.kv.t or e.kv._t or "-"
        local keys = {}
        for k in pairs(e.kv) do
            if k ~= "t" and k ~= "_t" then keys[#keys + 1] = k end
        end
        table.sort(keys)
        local parts = {}
        for j = 1, #keys do
            parts[#parts + 1] = keys[j] .. "=" .. tostring(e.kv[keys[j]])
        end
        print(string.format("[%s] %s.%-25s %s", s_t, e.hero, e.event,
            table.concat(parts, " ")))
    end
end
