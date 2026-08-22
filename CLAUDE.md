# WillowdaleMUD UI (WillowdaleMudletUI) for Mudlet

A Mudlet package that recreates the Willowdale web client's widgets on top of
MDW (Mudlet Dockable Widgets). Lua 5.1 only (Mudlet's runtime) - no goto, no
integer division, no 5.2+ stdlib.

## The three repos

- `../mdw` - the MDW framework this package consumes. Never put game-specific
  code there; if MDW lacks an API this package needs, add it to MDW as a
  general capability (e.g. `addToStack` migration was added for this package).
- The game server's own checkout, alongside these two. Not public, so never
  cite it by name or path in anything that ships. Two things in it are
  authoritative:
  - The Mudlet widget GMCP guide - THE data contract. Read it before touching
    any GMCP handling. Every field name, cadence, and edge case in this
    package comes from it; renderer comments cite its section numbers. Never
    invent or rename a GMCP field - they are the exact snake_case wire names
    from the Go structs.
  - The web client's `gmcp-ui.js` and `dockview-widgets.js` - the reference
    implementation. When a behavior question comes up (channel routing,
    combat status text, auto-target, unread logic), match what the web client
    does.

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

MDW >= `mdwui.minMdwVersion` (0.6.8) is a HARD requirement, gated ONCE at the
top of `mdwui.buildUI()` via `mdwui.mdwSatisfied()` - before any side effect,
so a refused build leaves the session untouched - instead of guarding every
MDW 0.4 call site. Bump the constant when adopting a newer MDW API - and with
it `mdwui.mdwUrl`, since the package installs MDW itself when it is missing or
too old (see "Bootstrapping MDW"). The `ui`
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
console - the surface is typed, so its answers belong in the stream the
player typed into, not in a widget that may be hidden or closed - and it
speaks
`cecho`/`cechoLink` with Mudlet's NAMED colours (its local `P` table).
`MDWUI_Update.lua` is the only other module that does, for the same reason and
with its own `P`; the widget renderers keep `decho` and the RGB palette
transcribed from the web CSS. Angle-bracket placeholders (`ui show <widget>`) are safe in that output:
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
muddle                                      # builds build/WillowdaleMudletUI.mpackage
```

`src/resources/` ships verbatim into the package ROOT, and the mfile `icon`
names a file in there which muddler ALSO copies to `.mudlet/Icon/` - so the
icon is stored twice and its bytes count twice against every self-update
download. Keep it small for that reason. The bundled font is available, not
applied: MDW's font settings are sizes only, so nothing selects a family, and
shipping the TTF is what lets a player pick the web client's face by name.

The smoke suite runs the real MDW + this package against `tests/stub_mudlet.lua`
(a headless Mudlet API) and fixture GMCP payloads. Add a check for every
behavior change; if new code uses a Mudlet API the stub lacks, extend the stub.
The harness cannot validate Qt rendering or real GMCP framing - flag when a
change needs a live Mudlet test against the game.

## Releases and self-update

PUBLISHING THE GITHUB RELEASE IS DEPLOYING - pushing main is not. The game
server subscribes to this repo's *release* events; when one is published it
downloads that release's two assets into its own `static/resources/ui/`, which
is the ONLY place an installed client ever looks. There is no deploy-on-push,
by design: a release is a deliberate act with a deliberate payload, so an
ordinary commit - or a mistaken one - can never reach a player.

Consequently NOTHING GENERATED IS COMMITTED. `build/` and `releases/` are both
gitignored; `tools/release.sh` builds the package, generates the feed into a
temp file, and uploads both as release assets. A generated file in git is a
generated file someone can ship by mistake, which is the exact failure this
design exists to remove.

The tag format `vX.Y.Z` and the two ASSET BASENAMES are therefore a contract
with the server's release handler, which looks assets up by name:

- `WillowdaleMudletUI.mpackage` - the package itself;
- `releases.json` - the update feed.

A release published with only one of them deploys a package no feed announces,
or a feed pointing at a package that never arrived. Rename either, or the tag
scheme, and a published release deploys nothing at all.

Changelog entries land under `## Unreleased` in `CHANGELOG.md` in the same
commit as the change, player-facing only - so the notes for a release exist
before the release does. `tools/release.sh X.Y.Z` is the ONLY way a release is
cut: it bumps `mfile` and `mdwui.version` together (the smoke suite asserts
they match), promotes `## Unreleased` to `## X.Y.Z - <date>`, generates the
feed from that changelog, runs the three verification steps, commits
"Release X.Y.Z" (SOURCE ONLY), tags `vX.Y.Z`, pushes main, and publishes the
release with both assets attached - which is the deploy. An empty
`## Unreleased` is a hard stop, as is a feed whose newest entry is not the
version being cut, and any failure from the bump onwards restores the tree.
Never bump a version, tag, or publish by hand.

The feed is GENERATED at release time, never hand-edited and never committed -
`tools/changelog_to_releases.lua` turns `CHANGELOG.md` into it, so the notes a
player is shown and the notes in the repo cannot drift apart. Its shape is the
game server's, shared with the mapper package: a JSON array, newest first, of
`{ version, released, changes[] }`. The heading pattern's digit class excludes
`## Unreleased` in the generator exactly as it did in the package's old
parser - work that is in no release must never be offered as one.

The updater in `MDWUI_Update.lua` therefore reads two fixed URLs
(`mdwui.releasesUrl`, `mdwui.packageUrl` in `MDWUI_Config.lua`) and constructs
neither:

- it fetches `releases.json`, decodes it with `json_to_value` (the same
  decoder the Journal reads book documents with - the package has one JSON
  parser, not two), and takes the entries newest-first;
- it compares against `mdwui.version` with the existing `mdwui.versionAtLeast`
  - no second comparison implementation;
- it downloads the package from ONE fixed path. The version is carried through
  for the message and the filename, but it does not select what arrives, so a
  feed and a package can never disagree about where to look.

A feed entry is remote text from a server having a possible bad day: a
non-array, a missing version, a wrong-typed field are each skipped rather than
thrown, because an error inside a download handler costs the player the update
path entirely.

Move the server paths and every installed client silently loses its update
path - they have no other way to find a release.

The server side of this lives in the game's own repo (its release-event
handler); `RELEASE_DEPLOY_HANDOFF.md`, gitignored like the other cross-repo
notes, is the spec it was built from.

The updater's own invariants, none of them obvious from the code:
`mdwui.state`'s `update*` keys are read across the swap - the watchdog armed by
the OLD script run is what the NEW one silences by setting `updateInstalled`,
so those keys must stay on `mdwui.state` (seeded with `or`) rather than in a
module local. Both of the swap's timers are created AFTER `uninstallPackage`,
because our own cleanup runs inside that call and `killAllTimers` would
otherwise take the pending install with it. The in-flight guard is a TIMESTAMP
with a 60s staleness window, never a boolean: Mudlet does not raise
`sysDownloadDone` or `sysDownloadError` in every failure mode, and a boolean
would wedge the checker for the session. Feed text is REMOTE text and
goes through `plain()` like anything from the game.

Update checking has deliberately NO periodic timer: once per session from
`buildUI`, plus on demand via `ui update`. A player who wants a poll can type
one. The install is reachable BOTH ways - the offer's `[Install update now]`
link and `ui update install` - because the link is a mouse affordance and this
surface is a keyboard one. Installing NEVER happens on its own: the check prints the new
version and its notes with a link, and only that link installs. The swap
itself is defensive because a failed one leaves a player with no UI at all -
verify the download BEFORE touching the installed package (zip magic `PK`,
plausible size), then uninstall and install; defer `installPackage` by one tick
so Mudlet's installer is not re-entered from inside its own event; and arm a
watchdog that prints a manual-install link if the swap has not completed by the
time it fires.

## Bootstrapping MDW

Mudlet resolves NO package dependencies - the mfile's `dependencies` field is
read by the package exporter and by nothing else - so a player who installs
only this package would meet `buildUI`'s version gate and one line of
explanation instead of a UI. `mdwui.ensureMdw()` (bottom of
`MDWUI_Update.lua`, reusing the updater's `verified()`, its download-path
dispatch and its in-flight guard) therefore installs MDW itself.

The pin lives in TWO constants in `MDWUI_Config.lua` and they move TOGETHER:
`mdwui.minMdwVersion` (what the code needs) and `mdwui.mdwUrl` (where to get
it). Adopting a newer MDW API means raising both in one edit; never pin
"latest". MDW never updates itself, by design - a framework swap is only safe
when the thing built on it says so - so this package is the only thing that
ever moves its framework, and it moves it in ONE direction: a player running
an MDW newer than the minimum is left alone.

The rules that keep a bootstrap from costing a player the UI they already
have:

- Download, verify, THEN uninstall. `uninstallPackage("MDW")` takes the whole
  UI down with it, so a GitHub error page must never get that far - same
  order, same `verified()`, as the self-update.
- Uninstall only when `table.contains(getPackages(), "MDW")`: absent is the
  ordinary case, and Mudlet just refuses to install over a name it holds.
- An MDW installed as a MODULE is refused outright, with the manual URL:
  `getPackages()` does not list modules, so the check above would read
  "absent" and leave a package named MDW beside the module - two copies of
  the `mdw` singleton over one UI, which is the very thing keeping MDW and
  this package separate packages is meant to prevent. A module is a
  deliberate choice by the player and stays theirs to update.
- The install `tempTimer` is created AFTER `uninstallPackage`, because MDW's
  teardown runs our own `mdw.onTeardown` hook and `killAllTimers` would take
  the pending install with it. Same rule as the package swap, one step more
  lethal.
- One attempt per session (`mdwui.state.mdwFetchedThisSession`), and every
  failure path prints `mdwui.mdwUrl` so a player behind a proxy can finish by
  hand.
- Nothing "activates" the UI afterwards: MDW's install runs setup -> onReady
  -> buildUI and this package only ever seeded `mdw.onReady`, so the UI builds
  itself. Do not add an activation call.

Triggers are events, NEVER script load: our own `sysInstallPackage` (deferred
a tick - Mudlet's installer must not be re-entered from inside its own event)
and `sysLoadEvent`. Calling `ensureMdw` at load time would read an
`mdw.version` that arrives a moment later and throw away the load-order
freedom the MDW contract guarantees. `buildUI`'s gate stays exactly where it
is: it is what protects the session when the bootstrap cannot run, and its
message keeps the manual URL for that case.

## Style

Comments explain WHY, not what - constraints the code cannot show, usually a
guide section number or a web-client behavior being matched. Don't extract a
function for something just as clear written inline.
