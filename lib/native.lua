---@meta
---lib/native.lua - control the UCZone framework's native auto-combat subsystems.
---
---The built-in per-hero baseline runs ALONGSIDE a brain script and issues its own
---orders (Hit & Run -> MOVE flood from 3_hit_n_run.lua; Orb Walker -> ATTACK flood
---via !_api_extend.lua). Those orders cancel a brain's multi-step combo casts.
---OnPrepareUnitOrders cannot veto them (it only sees PLAYER orders; the native
---modules issue with triggerCallBack=false), so the only lever is the framework's
---own menu switches. This module pauses/restores them for the combo's duration.
---
---Hero-agnostic: the hero's MENU name (e.g. "Lina", "Sniper" - capitalized, as it
---appears under Heroes > Hero List) is passed in. Switches live at
---  Heroes > Hero List > <name> > Extra Settings > Hit & Run > {Override, Kiting, Enabled}
---  Heroes > Hero List > <name> > Extra Settings > Orb Walker > {Override, Enabled}
---A module's real off-switch is its `Enabled` widget (Kiting only tunes behavior);
---`Override=true` makes the per-hero value win over the global default. Some heroes
---lack some widgets (e.g. Orb Walker often has no Enabled) - those resolve to nil
---and are skipped safely. State (handles / saved values / paused flag) is owned
---here, keyed by hero name, so callers just toggle.
---
---All Menu access is pcall-guarded so a missing/renamed node never errors.

local Native = {}

local cache = {}   -- name -> { resolved, hr_override, hr_kiting, hr_enabled, ow_override, ow_enabled }
local saved = {}   -- name -> prior widget values captured at pause
local paused = {}  -- name -> boolean

local function find(name, group, widget)
    local ok, h = pcall(Menu.Find, "Heroes", "Hero List", name, "Extra Settings", group, widget)
    return (ok and h) or nil
end
local function wget(w)
    if not w then return nil end
    local ok, v = pcall(function() return w:Get() end)
    -- v0.5.14 E5 (BL-B1): explicit conditional, NOT `ok and v or nil`. The
    -- ternary idiom collapses a legitimate `false` read into `nil`, which then
    -- fails RestoreHitRun's `s.<field> ~= nil` guard and leaves the widget
    -- stuck at the paused value (Override=true / Enabled=false / Kiting=false)
    -- past combo end. Round-trip `false` faithfully so the saved-snapshot ->
    -- restore path is lossless for boolean widgets.
    if not ok then return nil end
    return v
end
local function wset(w, v)
    if w then pcall(function() w:Set(v) end) end
end

local function resolve(name)
    local c = cache[name]
    if c and c.resolved then return c end
    c = c or {}
    cache[name] = c
    c.hr_override = find(name, "Hit & Run",  "Override")
    c.hr_kiting   = find(name, "Hit & Run",  "Kiting")
    c.hr_enabled  = find(name, "Hit & Run",  "Enabled")
    c.ow_override = find(name, "Orb Walker", "Override")
    c.ow_enabled  = find(name, "Orb Walker", "Enabled")
    -- v0.5.8 (F6): lock the cache only when an HR widget resolves. HR is mandatory
    -- for this lib to do anything useful; OW is optional and may legitimately stay
    -- nil forever (e.g. Lina has no OW Enabled). Locking on any-of-four risked a
    -- latent forward-portability bug: a hero whose OW menu is built one frame later
    -- than HR would lock with ow_*=nil and never re-resolve OW. No change for Lina
    -- (HR resolves on first call; OW remains nil either way).
    c.resolved = (c.hr_enabled ~= nil) or (c.hr_override ~= nil)
    return c
end

---Resolve (once, cached) and report which native switches were found, for the
---caller to log. Booleans, not handles.
---@param name string  hero menu name (e.g. "Lina")
---@return table  { hr_en, hr_ov, ow_en, ow_ov : boolean }
-- v0.5.8 E5: also report hr_kiting presence so callers can log whether the
-- Kiting widget exists in the framework HR resolve set on this hero build.
function Native.Resolve(name)
    local c = resolve(name)
    return {
        hr_en = c.hr_enabled ~= nil, hr_ov = c.hr_override ~= nil,
        hr_ki = c.hr_kiting  ~= nil,
        ow_en = c.ow_enabled ~= nil, ow_ov = c.ow_override ~= nil,
    }
end

---Pause (disable) the native Hit & Run + Orb Walker for `name`, saving prior
---values for a later restore. Idempotent. Returns true only on the first
---not-paused -> paused transition (so the caller can log once).
---v0.5.31 task-10 probe: also return the saved snapshot as a second value so
---the caller can log what we captured. Lets us diagnose whether the snapshot
---was poisoned (wget returned nil or wrong values) vs whether something writes
---hr_kiting=true post-restore.
---
---v0.5.32 user-config guard: if user's hr_override is already false (per-hero
---override OFF -> framework uses global HR config), SKIP the entire pause
---cycle. The brain's per-hero wsets to hr_enabled / hr_kiting wouldn't take
---effect anyway (override=false means global values are used), and forcing
---hr_override=true for the combo window triggers a framework-side state latch
---that breaks user's mouse-follow even after we RestoreHitRun puts override
---back to false. User-confirmed via isolation test 2026-06-01: with
---pause_hitrun toggle OFF, Lina moves; with toggle ON and per-hero
---override=false, Lina stuck. Skip preserves combo behaviour (user's global
---HR config is whatever it is; if it interferes with combos that's a separate
---fix). Returns false (newly_paused=false) + nil probe so callers see a noop;
---second-return type is a STRING reason for the skip rather than a probe
---table so callers can log the reason if they want.
---@param name string
---@return boolean newly_paused
---@return table?|string  probe_or_skip_reason  table on real pause, "override_off" string on skip
function Native.PauseHitRun(name)
    if paused[name] then return false end
    local c = resolve(name)
    -- v0.5.32: probe override BEFORE we touch anything. If user wants global
    -- HR config, our pause cycle does net harm. Skip and return a reason.
    local user_ov = wget(c.hr_override)
    if user_ov == false then
        return false, "override_off"
    end
    local s = {
        hr_override = user_ov, hr_kiting = wget(c.hr_kiting), hr_enabled = wget(c.hr_enabled),
        ow_override = wget(c.ow_override), ow_enabled = wget(c.ow_enabled),
    }
    saved[name] = s
    -- Override=true so the per-hero value wins over the global default; Enabled
    -- =false is the real off-switch; Kiting=false belt-and-suspenders.
    wset(c.hr_override, true)
    wset(c.hr_enabled, false)
    wset(c.hr_kiting, false)
    wset(c.ow_override, true)
    wset(c.ow_enabled, false)
    paused[name] = true
    -- v0.5.31 probe return: caller logs the saved snapshot via native_hitrun_save
    -- tlog so the next test session surfaces whether the saved.hr_kiting captured
    -- at this moment is true (user's actual config), false (correct - mouse-follow
    -- mode), or nil (widget didn't resolve, restore's nil-guard will silently
    -- skip the write).
    return true, {
        saved_hr_override = s.hr_override,
        saved_hr_enabled  = s.hr_enabled,
        saved_hr_kiting   = s.hr_kiting,
        saved_ow_override = s.ow_override,
        saved_ow_enabled  = s.ow_enabled,
    }
end

---Restore the native subsystems for `name` to their pre-pause values. Idempotent.
---Returns true only on the first paused -> not-paused transition.
---v0.5.8 E2 (covers lib_native_F5, history_F2, history_F8): on the newly-restored
---edge, also return a probe table of live widget reads taken IMMEDIATELY after our
---Set(...) calls, so callers can detect if the framework writes its own values
---back between cycles (poisoning the saved baseline). Signature widens to
---`return true, probe` on the transition; idempotent calls still return false.
---@param name string
---@return boolean newly_restored
---@return table?  probe  { hr_en_pre, hr_en_post, hr_ov_post, ow_ov_post }
function Native.RestoreHitRun(name)
    if not paused[name] then return false end
    local c = resolve(name)
    local s = saved[name] or {}
    if s.hr_override ~= nil then wset(c.hr_override, s.hr_override) end
    if s.hr_enabled  ~= nil then wset(c.hr_enabled,  s.hr_enabled)  end
    if s.hr_kiting   ~= nil then wset(c.hr_kiting,   s.hr_kiting)   end
    if s.ow_override ~= nil then wset(c.ow_override, s.ow_override) end
    if s.ow_enabled  ~= nil then wset(c.ow_enabled,  s.ow_enabled)  end
    paused[name] = false
    -- v0.5.8 E2: live readback AFTER writes so the caller can prove/refute
    -- that the framework HR module rewrites Enabled=false back between cycles.
    -- v0.5.31 task-10: extend with hr_ov_pre / hr_ki_pre / hr_ki_post so a
    -- single restore probe carries the full pre/post triplet for the three
    -- HR widgets. This is what disambiguates H1/H2/H3 from the workflow
    -- synthesis (saved poisoned vs nil-skip vs framework rewrite).
    local probe = {
        hr_en_pre  = s.hr_enabled,
        hr_en_post = wget(c.hr_enabled),
        hr_ov_pre  = s.hr_override,
        hr_ov_post = wget(c.hr_override),
        hr_ki_pre  = s.hr_kiting,
        hr_ki_post = wget(c.hr_kiting),
        ow_ov_post = wget(c.ow_override),
    }
    return true, probe
end

---@param name string
---@return boolean
function Native.IsPaused(name)
    return paused[name] == true
end

---v0.5.8 E4: belt-and-suspenders watchdog helper. The original v0.5.8 bug was
---"auto-attacks never resume after RestoreHitRun" -- a framework-side latch on
---hr_enabled that survives the saved-value restore. The original fix here
---unconditionally re-wrote hr_override=true / hr_enabled=true / hr_kiting=true,
---which fixed auto-attacks but ALSO clobbered the user's hr_kiting=false config
---(mouse-follow mode, observed 2026-06-01 demo: Lina would not move on mouse
---direction with brain on; without brain, fine). v0.5.30: shrink to ONLY
---re-assert hr_enabled. hr_override and hr_kiting stay at whatever RestoreHitRun
---put them at (the user's pre-pause saved values).
---
---v0.5.31 task-10 INV-D-01 guard: even shrunk to hr_enabled, the watchdog was
---STILL unconditionally writing true. If the user's mouse-follow config has
---hr_enabled=false (HR feature globally OFF so the engine handles raw
---mouse-direction movement), the brain force-flips it back on after every combo
----- identical-shape bug to the v0.5.30-fixed hr_kiting clobber, just on a
---different widget. Now: only write true if the user's saved value at
---pause-time WAS true. If saved.hr_enabled was false, the user wanted HR off
---and the watchdog respects that. If saved is nil (no pause yet, or the widget
---was nil-resolved at pause-time), skip entirely -- no signal to honor.
---Preserves the original v0.5.8 fix for users with hr_enabled=true normally;
---no-ops for users running hr_enabled=false (mouse-follow with HR off).
---WITHOUT touching paused[]/saved[] state. The caller invokes this ~500ms
---after a paused->restored edge. Idempotent at the widget level.
---@param name string
function Native.ReassertEnabled(name)
    local c = resolve(name)
    local s = saved[name]
    if s and s.hr_enabled == true then
        wset(c.hr_enabled, true)
    end
end

return Native
