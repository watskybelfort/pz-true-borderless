# extras

**You almost certainly do not need anything in here.**

The normal setup — the mod, the helper, the launch option — needs no administrator
rights and touches nothing outside your own user account. This folder is the opposite:
one machine-wide change, for one specific failure that survives everything else.

## Disable-MPO.ps1

Turns off Windows Multi-Plane Overlay.

**Try this only if all of the following are true:**

- `TrueBorderless.ps1 -Mode Status` reports `ok` on every line, with the game open, and
- `overscan` is `1` and `mode` is `true` in `TrueBorderless.ini`, and
- alt-tab **still** flashes.

MPO lets the graphics driver hand certain windows straight to the display engine,
skipping composition. It enters and leaves that path by itself depending on what is on
screen, and each transition can make the panel resynchronise — which is a black. It is
intermittent by design, which is why it feels like "it worked for two minutes and then
started flickering again": nothing you changed changed. What changed was what the
driver decided to do.

It is most common on NVIDIA with several monitors running at different refresh rates.

### Before you run it

- It needs **administrator** rights.
- It is **machine-wide**. It affects every application, not just this game.
- It needs a **reboot** to take effect.
- Some people see reduced video playback efficiency with MPO off.

### Running it

Open PowerShell as administrator, then:

```powershell
.\Disable-MPO.ps1        # disable
.\Disable-MPO.ps1 -Undo  # put it back
```

It writes exactly one registry value, `HKLM\SOFTWARE\Microsoft\Windows\Dwm\OverlayTestMode`,
and `-Undo` deletes it, which is what returns Windows to its own default.
