---@meta
---lib/nav.lua - movement-destination policy + transport selection for a per-layer movement
---chokepoint. PURE + hero-agnostic: no engine reads - the caller injects the safety predicate
---and capability flags. Built for the Tinker lane rebuild Piece 0 (TINKER_LANE_NAV_DESIGN.md);
---reusable by any hero/layer that wants one clamp + one transport ladder.
local Nav = {}

---Clamp a destination to the nearest safe point toward `retreat`.
---@param dest table { x, y } desired destination
---@param retreat table { x, y } UNIT vector toward safety (lane: toward own fountain)
---@param safe fun(pt: table): boolean injected structural predicate (e.g. tower_safe)
---@param opts table|nil { step = 100, max_steps = 40 }
---@return table pt, boolean clamped  -- dest itself when already safe (clamped=false); the first
---safe stepped-back point (clamped=true); or the max-back point when never safe (clamped=true,
---degraded - the caller reports).
function Nav.SafeDest(dest, retreat, safe, opts)
    opts = opts or {}
    local step, max_steps = opts.step or 100, opts.max_steps or 40
    if safe(dest) then return dest, false end
    local pt = dest
    for i = 1, max_steps do
        pt = { x = dest.x + retreat.x * step * i, y = dest.y + retreat.y * step * i }
        if safe(pt) then return pt, true end
    end
    return pt, true
end

---Transport rungs eligible for a leg of distance `d`, in try-order. The caller executes the first
---rung whose gated primitive succeeds and FALLS THROUGH on failure (e.g. keen finds no safe
---landing); "walk" is always last and always eligible. Pure decision only.
---@param d number distance to the (clamped) destination
---@param ctx table { keened, keen_ready, keen_min_gain, blink_ready, blink_min, blink_max }
---@return table rungs array of "keen"|"rearm"|"blink"|"walk"
function Nav.Ladder(d, ctx)
    ctx = ctx or {}
    d = d or 0
    local rungs = {}
    if not ctx.keened and d > (ctx.keen_min_gain or 0) then
        if ctx.keen_ready then rungs[#rungs + 1] = "keen"
        else rungs[#rungs + 1] = "rearm" end       -- keen on cd: a (safe) Rearm resets it
    end
    if ctx.blink_ready and d >= (ctx.blink_min or 0) and d <= (ctx.blink_max or math.huge) then
        rungs[#rungs + 1] = "blink"
    end
    rungs[#rungs + 1] = "walk"
    return rungs
end

---progress/stuck supervision for a movement leg: feed the CURRENT distance-to-destination each
---tick; stuck = no improvement of at least opts.eps for opts.window seconds. Pure state-in/state-out
---(the caller keeps `track` per leg; pass nil to start one). Unifies the hero-side watchdog family
---(no_progress / shove stuck-suppress / stuck-teleport) at the glue rebuild - same logic, one home.
---@param track table|nil { best_d, best_t }
---@param d number current distance to the destination
---@param t number current time
---@param opts table|nil { eps = 60, window = 3.0 }
---@return table track, boolean stuck
function Nav.Stuck(track, d, t, opts)
    opts = opts or {}
    local eps, window = opts.eps or 60, opts.window or 3.0
    if not track or d < track.best_d - eps then
        return { best_d = d, best_t = t }, false          -- (re)baseline on real progress
    end
    return track, (t - track.best_t) >= window
end

---best tree-hide blink landing (the pure half of the lane tree-blink feature): the tree whose
---standing-tree CLUSTER is densest, within blink range of `from`, and at least opts.threat_min from
---`threat`. Score = cluster size; ties -> farther from the threat. nil when nothing qualifies.
---trees = { {x,y}, ... } (the caller reads the standing trees near the hero, e.g. Map.TreesNear).
---@param opts table|nil { blink_max = 950, cluster_r = 250, min_trees = 4, threat_min = 800 }
---@return table|nil { x, y }
function Nav.TreeHideSpot(trees, from, threat, opts)
    opts = opts or {}
    local bmax  = opts.blink_max or 950
    local cr2   = (opts.cluster_r or 250) ^ 2
    local minn  = opts.min_trees or 4
    local tmin2 = (opts.threat_min or 800) ^ 2
    local best, bestn, besttd = nil, 0, -1
    for i = 1, #(trees or {}) do
        local c = trees[i]
        local dx, dy = c.x - from.x, c.y - from.y
        if dx * dx + dy * dy <= bmax * bmax then
            local tdx, tdy = c.x - (threat and threat.x or 1e9), c.y - (threat and threat.y or 1e9)
            local td2 = tdx * tdx + tdy * tdy
            if (not threat) or td2 >= tmin2 then
                local n = 0
                for j = 1, #trees do
                    local ex, ey = trees[j].x - c.x, trees[j].y - c.y
                    if ex * ex + ey * ey <= cr2 then n = n + 1 end
                end
                if n >= minn and (n > bestn or (n == bestn and td2 > besttd)) then
                    best, bestn, besttd = { x = c.x, y = c.y }, n, td2
                end
            end
        end
    end
    return best
end

return Nav
