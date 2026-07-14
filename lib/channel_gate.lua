---ChannelGate - "is starting a channel here safe from channel-breaking disables?"
---
---ARC E1 (TINKER_ENEMY_INTERACTION_REVIEW.md, Defense case-file #1): Tinker is the first
---hero with long self-channels (Rearm 1.2-2.7s, Keen 2.93s). A channel started within a
---disabler's cast range is a guaranteed loss: the stun breaks it with the mana spent
---(channels break on stuns/hexes/forced movement - NOT on attack damage), and the
---lane_unsafe 1v1-trade rule correctly stays to FARM against a lone laner, so it can
---never gate channel starts. This module supplies the missing kit-awareness: the static
---half of "don't channel near a ready disabler". (The READINESS half - last-seen-cast
---stamps fed from modifier events - arrived with ARC E2: Stamp/ReadyAt below; unstamped
---abilities still assume ready, the conservative default.)
---
---Pure over the three data tables (no engine reads, no state): the caller passes a
---hero_data abilities list + the ability_data and threat_data MODULES and caches the
---result per hero name.

local ChannelGate = {}

-- Roles whose arrival breaks a channel. hard_disable = stuns/hexes/roots-with-break;
-- channel_on_me = enemy channels that lock us (Dismember-class). gap_close (Charge-class)
-- is EXCLUDED on purpose: cast ranges there read huge/global and would gate every channel
-- all game - armed gap-close threats are E2's job (event-driven, not proximity).
local BREAKER_ROLES = { hard_disable = true, channel_on_me = true }

---Every channel-breaking ability in a kit with its gate range, nil if the kit has none.
---@param abilities table|nil  hero_data HEROES[name].abilities (list of ability names)
---@param AD table             lib.ability_data module (CastRange)
---@param TD table             lib.threat_data module (ABILITY_TO_THREAT + THREATS_ON_SELF)
---@return table|nil  list of { ability = name, mod = modifier_name, range = number }
function ChannelGate.Breakers(abilities, AD, TD)
    if not (abilities and AD and TD) then return nil end
    local out
    for _, ab in ipairs(abilities) do
        local mod = TD.ABILITY_TO_THREAT and TD.ABILITY_TO_THREAT[ab]
        local entry = mod and TD.THREATS_ON_SELF and TD.THREATS_ON_SELF[mod]
        if entry and BREAKER_ROLES[entry.role] then
            local r = tonumber(AD.CastRange and AD.CastRange(ab, 4)) or 0
            if r < 250 then r = 250 end   -- melee-range disables (Bash-class) still break on arrival
            out = out or {}
            out[#out + 1] = { ability = ab, mod = mod, range = r }
        end
    end
    return out
end

---Max cast range of any channel-breaking ability in a kit, nil if the kit has none.
---(Kept for E1 compatibility; now a thin max over Breakers.)
---@return number|nil
function ChannelGate.DisableRange(abilities, AD, TD)
    local br = ChannelGate.Breakers(abilities, AD, TD)
    if not br then return nil end
    local best
    for _, b in ipairs(br) do if not best or b.range > best then best = b.range end end
    return best
end

---E2 readiness stamps (pure; the hero owns the table + the clock).
---A stamp records an OBSERVED cast: the ability cannot be ready again before t + cd.
---ReadyAt answers "plausibly ready at time t?" - unstamped = assume ready (the
---conservative E1 default).
---@param stamps table       caller-owned { [caster_name] = { [ability] = expiry_t } }
---@param caster_name string
---@param ability string
---@param t number           observed cast time
---@param cd number           ability cooldown at the observed level
function ChannelGate.Stamp(stamps, caster_name, ability, t, cd)
    if not (stamps and caster_name and ability) then return end
    local c = stamps[caster_name]; if not c then c = {}; stamps[caster_name] = c end
    c[ability] = (t or 0) + (cd or 0)
end

---@return boolean  true when the ability is plausibly ready at time t
function ChannelGate.ReadyAt(stamps, caster_name, ability, t)
    local c = stamps and stamps[caster_name]
    local expiry = c and c[ability]
    return not expiry or (t or 0) >= expiry
end

return ChannelGate
