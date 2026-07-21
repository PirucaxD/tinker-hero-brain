-- lib/draw.lua - screen-space drawing/debug rendering (the math.h principle: one theme).
-- Lifted from Tinker.lua v0.1.324 (the 200-local headroom lift, wave 1): dbg_font, w2s,
-- dbg_text, world_text, world_ring, world_line, world_seg, world_obox - bodies unchanged,
-- the font cache moved into the module. Engine-bound (Render/Vector/Vec2 globals), so no
-- offline tests (run_tests has no Render mock; the overlay itself is the visual check).

local Draw = {}

local font
function Draw.Font()
    if not font then font = Render.LoadFont("Tahoma", 0, 500) end
    return font
end

function Draw.W2S(p) return Render.WorldToScreen(p) end

function Draw.Text(sp, text, col) Render.Text(Draw.Font(), 14, text, sp, col) end

function Draw.WorldText(wp, text, col, dx, dy)
    local sp, vis = Draw.W2S(wp)
    if vis then Draw.Text(Vec2(sp.x + (dx or 6), sp.y + (dy or 0)), text, col) end
end

function Draw.Ring(center, radius, col, thickness)
    -- draw arc-by-arc so a ring that is partly off-screen still shows its visible part (the old version
    -- bailed the WHOLE ring if any single point was off-screen -> large rings never drew).
    local seg = 36
    local prev, pvis
    for i = 0, seg do
        local a = (i / seg) * math.pi * 2
        local sp, vis = Draw.W2S(Vector(center.x + math.cos(a) * radius,
                                        center.y + math.sin(a) * radius, center.z))
        if i > 0 and pvis and vis then Render.Line(prev, sp, col, thickness or 1.6) end
        prev, pvis = sp, vis
    end
end

function Draw.Line(a, b, col, thickness)
    local sa, va = Draw.W2S(a)
    local sb, vb = Draw.W2S(b)
    if va and vb then Render.Line(sa, sb, col, thickness or 1.5) end
end

-- draw a world-space segment subdivided, so the ON-screen part of a long edge still shows even when an
-- endpoint is off-screen (Draw.Line alone skips the whole edge if either end is off-screen).
function Draw.Seg(a, b, col, n)
    n = n or 10
    local prev, pvis
    for i = 0, n do
        local t = i / n
        local sp, vis = Draw.W2S(Vector(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t, a.z))
        if i > 0 and pvis and vis then Render.Line(prev, sp, col, 1.6) end
        prev, pvis = sp, vis
    end
end

-- oriented rectangle centred on `center`: half-extent `ha` along (ux,uy), `hp` along the perpendicular.
function Draw.OBox(center, ux, uy, ha, hp, col)
    local px, py, z = -uy, ux, center.z
    local c1 = Vector(center.x + ux * ha + px * hp, center.y + uy * ha + py * hp, z)
    local c2 = Vector(center.x + ux * ha - px * hp, center.y + uy * ha - py * hp, z)
    local c3 = Vector(center.x - ux * ha - px * hp, center.y - uy * ha - py * hp, z)
    local c4 = Vector(center.x - ux * ha + px * hp, center.y - uy * ha + py * hp, z)
    Draw.Seg(c1, c2, col); Draw.Seg(c2, c3, col); Draw.Seg(c3, c4, col); Draw.Seg(c4, c1, col)
end

return Draw
