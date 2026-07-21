---MarchSim - offline attrition model of March of the Machines vs a lane wave.
---
---W-GEOM-2 (TINKER_W_GEOMETRY_STUDY.md sec 4/5): March is a robot STREAM, not an
---instant AOE - 144 robots over 6s, speed 400, each dying on its first collision
---(collision 50, splash 150). Whether the trailing RANGED creep dies in 2 casts
---depends on how the melee screen intercepts the stream, which is exactly what
---the X pattern changes. This sim answers that before any hero code does:
---straight front/behind (today) vs X arms at +-theta, at the 810 standard stand.
---It doubles as the wavefront math foundation for W-GEOM-3 (cast timing).
---
---Pure component math, no engine reads, deterministic (golden-ratio lateral
---spread instead of the game's random spawn line). Offline-only today: consumed
---by tools/run_tests.lua + tools/w_geom_report.lua, not by Tinker.lua.
---
---KV (npc_abilities.json, tinker_march_of_the_machines), in-client calibrated
---box: ~1800x1800 centered on the cast point, oriented along hero->cast-point.

local MarchSim = {}

MarchSim.K = {
    CAST_RANGE = 300, CAST_POINT = 0.53,
    HALF = 900,                -- box half-width AND spawn-edge offset (the box is centered on the cast point)
    SPEED = 400, RATE = 24, DURATION = 6.0,
    LIFE = 1800 / 400,         -- robot travel time across the box
    SPLASH = 150,
    HIT_R = 75,                -- ponytail: collision 50 + ~25 creep hull; calibrate in-client if kills read off
    BACKSTEP = 60,             -- today's behind-cast flip offset
}
local K = MarchSim.K
local PHI = 0.6180339887

local function norm(x, y)
    local d = math.sqrt(x * x + y * y)
    if d < 1e-6 then return 1, 0 end
    return x / d, y / d
end

---One cast's geometry. theta_deg rotates the facing off the hero->aim axis (an X arm);
---behind = today's backstep flip (robots spawn beyond the aim and sweep back; theta ignored).
---@return table { cx, cy, fx, fy }  cast point + unit facing; spawn edge = cast - HALF*facing
function MarchSim.Cast(hero, aim, theta_deg, behind)
    local ax, ay = norm(aim.x - hero.x, aim.y - hero.y)
    if behind then
        return { cx = hero.x - K.BACKSTEP * ax, cy = hero.y - K.BACKSTEP * ay, fx = -ax, fy = -ay }
    end
    local th = math.rad(theta_deg or 0)
    local c, s = math.cos(th), math.sin(th)
    local fx, fy = ax * c - ay * s, ax * s + ay * c
    local d = math.min(K.CAST_RANGE, math.sqrt((aim.x - hero.x) ^ 2 + (aim.y - hero.y) ^ 2))
    return { cx = hero.x + d * fx, cy = hero.y + d * fy, fx = fx, fy = fy }
end

---Standard wave formation anchored on the trailing ranged (the stand/aim anchor):
---melees `gap` ahead along the walk direction, spread laterally. Returns a creeps list
---for Simulate (melees first, ranged last).
function MarchSim.MakeWave(o)
    local n = o.n_melee or 3
    local gap, spread = o.gap or 200, o.spread or 120
    local wx, wy = norm(o.walk.x, o.walk.y)
    local px, py = -wy, wx
    local creeps = {}
    for i = 1, n do
        local lat = (i - (n + 1) / 2) * spread
        creeps[#creeps + 1] = { x = o.ranged.x + gap * wx + lat * px, y = o.ranged.y + gap * wy + lat * py,
                                hp = o.melee_hp, kind = "melee" }
    end
    creeps[#creeps + 1] = { x = o.ranged.x, y = o.ranged.y, hp = o.ranged_hp, kind = "ranged" }
    return creeps
end

-- aim anchor at cast time: the living ranged, else the living-creep centroid (nil if none)
local function live_aim(creeps)
    local sx, sy, cn = 0, 0, 0
    for _, c in ipairs(creeps) do
        if c.hp > 0 then
            if c.kind == "ranged" then return { x = c.x, y = c.y } end
            sx, sy, cn = sx + c.x, sy + c.y, cn + 1
        end
    end
    if cn == 0 then return nil end
    return { x = sx / cn, y = sy / cn }
end

---Run the stream-vs-wave sim.
---opts: hero {x,y}; creeps list {x,y,hp,kind}; walk unit dir + wave_speed (default 0 =
---stationary); dmg per robot; casts list {t, theta, behind} (aim resolved at cast time
---from the live ranged); dt (default 1/30); hit_r override; bg_dps = our own wave's
---continuous dps per enemy creep once it is in combat (stopped, or always when
---wave_speed 0) - the LAST-HIT RACE term: a creep finished by bg_dps is our wave's
---kill, not ours (died_to = "bg"|"robot"; cs counts robot kills only).
---Creeps walk until first damaged or within 150 of the hero (in combat), a deliberately
---coarse stop model. ponytail: no creep-vs-creep collision, no tower actor.
---@return table { robots, hits, cs, cleared, creeps = {kind, hp, died_at, died_cast, died_to, hits} }
function MarchSim.Simulate(opts)
    local dt = opts.dt or (1 / 30)
    local hit_r = opts.hit_r or K.HIT_R
    local speed = opts.wave_speed or 0
    local wx, wy = 0, 0
    if opts.walk and speed > 0 then wx, wy = norm(opts.walk.x, opts.walk.y) end

    local creeps = {}
    for i, c in ipairs(opts.creeps) do
        creeps[i] = { x = c.x, y = c.y, hp = c.hp, kind = c.kind, hits = 0, stopped = false }
    end

    local t_end = 0
    for _, cast in ipairs(opts.casts) do
        t_end = math.max(t_end, cast.t + K.CAST_POINT + K.DURATION + K.LIFE + 0.25)
    end

    local robots, spawned, total_hits = {}, 0, 0
    local t = 0
    while t <= t_end do
        -- resolve casts due (geometry frozen at cast time, aimed at the live ranged)
        for ci, cast in ipairs(opts.casts) do
            if not cast._geo and t >= cast.t then
                local aim = live_aim(creeps)
                if aim then
                    cast._geo = MarchSim.Cast(opts.hero, aim, cast.theta, cast.behind)
                    cast._next = 0
                else
                    cast._geo = false      -- nothing left to hit; cast skipped
                end
                cast._ci = ci
            end
        end
        -- spawn robots due: robot i fires at cast.t + CAST_POINT + i/RATE, golden-ratio lateral
        for _, cast in ipairs(opts.casts) do
            local g = cast._geo
            while g and cast._next < K.RATE * K.DURATION
                  and t >= cast.t + K.CAST_POINT + cast._next / K.RATE do
                local i = cast._next
                local lat = (((i * PHI) % 1) * 2 - 1) * K.HALF
                local ex, ey = g.cx - K.HALF * g.fx, g.cy - K.HALF * g.fy
                robots[#robots + 1] = { x = ex - lat * g.fy, y = ey + lat * g.fx,
                                        fx = g.fx, fy = g.fy, dies = t + K.LIFE, cast = cast._ci }
                spawned = spawned + 1
                cast._next = i + 1
            end
        end
        -- move creeps (walk until in combat) + the own-wave dps race, then robots
        for _, c in ipairs(creeps) do
            if c.hp > 0 and speed > 0 and not c.stopped then
                local dx, dy = c.x - opts.hero.x, c.y - opts.hero.y
                if c.hits > 0 or dx * dx + dy * dy < 150 * 150 then c.stopped = true
                else c.x, c.y = c.x + wx * speed * dt, c.y + wy * speed * dt end
            end
            if c.hp > 0 and (opts.bg_dps or 0) > 0 and (c.stopped or speed == 0) then
                c.hp = c.hp - opts.bg_dps * dt
                if c.hp <= 0 then c.died_at, c.died_to = t, "bg" end
            end
        end
        local r = 1
        while r <= #robots do
            local b = robots[r]
            b.x, b.y = b.x + b.fx * K.SPEED * dt, b.y + b.fy * K.SPEED * dt
            local boom = t > b.dies
            if not boom then
                for _, c in ipairs(creeps) do
                    if c.hp > 0 then
                        local dx, dy = c.x - b.x, c.y - b.y
                        if dx * dx + dy * dy <= hit_r * hit_r then boom = "hit"; break end
                    end
                end
            end
            if boom then
                if boom == "hit" then
                    total_hits = total_hits + 1
                    for _, c in ipairs(creeps) do
                        if c.hp > 0 then
                            local dx, dy = c.x - b.x, c.y - b.y
                            if dx * dx + dy * dy <= K.SPLASH * K.SPLASH then
                                c.hp = c.hp - opts.dmg
                                c.hits = c.hits + 1
                                if c.hp <= 0 then c.died_at, c.died_cast, c.died_to = t, b.cast, "robot" end
                            end
                        end
                    end
                end
                robots[r] = robots[#robots]; robots[#robots] = nil
            else
                r = r + 1
            end
        end
        t = t + dt
    end

    local out, cleared, cs = {}, true, 0
    for i, c in ipairs(creeps) do
        if not c.died_at then cleared = false end
        if c.died_to == "robot" then cs = cs + 1 end
        out[i] = { kind = c.kind, hp = math.max(0, c.hp), died_at = c.died_at,
                   died_cast = c.died_cast, died_to = c.died_to, hits = c.hits }
    end
    for _, cast in ipairs(opts.casts) do cast._geo, cast._next, cast._ci = nil, nil, nil end
    return { robots = spawned, hits = total_hits, cs = cs, cleared = cleared, creeps = out }
end

return MarchSim
