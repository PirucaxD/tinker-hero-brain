---@meta
---lib/order.lua - single chokepoint for all brain-issued orders.
---
---Discipline:
---  • Every order carries an identifier `<hero>-<layer>-<intent>` so we can
---    self-arbitrate in OnPrepareUnitOrders.
---  • `callback=true` (the API param the project memos call "push=true") routes
---    every order through OnPrepareUnitOrders so the brain owns its dispatch.
---  • Layer "def" forces execute_fast=true (Layer 2 must beat the humanizer).
---  • Duplicate detection: `Humanizer.GetOrderQueue()` does NOT expose the
---    identifier field, so we mirror our own pending registry keyed by id
---    with a 2.5s TTL. Issuing the same id twice within the window is a no-op.
---
---Wiring: a hero brain or a bootstrap script should chain our handlers into
---its returned callbacks table via `Order.Wire(callbacks)`. The handlers are
---internally idempotent / frame-deduped, so multiple wirings are safe but
---wasteful - prefer wiring once from a bootstrap script.

local Order = {}

-- v6.14.1 M8: STRICT was module-private before - there was no production
-- path to flip it without editing this file. `Order.SetStrict(bool)` lets a
-- bootstrap script or menu hook toggle this at runtime. Default true (dev).
local STRICT = true
function Order.SetStrict(v) STRICT = (v == true) end
local PENDING_TTL = 2.5

---@class OrderPending
---@field hero      string
---@field layer     string
---@field intent    string
---@field expires   number

---@type table<string, OrderPending>
local pending = {}

---@type table<integer, true>  -- frame->seen for OnUpdateEx GC dedup
local gc_frame = {}

local now = function() return GlobalVars.GetCurTime() end
local frame = function() return GlobalVars.GetFrameCount() end

----------------------------------------------------------------------------
-- order-type → required fields
----------------------------------------------------------------------------

local UO = Enum.UnitOrder

-- Orders that require a target entity.
local NEEDS_TARGET = {
    [UO.DOTA_UNIT_ORDER_MOVE_TO_TARGET]    = true,
    [UO.DOTA_UNIT_ORDER_ATTACK_TARGET]     = true,
    [UO.DOTA_UNIT_ORDER_CAST_TARGET]       = true,
    [UO.DOTA_UNIT_ORDER_CAST_TARGET_TREE]  = true,
    [UO.DOTA_UNIT_ORDER_PICKUP_RUNE]       = true,
    [UO.DOTA_UNIT_ORDER_CAST_RUNE]         = true,
}

-- Orders that require a position vector.
local NEEDS_POSITION = {
    [UO.DOTA_UNIT_ORDER_MOVE_TO_POSITION]  = true,
    [UO.DOTA_UNIT_ORDER_MOVE_TO_DIRECTION] = true,
    [UO.DOTA_UNIT_ORDER_ATTACK_MOVE]       = true,
    [UO.DOTA_UNIT_ORDER_CAST_POSITION]     = true,
}

-- Orders that require an ability handle.
local NEEDS_ABILITY = {
    [UO.DOTA_UNIT_ORDER_CAST_POSITION]    = true,
    [UO.DOTA_UNIT_ORDER_CAST_TARGET]      = true,
    [UO.DOTA_UNIT_ORDER_CAST_TARGET_TREE] = true,
    [UO.DOTA_UNIT_ORDER_CAST_NO_TARGET]   = true,
    [UO.DOTA_UNIT_ORDER_CAST_TOGGLE]      = true,
    [UO.DOTA_UNIT_ORDER_CAST_TOGGLE_AUTO] = true,
    [UO.DOTA_UNIT_ORDER_CAST_RUNE]        = true,
    [UO.DOTA_UNIT_ORDER_TRAIN_ABILITY]    = true,
}

-- Orders where a target would be spurious.
local STRIPS_TARGET = {
    [UO.DOTA_UNIT_ORDER_MOVE_TO_POSITION]  = true,
    [UO.DOTA_UNIT_ORDER_MOVE_TO_DIRECTION] = true,
    [UO.DOTA_UNIT_ORDER_ATTACK_MOVE]       = true,
    [UO.DOTA_UNIT_ORDER_CAST_POSITION]     = true,
    [UO.DOTA_UNIT_ORDER_CAST_NO_TARGET]    = true,
    [UO.DOTA_UNIT_ORDER_CAST_TOGGLE]       = true,
    [UO.DOTA_UNIT_ORDER_CAST_TOGGLE_AUTO]  = true,
    [UO.DOTA_UNIT_ORDER_HOLD_POSITION]     = true,
    [UO.DOTA_UNIT_ORDER_STOP]              = true,
    [UO.DOTA_UNIT_ORDER_GLYPH]             = true,
    [UO.DOTA_UNIT_ORDER_BUYBACK]           = true,
}

----------------------------------------------------------------------------
-- public API
----------------------------------------------------------------------------

---Build the canonical identifier string.
---@param hero   string
---@param layer  string  -- "agg" | "def"
---@param intent string
---@return string
function Order.Identifier(hero, layer, intent)
    return hero .. "-" .. layer .. "-" .. intent
end

---Is an order with the given identifier prefix currently pending?
---Prefix match - e.g. `IsPending("sniper-agg-")` is true if any in-flight
---order's id starts with that prefix.
---@param prefix string
---@return boolean
function Order.IsPending(prefix)
    local t = now()
    for id, p in pairs(pending) do
        if p.expires > t and id:sub(1, #prefix) == prefix then
            return true
        end
    end
    return false
end

---@class OrderSpec
---@field hero          string
---@field layer         string         -- "agg" | "def"
---@field intent        string
---@field order_type    integer        -- Enum.UnitOrder
---@field unit          userdata       -- issuer CNPC
---@field target?       userdata
---@field position?     userdata
---@field ability?      userdata
---@field queue?        boolean
---@field show_effects? boolean
---@field execute_fast? boolean        -- forced true for layer=="def"
---@field force_minimap? boolean       -- default true

---Issue an order. Returns true if dispatched, false on validation/duplicate.
---@param spec OrderSpec
---@return boolean
function Order.Issue(spec)
    -- 1. Required-field validation
    if not (spec and spec.hero and spec.layer and spec.intent and spec.order_type and spec.unit) then
        if STRICT then
            error("Order.Issue: missing required field (hero/layer/intent/order_type/unit)", 2)
        else
            Log.Write("[order] missing required field, dropping")
            return false
        end
    end

    if spec.layer ~= "agg" and spec.layer ~= "def" then
        if STRICT then
            error("Order.Issue: layer must be 'agg' or 'def', got '" .. tostring(spec.layer) .. "'", 2)
        else
            Log.Write("[order] bad layer: " .. tostring(spec.layer))
            return false
        end
    end

    -- 2. Player presence
    local player = Players.GetLocal()
    if not player then return false end

    -- 3. Issuer-unit must be alive and not dormant.
    local unit = spec.unit
    if not Entity.IsAlive(unit) or Entity.IsDormant(unit) then
        return false
    end

    -- 4. Build & dedupe identifier.
    local id = Order.Identifier(spec.hero, spec.layer, spec.intent)
    local t = now()
    local existing = pending[id]
    if existing and existing.expires > t then
        return false
    end

    -- 5. Target / position / ability validation per order type.
    local order_type = spec.order_type
    local target     = spec.target
    local position   = spec.position
    local ability    = spec.ability

    if NEEDS_TARGET[order_type] then
        if not target or not Entity.IsAlive(target) then
            return false
        end
    end

    if NEEDS_POSITION[order_type] and not position then
        return false
    end

    if NEEDS_ABILITY[order_type] then
        if not ability then return false end
        -- v6.14.1 C5: Ability.IsReady returns true for UNLEARNED abilities
        -- (no CD gate). Without the level check, an unlearned ability's order
        -- silently no-ops at engine level but the pending registry still
        -- records it, blocking re-issue with the same identifier for 2.5s.
        -- Same gotcha that bit Sniper v6.2.
        if Ability.GetLevel(ability) <= 0 then return false end
        if not Ability.IsReady(ability) then return false end
    end

    -- 6. Strip spurious target on order types that don't take one.
    if STRIPS_TARGET[order_type] and target ~= nil then
        if STRICT then
            Log.Write("[order] spurious target for order_type " .. tostring(order_type) .. " - stripping")
        end
        target = nil
    end

    -- 7. Resolve flags. force_minimap defaults true. execute_fast forced true
    --    for defensive layer; otherwise honors spec (default false). callback
    --    is always true so OnPrepareUnitOrders sees us.
    local queue         = spec.queue == true
    local show_effects  = spec.show_effects == true
    local callback      = true
    local execute_fast  = spec.execute_fast == true
    if spec.layer == "def" then execute_fast = true end
    local force_minimap = spec.force_minimap
    if force_minimap == nil then force_minimap = true end

    -- 8. Dispatch.
    Player.PrepareUnitOrders(
        player,
        order_type,
        target,
        position,
        ability,
        Enum.PlayerOrderIssuer.DOTA_ORDER_ISSUER_PASSED_UNIT_ONLY,
        unit,
        queue,
        show_effects,
        callback,
        execute_fast,
        id,
        force_minimap
    )

    pending[id] = {
        hero    = spec.hero,
        layer   = spec.layer,
        intent  = spec.intent,
        expires = t + PENDING_TTL,
    }
    return true
end

----------------------------------------------------------------------------
-- callbacks (wire from your script's returned table)
----------------------------------------------------------------------------

---OnUpdateEx - garbage-collects expired entries from the pending registry.
---Idempotent; multiple calls per frame are deduped to one GC pass.
function Order.OnUpdateEx_handler()
    local f = frame()
    if gc_frame[f] then return end
    gc_frame[f] = true
    -- keep the dedup table small: drop everything but current frame
    for k in pairs(gc_frame) do
        if k ~= f then gc_frame[k] = nil end
    end

    local t = now()
    for id, p in pairs(pending) do
        if p.expires <= t then pending[id] = nil end
    end
end

---OnPrepareUnitOrders - passthrough. Reserved for future arbitration
---(e.g., yielding to baseline orders on shared cooldowns). v1 returns true
---unconditionally so the order proceeds; the dispatch record is already in
---the pending registry from Order.Issue.
---@param _data table
---@return boolean
function Order.OnPrepareUnitOrders_handler(_data)
    return true
end

---Chain Order's handlers into a callbacks table the script will return.
---Handles the case where the caller has already set its own handlers - we
---call the prior handler first, then ours.
---@param callbacks table
function Order.Wire(callbacks)
    local prev_upd = callbacks.OnUpdateEx
    callbacks.OnUpdateEx = function()
        if prev_upd then prev_upd() end
        Order.OnUpdateEx_handler()
    end

    local prev_pre = callbacks.OnPrepareUnitOrders
    callbacks.OnPrepareUnitOrders = function(data)
        local ok = true
        if prev_pre then
            local r = prev_pre(data)
            if r == false then ok = false end
        end
        if Order.OnPrepareUnitOrders_handler(data) == false then ok = false end
        return ok
    end
end

----------------------------------------------------------------------------
-- init
----------------------------------------------------------------------------

local inited = false

---Idempotent one-time setup. Currently a no-op (state is module-level).
---Kept for symmetry with other libs and to give heroes a single Init call.
function Order.Init()
    if inited then return end
    inited = true
end

return Order
