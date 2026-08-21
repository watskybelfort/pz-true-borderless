--[[ ============================================================
     TrueBorderless - Display state machine

     Everything this file knows about the engine was read out of
     zombie.core.Core and org.lwjglx.opengl.Display in B42.20.3, so the
     reasoning is written down next to the code that depends on it.

     What vanilla borderless actually does
     -------------------------------------
     Core.setDisplayModeInternal(w, h, fullscreen) branches on the
     borderless option.  When borderless is on and fullscreen is off it
     throws away the w/h it was handed and builds the mode from
     glfwGetVideoMode(glfwGetPrimaryMonitor()).  Three consequences:

       1. The size always comes from the primary monitor, whichever
          monitor the window is actually on.
       2. Display.getAvailableDisplayModes() enumerates the primary
          monitor too, so the resolution list is wrong on any other
          screen and the engine cannot even name a portrait mode.
       3. Display.calcWindowPos then positions the window at
          (desktopWidth - windowWidth) / 2, which is an offset inside
          the primary monitor, not a point on the virtual desktop.  It
          only lands on zero because the primary monitor happens to
          start at the desktop origin.

     There is a fourth trap.  setDisplayModeAndFullscreenInternal
     returns early when the fullscreen flag did not change and the new
     DisplayMode equals the old one.  Toggling only the borderless
     checkbox satisfies both conditions, so the frame is removed and the
     window is never repositioned.  That is the "it did nothing" case.

     How this mod avoids all four
     ----------------------------
     In mode "true" we never ask the engine to be borderless.  We ask it
     to be an ordinary window whose CLIENT area is already exactly the
     target monitor's pixel size.  The engine resizes itself through its
     own path, so the GL viewport and Core.width/height stay correct.
     The Windows-side enforcer then strips the frame and moves the
     window onto the monitor origin.  Stripping WS_CAPTION/WS_THICKFRAME
     while setting the window rectangle to the monitor rectangle leaves
     the client area the same number of pixels it already was, so the
     framebuffer never changes size and the renderer never notices.

     That last point is why this costs nothing.  Nothing in zombie/*
     calls Display.wasResized(), so the engine would NOT recover from a
     framebuffer size change forced on it from outside - which is
     exactly why the enforcer is only ever allowed to move the window,
     never to resize it into a size the engine does not already hold.
     ============================================================ ]]

TrueBorderless = TrueBorderless or {}
local TB = TrueBorderless
local D  = {}
TB.Display = D

-- What we last drove the engine to, so we can tell a real change from a
-- redundant one without reading back across the render thread.
D.applied = nil

-- ------------------------------------------------------------------
-- Reading the engine
-- ------------------------------------------------------------------

--- Current display state as the engine sees it.
function D.probe()
    local s = { ok = false }
    pcall(function()
        local core = getCore()
        s.fullScreen = core:isFullScreen()
        s.borderless = core:getOptionBorderlessWindow()
        s.width      = core:getScreenWidth()
        s.height     = core:getScreenHeight()
        s.ok = true
    end)
    return s
end

--- Fallback target for when the enforcer has never run and so has not
--- published the real desktop layout.
---
--- Deliberately NOT the largest entry in getScreenModes().  That list is
--- whatever the driver advertises, which on this machine includes
--- 3840x2160 on a 3440x1440 panel - picking the biggest one asked for a
--- resolution the monitor does not have.  The resolution the game is
--- already running at is the one the player chose, and at boot that is
--- normally the desktop resolution, which is what we actually want.
function D.fallbackTarget()
    local w, h = 0, 0
    pcall(function()
        w = getCore():getScreenWidth()
        h = getCore():getScreenHeight()
    end)
    if w and h and w > 0 and h > 0 then return { w = w, h = h } end
    return nil
end

-- ------------------------------------------------------------------
-- The desktop layout, as published by the enforcer
--
-- Shape of TrueBorderless_monitors.ini:
--     count=2
--     current=1                 ; monitor the window is on right now
--     1.name=\\.\DISPLAY1
--     1.primary=true
--     1.x=0  1.y=0  1.w=3440  1.h=1440
--     2.name=\\.\DISPLAY2
--     2.primary=false
--     2.x=-1440  2.y=-1310  2.w=1440  2.h=3440
-- ------------------------------------------------------------------
function D.monitors()
    local ini = TB.readIni(TB.FILE_MONITORS)
    if not ini then return nil end

    local count = TB.toInt(ini.count, 0)
    if count <= 0 then return nil end

    local list = {}
    for i = 1, count do
        local p = tostring(i) .. "."
        local m = {
            index   = i,
            name    = ini[p .. "name"] or ("monitor " .. i),
            primary = TB.toBool(ini[p .. "primary"], false),
            x       = TB.toInt(ini[p .. "x"], 0),
            y       = TB.toInt(ini[p .. "y"], 0),
            w       = TB.toInt(ini[p .. "w"], 0),
            h       = TB.toInt(ini[p .. "h"], 0),
        }
        if m.w > 0 and m.h > 0 then list[#list + 1] = m end
    end
    if #list == 0 then return nil end

    return {
        list    = list,
        current = TB.toInt(ini.current, 0),
        stamp   = ini.ts,
    }
end

--- The exact window rectangle the enforcer wants, overscan included.
--- This is the single source of truth for mode "true": the enforcer does
--- the arithmetic once and both halves read the same numbers, so they
--- cannot drift apart the way two separate calculations did.
function D.publishedTarget()
    local ini = TB.readIni(TB.FILE_MONITORS)
    if not ini then return nil end
    local w = TB.toInt(ini["target.w"], 0)
    local h = TB.toInt(ini["target.h"], 0)
    if w <= 0 or h <= 0 then return nil end
    return {
        x = TB.toInt(ini["target.x"], 0),
        y = TB.toInt(ini["target.y"], 0),
        w = w,
        h = h,
        overscan = TB.toInt(ini["target.overscan"], 0),
        name = ini["target.monitor"] or "monitor",
    }
end

--- Decide which rectangle we are trying to cover.
--- Returns a monitor-shaped table, or nil if we cannot tell.
function D.pickTarget()
    local mons = D.monitors()
    local want = tostring(TB.cfg.monitor or "auto")

    if mons then
        local list = mons.list

        if want == "auto" then
            -- The enforcer tells us which monitor the window is on. That
            -- is what a player who dragged the window somewhere means by
            -- "fullscreen", and it is the one thing vanilla can never do.
            if mons.current >= 1 and list[mons.current] then
                return list[mons.current]
            end
        elseif want == "primary" then
            for _, m in ipairs(list) do
                if m.primary then return m end
            end
        else
            local idx = tonumber(want)
            if idx and list[idx] then return list[idx] end
            for _, m in ipairs(list) do
                if m.name == want then return m end
            end
            TB.warn("monitor '" .. want .. "' not found, falling back to primary")
        end

        for _, m in ipairs(list) do
            if m.primary then return m end
        end
        return list[1]
    end

    -- No enforcer yet. In "native" mode this is still completely correct:
    -- the engine ignores the width and height we pass and rebuilds the
    -- window from the primary monitor's own video mode, so the primary
    -- monitor gets covered edge to edge regardless of what we say here.
    local fb = D.fallbackTarget()
    if fb then
        return { index = 0, name = "primary (engine)", primary = true,
                 x = 0, y = 0, w = fb.w, h = fb.h }
    end
    return nil
end

-- ------------------------------------------------------------------
-- Driving the engine
-- ------------------------------------------------------------------

--- Core.setResolutionAndFullScreen dispatches onto the render thread via
--- RenderThread.invokeOnRenderContext, so this returns long before the
--- window has actually changed.  Never read state back in the same tick.
local function setMode(w, h, fullscreen)
    local ok = pcall(function()
        getCore():setResolutionAndFullScreen(w, h, fullscreen)
    end)
    if not ok then TB.warn("setResolutionAndFullScreen refused " .. w .. "x" .. h) end
    return ok
end

local function setBorderlessFlag(on)
    pcall(function() getCore():setOptionBorderlessWindow(on) end)
end

local function saveOptions()
    pcall(function() getCore():saveOptions() end)
end

--- Force the engine past setDisplayModeAndFullscreenInternal's early
--- return by making the intermediate DisplayMode genuinely different.
--- Only used by "native" mode; "true" mode does not need it because the
--- enforcer owns the geometry and does not care whether the engine
--- bothered to move the window.
local function nudge(w, h)
    setMode(math.max(640, w - 16), math.max(480, h - 16), false)
end

--- Put the engine into the state this mod wants.
--- @param force boolean re-apply even if we believe it is already right
function D.apply(force)
    if not TB.cfg.enabled or TB.cfg.mode == "off" then
        return false, "disabled"
    end

    -- Core.setDisplayMode is dispatched onto the render thread, so probe()
    -- still reports the OLD state for a while after we ask for a change.
    -- Without this guard the OnGameStart and OnMainMenuEnter re-asserts
    -- fire a second, redundant mode change a moment after the first.
    if not force and D.lastApplyAt then
        local ok, now = pcall(function() return getTimestampMs() end)
        if ok and now and (now - D.lastApplyAt) < 5000 then
            TB.debug("apply suppressed, a change is still settling")
            return false, "settling"
        end
    end

    local target = D.pickTarget()
    if not target then
        TB.warn("cannot determine a target monitor; is the enforcer running?")
        return false, "no target"
    end

    local before = D.probe()
    if not before.ok then
        TB.warn("engine display state unreadable")
        return false, "unreadable"
    end

    -- Whether we actually asked the engine for anything. Every display
    -- call the engine accepts hides and re-shows the window, which is a
    -- visible flash, so a redundant one is not free and must not be
    -- reported as if it were the thing that made borderless work.
    local touched = false

    -- Mode "true" hands the frame to the Windows-side enforcer. If that is
    -- not actually running we must NOT leave the engine in a plain window,
    -- because nobody would strip the titlebar and the player ends up with
    -- a decorated window overhanging the screen. Fall back to the mode
    -- that needs no help.
    local effectiveMode = TB.cfg.mode
    if effectiveMode ~= "native" and not D.enforcerSeen() then
        TB.warn("enforcer is not running; falling back to native borderless")
        TB.warn("start the game with tools\\TrueBorderless\\TrueBorderless.bat for the seamless mode")
        effectiveMode = "native"
    end

    if effectiveMode == "native" then
        -- Let the engine do it. It will size from the primary monitor
        -- whatever we pass, so the width and height here are only there
        -- to make the mode object differ from the current one.
        if before.borderless and not before.fullScreen and not force then
            TB.debug("native mode already applied")
        else
            touched = true
            setBorderlessFlag(true)
            if not before.fullScreen and before.borderless then
                nudge(target.w, target.h)
            end
            setMode(target.w, target.h, false)
        end
    else
        -- mode "true": an ordinary window, deliberately a little LARGER
        -- than the monitor. See TB.defaults.overscan - a window that
        -- matches a monitor exactly gets promoted by Windows onto a
        -- fullscreen presentation path and inherits its alt-tab
        -- transitions. Overhanging the edges makes that promotion
        -- impossible, so the window stays an ordinary composited window
        -- for the whole session and there is nothing left to flash.
        --
        -- The borderless flag must be OFF or setDisplayModeInternal
        -- discards our width and height and uses the primary monitor.
        local pub = D.publishedTarget()
        if pub then
            target = pub
        else
            -- No published rectangle. Do the arithmetic ourselves, which
            -- only happens if the enforcer published an old-format file.
            local ov = TB.cfg.overscan or 0
            target.w = target.w + 2 * ov
            target.h = target.h + 2 * ov
            target.x = target.x - ov
            target.y = target.y - ov
        end
        TB.debug(string.format("target rect %dx%d at %d,%d (overscan %d)",
            target.w, target.h, target.x, target.y, target.overscan or 0))

        local already = (not before.fullScreen)
                    and (not before.borderless)
                    and before.width  == target.w
                    and before.height == target.h

        if already and not force then
            TB.debug("engine already windowed at " .. target.w .. "x" .. target.h)
        else
            touched = true
            setBorderlessFlag(false)
            setMode(target.w, target.h, false)
        end
    end

    -- Only write options.ini back when something actually changed. It is
    -- cheap, but writing it for nothing is how a file that PZ also owns
    -- ends up churning.
    if touched then saveOptions() end

    D.applied = {
        mode    = effectiveMode,
        monitor = target.name,
        w       = target.w,
        h       = target.h,
        x       = target.x,
        y       = target.y,
    }

    local ok, now = pcall(function() return getTimestampMs() end)
    D.lastApplyAt = (ok and now) or nil

    D.publishRequest("on", target)

    -- Be honest about who chose the size and about whether we did
    -- anything at all. In "native" mode the engine overrides whatever we
    -- passed with the primary monitor's video mode, so printing our own
    -- numbers would be a lie.
    if not touched then
        TB.info("display already correct, left untouched (no mode change, no flash)")
    elseif effectiveMode == "native" then
        TB.info("switched to native borderless; the engine sizes it from the primary monitor")
    else
        TB.info(string.format("switched to real borderless on %s at %dx%d",
            tostring(target.name), target.w, target.h))
    end
    return true, target
end

-- ------------------------------------------------------------------
-- Baseline
--
-- PZ rewrites options.ini on exit, so whatever we leave behind becomes
-- the player's "choice" next launch and quietly compounds.  The state
-- found on the very first run is therefore written to our own file and
-- never overwritten, so "give me back what I had" always has an answer
-- even after twenty sessions.
-- ------------------------------------------------------------------
function D.captureBaseline()
    if TB.readIni(TB.FILE_BASELINE) then return end

    local s = D.probe()
    if not s.ok then return end

    TB.writeIni(TB.FILE_BASELINE, {
        fullScreen = s.fullScreen,
        borderless = s.borderless,
        width      = s.width,
        height     = s.height,
    }, { "fullScreen", "borderless", "width", "height" }, {
        "Display settings as TrueBorderless first found them.",
        "Written once and never updated. Delete this file to re-capture.",
    })
    TB.info(string.format("baseline captured: %dx%d fullScreen=%s borderless=%s",
        s.width, s.height, tostring(s.fullScreen), tostring(s.borderless)))
end

--- Hand the player their original display settings back.
function D.restore()
    local ini = TB.readIni(TB.FILE_BASELINE)
    if not ini then
        TB.warn("no baseline on disk, nothing to restore")
        D.publishRequest("off", nil)
        return false
    end

    local w  = TB.toInt(ini.width, 0)
    local h  = TB.toInt(ini.height, 0)
    local fs = TB.toBool(ini.fullScreen, false)
    local bl = TB.toBool(ini.borderless, false)
    if w <= 0 or h <= 0 then
        TB.warn("baseline is malformed, nothing to restore")
        return false
    end

    -- Tell the enforcer to let go first. If it re-asserted its geometry
    -- onto a window the engine is in the middle of resizing, the client
    -- area and the framebuffer would disagree until the next mode change.
    D.publishRequest("off", nil)

    setBorderlessFlag(bl)
    setMode(w, h, fs)
    saveOptions()

    D.applied = nil
    TB.info(string.format("restored %dx%d fullScreen=%s borderless=%s",
        w, h, tostring(fs), tostring(bl)))
    return true
end

-- ------------------------------------------------------------------
-- Talking to the enforcer
-- ------------------------------------------------------------------

--- Wall clock in ms. Guarded because this file also runs at OnGameBoot,
--- before some globals are guaranteed to exist.
local function stamp()
    local ok, v = pcall(function() return getTimestampMs() end)
    if ok and v then return tostring(v) end
    return "0"
end

--- @param want "on" | "off"
--- @param target monitor table or nil
function D.publishRequest(want, target)
    local t = {
        ts      = stamp(),
        want    = want,
        mode    = TB.cfg.mode,
        monitor = TB.cfg.monitor,
        topmost = TB.cfg.topmost,
        reassertOnFocus = TB.cfg.reassertOnFocus,
    }
    if target then
        t.w = target.w
        t.h = target.h
        t.x = target.x
        t.y = target.y
        t.targetName = target.name
    end
    TB.writeIni(TB.FILE_REQUEST, t,
        { "ts", "want", "mode", "monitor", "topmost", "reassertOnFocus",
          "targetName", "x", "y", "w", "h" },
        { "Written by the in-game mod. Read by TrueBorderless.ps1.",
          "Do not edit by hand; it is rewritten on every change." })
end

--- Is the enforcer alive right now?  It rewrites the monitor file every
--- three seconds while watching, so a recent timestamp is its heartbeat.
--- "Present on disk" is not enough: the file outlives the process, and
--- acting on a stale one is how mode "true" leaves a titlebar on screen.
D.HEARTBEAT_MS = 30000

function D.enforcerSeen()
    local ini = TB.readIni(TB.FILE_MONITORS)
    if not ini then return false, nil end

    local ts = tonumber(ini.ts)
    if not ts then return false, nil end

    local ok, now = pcall(function() return getTimestampMs() end)
    if not ok or not now then return false, ini.ts end

    local age = now - ts
    return (age >= 0 and age < D.HEARTBEAT_MS), ini.ts
end
