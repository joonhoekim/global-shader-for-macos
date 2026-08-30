# Usage

*[← README](../README.md)  ·  [한국어](usage.ko.md)*

## One instance, always

**If one is already running, applying a shader changes the running one instead
of starting a second.** A second instance is feedback in itself
([Architecture](architecture.md)), so it cannot be started, and the only
remaining meaning is "change it". This is where the script that used to talk to
the compositor on Linux ends up.

To stop it: `◲` → Quit in the menu bar, `--stop`, or SIGINT/SIGTERM.

## Chains — several shaders, in order

Hyprland's `decoration:screen_shader` takes exactly one. So adding film grain
behind a CRT meant merging two shaders into one file by hand, and the moment
they were merged you could no longer turn one off or swap their order.

**Here we decide the composition order ourselves, so there is no reason to.**

```sh
global-shader shaders/crt/crt.frag shaders/crt/glow.glsl
```

Each pass draws offscreen and the next pass receives that as `tex`. From the
shader's side, the fact that it is handed one frame of the screen is unchanged,
so a file in a chain behaves exactly as it does alone — and keeps running on
Linux. **Still not a character changed in the file.**

The intermediate targets ping-pong between two textures. No pass ever looks two
steps back, so there is no reason to hold N of them — at 4K one is 22MB.

If any single link fails to translate, **nothing changes.** Applying only the
earlier ones would give you a screen where the grain that used to sit behind the
CRT has quietly gone missing, and that is harder to notice than a screen that
did not change at all.

A chain that cannot be applied **does not reach the settings either.** Leaving
the screen alone is not enough — a broken link left in `config.json` means the
next run takes the *first-time* path for that chain, and failing there brings up
a passthrough. A single typo would become a black screen at the next login,
which is the hardest kind of cause to connect to its effect.

Reorder, enable, remove: from the menu bar, or over the socket from a script.

## The menu bar

Everything is under the one `◲`: chain order, knob sliders, profiles, shader
folders, scale / frame cap / redraw, start at login.

There is no separate settings window because this app is `LSUIElement`. Showing
a window means activating an accessory app, which steals focus from whatever you
were using. A tool that puts glass over your screen interrupting your work to
change one scale value does not add up.

### The overlay steps aside for the menu

The overlay lives at `CGShieldingWindowLevel()` — 2147483628 — and a menu's
dropdown window is 101. So while a menu is open the overlay **drops to level
100.** Normal windows (0), floating windows (3), modal panels (8) and the menu
bar (24) are still covered, and the only thing that changes is our own menu.
Dialogs go the other way and raise their own level above shielding.

The menu not getting the glass treatment is accepted. The premise of this window
is that you must be able to get out through here even when the shader has made
the screen unreadable, so the control panel being legible is the right trade.
Before this, [the menu was buried under the
glass](notes/history.md#the-menu-was-buried-under-the-glass) and invisible.

## Settings and profiles

```
~/.config/global-shader/          (respects $XDG_CONFIG_HOME)
  config.json          current chain · shader folders · run options · login item · language
  profiles/<name>.json  one chain, frozen under a name
  shaders/             default shader folder (walked, including subfolders)
```

Shader folders are followed **two levels** deep. Menus inside menus get hard to
follow with a mouse past two levels, so that is where it stops — but the levels
beyond are not ignored: they are **flattened** into the level above. Otherwise
files disappear from the list silently, and someone goes hunting for a shader
they know they put there.

A profile holds the chain order **plus the knob values plus the run options.** A
heavy shader wants the scale turned down, and which one is right differs per
shader.

```sh
global-shader --profile <name>         # apply (changes the running one, if any)
global-shader --profiles               # list
```

Saving is done from the menu (`Profiles → Save the current one as a profile…`)
or over the socket.

### Why JSON and not `UserDefaults`

This app assumes it will live in an environment that manages configuration
**declaratively** (Nix home-manager, chezmoi, a dotfiles repo). Those
environments share one circumstance: if a config file is placed as a symlink out
of a store or a repo, the target becomes **read-only** — so values a person is
meant to edit by hand get seeded instead ("copy only if absent"), leaving a real
writable file behind. The point is that a value you tweaked while ricing does
not vanish on the next rebuild.

`UserDefaults` cannot enter that layer. It is a binary plist, so it does not
diff, and `cfprefsd` holds a cache, so it is never quite clear when a value
written from outside takes effect. One JSON file, on the other hand, can be
seeded by a config manager, edited by a person, and committed. Which is why it
is written as sorted, pretty-printed JSON — a one-value change has to be a
one-line diff before anyone will keep it under version control.

**A read-only settings file does not kill it.** Values changed from the menu
live for this run only, and the menu says so.

## Start at login

`Settings → Start at login` in the menu. Turning it on writes
`~/Library/LaunchAgents/dev.jh.global-shader.plist` and runs `launchctl
bootstrap`.

Two reasons it is not `SMAppService`. It cannot carry arguments, and the app
writes registration state back into its own settings. In an environment that
wants to hold that kind of state declaratively there are then two truths, and
when they diverge you get "I definitely turned it off and it still starts at
login". Writing the LaunchAgent directly makes it the **same object** a config
manager would place, so moving it into a declarative setup later does not
contradict what the app has been doing.

It invokes the executable inside the bundle directly rather than `open -a`.
`open -a` starts the app and then **exits immediately**, which launchd reads as
"the job finished" — that does not fit `RunAtLoad`.

### Moving it into a declarative setup

If `~/Library/LaunchAgents` holds an agent that is **not ours but invokes this
binary**, the app locks the toggle and shows "managed elsewhere". Missing that
and adding a second one means two try to start at login, the second is refused by
the instance lock, and the symptom becomes "sometimes it doesn't come up".

```nix
# What it looks like under nix-darwin.
launchd.user.agents.global-shader = {
  command = "/Applications/GlobalShader.app/Contents/MacOS/global-shader";
  serviceConfig = {
    RunAtLoad = true;
    # No KeepAlive. What you quit from the menu should stay quit — a window
    # covering the whole screen coming back on its own is frightening.
    StandardOutPath = "/tmp/global-shader.log";
    StandardErrorPath = "/tmp/global-shader.log";
  };
};
```

The shader is not passed as an argument. `config.json` already holds it, so there
is no reason for the agent to change every time the shader does.

## The control socket

`~/Library/Caches/dev.jh.global-shader.sock`. One line per connection, one blob
back, then it closes. The same binary is also the client.

**Everything spoken over this socket is English**, regardless of the language
setting — see [Languages](i18n.md).

| CLI | socket | |
|---|---|---|
| `--get` | `list` | every knob (JSON: value, range, step, doc) |
| `--set N V` | `set N V` | change one. Out-of-range is clamped |
| `--reset [N]` | `reset [N]` | back to the file's value. `2.` means that whole pass |
| `--chain` | `chain` | the current chain (JSON) |
| `<file>…` | `chain set A⇥B` | replace the whole chain |
| | `chain add A` | append one pass |
| | `chain remove N` | drop pass N |
| | `chain toggle N` | turn pass N off and on |
| | `chain move F T` | reorder |
| | `chain clear` | empty it |
| `--profiles` | `profile list` | profile names |
| `--profile <name>` | `profile load <name>` | apply a profile |
| | `profile save <name>` | save the current one |
| | `profile delete <name>` | delete it |
| `--login [on\|off]` | `login [status\|on\|off]` | the login item |
| `--reload` | `reload` | re-read the shaders |
| `--status` | `status` | version, chain, profile, knob count, display count, redraw, fps (JSON) |
| `--stop` | `stop` | exit |

Paths and profile names can contain spaces, so **the entire rest of the line** is
taken as one argument. Only multiple paths are separated, by a tab (`⇥`) — the
same binary is the client, so we can hold ourselves to that convention, and
calling it by hand in a shell needs no quoting for a single path.

Calling `--set` when started with `--no-knobs`, or on a shader whose promotion
folded, returns the reason instead of pretending to succeed. A slider that
appears to do nothing is the worst failure there is.

## Options

**Command line options apply to this run only. The menu bar is where you change
things for good.**

There is one rule — the shader (chain, profile) persists, the run options do not.
`global-shader crt.frag` means "apply crt from now on", so it is written to the
settings; `--scale 0.7` is measuring something once, not changing your taste.
Writing that down would let a single measurement quietly contaminate the config.

```
--profile <name>  a saved chain.
--fps N           capture/render cap. Defaults to the display refresh rate.
--scale F         0.25–1.0. The first knob when frames run short.
--redraw M        auto (default) | always | never. auto looks at whether the shader reads time.
--no-hot-reload   do not re-read a file when it changes.
--no-knobs        turn off uniform promotion of @range #defines. Promotion is the default and costs 0.
--space-fix M     handling for Space-switch ghosting. off (default) | freeze | hide.
--no-vsync        turn off vsync. For measuring what a shader really costs.
--capturable      include the overlay in screenshots and recordings. One layer of feedback defence less.
--diag            feedback diagnostic. Draws a marker and reads it back out of the capture.
--exit-after N    exit on its own after N seconds.
--allow-multiple  skip the instance lock. For testing.
--lang L          language for this run. Otherwise the settings, then the system.
--check           translate and build pipelines only. No permission, no window. Takes chains too.
--dump-msl        --check plus the translated MSL.
-V, --version     version. It is also in the `--status` JSON.
```
