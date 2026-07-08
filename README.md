# Tinker hero brain (UCZone)

An auto-farm brain for Dota 2's Tinker on the UCZone Lua scripting platform.
Current milestone is **farm-only**: it farms lanes and jungle and retreats when
threatened; it never auto-engages enemy heroes. Defense, offense, and combo
layers are planned follow-ups on the same shared `lib/`.

Current build: **Tinker.lua v0.1.249**.

## What it does

A timing-anchored decision brain built around Tinker's kit (March of the
Machines, Rearm, Keen Conveyance, Blink):

- **All-lanes farming.** Mid is the home lane while the enemy mid T1 stands;
  after it falls, all three lanes compete on risk-then-gold. Side-lane waves
  are anticipated from a per-lane wave cadence, so it dispatches to fogged
  lanes and lands as the wave arrives.
- **Jungle route planning.** A receding-horizon planner fills the slack
  between waves with camp clears (paired camps in one March footprint,
  stack-aware budgets, cost-aware fountain refills as routed stops).
- **Keen/Rearm transport.** Keen Conveyance to buildings, outposts, and (at
  level 2) allied creeps moves the hero; travel blink fires whenever it is
  safe. Landings are gated by tower range, walkability, and fog-aware risk.
- **Safety layer.** Fog-aware proximity risk with threat weighting, tower
  radius as the only hard positional veto, depth economics past the enemy T1
  line, defensive wave clears when an enemy wave crashes an allied tower, and
  proactive blink escape.
- **Bottle discipline.** Automatic bottle use in the field and chain-drinking
  at the fountain, never interrupting a Rearm channel.

Typical bot-game result on an itemless build: 450-600+ GPM with zero deaths.

## Layout

- `Tinker/Tinker.lua` - the brain (the deployable script).
- `lib/` - hero-agnostic libraries: map/camp data, lane wave scanning and
  prediction, route planning, scheduling, navigation, escape and risk math,
  plus KV-generated game data. Pure logic is engine-stubbed and unit-tested.
- `tools/run_tests.lua` - the offline test suite (713 tests, no game needed).
- `tools/parse_debuglog.lua` - the log analyzer (farm/depth audits, per-wave
  coverage, time and gold accounting). Useful when reporting issues.

## Requirements

- The UCZone Dota 2 scripting platform, with scripts loading from
  `C:\Umbrella\scripts\`.
- A game as Tinker. Bot/demo games are fine and are what the brain is
  calibrated on.

## Install

Copy the brain and the libraries into the scripts directory:

```
cp Tinker/Tinker.lua  /c/Umbrella/scripts/Tinker.lua
cp lib/*.lua          /c/Umbrella/scripts/lib/
```

Load into a game as Tinker. The menu lives under Heroes > Hero List > Tinker >
Brain: enable "Auto-farm" and leave the rest at defaults. A debug overlay and
diagnostics toggles are available in the same menu.

## Testing and reporting issues

The brain logs structured telemetry to `C:\Umbrella\debug.log`. After a game:

```
lua tools/parse_debuglog.lua C:/Umbrella/debug.log --farm-report
lua tools/parse_debuglog.lua C:/Umbrella/debug.log --time-report
lua tools/parse_debuglog.lua C:/Umbrella/debug.log --farm-audit
lua tools/parse_debuglog.lua C:/Umbrella/debug.log --depth-audit
```

The audits should read zero violations; the reports show GPM, per-wave lane
coverage, and where the time and gold went. If you hit odd behavior, an issue
with the log file (or the relevant report output) attached is the fastest way
to get it fixed.

Offline development loop:

```
lua tools/run_tests.lua          # pure-Lua suite, expect 713 passing
luac -p Tinker/Tinker.lua        # byte-compile check
```

## License

MIT (see `LICENSE`).
