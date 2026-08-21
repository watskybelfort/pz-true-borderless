# How it works

Everything below came out of disassembling `zombie.core.Core` and
`org.lwjglx.opengl.Display` from `projectzomboid.jar` (Build 42.20.3), and out of
measuring the window state 20 times a second across forced focus changes. Where a
claim is a measurement, the numbers are here too.

---

## Part 1 — why the vanilla borderless checkbox looks like it does nothing

Five separate things in the engine, only the first of which most people ever hit.

| # | What the engine does | Where | Consequence |
|---|---|---|---|
| 1 | **Early-returns** when the fullscreen flag did not change and the `DisplayMode` is equal | `Display.setDisplayModeAndFullscreenInternal`, offsets 22–34 | Ticking only the borderless box strips the frame and **never moves the window**. This is the "it does nothing". |
| 2 | In borderless it **discards the width and height it was given** and uses `glfwGetVideoMode(glfwGetPrimaryMonitor())` | `Core.setDisplayModeInternal`, offsets 309–360 | The size always comes from the primary monitor, whichever screen you are on. |
| 3 | `getAvailableDisplayModes()` enumerates the primary monitor **only** | `Display.getAvailableDisplayModes`, offset 0 | The engine cannot even name a second monitor's resolution. |
| 4 | Positions the window at `(desktopWidth - windowWidth) / 2` | `Display.calcWindowPos`, offsets 110–128 | That is an offset *inside* the primary monitor, not a point on the virtual desktop. A monitor at negative coordinates is unreachable. |
| 5 | The default resolution comes from `glfwGetMonitorWorkarea` | `Core.initOptionsINI`, offset 110 | Desktop **minus** the taskbar. |

Defect 1 is what you feel. Defects 2–4 only matter if you want to cover a monitor
that is not the primary one — for instance a portrait 1440x3440 panel sitting at
`-1440, -1310`, which lives entirely in negative coordinates.

**What the mod does about it.** In `native` mode it drives the engine's own borderless
path, but in an order the early return cannot short-circuit: it makes the fullscreen
flag genuinely change, and where necessary inserts a different intermediate mode so
the new `DisplayMode` does not compare equal to the old one. The engine then really
does reposition the window, and on the primary monitor its own arithmetic lands in the
right place — `0, 0`, covering the screen, no frame.

That is pure Lua. No external process involved.

---

## Part 2 — the alt-tab flash, which is the part that actually matters

The one-second black when you alt-tab is **the monitor resynchronising**. Worth
knowing up front: **you cannot screenshot it.** `CopyFromScreen` reads the desktop
composition, which stays perfectly valid while the physical panel is dark. Anyone
trying to debug this by capturing pixels will conclude nothing is wrong. The only
reliable evidence is the window state and the display mode.

### Cause 1 — GLFW auto-iconify (exclusive fullscreen only)

Sampled 20×/second across a forced focus change:

| Configuration | Display mode | Minimised on focus loss? |
|---|---|---|
| **Exclusive fullscreen** | constant | **yes — 91 of 91 samples** |
| **Borderless** | constant | **never — 0 of 93** |

GLFW leaves `GLFW_AUTO_ICONIFY` at its default, which is on. A **fullscreen** window
minimises the instant it loses focus, which hands the display back to the desktop →
resync → black. Coming back it retakes the exclusive mode → resync → black again. One
in each direction, which is why it feels so bad.

In borderless the window is never fullscreen as far as GLFW is concerned, so
auto-iconify does not apply, nothing minimises, no mode set happens, and there is no
resync to be had.

### Cause 2 — Windows Fullscreen Optimizations

Windows moves a borderless window in and out of a flip presentation path as focus
changes, and that transition can drop a frame to black. `-Mode Seamless` turns the
feature off for the game's executables, via the same per-user registry value as the
checkbox in `ProjectZomboid64.exe` → Properties → Compatibility.

### Cause 3 — the one that survives everything else, and the reason this repo exists

A borderless window that measures **exactly** the monitor is still treated by Windows
as fullscreen. The compositor promotes it onto a flip presentation path and, from then
on, hands it the same enter/exit transitions as a genuinely fullscreen game — even
though the game never performed a single mode change.

This is why "it's a window, this shouldn't happen" is right in theory and wrong in
practice. **Windows does not look at whether the window has a border. It looks at
whether it covers the monitor exactly.**

So withdraw its candidacy: **a window one pixel larger than the monitor cannot be
promoted.** With `overscan=1` the window sits at `-1, -1` measuring `3442x1442` on a
`3440x1440` panel. The compositor treats it as an ordinary window for the whole
session, and there is no transition left that could flash.

The cost is one pixel of image falling off each edge — 0.03% of the frame on a
3440x1440 panel.

Measured with it applied:

```
[TrueBorderless][DEBUG] target rect 3442x1442 at -1,-1 (overscan 1)
[TrueBorderless][DEBUG] engine already windowed at 3442x1442
[TrueBorderless][INFO]  display already correct, left untouched

Display mode changed to 3442x1442 freq=0 fullScreen=false   <- one, at startup
window  -1,-1  3442x1442   client 3442x1442   decorated: False
```

And across a full session of tabbing in and out:

```
=== DISPLAY MODES SEEN ===
  3440x1440@240   (90 samples)
  -> the mode NEVER changed: no monitor resync
=== MINIMISED AT ANY POINT? ===
  no, never
```

One mode set in the entire session, the one at startup.

---

## Part 3 — why it costs nothing

The client area and the window measure the same thing, so the framebuffer never
changes size. That is deliberate, and it is the reason the frame time is identical to
before.

The enforcer **never resizes the client area**. Nothing in Project Zomboid calls
`Display.wasResized()`, so the engine would not notice a framebuffer size forced on it
from outside and would render at the wrong scale forever — letterboxed or stretched.
The in-game mod is what puts the engine at the right client size; the script only
agrees with it and owns the frame and the position.

There is a second reason the mod stays quiet: **every display call the engine accepts
performs `glfwHideWindow` + `glfwShowWindow`, which is a visible flash.** A mod that
"reapplies just in case" is a mod that flickers. So the mod checks first and does
nothing when the state is already right:

```
[TrueBorderless][INFO] display already correct, left untouched (no mode change, no flash)
```

---

## Part 4 — how the two halves talk

They share four files in `Documents\Zomboid\Lua\`, and each file has exactly one
writer, so there is no race and neither side has to lock anything.

| File | Direction | Carries |
|---|---|---|
| `TrueBorderless.ini` | shared | your settings |
| `TrueBorderless_monitors.ini` | helper → mod | the real desktop layout, plus `target.*`: the exact rectangle the window must occupy, overscan already applied |
| `TrueBorderless_request.ini` | mod → helper | what you just asked for with F10 |
| `TrueBorderless_baseline.ini` | mod → mod | the display settings found on arrival |

`target.*` exists so the overscan arithmetic happens in exactly one place. If both
sides computed it, they could disagree, and a client area that does not match the
window rectangle is a letterboxed picture.

`ts` in the monitors file doubles as the helper's heartbeat. If the mod does not see a
fresh timestamp it concludes the helper is not running and **falls back to `native` on
its own**, so you never end up staring at a titlebarred window because you forgot to
set up the launch option.

### The baseline file, and a trap worth knowing about

Project Zomboid rewrites `options.ini` when it exits. So anything a mod leaves set
becomes, on the next launch, indistinguishable from *your* choice — and settings
degrade quietly over time. `TrueBorderless_baseline.ini` captures your real settings
once, on first run, and is never updated. That is what `-Mode Revert` restores, and it
is why turning the mod off gives you back what you had rather than what it left.

---

## Part 5 — the mod layout, for anyone building on this

Build 42 reads `mod.info` from **inside a version folder**:

```
TrueBorderless/
  42/
    mod.info
    poster.png
    media/lua/client/TrueBorderless/*.lua
```

A mod laid out the old flat way — `mod.info` and `media/` at the mod root — is
**silently ignored**. It never appears in the Mods screen, its Lua is never parsed, and
nothing is logged anywhere. The `ModTemplate` that ships with the game is flat and
would not pass B42's own Workshop validation.

Also from `SteamWorkshopItem.validateContents()`, since it only ever reports one error
at a time and only after you have clicked Upload:

- `preview.png` must be **exactly 256x256** and at most 1000 KB.
- `Contents\` accepts only the folders `buildings`, `creative`, `maps`, `media`,
  `mods` — and no loose files.
- Forbidden extensions: `.app .bat .dll .dylib .exe .sh .so .zip`. **That is why the
  helper cannot ship inside the Workshop item**, quite apart from Lua not being able
  to call Win32.
- `workshop.txt` needs `version=`, `title=` and `visibility=`; valid visibilities are
  `public`, `friendsOnly`, `private`, `unlisted`.
