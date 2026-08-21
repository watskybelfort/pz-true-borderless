# True Borderless — for Project Zomboid Build 42

**English** · [Español](README.es.md)

Borderless fullscreen that actually covers the monitor, and an **alt-tab that never
goes black**.

You know the flash. You tab out to Discord, the screen blanks for half a second, you
tab back, it blanks again. That is what this removes.

There are two halves:

| | The Workshop mod alone | Mod **+** this helper |
|---|:---:|:---:|
| Borderless really covers the screen, taskbar included | ✅ | ✅ |
| Turning it off gives you your old settings back | ✅ | ✅ |
| Works on a **second** monitor | ❌ | ✅ |
| **Alt-tab with no black flash** | ❌ | ✅ |

The mod fixes borderless. The helper is what makes alt-tab seamless — and it has to
live outside the game, because Lua cannot reach the Windows API. [Why, exactly](#why-does-this-need-a-file-outside-the-game).

---

## Setup — three steps, about two minutes

### 1. Subscribe to the mod

Steam Workshop → **True Borderless** → Subscribe, then enable it in the game's
**Mods** screen like any other mod.

> Stopping here is fine. You get working borderless, just not the seamless alt-tab.

### 2. Download this helper

Click the green **Code** button at the top of this page → **Download ZIP**.

Extract it **anywhere you like** and leave it there — Documents, your game folder, a
folder called `PZ stuff` on your desktop. It does not matter, as long as you do not
move it afterwards.

There is nothing to install. It is two files that do the work:

```
TrueBorderless.ps1        the helper itself
TrueBorderless-Steam.bat  the small file Steam calls
```

### 3. Point Steam at it

1. Right-click **Project Zomboid** in your Steam library → **Properties**
2. Stay on **General**, find the **Launch Options** box at the bottom
3. Paste this in, and **replace the path with your own**:

```
"C:\Path\To\pz-true-borderless\TrueBorderless-Steam.bat" %command%
```

**Keep the quotes, and keep ` %command%` on the end.** Those two things are what make
it work.

<details>
<summary><b>How do I get my own path?</b> (click)</summary>

Open the folder you extracted, hold **Shift**, right-click `TrueBorderless-Steam.bat`,
and pick **Copy as path**. Windows puts it on your clipboard *with the quotes already
around it*. Paste it into the box, press space, and type `%command%` after it.

The result looks like this:

```
"C:\Users\You\Documents\pz-true-borderless\TrueBorderless-Steam.bat" %command%
```
</details>

### Done

Press **Play**. A small window flickers past while it sets things up, then the game
starts. Alt-tab away and back — no black.

From now on it does not matter *how* you start the game: the Play button, a desktop
shortcut, Big Picture, a `steam://` link. Steam always comes through the launch
options first, so it always works. Nothing runs in the background when the game is
closed.

---

## Checking it worked

Alt-tab out and back. If the screen stays lit the whole time, you are done.

Want the details? Double-click **`TrueBorderless.ps1`**… actually don't — Windows
opens `.ps1` files in Notepad. Instead, open the folder, type `powershell` in the
address bar, press Enter, and run:

```powershell
.\TrueBorderless.ps1 -Mode Status
```

It prints your monitors, what the game window is currently doing, and a checklist of
everything that can still cause a flash. Every line should say `ok`.

---

## Uninstalling

1. Clear the **Launch Options** box in Steam.
2. Put Windows' own settings back:

   ```powershell
   .\TrueBorderless.ps1 -Mode SeamlessUndo
   .\TrueBorderless.ps1 -Mode Revert
   ```

3. Delete the folder. Unsubscribe from the mod if you want.

`-Mode Revert` restores the resolution and fullscreen settings you had **before you
ever ran this**, not whatever it happened to leave behind. It saved them on the very
first run for exactly this reason.

---

## Why does this need a file outside the game?

Short version: the last black flash is caused by Windows, not by Project Zomboid, and
a mod has no way to talk to Windows.

Longer version, because you should know what you are running:

A borderless window whose rectangle matches a monitor **exactly** gets promoted by
Windows onto the fullscreen presentation path. That is normally a *good* thing — it is
how borderless games get fullscreen-like performance. The cost is that you also
inherit fullscreen's transitions, so alt-tab blanks the panel while it moves the
window in and out of that path.

The fix is almost stupid: make the window **one pixel bigger than the monitor**, so it
hangs a pixel off every edge. Now it is not an exact match, Windows leaves it
composited like any ordinary window, and alt-tab is instant. You never see the missing
pixel — it is off-screen.

Positioning a window at `-1, -1` and sizing it past the screen edge means calling
`SetWindowLongPtr` and `SetWindowPos`. Project Zomboid's Lua sandbox has no access to
either, and no mod can add it. So that one job — and only that job — lives in a script
outside the game.

The full technical write-up, including the four separate bugs in vanilla's borderless
and how they were found, is in [docs/how-it-works.md](docs/how-it-works.md).

---

## Is this safe to run?

Fair question — you should be suspicious of `.bat` files off the internet.

- **The whole thing is right here, in plain text.** `TrueBorderless.ps1` is one file
  you can read top to bottom, and it is commented for people, not for compilers.
- **No admin rights.** Nothing it touches needs elevation.
- **No network access.** It never connects to anything. There is nothing to phone home
  to.
- **Nothing stays running.** The helper exits by itself when the game closes. Nothing
  is added to startup, and no service is installed.

Everything it writes, in full:

| What | Where | Undo |
|---|---|---|
| Its own settings | `Documents\Zomboid\Lua\TrueBorderless*.ini` | delete them |
| Resolution + fullscreen flags | `Documents\Zomboid\options.ini` (a backup is made next to it on first run) | `-Mode Revert` |
| "Disable Fullscreen Optimizations" for the game | `HKCU\...\AppCompatFlags\Layers` — the same registry value the checkbox in a program's Properties writes | `-Mode SeamlessUndo` |

That last one is worth a note: it is per-user, it is the same thing you would do by
hand in `ProjectZomboid64.exe` → Properties → Compatibility, and the script *edits*
the value rather than replacing it, so other tools' compatibility settings survive.

---

## Troubleshooting

Most problems are one of four things — see [docs/troubleshooting.md](docs/troubleshooting.md)
for the full list.

**The game opens as a normal window with a title bar.**
The launch option is not being used. Check it is in the **Launch Options** box (not the
game's own settings), that the path is right, and that ` %command%` is on the end.

**Steam says my playtime is 0 / the overlay doesn't work.**
The ` %command%` at the end is missing.

**"Running scripts is disabled on this system."**
Not something you need to fix — the `.bat` already launches PowerShell with
`-ExecutionPolicy Bypass`, which handles it. If you are running the `.ps1` by hand,
use `powershell -ExecutionPolicy Bypass -File .\TrueBorderless.ps1`.

**It works, but the window is on the wrong monitor.**
Open `Documents\Zomboid\Lua\TrueBorderless.ini` and set `monitor=` to the number you
want. Run `-Mode Status` to see how they are numbered.

---

## Settings

Everything lives in one file, `Documents\Zomboid\Lua\TrueBorderless.ini`, and it is
written with comments explaining itself. Both the mod and the helper read it, so there
is only ever one place to change anything. The in-game panel under **Options → Mod
Options → True Borderless** writes to the same file.

| Setting | Default | Meaning |
|---|---|---|
| `mode` | `true` | `true` = the helper owns the window (seamless alt-tab, works on any monitor). `native` = engine borderless only, no helper needed. `off` = leave the display alone. |
| `overscan` | `1` | Pixels the window hangs off each edge. This is the whole trick. `0` disables it. |
| `monitor` | `auto` | `auto`, `primary`, or a monitor number. |
| `topmost` | `false` | Keep the window above everything else. |

**F10** toggles the whole thing on and off in-game. Rebind it under
**Options → Key Bindings**.

---

## Requirements

- **Windows.** The helper uses the Win32 API. The mod on its own is plain Lua and works
  everywhere, but `native` mode is all you get.
- **Project Zomboid Build 42.** Not tested on B41.
- PowerShell 5.1, which ships with Windows. Nothing to install.

## Licence

MIT — see [LICENSE](LICENSE). Do what you like with it.
