---@meta
---lib/route.lua - farm-route planning: a pure, receding-horizon, prize-collecting-within-a-time-
---budget planner over a unified FarmTarget set. Hero-agnostic + stateless: NO engine calls, no
---clock, no background loop. The hero passes plain FarmTarget records + its kinematic state +
---weights, gets back the best ordered SEQUENCE, and executes only the first leg (re-planning on its
---own cadence). Mirrors the lib/lane pure-core pattern. See Tinker/TINKER_ROUTE_DESIGN.md.
local Lane = require("lib.lane")    -- InterceptETA for leg chaining (pure scalar; safe offline)

local Route = {}

---one leg's travel time from `from_pos` to a target's pos, via the best ready teleport anchor or
---plain walk (lib/lane.InterceptETA). Pure.
---@return number eta seconds
function Route._leg_time(from_pos, target, hero_state)
    local r = Lane.InterceptETA(from_pos, hero_state.anchors, hero_state.move_speed,
                                hero_state.tp, target.pos, nil)
    return r.eta
end

---walk the timeline for a FIXED ordered sequence and return the collected subset + totals. Starting
---at hero_state.pos and opts.now, each target adds a leg + a wait-until-window.from + clear_t; a
---target is COLLECTED only if it finishes within the horizon and before window.to. The walk STOPS at
---the first uncollectable target (a sequence is only as good as its collectable prefix). Times are
---absolute on the same clock as opts.now (windows are absolute game-clock times). Pure.
---@return table { collected = {FarmTarget,...}, gold = number, time = number }
function Route._timeline(seq, hero_state, opts)
    local now      = opts.now or 0
    local deadline = now + (opts.horizon_s or 30)
    local pos   = hero_state.pos
    local clock = now
    -- resource state; nil mana/hp -> gating is inert (back-compat with resource-free callers)
    local mana, hp = hero_state.mana, hero_state.hp
    local mrate = hero_state.mana_regen or 0
    local hrate = hero_state.hp_regen   or 0
    local mmax  = hero_state.max_mana   or math.huge
    local hmax  = hero_state.max_hp     or math.huge
    local rsv   = hero_state.reserve_mana or 0
    local hpfl  = hero_state.hp_floor   or 0
    local frac  = opts.refill_frac or hero_state.refill_frac or 1
    local collected, gold = {}, 0
    for i = 1, #seq do
        local tg    = seq[i]
        local start = clock + Route._leg_time(pos, tg, hero_state)
        if tg.window and tg.window.from and tg.window.from > start then start = tg.window.from end
        local gap = start - clock                         -- regen accrues over travel + wait
        if mana then mana = math.min(mmax, mana + mrate * gap) end
        if hp   then hp   = math.min(hmax, hp   + hrate * gap) end
        local finish = start + (tg.clear_t or 0)
        if finish > deadline then break end
        -- round-trip reservation (opts.return_pos): a collected target must leave time to get back to
        -- return_pos by the deadline, else it is dropped (a far target a one-step ETA made look cheap to
        -- reach but expensive to leave). The return cost is KEEN-AWARE when opts.return_anchors is given
        -- (Lane.InterceptETA = cheapest of a plain walk or a ready teleport anchor), so a camp near a keen
        -- anchor is NOT over-excluded (the v0.1.93 pure-walk-back over-exclusion); this is consistent with
        -- how the outbound leg is estimated. Straight-line return_speed path kept for anchor-free callers.
        -- Gated on return_pos so other callers are unaffected. Pure (InterceptETA is scalar).
        if opts.return_pos and not tg.restore then
            local ret
            if opts.return_anchors then
                ret = Lane.InterceptETA(tg.pos, opts.return_anchors, opts.return_speed,
                                        opts.return_tp, opts.return_pos).eta
            elseif opts.return_speed and opts.return_speed > 0 then
                local dx = (tg.pos.x or 0) - opts.return_pos.x
                local dy = (tg.pos.y or 0) - opts.return_pos.y
                ret = math.sqrt(dx * dx + dy * dy) / opts.return_speed
            end
            if ret and finish + ret > deadline then break end
        end
        if tg.restore then                                -- refill node: top up, spend the wait, no value
            if mana then
                -- COST-AWARE refill (ancient arc, 2026-07-04): top up at least enough for the NEXT
                -- target (mana_cost + reserve), capped at max. The plain frac top-up (0.70 tempo
                -- leave) blocked big-ticket camps (an ancient clear ~1200+) exactly at the levels
                -- where the full pool first affords them - the refill node could never ENABLE what
                -- it was inserted for.
                local nxt = seq[i + 1]
                local need = (nxt and not nxt.restore) and ((nxt.mana_cost or 0) + rsv) or 0
                mana = math.min(mmax, math.max(mmax * frac, need))
            end
            if hp   then hp   = hmax * frac end
            collected[#collected + 1] = tg
            clock, pos = finish, tg.pos
        else
            local past_to = tg.window and tg.window.to and finish > tg.window.to
            local afford  = (mana == nil or mana >= (tg.mana_cost or 0) + rsv)
                        and (hp   == nil or (hp - (tg.hp_cost or 0)) >= hpfl)
            if not past_to and afford then
                collected[#collected + 1] = tg
                -- time-decay (lane waves): a wave's gold is lost as it ages (denied / next wave), so its
                -- value at COLLECTION decays from tg.born. Collecting it later (e.g. after a camp) is worth
                -- less -> the planner orders decaying targets FIRST (catch waves in their window). Pure.
                local v = tg.value or 0
                if tg.decay_per_s then
                    local age = start - (tg.born or now)
                    if age > 0 then v = math.max(tg.value_floor or 0, v - tg.decay_per_s * age) end
                end
                gold = gold + v
                if mana then mana = mana - (tg.mana_cost or 0) end
                if hp   then hp   = hp   - (tg.hp_cost   or 0) end
                clock, pos = finish, tg.pos
            else
                break
            end
        end
    end
    return { collected = collected, gold = gold, time = clock - now }
end

---risk-adjusted objective of a FIXED sequence: sum(value) - risk_weight*sum(risk) over the COLLECTED
---targets, plus the totals for tie-breaking. Pure.
-- #4: this is MAX risk-adjusted gold WITHIN the horizon, NOT gold/time. That is the correct GPM
-- objective here: each ~30s window is filled with the most gold, ties break on less time, and since
-- only leg-1 executes and the plan re-runs every leg, a near efficient set is never permanently lost
-- to a far high-value one (the far camp's leg shrinks as the hero closes; max_leg_s bounds the reach).
-- Deliberately not a gold/time rate: that would need a fragile time-weight knob for no measured gain.
---@return table { score = number, gold = number, time = number, collected = table }
---opts.step_decay (0..1, default 1 = off): positional discount on later steps' value in the
---SCORE only (gold stays the true sum). Receding-horizon execution runs only leg 1 and replans;
---later steps execute with probability < 1 (resource drift, new waves, cost-model error), so a
---plan that banks its big value FIRST beats one that promises it later at equal totals. With
---decay d, [small, big] scores small + d*big while [big now] scores big - the front-loaded
---plan wins whenever the promise is thinner than the bank.
function Route._score(seq, hero_state, opts)
    local tl = Route._timeline(seq, hero_state, opts)
    local rw, pen = opts.risk_weight or 0, 0
    for i = 1, #tl.collected do pen = pen + rw * (tl.collected[i].risk or 0) end
    local g = tl.gold
    local dec = opts.step_decay
    if dec and dec < 1 then
        g = 0
        local w = 1
        for i = 1, #tl.collected do
            g = g + w * (tl.collected[i].value or 0)
            w = w * dec
        end
    end
    return { score = g - pen, gold = tl.gold, time = tl.time, collected = tl.collected }
end

---the planner: the best ordered sequence (length <= opts.max_steps) maximizing risk-adjusted gold
---collectable within opts.horizon_s. Eligible targets exclude contested + hard-risk-vetoed ones,
---then are trimmed to the top opts.pool_cap by a cheap one-step value/time score (bounds the search).
---A bounded DFS with feasibility pruning (stop extending once a target is uncollectable) + an
---optimistic value bound (prune when the best possible remaining gold cannot beat the incumbent
---score) returns the optimum within the bound. Pure. Empty -> { steps={}, gold=0, time=0, score=0 }.
---opts: now, horizon_s, max_steps(=4), risk_weight, risk_hard(=1.0), pool_cap(=10).
---@return table plan { steps = {FarmTarget,...}, gold, time, score }
function Route.Plan(targets, hero_state, opts)
    opts = opts or {}
    local risk_hard = opts.risk_hard or 1.0
    local max_steps = opts.max_steps or 4
    local pool_cap  = opts.pool_cap  or 10

    -- 1. eligibility filter (drop contested + hard-risk-vetoed + UNREACHABLE). opts.max_leg_s: drop a target
    --    whose reach ETA from the hero (walk or ready teleport, via _leg_time) exceeds it, so the planner
    --    never commits to a camp Tinker cannot get to before the move watchdog fires (the far-camp stuck).
    --    Refill nodes are never distance-filtered. (Keen L2 creep-reach will relax this later.)
    local pool = {}
    for i = 1, #(targets or {}) do
        local tg = targets[i]
        if tg and tg.pos and not tg.contested and (tg.risk or 0) < risk_hard
           and (tg.restore or not opts.max_leg_s or Route._leg_time(hero_state.pos, tg, hero_state) <= opts.max_leg_s) then
            pool[#pool + 1] = tg
        end
    end

    -- 2. trim to the top pool_cap by a cheap one-step score value/(leg+clear) from the hero now.
    --    Sort a parallel {tg,s1} list so the caller's target tables are never mutated.
    if #pool > pool_cap then
        local restores, normals = {}, {}                 -- refill nodes (value 0) must never be trimmed
        for i = 1, #pool do
            if pool[i].restore then restores[#restores + 1] = pool[i] else normals[#normals + 1] = pool[i] end
        end
        -- #3: rank by the SAME risk-adjusted value the DFS objective uses (was value-only), so a close
        -- RISKY camp no longer crowds a safer camp out of the pool before the planner ever weighs it.
        -- Distance still discounts via the rate; the far-high-value-camp case is handled by pool_cap
        -- (raise it, hero side) + receding re-planning (a far camp's leg shrinks as the hero closes).
        local rw = opts.risk_weight or 0
        local scored = {}
        for i = 1, #normals do
            local tg = normals[i]
            local t  = Route._leg_time(hero_state.pos, tg, hero_state) + (tg.clear_t or 0)
            scored[i] = { tg = tg, s1 = ((tg.value or 0) - rw * (tg.risk or 0)) / math.max(0.5, t) }
        end
        table.sort(scored, function(a, b) return a.s1 > b.s1 end)
        pool = {}
        local keep = math.max(0, pool_cap - #restores)
        for i = 1, math.min(keep, #normals) do pool[i] = scored[i].tg end
        for i = 1, #restores do pool[#pool + 1] = restores[i] end
    end
    local n = #pool

    -- prefix sums of values sorted desc, for the optimistic remaining-gold bound (an upper bound:
    -- it ignores travel/risk and may reuse values, so it never prunes a real improvement).
    local vals = {}
    for i = 1, n do vals[i] = pool[i].value or 0 end
    table.sort(vals, function(a, b) return a > b end)
    local prefix = { [0] = 0 }
    for i = 1, n do prefix[i] = prefix[i - 1] + vals[i] end
    local function top_sum(k) if k < 0 then k = 0 end; return prefix[math.min(k, n)] end

    -- 3. bounded DFS over ordered sequences (each target at most once)
    local best = { steps = {}, gold = 0, time = 0, score = 0 }
    local used, seq = {}, {}
    local function dfs(depth, gold_so_far)
        if gold_so_far + top_sum(max_steps - depth) < best.score then return end   -- optimistic prune
        for i = 1, n do
            if not used[i] then
                used[i] = true; seq[depth + 1] = pool[i]
                local sc = Route._score(seq, hero_state, opts)
                if #sc.collected == depth + 1 then            -- fully collectable prefix: valid + extendable
                    if sc.score > best.score or (sc.score == best.score and sc.time < best.time) then
                        local steps = {}
                        for j = 1, depth + 1 do steps[j] = seq[j] end
                        best = { steps = steps, gold = sc.gold, time = sc.time, score = sc.score }
                    end
                    if depth + 1 < max_steps then dfs(depth + 1, sc.gold) end
                end
                seq[depth + 1] = nil; used[i] = false
            end
        end
    end
    dfs(0, 0)
    return best
end

---convenience: the single first leg to execute now (nil if no plan).
---@return table|nil FarmTarget
function Route.Select(targets, hero_state, opts)
    return Route.Plan(targets, hero_state, opts).steps[1]
end

return Route
