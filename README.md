# WillowdaleMUD UI for Mudlet

The WillowdaleMUD interface for [Mudlet](https://www.mudlet.org/), built on
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
- **Quests** - the quests you are tracking, plus anything turn-in-able in this
  zone, with track toggles and lazy per-quest detail
- **Journal** - the whole `journal` command: books, documents, rumors,
  observations and your own notes, paginated and pulled on demand, plus a
  Quests category holding the full filterable quest list
- **Communications** - channel tabs (All / Room / Global / Tells / Group) with
  server-side history on load
- **Prompt bar** - your real in-game prompt, delivered over GMCP as ANSI
- **Map** - Mudlet's native mapper, fed by the server's Client.Map protocol
- **Numpad walking** - the same keypad shortcuts as the web client: 1-9 walk
  (5 looks), `-` goes up and `+` goes down, whether or not the command line
  already holds text (PC keypads: NumLock on)
- **The `ui` command** - the whole interface from the keyboard: show, hide,
  move, resize and read any widget

## Keyboard control: the `ui` command

Everything the mouse can do to this UI, `ui` can do by name. Type `ui` for an
overview: the versions in play, the current layout, then every command in a
config-style table - command, current value, options - with the on/off toggles
grouped first; each line is a link that runs its command (a toggle's line flips
it). Names match on a unique prefix and widgets answer to their spoken
shorthands, so `ui sh que` is `ui show quests`. Everything `ui` says goes to the
main window.

```
ui                          the status screen: versions, layout, every command
                            with its value and options
ui help <command>           what one command does
ui list                     docks, rows, groups, tabs, heights, fonts, theme
                            (also: ui containers)

ui show|hide|toggle|focus <widget>    reveal, close, flip, or front a widget
ui float <widget>                     its own floating group, centred
ui dock <widget> left|right [top|bottom]
ui group <widget> <other>             add it to another widget's group as a tab
ui ungroup <widget>                   pull it out into its own group

ui sidebar left|right [on|off]        (or just: ui left, ui right)
ui prompt bar [on|off]                the prompt bar itself
ui numpad [on|off]                    numpad walking
ui width left|right <px|+n|-n>        dock width
ui height <widget> <px|+n|-n>         the height of the row it sits in

ui scroll [<widget>] up|down|top|bottom [lines]     default 10 lines
ui read <widget>                      print its text to the main window
ui font [main|menu|header|prompt|<widget>] [<size>|+n|-n]
ui theme [<name>|next|prev]           the UI theme (also: ui color)

ui comm [<tab>|clear]                 channel tabs
ui prompt [<key> [on|off]]            vitals worth hp ae balance enemy
ui combat [<key> [on|off]]            hp ae balance enemy info
ui quest [<id>|back|expand <id>|collapse <id>]
ui journal [<category>|back|page <n>|open <n>|close <n>|book <n> <page>]
ui journal zone|status|category <value>             quest-list filters

ui refresh [<what>]                   re-request all GMCP data, or one part:
                                      character vitals inventory equipment
                                      keyring forage affects quests journal
                                      comm room group map
ui debug [gmcp [<path>]]              UI diagnostics, or dump the GMCP data
                                      (ui debug gmcp Char.Vitals)
ui reset [all] confirm                back to the default layout
ui rebuild                            rebuild the UI in place
ui update [install]                   check GitHub for a newer UI, or take
                                      the offer without the mouse
```

Revealing a widget by keyboard puts it **back where it was** - its old group,
else the end of its old dock - rather than floating it in the centre, since
there is no drag to put it back with.

`ui scroll` and `ui read` need Mudlet 4.17 or newer (per-window scrolling).
`ui reset` keeps your prompt-bar and Combat toggles and numpad choice;
`ui reset all confirm` wipes those too.

When a widget looks stale, `ui refresh <part>` asks the server for that data
again; `ui debug` (and `ui debug gmcp <path>`) shows what the client actually
received, which is what a bug report needs.

## Numpad walking

On by default, matching the web client. The bindings are ordinary Mudlet keys
- in the Keys editor under WillowdaleMudletUI > Numpad Walking - so you can see
and edit them. They claim the keypad: while on you cannot type digits with it.
`ui numpad off` disables that folder and gives the keypad back
(`lua mdwui.setNumpadWalking(false)` does the same); the choice persists with
your MDW layout. PC keypads need NumLock on; the main keyboard's arrow keys
are untouched.

## Install

Install both `MDW.mpackage` and `WillowdaleMudletUI.mpackage` through Mudlet's
package manager. Install order does not matter - this package follows MDW's
integration contract (it only seeds tables at load time and MDW invokes it
whenever its UI builds). Widget arrangement is yours after the first run: MDW
persists your layout, and the default grouping never overrides it.

**MDW 0.5.0 or newer is required, and this package installs it for you.**
Install the UI on its own and it fetches the MDW release it was built against,
then builds the interface once MDW lands - Mudlet resolves no package
dependencies itself. If that download cannot be made (no network, GitHub
blocked) it declines to build and prints a single `needs MDW 0.5.0 or newer`
line on the main console with the URL, rather than half a UI. MDW is never
downgraded: a newer one than the minimum is left alone.

## Design notes

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

The built package lands in `./build/WillowdaleMudletUI.mpackage`.

## Tests

`tests/smoke.lua` runs the package (together with a sibling `../mdw` checkout)
against a stubbed Mudlet API and fixture GMCP payloads:

```bash
lua5.1 tests/smoke.lua        # from the repo root
MDW_SRC=/path/to/mdw/src/scripts/ lua5.1 tests/smoke.lua
```

## License

MIT License.
