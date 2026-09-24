# Lockstep (Omarchy plugin)

Every monitor marches in step: one set of workspaces across all your screens. Press `SUPER+3` and *all* your
screens switch to workspace 3. The bar shows workspace groups instead of the
per-monitor ids Hyprland uses internally.

Hyprland's own model gives every monitor its own workspace, so `SUPER+3`
switches only the monitor you are on, and the bar shows whatever id happens to
be on that monitor. This plugin layers the i3/sway-style "one workspace
everywhere" model on top of it.

## How it works

Monitors are numbered left to right (then top to bottom), starting at 0.
Workspace group `g` on monitor `i` is Hyprland workspace `g + 10 * i`:

| Group | Monitor 0 | Monitor 1 | Monitor 2 |
|---|---|---|---|
| 1 | 1 | 11 | 21 |
| 2 | 2 | 12 | 22 |
| … | … | … | … |
| 10 | 10 | 20 | 30 |

Every id is pinned to its monitor with a persistent workspace rule, so the
workspaces always exist and never wander. Switching a group sets each monitor's
active workspace directly through Hyprland's Lua API; the focused monitor is
switched last so keyboard focus and the cursor stay where they were. Anything
else that changes a workspace (a gesture, another tool, a stock keybinding)
fires `workspace.active`, and the plugin pulls the other monitors along.

Two parts:

- `hypr/lockstep.lua` runs inside Hyprland: rules, keybindings, sync.
- `Panel.qml` is the bar widget: the Lockstep mark, one button per group, and
  a small menu (click the mark) that shows whether Lockstep is active or
  paused, what each monitor is showing, and a switch to pause or resume.

## Pause and resume

Pausing hands the monitors back to stock Hyprland behaviour: `SUPER+n` moves
only the monitor you are on, and nothing follows. The workspace ids and rules
stay in place, so resuming just pulls every monitor back into step. The mark's
link is cut while paused.

- Click the mark for the menu and flip the switch (or press Space).
- Middle-click the mark to pause or resume without opening the menu.
- From a shell: `hyprctl repl 'lockstep.toggle()'` or
  `lockstep.set_enabled(false)`.

The state is kept in `~/.local/state/omarchy/lockstep/enabled` and survives
`hyprctl reload`. If the menu says **Not loaded**, Hyprland has not run the
Lua yet: check the `dofile` line in `bindings.lua`.

## Install

```bash
omarchy plugin add https://github.com/j0achim/omarchy-lockstep
omarchy plugin enable joachim.lockstep --section left
```

Then load the Lua side from `~/.config/hypr/bindings.lua`:

```lua
dofile(os.getenv("HOME") .. "/.config/omarchy/plugins/joachim.lockstep/hypr/lockstep.lua")
```

Reload with `hyprctl reload` and check `hyprctl configerrors`. Remove the stock
`omarchy.workspaces` widget from the bar (`~/.config/omarchy/shell.json`) so
you do not see both.

On first load, workspaces that already sit on a monitor get renumbered in
place (workspace 6 on the third monitor becomes 26), so nothing moves.

Optional, for a theme per workspace group (see below):

```bash
omarchy hook install theme-set ~/.config/omarchy/plugins/joachim.lockstep/hooks/lockstep-theme
```

## Keys

The plugin unbinds Omarchy's per-monitor workspace keys and rebinds them:

| Key | Action |
|---|---|
| `SUPER + 1…0` | Switch every monitor to group 1…10 |
| `SUPER + SHIFT + 1…0` | Move the window to that group (same monitor) and follow |
| `SUPER + SHIFT + ALT + 1…0` | Move the window to that group silently |
| `SUPER + TAB` / `SUPER + SHIFT + TAB` | Next / previous occupied group |
| `SUPER + CTRL + TAB` | The group you came from |
| `SUPER + scroll` | Next / previous occupied group |
| `SUPER + SHIFT + arrows` | Move the window in that direction; at the monitor edge it crosses to the next monitor, same group |

Set `lockstep = { bind_keys = false }` before the `dofile` line to
keep your own bindings and call `lockstep.focus(n)` yourself.

## Options

Lua, set before the `dofile`:

```lua
lockstep = {
  groups = 10,      -- groups per monitor (only 1-10 get number keys)
  stride = 10,      -- id spacing between monitors; >= groups
  bind_keys = true, -- replace Omarchy's workspace bindings
  gather_on_undock = true, -- pull a lost monitor's windows onto the rest, send them back later
  theme_delay = 200,        -- ms before the full theme set (bar + wallpaper change at once)
}
```

Bar widget, in `shell.json` or via `omarchy bar set joachim.lockstep <key> <value>`:
`groups`, `stride` (keep both equal to the Lua values) and `minShown` (always
show at least this many groups).

## Runtime

```bash
hyprctl repl 'return lockstep.status()'   # which id each monitor shows
hyprctl repl 'lockstep.focus(4)'           # switch every monitor to group 4
hyprctl repl 'lockstep.gather()'           # pull windows from vanished monitors'
                                                    # ids into the same group now
hyprctl repl 'lockstep.set_theme(2, "Nord")' # theme for group 2 (see Themes)
```

## Monitor changes

When a monitor appears or disappears the rules are rebuilt from the new
left-to-right order and every workspace is moved to the monitor its id belongs
to. Windows on ids whose monitor is gone (for example 11–20 after undocking)
are gathered into the same group on the last remaining monitor, so group 3 on
the laptop holds everything that was in group 3. Each gathered window's origin
is remembered in `~/.local/state/omarchy/lockstep/parked`; when a monitor is
back at that position, windows that were not moved in the meantime return to
it. Set `gather_on_undock = false` to leave orphaned ids parked and hidden
instead, and gather by hand with `lockstep.gather()`.

## Themes per group

Each group can have its own Omarchy theme. Go to a group and pick a theme in
Omarchy's theme switcher as usual: with the `theme-set` hook installed, that
theme now belongs to the group, and switching groups switches the theme. Groups
without one use the default, which is the theme you had when this was first
loaded.

```bash
hyprctl repl 'lockstep.set_theme(3, "Gruvbox")'    # assign without switching there
hyprctl repl 'lockstep.set_theme(3, nil)'          # group 3 back to the default
hyprctl repl 'lockstep.set_theme("default", "Nord")'
cat ~/.local/state/omarchy/lockstep/themes         # the map
```

Switching feels instant: the bar and wallpaper change about 90 ms after the
key press, over omarchy-shell IPC, from the theme's `colors.toml`,
`shell.toml` and wallpaper cached in `~/.cache/omarchy/lockstep/themes/`.
The full `omarchy theme set` (terminals, Hyprland borders, browser, editors)
follows `theme_delay` ms (200) later and is done after roughly 0.8 s.
`bin/lockstep-theme` serializes those runs and always applies the *latest*
switch, so flicking through groups stays cheap. A theme is cached the first
time it is applied in full, so the very first visit to a new theme takes the
slow path once.
While Lockstep is paused, themes neither switch nor get recorded.

## Limitations

- Per-group themes are global, like Omarchy themes: every monitor shows the
  group's theme. Entering a theme picks its first background, so a different
  background chosen with `omarchy theme bg next` does not stick to the group.

- Numbered workspaces only. Named and special workspaces are ignored.
- `SUPER + SHIFT + arrows` are Hyprland's *move* dispatcher here instead of
  Omarchy's *swap*, because swap never leaves a monitor.
- `SUPER + SHIFT + ALT + arrows` (Omarchy's "move workspace to monitor") still
  works but fights the id-to-monitor mapping; the next sync moves it back.
- A group is "occupied" in the bar when any of its member workspaces has a
  window on any monitor.
