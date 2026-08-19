# Willowdale MUD UI (WillowdaleMUDUI) for Mudlet

A Mudlet package that recreates the Willowdale web client's widgets on top of
MDW (Mudlet Dockable Widgets). Lua 5.1 only (Mudlet's runtime) - no goto, no
integer division, no 5.2+ stdlib.

## The three repos

- `../mdw` - the MDW framework this package consumes. Never put game-specific
  code there; if MDW lacks an API this package needs, add it to MDW as a
  general capability (e.g. `addToStack` migration was added for this package).
- `../WillowdaleMUD` - the game server. Two things in it are authoritative:
  - `documentation/Mudlet_Widget_GMCP_Guide.md` - THE data contract. Read it
    before touching any GMCP handling. Every field name, cadence, and edge
    case in this package comes from it; renderer comments cite its section
    numbers. Never invent or rename a GMCP field - they are the exact
    snake_case wire names from the Go structs.
  - `_datafiles/html/public/static/webclient/js/gmcp-ui.js` and
    `dockview-widgets.js` - the reference implementation. When a behavior
    question comes up (channel routing, combat status text, auto-target,
    unread logic), match what the web client does.

## The MDW integration contract (why load order never matters)

Scripts must NEVER call `mdw.*` functions at load time - only seed tables:
`mdw = mdw or {}`, `mdw.onReady[mdwui.packageName] = ...`, `mdw.gameConfig`,
`mdw.loadExamples`. MDW runs the registration on every UI build (install,
profile load, MDW package updates), and `MDWUI_Init.lua` ends with the
late-join call for when this package installs while MDW is already up.
`mdwui.packageName` must always equal the mfile's "package" value - Mudlet
reports that name in sysUninstallPackage, and cleanup only fires on a match.
Consequence: `mdwui.buildUI()` must stay idempotent - `Widget:new` returns
existing widgets, and re-running must not duplicate anything.

## Rendering architecture (the rules that look like accidents)

- Panels are PURE FUNCTIONS of Mudlet's `gmcp` table: clear the console,
  repaint from the latest payloads. Safe to call anytime, with any subset of
  data present. Keep them that way - no incremental DOM-style patching.
- Panel renderers write DIRECTLY to `widget.content` and are bound as the
  widget's `reflow` via `mdwui.bindRenderer`. Never route panel output through
  `widget:echo`/`:decho`: MDW's echo buffer cannot replay clickable links, so
  buffered content would lose its links on every resize. The renderer-as-reflow
  binding is what keeps links alive.
- The Comm widget is the one exception: chat is a stream, so it goes through
  MDW's buffered `dechoTo` pipeline (which also provides the "All" mirror).
- Widget actions send REAL game commands (`send("target #5")`), never GMCP -
  the web client's rule: GMCP only carries data a command could also reveal.
- Use the `ansi` field of payloads + `ansi2decho()`; never the `html` field.
- Default grouping runs ONLY on a first run: `defaultGroup` skips any widget
  with `_pendingStackId` because a saved MDW layout owns placement. Widgets
  "not regrouping" after the player rearranged them is correct behavior.

## Lifecycle discipline

Every event handler, timer, and widget goes through `mdwui.registerHandler` /
`mdwui.addTimer` / `mdwui.state.widgets`, so `mdwui.onUninstall` can remove
every trace while leaving MDW itself running. Anything registered another way
will leak across uninstalls.

## Verification (all three before calling work done)

```bash
lua5.1 tests/smoke.lua                      # from repo root; needs ../mdw
~/.luarocks/bin/luacheck src/ tests/        # must be 0 warnings
muddle                                      # builds build/MDW_UI.mpackage
```

The smoke suite runs the real MDW + this package against `tests/stub_mudlet.lua`
(a headless Mudlet API) and fixture GMCP payloads. Add a check for every
behavior change; if new code uses a Mudlet API the stub lacks, extend the stub.
The harness cannot validate Qt rendering or real GMCP framing - flag when a
change needs a live Mudlet test against the game.

## Style

Comments explain WHY, not what - constraints the code cannot show, usually a
guide section number or a web-client behavior being matched. Don't extract a
function for something just as clear written inline.
