--[[ ============================================================
     TrueBorderless - In-game options  (client only)

     Plain ASCII strings throughout, no getText and no percent signs.
     PZ runs translation strings through Java's String.format, and a
     stray percent takes the whole main menu down with it.
     ============================================================ ]]

TrueBorderless = TrueBorderless or {}
local TB = TrueBorderless

local MODE_LABELS = { "Real borderless", "Engine borderless", "Off" }
local MODE_VALUES = { "true", "native", "off" }

local function indexOfMode(v)
    for i = 1, #MODE_VALUES do
        if MODE_VALUES[i] == v then return i end
    end
    return 1
end

-- The monitor list is only known once the enforcer has published it. The
-- options screen is built at boot, which may be before that has ever
-- happened, so the entries are generated from whatever is on disk and
-- fall back to bare indices.
local function monitorChoices()
    local labels = { "Auto - the screen the window is on", "Primary" }
    local values = { "auto", "primary" }

    local mons = TB.Display.monitors()
    if mons then
        for _, m in ipairs(mons.list) do
            local tag = string.format("%d - %dx%d", m.index, m.w, m.h)
            if m.primary then tag = tag .. " (primary)" end
            labels[#labels + 1] = tag
            values[#values + 1] = tostring(m.index)
        end
    else
        for i = 1, 4 do
            labels[#labels + 1] = "Monitor " .. i
            values[#values + 1] = tostring(i)
        end
    end
    return labels, values
end

local function indexOf(list, v)
    for i = 1, #list do
        if list[i] == v then return i end
    end
    return 1
end

local function build()
    if not PZAPI or not PZAPI.ModOptions then return end

    TB.loadPrefs()

    local monLabels, monValues = monitorChoices()
    local o = PZAPI.ModOptions:create("TrueBorderless", "True Borderless")

    o:addTitle("Real borderless fullscreen")
    o:addDescription("The vanilla borderless option builds the window from the primary monitor no matter which screen you are on, and never moves it when you only tick the box. This replaces it with a window that covers the target monitor exactly, including the taskbar, at no frame cost.")

    o:addTickBox("enabled", "Enable True Borderless", TB.defaults.enabled,
        "Master switch. Off hands your original display settings back.")

    local mode = o:addComboBox("mode", "Mode",
        "Real borderless keeps the engine in a plain window sized to the monitor and lets the Windows helper own the frame. It is the only mode that works on a screen other than your primary one. Engine borderless uses the game's own flag and is limited to the primary monitor.")
    local mi = indexOfMode(TB.cfg.mode)
    for i = 1, #MODE_LABELS do
        mode:addItem(MODE_LABELS[i], i == mi)
    end

    local mon = o:addComboBox("monitor", "Target screen",
        "Which monitor to cover. Auto uses whichever screen the window is currently on, so you can drag the window over and press the toggle key.")
    local cur = indexOf(monValues, tostring(TB.cfg.monitor))
    for i = 1, #monLabels do
        mon:addItem(monLabels[i], i == cur)
    end

    o:addSeparator()
    o:addTitle("Behaviour")

    o:addTickBox("topmost", "Keep above other windows", TB.defaults.topmost,
        "Not needed to cover the taskbar, and it makes overlays and alt-tab feel sticky. Only turn this on if something keeps drawing over the game.")

    o:addTickBox("reassertOnFocus", "Re-apply when the window regains focus", TB.defaults.reassertOnFocus,
        "Cheap insurance against anything that puts the frame back behind our back. Costs nothing while the window is untouched.")

    o:addSeparator()
    o:addButton("applyNow", "Apply now",
        "Re-runs the whole thing against the current desktop layout. Use this after moving the window to another screen.",
        function() TB.Display.apply(true) end)

    o:addButton("restoreNow", "Restore my original settings",
        "Puts back the resolution, fullscreen and borderless values that were in options.ini the first time this mod ever ran.",
        function() TB.Display.restore() end)

    o:addSeparator()
    o:addTitle("Diagnostics")

    local log = o:addComboBox("logLevel", "Log detail",
        "How much True Borderless writes to console.txt.")
    log:addItem("Off", TB.cfg.logLevel == 0)
    log:addItem("Warnings", TB.cfg.logLevel == 1)
    log:addItem("Normal", TB.cfg.logLevel == 2)
    log:addItem("Debug", TB.cfg.logLevel == 3)

    -- Called by PZAPI when the player applies the options screen.
    o.apply = function(self)
        local function val(id)
            local opt = self:getOption(id)
            if not opt then return nil end
            return opt:getValue()
        end

        local wasEnabled = TB.cfg.enabled
        local wasMode    = TB.cfg.mode
        local wasMonitor = TB.cfg.monitor

        local e = val("enabled")
        if e ~= nil then TB.cfg.enabled = e end

        local t = val("topmost")
        if t ~= nil then TB.cfg.topmost = t end

        local r = val("reassertOnFocus")
        if r ~= nil then TB.cfg.reassertOnFocus = r end

        local mIdx = val("mode")
        if mIdx and MODE_VALUES[mIdx] then TB.cfg.mode = MODE_VALUES[mIdx] end

        local monIdx = val("monitor")
        if monIdx and monValues[monIdx] then TB.cfg.monitor = monValues[monIdx] end

        local li = val("logLevel")
        if li then TB.cfg.logLevel = li - 1 end

        TB.savePrefs()

        -- Act on the switches now rather than at the next boot. Anything
        -- that changes which pixels we are trying to cover has to be a
        -- forced apply, because apply() short-circuits when the engine
        -- state already looks right.
        local changed = (TB.cfg.enabled ~= wasEnabled)
                     or (TB.cfg.mode    ~= wasMode)
                     or (TB.cfg.monitor ~= wasMonitor)

        if not TB.cfg.enabled or TB.cfg.mode == "off" then
            if wasEnabled and wasMode ~= "off" then TB.Display.restore() end
        else
            TB.Display.apply(changed)
        end

        TB.info("options applied - mode " .. tostring(TB.cfg.mode)
            .. ", screen " .. tostring(TB.cfg.monitor))
    end
end

-- PZAPI is set up by the base game's own client Lua; building at boot
-- keeps us out of its load order.
Events.OnGameBoot.Add(function()
    local ok, err = pcall(build)
    if not ok then TB.warn("could not build the options panel: " .. tostring(err)) end
end)
