# Troubleshooting

Start here, always:

```powershell
.\TrueBorderless.ps1 -Mode Status
```

It prints your monitors, what the game window is doing right now, and a checklist of
everything still capable of causing a flash. Run it **with the game open** for the full
picture.

---

## The game opens as a normal window, with a title bar

The launch option is not running. In `mode=true` the game deliberately starts as a
plain window and the helper strips the frame a moment later — so a titlebar that never
goes away means the helper never started.

Check, in order:

1. It is in **Properties → General → Launch Options**, not in the game's own settings.
2. The path is right, and the file is still where the path says it is.
3. The quotes are there: `"C:\...\TrueBorderless-Steam.bat" %command%`
4. ` %command%` is on the end, after a space.

Quick test without Steam: open the folder, type `powershell` in the address bar, and
run `.\TrueBorderless.ps1 -Mode Apply` while the game is open. If the frame disappears,
the helper is fine and the launch option is the problem.

---

## Steam shows 0 hours played, or the overlay does not work

` %command%` is missing from the end of the launch option. Without it, Steam launches
the `.bat`, the `.bat` exits immediately, and Steam decides the game is closed.

---

## "Running scripts is disabled on this system"

You do not need to change your execution policy. The `.bat` launches PowerShell with
`-ExecutionPolicy Bypass`, which handles it.

If you are running the `.ps1` directly, do the same:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\TrueBorderless.ps1 -Mode Status
```

If Windows says the file is **blocked** because it came from the internet, either
right-click it → **Properties** → tick **Unblock**, or run:

```powershell
Get-ChildItem -Recurse | Unblock-File
```

---

## The window lands on the wrong monitor

Open `Documents\Zomboid\Lua\TrueBorderless.ini` and set `monitor=` to the number of the
one you want. `-Mode Status` prints the numbering:

```
Monitors (full bounds, taskbar included):
  1. \\.\DISPLAY1    3440x1440  at 0,0  (primary)
  2. \\.\DISPLAY2    1440x3440  at -1440,-1310
```

`monitor=auto` means "the monitor the window is already on", which is usually what you
want once it is there. At startup there is no window yet, so `auto` can only mean the
primary one.

---

## The picture is letterboxed, or stretched, or scaled wrong

The window rectangle and the engine's client area have gone out of agreement.

The engine never notices a framebuffer size imposed from outside — nothing in Project
Zomboid calls `Display.wasResized()` — so if the window is one size and the engine is
rendering at another, it stays wrong until the resolution changes.

Fix: close the game and run

```powershell
.\TrueBorderless.ps1 -Mode Prepare
```

which writes the matching `width`/`height` into `options.ini` before the next launch.
The Steam launch option does this every time, so if you are seeing this, something
started the game without it.

Do not use `-Force`. It exists for diagnosis, and letterboxing is exactly what it
causes.

---

## Alt-tab still flashes

Run `-Mode Status` **with the game open** and read the checklist. In order of how
often each one is the culprit:

- **`fullScreen=true` in options.ini.** Exclusive fullscreen minimises on focus loss.
  That *is* the flash, and no amount of window tinkering will fix it. `-Mode Prepare`
  sets it correctly.
- **`overscan=0`.** Then the window matches the monitor exactly, Windows promotes it
  to the fullscreen presentation path, and you get fullscreen's transitions back. Set
  it to `1`.
- **`mode=native`.** Native mode uses the engine's borderless, which sizes the window
  to exactly the monitor — same promotion, same flash. Native is the no-helper mode;
  if you have the helper, use `mode=true`.
- **Fullscreen Optimizations still on.** `-Mode Seamless` disables them. It only takes
  effect on the *next* launch.

If all four say `ok` and it still flashes, the remaining suspect is Multi-Plane
Overlay. There is a script for that in [`extras/`](../extras/README.md) — it needs
administrator rights and a reboot, and it is genuinely a last resort. Try everything
above first; MPO is almost never the answer once the overscan is in place.

---

## I want it gone

```powershell
.\TrueBorderless.ps1 -Mode SeamlessUndo   # Fullscreen Optimizations back to default
.\TrueBorderless.ps1 -Mode Revert         # your original resolution and fullscreen flag
```

Then clear the Launch Options box and delete the folder.

If you want to wipe its memory as well so a future run starts clean, delete
`Documents\Zomboid\Lua\TrueBorderless*.ini`. Note that deleting
`TrueBorderless_baseline.ini` means `-Mode Revert` has nothing left to restore, so do
the revert first.

---

## A PowerShell window is stuck open

It waits up to five minutes for the game window to appear and then gives up on its own,
so it will close by itself. Closing it by hand is safe at any time — the game keeps
whatever frame it already has.

---

## Every mode the helper has

| Mode | What it does |
|---|---|
| `Watch` | Wait for the game, keep the window correct until it exits. Default. |
| `Apply` | Fix the window once, now, and exit. |
| `Restore` | Put the original window frame back. |
| `Status` | Report everything and exit. Changes nothing. |
| `Monitors` | Print the desktop layout and refresh the file the mod reads. |
| `Prepare` | Write the right `width`/`height`/flags into `options.ini` for the next launch. |
| `Revert` | Undo `Prepare`, restoring the settings from before first run. |
| `Seamless` | `Prepare` + disable Fullscreen Optimizations + print the checklist. |
| `SeamlessUndo` | Re-enable Fullscreen Optimizations. |
