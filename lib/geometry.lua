---@meta
---lib/geometry.lua - generic 2D position / distance / prediction helpers.
---
---Hero-agnostic. All functions take entity or vector args explicitly
---(no implicit hero-state reads).
---
---Extracted from Sniper.lua v6.15.112 to reduce main-chunk local count.

local Geometry = {}

---2D distance between two entities.
---@param a userdata|nil first entity
---@param b userdata|nil second entity
---@return number distance, math.huge if either entity is nil
function Geometry.dist_between(a, b)
    if not a or not b then return math.huge end
    local pa = Entity.GetAbsOrigin(a)
    local pb = Entity.GetAbsOrigin(b)
    if not pa or not pb then return math.huge end
    -- Distance2D over (pa - pb):Length2D(): one native call, no temp Vector.
    return pa:Distance2D(pb)
end

---2D distance from one entity to another (alias of dist_between, but
---with an explicit "from → to" mental model for callers used to that).
---@param from userdata|nil
---@param to userdata|nil
---@return number
function Geometry.dist_from_to(from, to)
    return Geometry.dist_between(from, to)
end

---Predicted target position `lead_s` seconds ahead, from the target's
---actual VELOCITY VECTOR.
---
---Returns `nil` when the target is unusable (nil / not an Entity / no
---position). Callers handle this with `... or fallback` (every Sniper
---call site does `Geom.lead_target_pos(...) or c.target_pos`).
---Returns the target's CURRENT position (no lead) when the target is
---valid but not actually moving.
---
---v6.15.125 REWRITE - the old model was mathematically wrong. It used
---`NPC.GetMoveSpeed`, which is a move-speed STAT (≈285-330 for any hero,
---non-zero while standing still), projected along the facing yaw. So a
---STATIONARY target had its zone placed `GetMoveSpeed * lead_s` (~450u
---at lead 1.5s) off-centre in its facing direction, and a moving target
---had the lead pointed along facing rather than travel (wrong whenever
---facing ≠ motion). The `mvspeed < 200` gate never caught stationary
---units because the stat itself is ~300.
---
---The model now reads the engine's true velocity vector via
---`Entity.GetField(target, "m_vecVelocity")`: zero velocity → zero lead
---(a stationary target keeps its centre), real velocity → correct
---travel direction and speed. `future = pos + velocity * lead_s`.
---Pattern proven in the Windranger 2 third-party script (Shackleshot
---leads). `m_vecVelocity` is an undocumented Source 2 field - pcall-
---guarded; the fallback (facing × move-speed, only while a move order
---is live) is the old model but at least gated so it never leads a
---standing unit.
---
---@param target userdata|nil target entity
---@param me userdata|nil caster entity (unused; kept for API stability)
---@param lead_s number lead time in seconds
---@return userdata|nil predicted Vector position, or nil if target invalid
function Geometry.lead_target_pos(target, me, lead_s)
    if not target or not Entity.IsEntity(target) then return nil end
    local tpos = Entity.GetAbsOrigin(target)
    if not tpos then return nil end

    -- Primary: the engine's real velocity vector.
    local vel
    local ok, v = pcall(Entity.GetField, target, "m_vecVelocity")
    if ok and v and v.Length and v:Length() > 5 then
        vel = v
    elseif NPC.IsRunning and NPC.IsRunning(target) then
        -- Fallback (velocity field unavailable): facing × move-speed,
        -- but ONLY while a move order is live so a standing unit gets
        -- no lead.
        local rot = Entity.GetRotation and Entity.GetRotation(target)
        local f   = rot and rot.GetForward and rot:GetForward()
        if f and f.Normalized then
            local n  = f:Normalized()
            local ms = (NPC.GetMoveSpeed and NPC.GetMoveSpeed(target)) or 0
            vel = Vector((n.x or 0) * ms, (n.y or 0) * ms, 0)
        end
    end
    if not vel then return tpos end

    return Vector(tpos.x + (vel.x or 0) * lead_s,
                  tpos.y + (vel.y or 0) * lead_s,
                  tpos.z)
end

----------------------------------------------------------------------------
-- smoothed velocity prediction (vel_hist) + AoE-coverage placement
-- Added 2026-05-28. Hero-agnostic; mirrors the inline sample_velocities /
-- predict_pos model proven in Sniper (Sniper keeps its own inline copy for now;
-- see Sniper/PREDICTION_LIB_MIGRATION.md). Module-level vel_hist state is shared
-- across all consumers via Lua's require-cache; call SampleVelocities once per
-- tick from a consumer's OnUpdateEx.
----------------------------------------------------------------------------

local MS_GEO = Enum.ModifierState
local VEL_HIST_N = 6      -- ring-buffer samples (~0.2-0.3s at 20-30Hz)
local vel_hist = {}       -- entity_idx -> { {t,x,y}, ... } (newest last)
local function geo_now() return GlobalVars.GetCurTime() end

---Record nearby enemy hero positions into the velocity-history ring buffers.
---A >0.25s vision gap, or a per-tick jump beyond foot speed (700 u/s = a
---blink/teleport discontinuity), resets that unit's buffer so PredictPos never
---leads off a phantom velocity.
---@param me userdata  caster (origin of the radius scan)
---@param radius number|nil  scan radius (default 1600)
function Geometry.SampleVelocities(me, radius)
    if not me or not Entity.IsEntity(me) then return end
    local list = Entity.GetHeroesInRadius(me, radius or 1600, Enum.TeamType.TEAM_ENEMY)
    if not list then return end
    local t = geo_now()
    for i = 1, #list do
        local h = list[i]
        if h and Entity.IsEntity(h) and Entity.IsAlive(h) then
            local idx = Entity.GetIndex(h)
            local pos = Entity.GetAbsOrigin(h)
            if idx and pos then
                local buf = vel_hist[idx]
                if buf and #buf > 0 then
                    local last = buf[#buf]
                    local gap  = t - last.t
                    if gap > 0.25 then
                        buf = nil
                    else
                        local dx, dy = pos.x - last.x, pos.y - last.y
                        local cap = 700 * (gap + 0.05)
                        if (dx * dx + dy * dy) > (cap * cap) then buf = nil end
                    end
                end
                if not buf then buf = {}; vel_hist[idx] = buf end
                buf[#buf + 1] = { t = t, x = pos.x, y = pos.y }
                while #buf > VEL_HIST_N do table.remove(buf, 1) end
            end
        end
    end
end

---Predicted position `lead_s` ahead using the SMOOTHED velocity (averaged over
---the SampleVelocities buffer), which steadies jitter vs the instantaneous read.
---Falls back to lead_target_pos (capped at foot speed) when there is no usable
---history; stationary / hard-CC'd targets get no lead. Returns nil for an
---invalid target (callers do `... or fallback`).
---@param target userdata|nil
---@param lead_s number
---@return userdata|nil predicted Vector
function Geometry.PredictPos(target, lead_s)
    if not target or not Entity.IsEntity(target) then return nil end
    local tpos = Entity.GetAbsOrigin(target)
    if not tpos then return nil end
    local idx = Entity.GetIndex(target)
    local buf = idx and vel_hist[idx]
    if buf and #buf >= 2 then
        local newest, oldest = buf[#buf], buf[1]
        local dt = newest.t - oldest.t
        if dt >= 0.05 and (geo_now() - newest.t) < 0.25 then
            local vx = (newest.x - oldest.x) / dt
            local vy = (newest.y - oldest.y) / dt
            if (vx * vx + vy * vy) > 3600 then  -- smoothed speed > 60 u/s
                return Vector(tpos.x + vx * lead_s, tpos.y + vy * lead_s, tpos.z)
            end
            return tpos  -- ~stationary: no lead
        end
    end
    -- buffer-empty fallback: hard-CC = no lead; else instantaneous, foot-capped.
    if MS_GEO and NPC.HasState and (
          NPC.HasState(target, MS_GEO.MODIFIER_STATE_STUNNED)
       or NPC.HasState(target, MS_GEO.MODIFIER_STATE_ROOTED)
       or NPC.HasState(target, MS_GEO.MODIFIER_STATE_FROZEN)) then
        return tpos
    end
    local lp = Geometry.lead_target_pos(target, nil, lead_s)
    if not lp then return tpos end
    local lx, ly = (lp.x or 0) - tpos.x, (lp.y or 0) - tpos.y
    local cap = 700 * lead_s
    if (lx * lx + ly * ly) > cap * cap then return tpos end
    return lp
end

---Best AoE center to cover the most of `units` (each predicted `lead_s` ahead)
---within `radius`. If `must_cover` is given, only centers within `radius` of
---that unit's predicted position are considered (it is always caught) and the
---result maximizes the OTHERS around it. Candidate centers include points
---BETWEEN units (not just unit positions), so two units up to 2*radius apart
---can both be caught. Returns (center Vector, count) or (nil, 0).
---@param units userdata[]  candidate enemy units
---@param radius number  AoE radius
---@param lead_s number  prediction lead
---@param must_cover userdata|nil  unit that must be covered (e.g. the R target)
---@return userdata|nil center, integer count
function Geometry.BestAoeCenter(units, radius, lead_s, must_cover)
    if not units or #units == 0 then return nil, 0 end
    local preds = {}
    for i = 1, #units do
        local p = Geometry.PredictPos(units[i], lead_s)
        if p then preds[#preds + 1] = p end
    end
    if #preds == 0 then return nil, 0 end

    local anchor = must_cover and Geometry.PredictPos(must_cover, lead_s) or nil
    if must_cover and not anchor then return nil, 0 end

    local cand = {}
    if anchor then
        cand[#cand + 1] = anchor
        for i = 1, #preds do
            local d = anchor:Distance2D(preds[i])
            if d > 1 and d <= 2 * radius then
                -- v0.5.175: MIDPOINT placement (anchor..pred). For d <= 2*radius the
                -- midpoint sits d/2 <= radius from BOTH, so the anchor stays covered
                -- and the far unit is INSIDE the radius with margin (d/2). Robust vs
                -- the old rim placement (off = d - radius put the far unit at exactly
                -- `radius`, which floating-point could round just outside, collapsing
                -- a catchable pair to single-target -- the Lina w_aim demo logged
                -- d=482 -> covered=1). Generated FIRST so it wins coverage ties over
                -- the rim candidate, which is kept so coverage never regresses for 3+.
                cand[#cand + 1] = Vector((anchor.x + preds[i].x) * 0.5,
                                         (anchor.y + preds[i].y) * 0.5, anchor.z)
                local off = d - radius; if off < 0 then off = 0 end  -- in [0, radius]
                local f = off / d
                cand[#cand + 1] = Vector(anchor.x + (preds[i].x - anchor.x) * f,
                                         anchor.y + (preds[i].y - anchor.y) * f, anchor.z)
            end
        end
    else
        for i = 1, #preds do cand[#cand + 1] = preds[i] end
        for i = 1, #preds do
            for j = i + 1, #preds do
                if preds[i]:Distance2D(preds[j]) <= 2 * radius then
                    cand[#cand + 1] = Vector((preds[i].x + preds[j].x) * 0.5,
                                             (preds[i].y + preds[j].y) * 0.5, preds[i].z)
                end
            end
        end
    end

    local best_c, best_n = nil, 0
    for c = 1, #cand do
        local center = cand[c]
        if not anchor or center:Distance2D(anchor) <= radius + 1 then
            local n = 0
            for i = 1, #preds do
                if center:Distance2D(preds[i]) <= radius then n = n + 1 end
            end
            if n > best_n then best_n, best_c = n, center end
        end
    end
    return best_c, best_n
end

---Best aim point for a LINE/projectile skill cast from `source`: the direction
---whose width band (half_width) and `length` cross the most of `units` (each
---predicted `lead_s` ahead). The line analog of BestAoeCenter. If `must_cover`
---is given, only directions whose band contains that unit are considered.
---Candidate directions are toward each predicted unit (+ toward must_cover).
---Returns (aim_point Vector at `length` along the best direction, count) or
---(nil, 0). Cast the skill at the returned point to aim the line that way.
---@param units userdata[]  candidate enemy units
---@param source userdata  caster position (Vector)
---@param half_width number  half the line width
---@param length number  line length
---@param lead_s number  prediction lead
---@param must_cover userdata|nil  unit the line must contain
---@return userdata|nil aim_point, integer count
function Geometry.BestLineAim(units, source, half_width, length, lead_s, must_cover)
    if not units or #units == 0 or not source then return nil, 0 end
    local sx, sy, sz = source.x, source.y, source.z
    local preds = {}
    for i = 1, #units do
        local p = Geometry.PredictPos(units[i], lead_s)
        if p then preds[#preds + 1] = p end
    end
    if #preds == 0 then return nil, 0 end
    local cover = must_cover and Geometry.PredictPos(must_cover, lead_s) or nil
    if must_cover and not cover then return nil, 0 end

    local hw2 = half_width * half_width
    local function on_line(ux, uy, p)
        local rx, ry = p.x - sx, p.y - sy
        local proj = rx * ux + ry * uy
        if proj < 0 or proj > length then return false end
        return ((rx * rx + ry * ry) - proj * proj) <= hw2
    end

    -- Candidate aim directions. "Toward each unit" alone under-covers a 2D spread
    -- (it can only aim AT a unit); add the centroid and pairwise midpoints so the
    -- line can thread BETWEEN units and cross more of a non-radial cluster.
    local cands = {}
    for i = 1, #preds do cands[#cands + 1] = preds[i] end
    if #preds >= 2 then
        local cx, cy = 0, 0
        for i = 1, #preds do cx = cx + preds[i].x; cy = cy + preds[i].y end
        cands[#cands + 1] = Vector(cx / #preds, cy / #preds, preds[1].z)  -- centroid
        for i = 1, #preds do
            for j = i + 1, #preds do
                cands[#cands + 1] = Vector((preds[i].x + preds[j].x) * 0.5,
                                           (preds[i].y + preds[j].y) * 0.5, preds[i].z)
            end
        end
    end
    if cover then cands[#cands + 1] = cover end

    local best_ux, best_uy, best_n
    for c = 1, #cands do
        local dx, dy = cands[c].x - sx, cands[c].y - sy
        local len = math.sqrt(dx * dx + dy * dy)
        if len > 1 then
            local ux, uy = dx / len, dy / len
            if not cover or on_line(ux, uy, cover) then
                local n = 0
                for i = 1, #preds do if on_line(ux, uy, preds[i]) then n = n + 1 end end
                if not best_n or n > best_n then best_n, best_ux, best_uy = n, ux, uy end
            end
        end
    end
    if not best_ux then
        if cover then return Vector(cover.x, cover.y, cover.z), 1 end
        return nil, 0
    end
    return Vector(sx + best_ux * length, sy + best_uy * length, sz), best_n or 0
end

---Closest reachable landing INSIDE a teleport reach-disc to a target. An anchor's reach is a disc
---(centre + radius r): the teleport may drop us anywhere within r of the centre, so the point closest to
---`target` is the target itself when it lies inside the disc, else the disc EDGE along centre->target.
---Pure scalar (offline-testable). Shared model for Keen Conveyance (structures now, creeps later) AND
---Boots of Travel, which teleport the same way.
---@param cx number @param cy number  disc centre
---@param r number   reach radius
---@param tx number @param ty number  target
---@return number lx @return number ly  the landing point
---@return number residual  distance from the landing to the target (0 when the target is inside the disc)
function Geometry.DiscReachPoint(cx, cy, r, tx, ty)
    local dx, dy = tx - cx, ty - cy
    local d = math.sqrt(dx * dx + dy * dy)
    if d <= (r or 0) or d < 1e-9 then return tx, ty, 0 end     -- target inside reach -> land ON it
    local k = r / d
    return cx + dx * k, cy + dy * k, d - r
end

---Best teleport landing among a set of reach discs: the landing NEAREST the target whose point passes an
---optional `accept` filter. Each anchor = { pos = {x,y}, r = <reach>, ... }. The hero supplies
---`accept(lx, ly, anchor) -> bool` for engine-dependent checks (walkable / safe / creep-free), so this
---stays pure. A rejected (nearer) landing never blocks a farther accepted one. Returns nil if none pass.
---SAME picker for structure anchors now and creep/BoT anchors later - only the anchor list + accept differ.
---@param anchors table array of { pos = {x,y}, r = number }
---@param target table { x, y }
---@param opts table|nil { accept = function(lx,ly,anchor)->bool }
---@return table|nil { anchor, lx, ly, residual }
function Geometry.BestReachLanding(anchors, target, opts)
    if not (anchors and target) then return nil end
    local accept = opts and opts.accept
    local best, bestres = nil, math.huge
    for i = 1, #anchors do
        local a = anchors[i]
        if a and a.pos and a.r then
            local lx, ly, residual = Geometry.DiscReachPoint(a.pos.x, a.pos.y, a.r, target.x, target.y)
            if residual < bestres and (not accept or accept(lx, ly, a)) then
                best, bestres = { anchor = a, lx = lx, ly = ly, residual = residual }, residual
            end
        end
    end
    return best
end

return Geometry
