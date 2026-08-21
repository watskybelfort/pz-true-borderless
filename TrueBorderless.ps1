<#
.SYNOPSIS
    TrueBorderless - the Windows-side enforcer for real borderless fullscreen
    in Project Zomboid Build 42.

.DESCRIPTION
    Project Zomboid's own borderless option cannot cover a monitor correctly:

      * Core.setDisplayModeInternal builds the borderless window from
        glfwGetVideoMode(glfwGetPrimaryMonitor()) and discards the width and
        height it was given, so the size always comes from the primary
        monitor whichever screen the window is on.
      * Display.getAvailableDisplayModes() enumerates the primary monitor
        too, so the engine cannot even name a second monitor's resolution.
      * Display.calcWindowPos positions the window at
        (desktopWidth - windowWidth) / 2, an offset inside the primary
        monitor rather than a point on the virtual desktop.
      * Core.initOptionsINI picks the default resolution from
        glfwGetMonitorWorkarea, which is the desktop minus the taskbar.

    This script owns the part the engine gets wrong: the window frame and
    where the window sits. It strips the caption and the sizing border and
    snaps the window to the FULL monitor rectangle (rcMonitor), not the
    taskbar work area (rcWork).

    It deliberately never resizes the client area. Nothing in the game calls
    Display.wasResized(), so the engine would not notice a framebuffer size
    forced on it from outside and would render at the wrong scale forever.
    The in-game mod is what puts the engine at the right client size; this
    script only agrees with it. That is why the frame costs the same as it
    did before.

.PARAMETER Mode
    Watch    Keep the window correct until the game exits. Default.
    Apply    Apply once and exit.
    Restore  Put the original window frame back.
    Status   Report what is going on and exit.
    Monitors Print the desktop layout and refresh the file the mod reads.

.EXAMPLE
    .\TrueBorderless.ps1
    .\TrueBorderless.ps1 -Mode Status
    .\TrueBorderless.ps1 -Mode Restore
#>
[CmdletBinding()]
param(
    [ValidateSet('Watch', 'Apply', 'Restore', 'Status', 'Monitors', 'Prepare', 'Revert',
                 'Seamless', 'SeamlessUndo')]
    [string] $Mode = 'Watch',

    # Where the game is installed. Only needed by Seamless, which has to
    # name the executables to Windows. Left empty it is worked out from
    # Steam's own library index, so nobody has to edit this file.
    [string] $GamePath = '',

    # Extra process names to consider, on top of the built-in list.
    [string[]] $ProcessName = @(),

    # How often the watcher re-checks the window. 750 ms is far below human
    # perception for a window fix and is a few microseconds of work.
    [int] $IntervalMs = 750,

    # Seconds to keep waiting for the game to appear before giving up.
    # 0 waits forever, which is what the launcher wants.
    [int] $WaitSeconds = 0,

    # Act even when the client area does not match the target monitor.
    # This WILL letterbox or stretch, because the engine will not notice
    # the new framebuffer size. Only useful for diagnosis.
    [switch] $Force,

    [string] $ZomboidPath = (Join-Path $env:USERPROFILE 'Zomboid')
)

$ErrorActionPreference = 'Stop'

# ----------------------------------------------------------------------
# Win32
# ----------------------------------------------------------------------
$nativeSource = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public static class TBNative
{
    // ---- window styles ------------------------------------------------
    public const int GWL_STYLE   = -16;
    public const int GWL_EXSTYLE = -20;

    public const long WS_POPUP       = 0x80000000L;
    public const long WS_VISIBLE     = 0x10000000L;
    public const long WS_CAPTION     = 0x00C00000L;
    public const long WS_BORDER      = 0x00800000L;
    public const long WS_DLGFRAME    = 0x00400000L;
    public const long WS_THICKFRAME  = 0x00040000L;
    public const long WS_MINIMIZEBOX = 0x00020000L;
    public const long WS_MAXIMIZEBOX = 0x00010000L;
    public const long WS_SYSMENU     = 0x00080000L;

    public const long WS_EX_DLGMODALFRAME = 0x00000001L;
    public const long WS_EX_CLIENTEDGE    = 0x00000200L;
    public const long WS_EX_WINDOWEDGE    = 0x00000100L;
    public const long WS_EX_STATICEDGE    = 0x00020000L;

    public const uint SWP_NOACTIVATE     = 0x0010;
    public const uint SWP_FRAMECHANGED   = 0x0020;
    public const uint SWP_SHOWWINDOW     = 0x0040;
    public const uint SWP_NOOWNERZORDER  = 0x0200;
    public const uint SWP_NOZORDER       = 0x0004;

    public const int SW_RESTORE = 9;

    public static readonly IntPtr HWND_TOP       = new IntPtr(0);
    public static readonly IntPtr HWND_TOPMOST   = new IntPtr(-1);
    public static readonly IntPtr HWND_NOTOPMOST = new IntPtr(-2);

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct MONITORINFOEX
    {
        public int cbSize;
        public RECT rcMonitor;
        public RECT rcWork;
        public uint dwFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
        public string szDevice;
    }

    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
    public delegate bool MonitorEnumProc(IntPtr hMonitor, IntPtr hdc, ref RECT rect, IntPtr data);

    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after,
                                    int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, StringBuilder s, int n);

    [DllImport("user32.dll")] public static extern IntPtr MonitorFromWindow(IntPtr h, uint flags);
    [DllImport("user32.dll")] public static extern bool EnumDisplayMonitors(IntPtr hdc, IntPtr clip, MonitorEnumProc cb, IntPtr data);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern bool GetMonitorInfoW(IntPtr hMonitor, ref MONITORINFOEX mi);

    // GetWindowLongPtrW / SetWindowLongPtrW only exist on 64-bit user32.
    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")] private static extern IntPtr GetWindowLongPtr64(IntPtr h, int i);
    [DllImport("user32.dll", EntryPoint = "SetWindowLongPtrW")] private static extern IntPtr SetWindowLongPtr64(IntPtr h, int i, IntPtr v);
    [DllImport("user32.dll", EntryPoint = "GetWindowLongW")] private static extern int GetWindowLong32(IntPtr h, int i);
    [DllImport("user32.dll", EntryPoint = "SetWindowLongW")] private static extern int SetWindowLong32(IntPtr h, int i, int v);

    public static long GetStyle(IntPtr h, int index)
    {
        if (IntPtr.Size == 8) return GetWindowLongPtr64(h, index).ToInt64();
        return (long)(uint)GetWindowLong32(h, index);
    }

    public static void SetStyle(IntPtr h, int index, long value)
    {
        if (IntPtr.Size == 8) SetWindowLongPtr64(h, index, new IntPtr(value));
        else SetWindowLong32(h, index, unchecked((int)value));
    }

    // ---- DPI ----------------------------------------------------------
    // Without this the whole script reads virtualised coordinates on any
    // display scaled above 100 percent, and would place the window using
    // logical pixels while the game renders physical ones.
    [DllImport("user32.dll")] private static extern bool SetProcessDpiAwarenessContext(IntPtr ctx);
    [DllImport("shcore.dll")] private static extern int SetProcessDpiAwareness(int value);
    [DllImport("user32.dll")] private static extern bool SetProcessDPIAware();
    [DllImport("shcore.dll")] private static extern int GetProcessDpiAwareness(IntPtr hProcess, out int value);

    public static string MakeDpiAware()
    {
        // Awareness can only be set once per process, and every setter
        // reports failure the second time even though the process is
        // already aware. So set on a best-effort basis and then ask what
        // the process actually ended up with, rather than inferring it
        // from a return value that lies when we are hosted by a caller
        // that got there first.
        try { SetProcessDpiAwarenessContext(new IntPtr(-4)); } catch { }
        try { SetProcessDpiAwareness(2); } catch { }
        try { SetProcessDPIAware(); } catch { }

        try
        {
            int level;
            if (GetProcessDpiAwareness(IntPtr.Zero, out level) == 0)
            {
                if (level == 2) return "per-monitor";
                if (level == 1) return "system";
                return "unaware";
            }
        }
        catch { }
        return "unknown";
    }

    // ---- monitors -----------------------------------------------------
    public class Mon
    {
        public string Name;
        public bool Primary;
        public int X, Y, W, H;
        public IntPtr Handle;
    }

    public static List<Mon> GetMonitors()
    {
        List<Mon> found = new List<Mon>();
        MonitorEnumProc cb = delegate(IntPtr hMon, IntPtr hdc, ref RECT rect, IntPtr data)
        {
            MONITORINFOEX mi = new MONITORINFOEX();
            mi.cbSize = Marshal.SizeOf(typeof(MONITORINFOEX));
            if (GetMonitorInfoW(hMon, ref mi))
            {
                Mon m = new Mon();
                m.Name    = mi.szDevice;
                m.Primary = (mi.dwFlags & 1) != 0;
                // rcMonitor, NOT rcWork. rcWork is the desktop minus the
                // taskbar and is exactly the mistake this tool exists to fix.
                m.X = mi.rcMonitor.Left;
                m.Y = mi.rcMonitor.Top;
                m.W = mi.rcMonitor.Right - mi.rcMonitor.Left;
                m.H = mi.rcMonitor.Bottom - mi.rcMonitor.Top;
                m.Handle = hMon;
                found.Add(m);
            }
            return true;
        };
        EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, cb, IntPtr.Zero);
        // Stable order so the indices the mod stores keep meaning the same
        // screen between runs: primary first, then left to right, top down.
        found.Sort(delegate(Mon a, Mon b)
        {
            if (a.Primary != b.Primary) return a.Primary ? -1 : 1;
            if (a.X != b.X) return a.X.CompareTo(b.X);
            return a.Y.CompareTo(b.Y);
        });
        return found;
    }

    // ---- window discovery ---------------------------------------------
    public class Win
    {
        public IntPtr Handle;
        public uint Pid;
        public string Title;
        public string Class;
        public int W, H;
    }

    public static List<Win> FindWindows(uint[] pids)
    {
        List<Win> hits = new List<Win>();
        EnumWindowsProc cb = delegate(IntPtr h, IntPtr l)
        {
            if (!IsWindowVisible(h)) return true;
            uint pid;
            GetWindowThreadProcessId(h, out pid);
            bool match = false;
            for (int i = 0; i < pids.Length; i++) { if (pids[i] == pid) { match = true; break; } }
            if (!match) return true;

            RECT r;
            if (!GetWindowRect(h, out r)) return true;
            int w = r.Right - r.Left, hh = r.Bottom - r.Top;
            if (w < 200 || hh < 200) return true;   // splash and tool windows

            StringBuilder t = new StringBuilder(512);
            GetWindowTextW(h, t, 512);
            StringBuilder c = new StringBuilder(512);
            GetClassNameW(h, c, 512);

            Win win = new Win();
            win.Handle = h; win.Pid = pid;
            win.Title = t.ToString(); win.Class = c.ToString();
            win.W = w; win.H = hh;
            hits.Add(win);
            return true;
        };
        EnumWindows(cb, IntPtr.Zero);
        return hits;
    }
}
'@

if (-not ('TBNative' -as [type])) {
    Add-Type -TypeDefinition $nativeSource -Language CSharp
}
$script:DpiMode = [TBNative]::MakeDpiAware()

# ----------------------------------------------------------------------
# Files shared with the in-game mod
# ----------------------------------------------------------------------
# NOT the Zomboid folder itself. Project Zomboid's Lua getFileWriter and
# getFileReader resolve relative to Zomboid\Lua, so that is the only place
# the in-game half can read from or write to. Verified on 2026-08-20: the
# mod's files landed in Zomboid\Lua while this script was looking in the
# root, and the two halves never saw each other.
$script:LuaDir       = Join-Path $ZomboidPath 'Lua'
$script:PrefsFile    = Join-Path $script:LuaDir 'TrueBorderless.ini'
$script:MonitorsFile = Join-Path $script:LuaDir 'TrueBorderless_monitors.ini'
$script:RequestFile  = Join-Path $script:LuaDir 'TrueBorderless_request.ini'
$script:WinStateFile = Join-Path $script:LuaDir 'TrueBorderless_win.ini'

function Read-Ini {
    param([string] $Path)
    $out = @{}
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    foreach ($line in (Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue)) {
        $t = $line.Trim()
        if ($t -eq '' -or $t.StartsWith(';') -or $t.StartsWith('#')) { continue }
        $i = $t.IndexOf('=')
        if ($i -lt 1) { continue }
        $out[$t.Substring(0, $i).Trim()] = $t.Substring($i + 1).Trim()
    }
    return $out
}

function Write-Ini {
    param([string] $Path, [hashtable] $Data, [string[]] $Header)
    $sb = New-Object System.Text.StringBuilder
    if ($Header) {
        foreach ($h in $Header) { [void]$sb.AppendLine('; ' + $h) }
        [void]$sb.AppendLine('')
    }
    foreach ($k in ($Data.Keys | Sort-Object)) {
        [void]$sb.AppendLine(('{0}={1}' -f $k, $Data[$k]))
    }
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    # Written whole, never appended, so a reader never sees half a file.
    [System.IO.File]::WriteAllText($Path, $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))
}

function ConvertTo-Bool {
    param($Value, [bool] $Default = $false)
    if ($null -eq $Value) { return $Default }
    $s = ([string]$Value).Trim().ToLowerInvariant()
    if ($s -eq 'true' -or $s -eq '1' -or $s -eq 'yes' -or $s -eq 'on')  { return $true }
    if ($s -eq 'false' -or $s -eq '0' -or $s -eq 'no' -or $s -eq 'off') { return $false }
    return $Default
}

# First run: put a settings file on disk so both halves read the same value.
#
# The mod and this script share Zomboid\Lua\TrueBorderless.ini, and when it is
# missing each falls back to its own default - the mod to "native", because
# that is all a mod can do on its own, and this script to "true", because the
# only reason to have installed it is the overscan that "true" enables. Two
# different guesses about the same setting is a bug waiting to happen, so the
# first run settles it by writing the file down.
function Initialize-Prefs {
    if (Test-Path -LiteralPath $script:PrefsFile) { return $false }

    Write-Ini $script:PrefsFile @{
        enabled         = 'true'
        mode            = 'true'
        monitor         = 'auto'
        overscan        = '1'
        topmost         = 'false'
        reassertOnFocus = 'true'
        logLevel        = '2'
    } @(
        'True Borderless - shared settings.',
        'Read by the in-game mod and by TrueBorderless.ps1. Safe to edit by hand.',
        '',
        'mode     true   = the engine stays windowed and this script owns the',
        '                  window frame. Required for seamless alt-tab, and the',
        '                  only mode that works on a non-primary monitor.',
        '         native = use the engine own borderless flag. Works with no',
        '                  helper running, but Windows will still blink on',
        '                  alt-tab. This is what Workshop-only users get.',
        '         off    = leave the display alone.',
        'monitor  auto | primary | a 1-based index from TrueBorderless_monitors.ini',
        'overscan pixels the window hangs off each edge of the monitor, in mode',
        '         true. 1 is enough. This is the whole trick: a borderless window',
        '         whose rectangle matches a monitor EXACTLY gets promoted by',
        '         Windows onto the fullscreen presentation path, and then',
        '         alt-tab costs the same black frame as real fullscreen. One',
        '         pixel of overhang means it is not an exact match, so the',
        '         window stays composited and the switch is seamless. 0 turns',
        '         the trick off.'
    )
    Write-Host ("  wrote first-run settings to {0}" -f $script:PrefsFile) -ForegroundColor Green
    Write-Host '  mode=true, overscan=1  (seamless alt-tab)' -ForegroundColor DarkGray
    return $true
}

function Get-Prefs {
    $ini = Read-Ini $script:PrefsFile
    $p = @{
        enabled         = $true
        mode            = 'native'
        monitor         = 'auto'
        overscan        = 1
        topmost         = $false
        reassertOnFocus = $true
    }
    if ($ini) {
        $p.enabled         = ConvertTo-Bool $ini['enabled'] $true
        $p.topmost         = ConvertTo-Bool $ini['topmost'] $false
        $p.reassertOnFocus = ConvertTo-Bool $ini['reassertOnFocus'] $true
        if ($ini['mode'])    { $p.mode    = ([string]$ini['mode']).ToLowerInvariant() }
        if ($ini['monitor']) { $p.monitor = [string]$ini['monitor'] }
        $ov = 0
        if ($null -ne $ini['overscan'] -and [int]::TryParse([string]$ini['overscan'], [ref]$ov)) {
            $p.overscan = [Math]::Max(0, [Math]::Min(16, $ov))
        }
    }
    # The in-game toggle key writes here, and it wins over the stored prefs
    # only while it really is the more recent expression of intent. Without
    # the timestamp check a stale request file keeps overriding the settings
    # file forever, so editing the settings appears to do nothing.
    $req = $null
    if ((Test-Path -LiteralPath $script:RequestFile) -and (Test-Path -LiteralPath $script:PrefsFile)) {
        $rt = (Get-Item -LiteralPath $script:RequestFile).LastWriteTimeUtc
        $pt = (Get-Item -LiteralPath $script:PrefsFile).LastWriteTimeUtc
        if ($rt -ge $pt) { $req = Read-Ini $script:RequestFile }
    } elseif (Test-Path -LiteralPath $script:RequestFile) {
        $req = Read-Ini $script:RequestFile
    }
    if ($req -and $req['want']) {
        if (([string]$req['want']).ToLowerInvariant() -eq 'off') { $p.enabled = $false }
        if ($req['mode'])    { $p.mode    = ([string]$req['mode']).ToLowerInvariant() }
        if ($req['monitor']) { $p.monitor = [string]$req['monitor'] }
        $p.topmost = ConvertTo-Bool $req['topmost'] $p.topmost
    }
    return $p
}

# ----------------------------------------------------------------------
# Finding the game window
#
# Matched on the GLFW window class rather than the process name, because
# Project Zomboid may be started as ProjectZomboid64.exe or straight from
# java.exe via the .bat launchers, and in both cases LWJGL registers its
# window class as GLFW30.
# ----------------------------------------------------------------------
function Get-GameWindow {
    $names = @('ProjectZomboid64', 'ProjectZomboid', 'java', 'javaw') + $ProcessName
    $procs = Get-Process -Name $names -ErrorAction SilentlyContinue
    if (-not $procs) { return $null }

    # A dedicated server runs headless from the same java.exe; it has no
    # visible window, so it drops out here on its own.
    $pids = @()
    foreach ($p in $procs) { $pids += [uint32]$p.Id }

    $wins = [TBNative]::FindWindows([uint32[]]$pids)
    if (-not $wins -or $wins.Count -eq 0) { return $null }

    $best = $null
    foreach ($w in $wins) {
        $score = 0
        if ($w.Class -like 'GLFW*')            { $score += 100 }
        if ($w.Title -like '*Project Zomboid*') { $score += 50 }
        if ($w.Title -like '*Zomboid*')         { $score += 10 }
        $score += [math]::Min(20, [int](($w.W * $w.H) / 500000))
        if ($null -eq $best -or $score -gt $best.Score) {
            $best = [pscustomobject]@{ Win = $w; Score = $score }
        }
    }
    if ($null -eq $best -or $best.Score -lt 10) { return $null }
    return $best.Win
}

function Get-TargetMonitor {
    param($Window, $Prefs)
    $mons = [TBNative]::GetMonitors()
    if (-not $mons -or $mons.Count -eq 0) { return $null }

    $want = ([string]$Prefs.monitor).Trim()

    if ($want -eq 'auto') {
        # MONITOR_DEFAULTTONEAREST = 2
        $h = [TBNative]::MonitorFromWindow($Window.Handle, 2)
        foreach ($m in $mons) { if ($m.Handle -eq $h) { return $m } }
    }
    elseif ($want -eq 'primary') {
        foreach ($m in $mons) { if ($m.Primary) { return $m } }
    }
    else {
        $idx = 0
        if ([int]::TryParse($want, [ref]$idx)) {
            if ($idx -ge 1 -and $idx -le $mons.Count) { return $mons[$idx - 1] }
        }
        foreach ($m in $mons) { if ($m.Name -eq $want) { return $m } }
        Write-Host ("  ! monitor '{0}' not found, using primary" -f $want) -ForegroundColor Yellow
    }

    foreach ($m in $mons) { if ($m.Primary) { return $m } }
    return $mons[0]
}

function Publish-Monitors {
    param($Window, $Prefs)
    $mons = [TBNative]::GetMonitors()
    if (-not $Prefs) { $Prefs = Get-Prefs }
    $data = @{
        count = $mons.Count
        ts    = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
        dpi   = $script:DpiMode
    }
    $current = 0
    if ($Window) {
        $h = [TBNative]::MonitorFromWindow($Window.Handle, 2)
        for ($i = 0; $i -lt $mons.Count; $i++) {
            if ($mons[$i].Handle -eq $h) { $current = $i + 1 }
        }
    }
    $data['current'] = $current

    for ($i = 0; $i -lt $mons.Count; $i++) {
        $m = $mons[$i]
        $n = $i + 1
        $data["$n.name"]    = $m.Name
        $data["$n.primary"] = $m.Primary.ToString().ToLowerInvariant()
        $data["$n.x"] = $m.X
        $data["$n.y"] = $m.Y
        $data["$n.w"] = $m.W
        $data["$n.h"] = $m.H
    }

    # The exact rectangle the window must occupy, overscan included. The
    # mod renders at target.w x target.h and this script positions the
    # window at target.x, target.y, so there is exactly one place where
    # that arithmetic happens and the two halves cannot disagree.
    if ($current -ge 1) {
        $tm = $mons[$current - 1]
        $rect = Get-TargetRect $tm $Prefs
        $data['target.x'] = $rect.X
        $data['target.y'] = $rect.Y
        $data['target.w'] = $rect.W
        $data['target.h'] = $rect.H
        $data['target.overscan'] = $rect.Overscan
        $data['target.monitor'] = $tm.Name
    }

    Write-Ini $script:MonitorsFile $data @(
        'Desktop layout published by TrueBorderless.ps1 for the in-game mod.',
        'Rectangles are full monitor bounds, not the taskbar work area.',
        'target.* is the exact window rectangle the mod should render at.',
        'Rewritten while the enforcer runs; ts doubles as its heartbeat.'
    )
    return $mons
}

# ----------------------------------------------------------------------
# The actual fix
# ----------------------------------------------------------------------
function Save-WindowState {
    param($Window)
    $existing = Read-Ini $script:WinStateFile
    if ($existing) {
        $samePid  = ([string]$existing['pid']  -eq [string]$Window.Pid)
        $sameHwnd = ([string]$existing['hwnd'] -eq [string]$Window.Handle.ToInt64())
        # Already captured for this window. Never overwrite, or the "original"
        # frame we save would be the borderless one we just applied.
        if ($samePid -and $sameHwnd) { return }
    }
    $r = New-Object TBNative+RECT
    [void][TBNative]::GetWindowRect($Window.Handle, [ref]$r)
    Write-Ini $script:WinStateFile @{
        pid     = $Window.Pid
        hwnd    = $Window.Handle.ToInt64()
        style   = [TBNative]::GetStyle($Window.Handle, [TBNative]::GWL_STYLE)
        exstyle = [TBNative]::GetStyle($Window.Handle, [TBNative]::GWL_EXSTYLE)
        x = $r.Left; y = $r.Top; w = ($r.Right - $r.Left); h = ($r.Bottom - $r.Top)
    } @('Original window frame, captured before TrueBorderless touched it.')
}

# The rectangle we actually want the window to occupy.
# In mode "true" it is the monitor grown by `overscan` on every side, so
# that Windows never promotes the window to a fullscreen presentation
# path. In mode "native" the engine owns the geometry and we only match
# the monitor exactly.
function Get-TargetRect {
    param($Monitor, $Prefs)
    $ov = 0
    if ($Prefs.mode -ne 'native') { $ov = [int]$Prefs.overscan }
    return [pscustomobject]@{
        X = $Monitor.X - $ov
        Y = $Monitor.Y - $ov
        W = $Monitor.W + 2 * $ov
        H = $Monitor.H + 2 * $ov
        Overscan = $ov
    }
}

function Test-AlreadyBorderless {
    param($Window, $Monitor, $Prefs)
    $style = [TBNative]::GetStyle($Window.Handle, [TBNative]::GWL_STYLE)
    $decorated = ($style -band ([TBNative]::WS_CAPTION -bor [TBNative]::WS_THICKFRAME)) -ne 0
    if ($decorated) { return $false }

    $want = Get-TargetRect $Monitor $Prefs
    $r = New-Object TBNative+RECT
    if (-not [TBNative]::GetWindowRect($Window.Handle, [ref]$r)) { return $false }
    return ($r.Left -eq $want.X -and $r.Top -eq $want.Y -and
            ($r.Right - $r.Left) -eq $want.W -and ($r.Bottom - $r.Top) -eq $want.H)
}

function Set-Borderless {
    param($Window, $Monitor, $Prefs, [switch] $Quiet)

    if ([TBNative]::IsIconic($Window.Handle)) {
        [void][TBNative]::ShowWindow($Window.Handle, [TBNative]::SW_RESTORE)
    }

    # The client area must already be the monitor's size. Stripping the
    # frame while setting the window rect to the monitor rect leaves the
    # client exactly as many pixels as it was, which is the whole reason
    # this is free. Resizing it instead would desync the GL viewport,
    # because the game never reads Display.wasResized().
    $want = Get-TargetRect $Monitor $Prefs

    $c = New-Object TBNative+RECT
    [void][TBNative]::GetClientRect($Window.Handle, [ref]$c)
    $cw = $c.Right - $c.Left
    $ch = $c.Bottom - $c.Top

    if (($cw -ne $want.W -or $ch -ne $want.H) -and -not $Force) {
        if (-not $Quiet) {
            Write-Host ("  ! client is {0}x{1} but the target rect is {2}x{3}" -f $cw, $ch, $want.W, $want.H) -ForegroundColor Yellow
            if ($want.Overscan -gt 0) {
                Write-Host ("    That is {0} plus {1}px of overscan on each side, which is what" -f $Monitor.Name, $want.Overscan) -ForegroundColor Yellow
                Write-Host "    stops Windows treating the window as fullscreen." -ForegroundColor Yellow
            }
            Write-Host "    Set the game's resolution to match (the in-game mod does this" -ForegroundColor Yellow
            Write-Host "    automatically), or re-run with -Force to accept a stretched image." -ForegroundColor Yellow
        }
        return $false
    }

    Save-WindowState $Window

    $style = [TBNative]::GetStyle($Window.Handle, [TBNative]::GWL_STYLE)
    $style = $style -band (-bnot ([TBNative]::WS_CAPTION -bor [TBNative]::WS_THICKFRAME -bor
                                  [TBNative]::WS_MINIMIZEBOX -bor [TBNative]::WS_MAXIMIZEBOX -bor
                                  [TBNative]::WS_SYSMENU -bor [TBNative]::WS_BORDER -bor
                                  [TBNative]::WS_DLGFRAME))
    $style = $style -bor [TBNative]::WS_POPUP -bor [TBNative]::WS_VISIBLE

    $ex = [TBNative]::GetStyle($Window.Handle, [TBNative]::GWL_EXSTYLE)
    $ex = $ex -band (-bnot ([TBNative]::WS_EX_DLGMODALFRAME -bor [TBNative]::WS_EX_CLIENTEDGE -bor
                            [TBNative]::WS_EX_WINDOWEDGE -bor [TBNative]::WS_EX_STATICEDGE))

    [TBNative]::SetStyle($Window.Handle, [TBNative]::GWL_STYLE, $style)
    [TBNative]::SetStyle($Window.Handle, [TBNative]::GWL_EXSTYLE, $ex)

    $after = [TBNative]::HWND_TOP
    if ($Prefs.topmost) { $after = [TBNative]::HWND_TOPMOST }

    $flags = [TBNative]::SWP_FRAMECHANGED -bor [TBNative]::SWP_SHOWWINDOW -bor [TBNative]::SWP_NOOWNERZORDER
    [void][TBNative]::SetWindowPos($Window.Handle, $after,
        $want.X, $want.Y, $want.W, $want.H, $flags)

    if (-not $Quiet) {
        $note = ''
        if ($want.Overscan -gt 0) { $note = (' (+{0}px overscan, never promoted to fullscreen)' -f $want.Overscan) }
        Write-Host ("  + {0} -> {1} at {2},{3} {4}x{5}{6}" -f $Window.Class, $Monitor.Name, $want.X, $want.Y, $want.W, $want.H, $note) -ForegroundColor Green
    }
    return $true
}

function Restore-Window {
    $state = Read-Ini $script:WinStateFile
    if (-not $state) {
        Write-Host '  nothing saved, nothing to restore' -ForegroundColor Yellow
        return $false
    }

    $hwnd = [IntPtr][int64]$state['hwnd']
    if (-not [TBNative]::IsWindow($hwnd)) {
        Write-Host '  the saved window is gone; the game was restarted' -ForegroundColor Yellow
        Remove-Item -LiteralPath $script:WinStateFile -Force -ErrorAction SilentlyContinue
        return $false
    }

    [TBNative]::SetStyle($hwnd, [TBNative]::GWL_STYLE,   [int64]$state['style'])
    [TBNative]::SetStyle($hwnd, [TBNative]::GWL_EXSTYLE, [int64]$state['exstyle'])
    $flags = [TBNative]::SWP_FRAMECHANGED -bor [TBNative]::SWP_SHOWWINDOW -bor [TBNative]::SWP_NOOWNERZORDER
    [void][TBNative]::SetWindowPos($hwnd, [TBNative]::HWND_NOTOPMOST,
        [int]$state['x'], [int]$state['y'], [int]$state['w'], [int]$state['h'], $flags)

    Remove-Item -LiteralPath $script:WinStateFile -Force -ErrorAction SilentlyContinue
    Write-Host '  original window frame restored' -ForegroundColor Green
    return $true
}

# ----------------------------------------------------------------------
# Boot state
#
# Project Zomboid B42 does NOT load mod Lua at the main menu - a full
# boot-to-menu console.txt contains no mod loading at all, not even for
# mods listed in mods\default.txt. Mod Lua is loaded when a world is
# started or joined. So the in-game half of TrueBorderless cannot be what
# puts the engine into the right display state at startup; by the time it
# runs you are already looking at the game.
#
# The state the game boots into therefore has to come from options.ini,
# written before the process starts. That is what this does.
# ----------------------------------------------------------------------
# options.ini really is in the Zomboid root; the baseline is written by the
# in-game half and therefore lives with the rest of its files, in Lua.
$script:OptionsFile  = Join-Path $ZomboidPath 'options.ini'
$script:BaselineFile = Join-Path $script:LuaDir 'TrueBorderless_baseline.ini'

function Get-OptionsValue {
    param([string[]] $Lines, [string] $Key)
    foreach ($l in $Lines) {
        if ($l -like ($Key + '=*')) { return $l.Substring($Key.Length + 1).Trim() }
    }
    return $null
}

function Set-BootState {
    # PZ rewrites options.ini when it exits, so editing it under a running
    # game is pointless at best and destructive at worst.
    if (Get-GameWindow) {
        Write-Host '  ! Project Zomboid is running. Close it first, or use -Mode Apply' -ForegroundColor Yellow
        return $false
    }
    if (-not (Test-Path -LiteralPath $script:OptionsFile)) {
        Write-Host ("  ! options.ini not found at {0}" -f $script:OptionsFile) -ForegroundColor Yellow
        return $false
    }

    $prefs = Get-Prefs
    if (-not $prefs.enabled -or $prefs.mode -eq 'off') {
        Write-Host '  disabled in TrueBorderless.ini; leaving options.ini alone' -ForegroundColor DarkGray
        return $false
    }

    $mons = [TBNative]::GetMonitors()
    $mon = $null
    $want = ([string]$prefs.monitor).Trim()
    if ($want -ne 'auto' -and $want -ne 'primary') {
        $idx = 0
        if ([int]::TryParse($want, [ref]$idx) -and $idx -ge 1 -and $idx -le $mons.Count) {
            $mon = $mons[$idx - 1]
        }
    }
    if (-not $mon) {
        # "auto" means "the monitor the window is on", and there is no
        # window yet, so at boot time it can only mean the primary one.
        foreach ($m in $mons) { if ($m.Primary) { $mon = $m; break } }
    }
    if (-not $mon) { $mon = $mons[0] }

    $lines = @(Get-Content -LiteralPath $script:OptionsFile)

    # Capture the player's real settings once, before we have ever touched
    # them. The in-game mod reads the same file and will not overwrite it,
    # so "restore what I had" keeps meaning the right thing forever.
    if (-not (Test-Path -LiteralPath $script:BaselineFile)) {
        Write-Ini $script:BaselineFile @{
            fullScreen = (Get-OptionsValue $lines 'fullScreen')
            borderless = (Get-OptionsValue $lines 'borderless')
            width      = (Get-OptionsValue $lines 'width')
            height     = (Get-OptionsValue $lines 'height')
        } @(
            'Display settings as TrueBorderless first found them.',
            'Written once and never updated. Delete this file to re-capture.'
        )
        Write-Host '  baseline captured from options.ini' -ForegroundColor DarkGray
    }

    # A one-off safety copy next to the file itself, for people who never
    # read the README.
    $backup = $script:OptionsFile + '.trueborderless-backup'
    if (-not (Test-Path -LiteralPath $backup)) {
        Copy-Item -LiteralPath $script:OptionsFile -Destination $backup -Force
    }

    # In mode "true" the borderless flag must be OFF, or the engine throws
    # away the resolution we are setting here and rebuilds the window from
    # the primary monitor. See README-TrueBorderless.md.
    # In mode "true" the engine must render at the overscanned size, or the
    # client area will not match the rectangle the enforcer puts the window
    # in and the picture would be letterboxed.
    $rect = Get-TargetRect $mon $prefs
    $wanted = @{
        fullScreen = 'false'
        borderless = $(if ($prefs.mode -eq 'native') { 'true' } else { 'false' })
        width      = [string]$rect.W
        height     = [string]$rect.H
    }

    $changed = @()
    $out = New-Object System.Collections.ArrayList
    foreach ($l in $lines) {
        $replaced = $false
        foreach ($k in $wanted.Keys) {
            if ($l -like ($k + '=*')) {
                $old = $l.Substring($k.Length + 1).Trim()
                if ($old -ne $wanted[$k]) { $changed += ('{0}: {1} -> {2}' -f $k, $old, $wanted[$k]) }
                [void]$out.Add(($k + '=' + $wanted[$k]))
                $replaced = $true
                break
            }
        }
        if (-not $replaced) { [void]$out.Add($l) }
    }

    [System.IO.File]::WriteAllLines($script:OptionsFile, $out.ToArray(),
        (New-Object System.Text.UTF8Encoding($false)))

    if ($changed.Count -eq 0) {
        Write-Host ("  options.ini already correct for {0} ({1}x{2})" -f $mon.Name, $mon.W, $mon.H) -ForegroundColor DarkGray
    } else {
        Write-Host ("  options.ini prepared for {0} ({1}x{2})" -f $mon.Name, $mon.W, $mon.H) -ForegroundColor Green
        foreach ($c in $changed) { Write-Host ('    ' + $c) -ForegroundColor DarkGray }
    }

    if ($prefs.mode -ne 'native') {
        # In this mode borderless has to be off so the engine honours the
        # width and height set above, which makes the window frame this
        # script's problem. If nothing strips it, the game boots as an
        # ordinary titlebarred window overhanging the screen.
        Write-Host '  note: mode is "true", so the game boots as a plain window and' -ForegroundColor DarkGray
        Write-Host '        this script strips the frame once it appears. Launch through' -ForegroundColor DarkGray
        Write-Host '        the Steam launch option and that happens by itself.' -ForegroundColor DarkGray
    }
    return $true
}

function Reset-BootState {
    # Puts options.ini back to the display settings captured in the
    # baseline, i.e. what the player had before TrueBorderless existed.
    if (Get-GameWindow) {
        Write-Host '  ! Project Zomboid is running. Close it first.' -ForegroundColor Yellow
        return $false
    }
    $base = Read-Ini $script:BaselineFile
    if (-not $base) {
        Write-Host '  ! no baseline on disk, nothing to revert to' -ForegroundColor Yellow
        return $false
    }
    if (-not (Test-Path -LiteralPath $script:OptionsFile)) {
        Write-Host '  ! options.ini not found' -ForegroundColor Yellow
        return $false
    }

    $wanted = @{
        fullScreen = [string]$base['fullScreen']
        borderless = [string]$base['borderless']
        width      = [string]$base['width']
        height     = [string]$base['height']
    }

    $lines = @(Get-Content -LiteralPath $script:OptionsFile)
    $changed = @()
    $out = New-Object System.Collections.ArrayList
    foreach ($l in $lines) {
        $replaced = $false
        foreach ($k in $wanted.Keys) {
            if ($l -like ($k + '=*')) {
                $old = $l.Substring($k.Length + 1).Trim()
                if ($old -ne $wanted[$k]) { $changed += ('{0}: {1} -> {2}' -f $k, $old, $wanted[$k]) }
                [void]$out.Add(($k + '=' + $wanted[$k]))
                $replaced = $true
                break
            }
        }
        if (-not $replaced) { [void]$out.Add($l) }
    }
    [System.IO.File]::WriteAllLines($script:OptionsFile, $out.ToArray(),
        (New-Object System.Text.UTF8Encoding($false)))

    if ($changed.Count -eq 0) {
        Write-Host '  options.ini already matches your baseline' -ForegroundColor DarkGray
    } else {
        Write-Host '  options.ini reverted to your baseline' -ForegroundColor Green
        foreach ($c in $changed) { Write-Host ('    ' + $c) -ForegroundColor DarkGray }
    }
    return $true
}

# ----------------------------------------------------------------------
# Seamless alt-tab
#
# The one-second black on alt-tab is the monitor resynchronising, and it
# has exactly two causes on this setup. Measured on 2026-08-20 by sampling
# the display mode and the window state 20 times a second across a forced
# focus change:
#
#   1. EXCLUSIVE FULLSCREEN. GLFW leaves GLFW_AUTO_ICONIFY at its default,
#      which is on, so a fullscreen window MINIMISES the instant it loses
#      focus and hands the display back to the desktop. Measured: the
#      window was iconic in 91 of 91 samples. Coming back re-acquires the
#      exclusive mode. That is a resync in each direction.
#      Fix: never be in exclusive fullscreen. That is what the mod does.
#
#   2. FULLSCREEN OPTIMIZATIONS. Windows gives a borderless window that
#      covers a monitor a flip-model presentation path, and moves it in
#      and out of that path as focus changes. The transition can blank a
#      frame. Fix: this function, which tells Windows to keep the window
#      composited like any other window, always.
#
# Note that neither black can be photographed: CopyFromScreen reads the
# desktop composition, which stays perfectly valid while the physical
# panel is dark. The window state and the display mode are the only
# reliable evidence, which is why they are what gets measured.
# ----------------------------------------------------------------------
$script:LayersKey = 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers'
$script:FsoFlag   = 'DISABLEDXMAXIMIZEDWINDOWEDMODE'

# Where Project Zomboid actually lives.
#
# A hardcoded path is how a tool that works on its author's machine stops
# working on everybody else's, so this asks the three sources that actually
# know, cheapest first, and caches the answer:
#
#   1. -GamePath, which is what the Steam wrapper passes in. Steam
#      substitutes the full executable path into %command%, so the wrapper
#      knows the install folder for certain before the game even starts.
#   2. A running ProjectZomboid64.exe. Nothing is more authoritative than
#      the process itself.
#   3. Steam's library index. libraryfolders.vdf lists every drive Steam
#      installs to, which is the entire reason that file exists.
function Resolve-GamePath {
    if ($script:ResolvedGamePath) { return $script:ResolvedGamePath }

    $candidates = @()

    if ($GamePath) { $candidates += $GamePath }

    $proc = Get-Process -Name ProjectZomboid64 -ErrorAction SilentlyContinue |
            Select-Object -First 1
    if ($proc) {
        try { $candidates += (Split-Path -Parent $proc.MainModule.FileName) } catch { }
    }

    $steam = $null
    foreach ($key in @('HKCU:\Software\Valve\Steam',
                       'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam',
                       'HKLM:\SOFTWARE\Valve\Steam')) {
        try {
            $v = Get-ItemProperty -LiteralPath $key -ErrorAction Stop
            if ($v.SteamPath)   { $steam = $v.SteamPath;   break }
            if ($v.InstallPath) { $steam = $v.InstallPath; break }
        } catch { }
    }

    if ($steam) {
        $steam = $steam.Replace('/', '\')
        $libs  = @($steam)
        $vdf   = Join-Path $steam 'steamapps\libraryfolders.vdf'
        if (Test-Path -LiteralPath $vdf) {
            # Valve's own key/value format. Only the "path" entries matter
            # here, and a regex over those is far less fragile than trying
            # to parse the whole grammar.
            $raw = Get-Content -LiteralPath $vdf -Raw
            foreach ($m in [regex]::Matches($raw, '"path"\s*"([^"]+)"')) {
                $libs += $m.Groups[1].Value.Replace('\\', '\')
            }
        }
        foreach ($lib in $libs) {
            $candidates += (Join-Path $lib 'steamapps\common\ProjectZomboid')
        }
    }

    foreach ($c in $candidates) {
        if ($c -and (Test-Path -LiteralPath (Join-Path $c 'ProjectZomboid64.exe'))) {
            $script:ResolvedGamePath = $c
            return $c
        }
    }
    return $null
}

function Get-GameExecutables {
    $root = Resolve-GamePath
    if (-not $root) { return @() }

    $list = @()
    foreach ($rel in @('ProjectZomboid64.exe', 'jre64\bin\java.exe', 'jre64\bin\javaw.exe')) {
        $p = Join-Path $root $rel
        if (Test-Path -LiteralPath $p) { $list += $p }
    }
    return $list
}

function Set-Seamless {
    param([switch] $Undo)

    $exes = Get-GameExecutables
    if ($exes.Count -eq 0) {
        Write-Host '  ! could not find the Project Zomboid install folder.' -ForegroundColor Yellow
        Write-Host '    Point at it by hand, e.g.' -ForegroundColor DarkGray
        Write-Host '      -GamePath "D:\SteamLibrary\steamapps\common\ProjectZomboid"' -ForegroundColor DarkGray
        return $false
    }
    if (-not (Test-Path -LiteralPath $script:LayersKey)) {
        New-Item -Path $script:LayersKey -Force | Out-Null
    }

    foreach ($exe in $exes) {
        $current = ''
        try {
            $current = [string](Get-ItemProperty -LiteralPath $script:LayersKey -Name $exe -ErrorAction Stop).$exe
        } catch { $current = '' }

        # The value is a space separated list of compatibility layers that
        # always starts with "~". Other tools write here too, so edit the
        # list rather than replacing it.
        $parts = @()
        if ($current) { $parts = $current.Split(' ') | Where-Object { $_ -ne '' -and $_ -ne '~' } }
        $parts = $parts | Where-Object { $_ -ne $script:FsoFlag }
        if (-not $Undo) { $parts = @($script:FsoFlag) + $parts }

        if ($parts.Count -eq 0) {
            Remove-ItemProperty -LiteralPath $script:LayersKey -Name $exe -ErrorAction SilentlyContinue
            Write-Host ("  - cleared  {0}" -f (Split-Path -Leaf $exe)) -ForegroundColor DarkGray
        } else {
            $value = '~ ' + ($parts -join ' ')
            New-ItemProperty -LiteralPath $script:LayersKey -Name $exe -Value $value -PropertyType String -Force | Out-Null
            Write-Host ("  {0} {1}  ->  {2}" -f $(if ($Undo) { '-' } else { '+' }), (Split-Path -Leaf $exe), $value) -ForegroundColor $(if ($Undo) { 'DarkGray' } else { 'Green' })
        }
    }

    Write-Host ''
    if ($Undo) {
        Write-Host '  Fullscreen Optimizations back to the Windows default.' -ForegroundColor DarkGray
    } else {
        Write-Host '  Fullscreen Optimizations disabled for the game.' -ForegroundColor Green
        Write-Host '  Takes effect the next time the game starts.' -ForegroundColor DarkGray
    }
    return $true
}

function Test-Seamless {
    Write-Host ''
    Write-Host '  === seamless checklist ===' -ForegroundColor Cyan

    $problems = 0

    $opts = @{}
    if (Test-Path -LiteralPath $script:OptionsFile) {
        foreach ($line in (Get-Content -LiteralPath $script:OptionsFile)) {
            $i = $line.IndexOf('=')
            if ($i -gt 0) { $opts[$line.Substring(0, $i).Trim()] = $line.Substring($i + 1).Trim() }
        }
    }

    $fs = ConvertTo-Bool $opts['fullScreen'] $false
    if ($fs) {
        Write-Host '    FAIL  options.ini has fullScreen=true' -ForegroundColor Red
        Write-Host '          Exclusive fullscreen minimises on focus loss. That IS the black flash.' -ForegroundColor Red
        $problems++
    } else {
        Write-Host '    ok    not exclusive fullscreen' -ForegroundColor Green
    }

    $bl = ConvertTo-Bool $opts['borderless'] $false
    $prefs = Get-Prefs
    if ($prefs.mode -eq 'native' -and -not $bl) {
        Write-Host '    warn  borderless=false with mode=native; run -Mode Prepare' -ForegroundColor Yellow
    } else {
        Write-Host '    ok    borderless window' -ForegroundColor Green
    }

    foreach ($exe in (Get-GameExecutables)) {
        $v = ''
        try { $v = [string](Get-ItemProperty -LiteralPath $script:LayersKey -Name $exe -ErrorAction Stop).$exe } catch { $v = '' }
        if ($v -like ('*' + $script:FsoFlag + '*')) {
            Write-Host ('    ok    Fullscreen Optimizations off for {0}' -f (Split-Path -Leaf $exe)) -ForegroundColor Green
        } else {
            Write-Host ('    warn  Fullscreen Optimizations still on for {0}' -f (Split-Path -Leaf $exe)) -ForegroundColor Yellow
            $problems++
        }
    }

    $w = Get-GameWindow
    if ($w) {
        $style = [TBNative]::GetStyle($w.Handle, [TBNative]::GWL_STYLE)
        $dec = ($style -band ([TBNative]::WS_CAPTION -bor [TBNative]::WS_THICKFRAME)) -ne 0
        if ($dec) { Write-Host '    FAIL  the running window still has a frame' -ForegroundColor Red; $problems++ }
        else { Write-Host '    ok    running window has no frame' -ForegroundColor Green }
        if ([TBNative]::IsIconic($w.Handle)) {
            Write-Host '    FAIL  the running window is minimised' -ForegroundColor Red
            $problems++
        }
    } else {
        Write-Host '    --    game not running, skipped the live checks' -ForegroundColor DarkGray
    }

    Write-Host ''
    if ($problems -eq 0) { Write-Host '  nothing left that can make the monitor resync.' -ForegroundColor Green }
    else { Write-Host ("  {0} thing(s) can still cause a flash." -f $problems) -ForegroundColor Yellow }
    return ($problems -eq 0)
}

# ----------------------------------------------------------------------
# Modes
# ----------------------------------------------------------------------
function Show-Banner {
    Write-Host ''
    Write-Host '  TrueBorderless - real borderless fullscreen for Project Zomboid B42' -ForegroundColor Cyan
    Write-Host ("  dpi awareness: {0}   zomboid folder: {1}" -f $script:DpiMode, $ZomboidPath) -ForegroundColor DarkGray
    Write-Host ''
}

function Show-Monitors {
    $mons = Publish-Monitors (Get-GameWindow)
    Write-Host '  Monitors (full bounds, taskbar included):' -ForegroundColor Cyan
    for ($i = 0; $i -lt $mons.Count; $i++) {
        $m = $mons[$i]
        $tag = ''
        if ($m.Primary) { $tag = '  (primary)' }
        Write-Host ("    {0}. {1,-14} {2,5}x{3,-5} at {4},{5}{6}" -f ($i + 1), $m.Name, $m.W, $m.H, $m.X, $m.Y, $tag)
    }
    Write-Host ''
    Write-Host ("  published to {0}" -f $script:MonitorsFile) -ForegroundColor DarkGray
}

function Show-Status {
    Show-Monitors
    Write-Host ''
    $w = Get-GameWindow
    if (-not $w) {
        Write-Host '  Project Zomboid is not running.' -ForegroundColor Yellow
        return
    }
    $p = Get-Prefs
    $r = New-Object TBNative+RECT
    [void][TBNative]::GetWindowRect($w.Handle, [ref]$r)
    $c = New-Object TBNative+RECT
    [void][TBNative]::GetClientRect($w.Handle, [ref]$c)
    $style = [TBNative]::GetStyle($w.Handle, [TBNative]::GWL_STYLE)
    $decorated = ($style -band ([TBNative]::WS_CAPTION -bor [TBNative]::WS_THICKFRAME)) -ne 0
    $mon = Get-TargetMonitor $w $p

    Write-Host '  Game window:' -ForegroundColor Cyan
    Write-Host ("    pid {0}  class {1}" -f $w.Pid, $w.Class)
    Write-Host ("    title      {0}" -f $w.Title)
    Write-Host ("    window     {0},{1}  {2}x{3}" -f $r.Left, $r.Top, ($r.Right - $r.Left), ($r.Bottom - $r.Top))
    Write-Host ("    client     {0}x{1}" -f ($c.Right - $c.Left), ($c.Bottom - $c.Top))
    Write-Host ("    style      0x{0:X8}   decorated: {1}" -f $style, $decorated)
    Write-Host ''
    Write-Host '  Settings:' -ForegroundColor Cyan
    Write-Host ("    enabled {0}   mode {1}   monitor {2}   topmost {3}" -f $p.enabled, $p.mode, $p.monitor, $p.topmost)
    if ($mon) {
        Write-Host ("    target  {0}  {1}x{2} at {3},{4}" -f $mon.Name, $mon.W, $mon.H, $mon.X, $mon.Y)
        if (Test-AlreadyBorderless $w $mon $p) {
            Write-Host '    state   REAL BORDERLESS - window covers the monitor exactly' -ForegroundColor Green
        } else {
            Write-Host '    state   not applied' -ForegroundColor Yellow
        }
    }
}

function Start-Watch {
    Show-Banner
    [void](Initialize-Prefs)
    Write-Host '  Watching. Ctrl+C to stop; the window keeps its frame either way.' -ForegroundColor DarkGray
    Write-Host ''

    $deadline = $null
    if ($WaitSeconds -gt 0) { $deadline = (Get-Date).AddSeconds($WaitSeconds) }

    $announced   = $false
    $lastPublish = [DateTime]::MinValue
    $lastRequest = ''
    $wasEnabled  = $null

    while ($true) {
        $w = Get-GameWindow

        if (-not $w) {
            if ($announced) {
                Write-Host '  game closed.' -ForegroundColor DarkGray
                # The saved frame belongs to a window that no longer exists.
                # Leaving it behind would make a later -Mode Restore chase a
                # dead handle.
                Remove-Item -LiteralPath $script:WinStateFile -Force -ErrorAction SilentlyContinue
                break
            }
            if ($deadline -and (Get-Date) -gt $deadline) {
                Write-Host '  gave up waiting for Project Zomboid.' -ForegroundColor Yellow
                break
            }
            Start-Sleep -Milliseconds 1000
            continue
        }

        if (-not $announced) {
            $announced = $true
            Write-Host ("  found the game window (pid {0}, class {1})" -f $w.Pid, $w.Class) -ForegroundColor Green
        }

        $prefs = Get-Prefs

        # Republish the desktop layout every few seconds. This is also the
        # heartbeat the mod reads to know the enforcer is alive.
        #
        # Read the prefs FIRST. This publish used to sit above that line, so
        # the very first file the mod ever read was written with $prefs still
        # null - that is, without the overscan - and the mod could boot off it
        # before the three second republish corrected it.
        if (((Get-Date) - $lastPublish).TotalSeconds -ge 3) {
            [void](Publish-Monitors $w $prefs)
            $lastPublish = Get-Date
        }

        # React to the in-game toggle key without polling the file's content
        # on every pass.
        $stamp = ''
        if (Test-Path -LiteralPath $script:RequestFile) {
            $stamp = (Get-Item -LiteralPath $script:RequestFile).LastWriteTimeUtc.Ticks.ToString()
        }
        if ($stamp -ne $lastRequest) {
            $lastRequest = $stamp
            if ($null -ne $wasEnabled -and $wasEnabled -ne $prefs.enabled) {
                if ($prefs.enabled) { Write-Host '  toggled on from inside the game' -ForegroundColor Green }
                else                { Write-Host '  toggled off from inside the game' -ForegroundColor Yellow }
            }
        }

        if ($prefs.enabled -and $prefs.mode -ne 'off') {
            $mon = Get-TargetMonitor $w $prefs
            if ($mon -and -not (Test-AlreadyBorderless $w $mon $prefs)) {
                # Only act when the window actually drifted. In the steady
                # state this loop is two user32 calls and nothing else.
                [void](Set-Borderless $w $mon $prefs)
            }
        }
        elseif ($null -ne $wasEnabled -and $wasEnabled) {
            [void](Restore-Window)
        }

        $wasEnabled = $prefs.enabled
        Start-Sleep -Milliseconds $IntervalMs
    }
}

# ----------------------------------------------------------------------
switch ($Mode) {
    'Monitors' { Show-Banner; Show-Monitors }
    'Status'   { Show-Banner; Show-Status; [void](Test-Seamless) }
    'Prepare'  { Show-Banner; [void](Set-BootState) }
    'Revert'   { Show-Banner; [void](Reset-BootState) }
    'Seamless' {
        Show-Banner
        [void](Initialize-Prefs)
        [void](Set-BootState)
        Write-Host ''
        [void](Set-Seamless)
        [void](Test-Seamless)
    }
    'SeamlessUndo' {
        Show-Banner
        [void](Set-Seamless -Undo)
    }
    'Restore'  {
        Show-Banner
        [void](Restore-Window)
    }
    'Apply' {
        Show-Banner
        $w = Get-GameWindow
        if (-not $w) {
            Write-Host '  Project Zomboid is not running.' -ForegroundColor Yellow
        } else {
            [void](Publish-Monitors $w)
            $p = Get-Prefs
            $mon = Get-TargetMonitor $w $p
            if ($mon) { [void](Set-Borderless $w $mon $p) }
        }
    }
    'Watch' { Start-Watch }
}
