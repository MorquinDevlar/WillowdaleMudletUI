# Willowdale MUD UI for Mudlet

The Willowdale MUD interface for [Mudlet](https://www.mudlet.org/), built on
[MDW (Mudlet Dockable Widgets)](https://github.com/MorquinDevlar/mdw). It
recreates the Willowdale web client's widget layout, driven live by the game's
GMCP feed:

```
Left dock                      Center            Right dock
  [Affects | Keyring]          Main display        [Map]  (native mapper)
  [Equipment | Inventory |                          [Comm | Quests | Journal]
   Forage]
  [Character | Combat | Group]
```

- **Character** - identity, attributes, wealth, XP, and the game clock/calendar
- **Combat** - HP/AE/Balance/Enemy gauges, status, and a clickable enemy list
  (click to target; auto-retargets when your target dies)
- **Affects** - buffs and states with locally driven countdowns
- **Equipment / Inventory / Keyring / Forage** - clickable item lists (look,
  use with each item's own verb, drop, remove)
- **Quests / Journal** - active quests with track toggles and lazy per-quest
  detail; completed quests and rumors
- **Communications** - channel tabs (All / Room / Global / Tells / Group) with
  server-side history on load
- **Prompt bar** - your real in-game prompt, delivered over GMCP as ANSI
- **Map** - Mudlet's native mapper, fed by the server's Client.Map protocol

## Install

Install both `MDW.mpackage` and `WillowdaleMUDUI.mpackage` through Mudlet's
package manager. Install order does not matter - this package follows MDW's
integration contract (it only seeds tables at load time and MDW invokes it
whenever its UI builds). Widget arrangement is yours after the first run: MDW
persists your layout, and the default grouping never overrides it.

## Design notes

- The GMCP data contract is documented in the WillowdaleMUD repo:
  `documentation/Mudlet_Widget_GMCP_Guide.md`. Field names, cadence, and the
  edge cases handled here all come from that guide.
- Panels render as pure functions of Mudlet's `gmcp` table: every update
  clears and repaints from the latest payloads, and widget resize re-renders
  through the same functions (which is what keeps clickable links alive -
  see `mdwui.bindRenderer`).
- Widget actions send real game commands, mirroring the web client's rule
  that GMCP only carries data a command could also reveal.

## Building from source

Requires [Muddler](https://github.com/demonnic/muddler):

```bash
muddle
```

The built package lands in `./build/WillowdaleMUDUI.mpackage`.

## Tests

`tests/smoke.lua` runs the package (together with a sibling `../mdw` checkout)
against a stubbed Mudlet API and fixture GMCP payloads:

```bash
lua5.1 tests/smoke.lua        # from the repo root
MDW_SRC=/path/to/mdw/src/scripts/ lua5.1 tests/smoke.lua
```

## License

MIT License.
