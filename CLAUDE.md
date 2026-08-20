# Willowdale MUD UI (WillowdaleMudletUI) for Mudlet

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

MDW >= `mdwui.minMdwVersion` (0.4.0) is a HARD requirement, gated ONCE at the
top of `mdwui.buildUI()` via `mdwui.mdwSatisfied()` - before any side effect,
so a refused build leaves the session untouched - instead of guarding every
MDW 0.4 call site. Bump the constant when adopting a newer MDW API. The `ui`
command dispatcher keeps its per-capability guards regardless: the alias is
installed even when the build was refused under an old MDW.

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
will leak across uninstalls. MDW ALSO reaps our creations by ownership stamp
(everything built inside the onReady callback), but our own handler stays -
it is what covers older MDW versions and handler-order races, and it must
remove ALL our registrations: onReady, onTeardown, gamePackages, the top bar.
The `mdw.onTeardown` hook kills our timers at every MDW teardown so the
affects ticker never outlives its widget. Numpad walking is the package's own
native key folder (`src/keys`), which Mudlet installs and removes with the
package; this package binds no temp keys at all, so there is nothing
key-related to collect at teardown or uninstall.

## Keyboard command surface (`ui`)

`MDWUI_Commands.lua` holds the dispatcher `mdwui.command(line)`; `src/aliases`
holds the only shipped alias, a one-line shim into it. The alias and the smoke
suite both enter through that one function, so a check against
`mdwui.command` is a check against what the player types. It must
NEVER `send()` unknown input - the server has no `ui` command - and every MDW
0.4 capability it calls is guarded on existence (`capability("focusWidget")`),
the same style as the rest of this package. All output goes to the MAIN
console - that is where a screen reader is reading - and this module alone
speaks `cecho`/`cechoLink` with Mudlet's NAMED colours (its local `P` table);
the widget renderers keep `decho` and the RGB palette transcribed from the web
CSS. Angle-bracket placeholders (`ui show <widget>`) are safe in that output:
Mudlet prints an unrecognised tag literally, so only `<r> <b> <i> <u> <s> <o>`
and real colour names must be avoided - text from the GAME still goes through
`plain()`, since a quest title could contain either. The overview and
`ui help <verb>` come from ONE source: the `OVERVIEW` table for the screen,
the command table's own `usage`/`help` for the detail, so a new verb cannot be
listed in one and missing from the other. The overview is a config-style status
table (OVERVIEW sections of {cmd, link, opts, value getter}): command, live
value, options; the on/off section comes first and the options column
word-wraps at 80 columns. A new verb gets a row there, with a value getter when
it has a state.
Widgets resolve as `mdwui.widgetSynonyms` first, then `mdw.findWidget` (exact
name, exact title, unique prefix), and print by TITLE - group names never
reach the player. Numpad walking ships as native Mudlet keys -
`src/keys/keys.json` (the `Numpad Walking` folder) and
`src/keys/Numpad Walking/keys.json` (keypad 1-9, minus, plus: NumLock-on codes
ONLY, because macOS stamps the Keypad modifier on the arrow keys too) - and
`ui numpad` just flips that folder with `enableKey`/`disableKey`;
`mdwui.config.numpadKeyFolder` must equal the folder name, and the smoke suite
checks the JSON against the web client's `codeShortcuts`.
`mdwui.applyNumpadKeys` (called from `buildUI`) re-applies the folder's on/off
state on every build. Rule: every new widget or player-facing toggle gets a
`ui` verb and a smoke check in the same change.

## Version exposure (Willowdale package convention)

Every Willowdale package exposes `<ns>.version` as a plain string matching
its mfile "version", assigned at script-load time: `mdw.version`,
`mdwui.version`, `mapper.version` (the mapper's is build-substituted from
`__VERSION__`). Read another package's version only at runtime and guarded -
`(mapper and mapper.version) or "-"` - never at load time. The smoke suite
enforces that `mdwui.version` matches the mfile; bump them together. The top
bar (`WillowdaleTop`, MDW `createBar`) renders Char.Info name/class and the
connection timer left-aligned, and the UI, MDW and mapper versions
right-aligned - padded to the bar console's wrap width (the same
`mdw.calculateWrap` MDW applies to it) and repainted by the 1s ticker, which
is also how it catches up after resizes.

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
