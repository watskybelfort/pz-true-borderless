--[[ ============================================================
     TrueBorderless - Core
     Namespace, config store, ini plumbing, logging.

     Client only.  Window management is a property of one machine's
     screen; the server has no opinion about it and must never be told.

     Loads first: "Core" sorts before every other file in this folder.
     ============================================================ ]]

TrueBorderless = TrueBorderless or {}
local TB = TrueBorderless

TB.VERSION = "1.1.0"
TB.MODID   = "TrueBorderless"

-- ------------------------------------------------------------------
-- Files
--
-- The Lua side and the Windows-side enforcer talk through the Zomboid
-- user folder, because PZ's Lua sandbox has no other way out of the
-- process.  Each file has exactly one writer, so there is no race and
-- neither side has to lock anything.
--
--   PREFS     user-editable, read by both, written by the options screen
--   MONITORS  enforcer -> mod   (the real desktop layout)
--   REQUEST   mod -> enforcer   (what the player just asked for)
--   BASELINE  mod -> mod        (the display settings we found on arrival)
-- ------------------------------------------------------------------
TB.FILE_PREFS    = "TrueBorderless.ini"
TB.FILE_MONITORS = "TrueBorderless_monitors.ini"
TB.FILE_REQUEST  = "TrueBorderless_request.ini"
TB.FILE_BASELINE = "TrueBorderless_baseline.ini"

-- ------------------------------------------------------------------
-- Config
--
-- `mode` is the whole design in one value:
--
--   "native"  DEFAULT, and the only mode that needs nothing but this
--             mod.  Uses the engine's own borderless path, but drives it
--             in an order that defeats the early return in
--             Display.setDisplayModeAndFullscreenInternal, which is the
--             single reason ticking the vanilla checkbox appears to do
--             nothing.  Correct on the primary monitor, which is where
--             the engine's own arithmetic happens to work out.
--
--   "true"    Engine stays in plain windowed mode at the exact pixel
--             size of the target monitor, and an external Windows helper
--             removes the frame and snaps it to the monitor origin.
--             Needed only to cover a monitor other than the primary one,
--             because the engine's borderless path is hard wired to
--             glfwGetPrimaryMonitor.  Requires the helper to be running;
--             without it this mode leaves you in a plain window.
--
--   "off"     Do nothing.  Restores whatever the player had.
-- ------------------------------------------------------------------
TB.defaults = {
    enabled = true,
    mode    = "native",

    -- Which screen to cover. "auto" means the monitor the window is
    -- already sitting on, which is what a player dragging the window
    -- around expects.  Otherwise a 1-based index into the monitor list
    -- the enforcer publishes, or "primary".
    monitor = "auto",

    -- Pixels the window is allowed to hang off each edge of the monitor,
    -- used by mode "true".
    --
    -- This is the whole point of that mode. Windows promotes a borderless
    -- window whose rectangle matches a monitor EXACTLY to a fullscreen
    -- presentation path, and then hands it the same enter/leave
    -- transitions a real fullscreen application gets - which is the black
    -- flash on alt-tab that this mod exists to remove. A window even one
    -- pixel larger than the monitor is not a candidate for that promotion,
    -- so the compositor treats it as an ordinary window forever and there
    -- is nothing left to transition.
    --
    -- The cost is `overscan` pixels of the image falling off each edge.
    -- At 1 px on a 3440x1440 panel that is 0.03 percent of the picture.
    overscan = 1,

    -- Keep the window above everything else.  Off by default: a topmost
    -- game window hides Discord popups and makes alt-tab feel sticky,
    -- and it is not needed to cover the taskbar.  A foreground window
    -- that exactly covers a monitor already covers the taskbar.
    topmost = false,

    -- Re-apply automatically when focus returns.  Cheap insurance
    -- against anything that re-decorates the window behind our back.
    reassertOnFocus = true,

    logLevel = 2,   -- 0 off, 1 warn, 2 info, 3 debug
}

TB.cfg = {}

function TB.resetConfig()
    TB.cfg = {}
    for k, v in pairs(TB.defaults) do TB.cfg[k] = v end
    return TB.cfg
end

-- ------------------------------------------------------------------
-- Logging
-- ------------------------------------------------------------------
local LEVEL_TAG = { [1] = "WARN", [2] = "INFO", [3] = "DEBUG" }

function TB.log(level, msg)
    if (TB.cfg.logLevel or 2) < level then return end
    print("[TrueBorderless][" .. (LEVEL_TAG[level] or "?") .. "] " .. tostring(msg))
end

function TB.warn(msg)  TB.log(1, msg) end
function TB.info(msg)  TB.log(2, msg) end
function TB.debug(msg) TB.log(3, msg) end

-- ------------------------------------------------------------------
-- ini read / write
--
-- Deliberately a flat key=value store with dotted keys rather than a
-- real section parser.  It is the only shape both a PZ Lua script and a
-- PowerShell one-liner can agree on without either of them growing a
-- parser, and the files are small enough that nesting buys nothing.
-- ------------------------------------------------------------------

local function trim(s)
    return (string.gsub(s, "^%s*(.-)%s*$", "%1"))
end

--- Read a flat ini into a table of strings. Missing file yields nil, so
--- callers can tell "absent" from "present but empty".
function TB.readIni(name)
    local out, any = {}, false
    local ok = pcall(function()
        local r = getFileReader(name, false)
        if not r then return end
        any = true
        while true do
            local line = r:readLine()
            if line == nil then break end
            line = trim(line)
            if line ~= "" and string.sub(line, 1, 1) ~= ";" and string.sub(line, 1, 1) ~= "#" then
                local k, v = string.match(line, "^([^=]+)=(.*)$")
                if k then out[trim(k)] = trim(v) end
            end
        end
        r:close()
    end)
    if not ok or not any then return nil end
    return out
end

--- Write a flat ini. `order` is optional and only controls readability.
function TB.writeIni(name, tbl, order, header)
    local ok = pcall(function()
        local w = getFileWriter(name, true, false)
        if not w then return end
        if header then
            for _, line in ipairs(header) do w:write("; " .. line .. "\r\n") end
            w:write("\r\n")
        end
        local written = {}
        if order then
            for _, k in ipairs(order) do
                if tbl[k] ~= nil then
                    w:write(k .. "=" .. tostring(tbl[k]) .. "\r\n")
                    written[k] = true
                end
            end
        end
        local rest = {}
        for k in pairs(tbl) do
            if not written[k] then rest[#rest + 1] = k end
        end
        table.sort(rest)
        for _, k in ipairs(rest) do
            w:write(k .. "=" .. tostring(tbl[k]) .. "\r\n")
        end
        w:close()
    end)
    if not ok then TB.warn("could not write " .. tostring(name)) end
    return ok
end

-- ------------------------------------------------------------------
-- Typed accessors for values that arrive from disk as strings
-- ------------------------------------------------------------------
function TB.toBool(v, default)
    if v == nil then return default end
    if type(v) == "boolean" then return v end
    v = string.lower(tostring(v))
    if v == "true" or v == "1" or v == "yes" or v == "on" then return true end
    if v == "false" or v == "0" or v == "no" or v == "off" then return false end
    return default
end

function TB.toInt(v, default)
    if v == nil then return default end
    local n = tonumber(v)
    if n == nil then return default end
    return math.floor(n)
end

-- ------------------------------------------------------------------
-- Preferences
-- ------------------------------------------------------------------
local VALID_MODES = { ["true"] = true, ["native"] = true, ["off"] = true }

function TB.loadPrefs()
    TB.resetConfig()
    local ini = TB.readIni(TB.FILE_PREFS)
    if not ini then
        -- First run: leave a documented file behind so the enforcer has
        -- something to read and the player has something to edit.
        TB.savePrefs()
        return TB.cfg
    end

    TB.cfg.enabled         = TB.toBool(ini.enabled, TB.defaults.enabled)
    TB.cfg.topmost         = TB.toBool(ini.topmost, TB.defaults.topmost)
    TB.cfg.reassertOnFocus = TB.toBool(ini.reassertOnFocus, TB.defaults.reassertOnFocus)
    TB.cfg.logLevel        = TB.toInt(ini.logLevel, TB.defaults.logLevel)
    TB.cfg.overscan        = TB.toInt(ini.overscan, TB.defaults.overscan)
    if TB.cfg.overscan < 0 then TB.cfg.overscan = 0 end
    if TB.cfg.overscan > 16 then TB.cfg.overscan = 16 end

    local m = ini.mode and string.lower(ini.mode) or nil
    TB.cfg.mode = (m and VALID_MODES[m]) and m or TB.defaults.mode

    TB.cfg.monitor = (ini.monitor ~= nil and ini.monitor ~= "") and ini.monitor or TB.defaults.monitor

    return TB.cfg
end

function TB.savePrefs()
    TB.writeIni(TB.FILE_PREFS, {
        enabled         = TB.cfg.enabled,
        mode            = TB.cfg.mode,
        monitor         = TB.cfg.monitor,
        overscan        = TB.cfg.overscan,
        topmost         = TB.cfg.topmost,
        reassertOnFocus = TB.cfg.reassertOnFocus,
        logLevel        = TB.cfg.logLevel,
    }, { "enabled", "mode", "monitor", "overscan", "topmost", "reassertOnFocus", "logLevel" }, {
        "TrueBorderless - shared settings",
        "Read by the in-game mod and by tools\\TrueBorderless\\TrueBorderless.ps1.",
        "",
        "mode     true   = engine stays windowed, the enforcer owns the frame.",
        "                  The only mode that works on a non-primary monitor.",
        "         native = use the engine's own borderless flag.",
        "         off    = leave the display alone.",
        "monitor  auto | primary | a 1-based index from TrueBorderless_monitors.ini",
        "overscan pixels the window hangs off each edge in mode true. 1 stops",
        "         Windows promoting it to a fullscreen presentation path, which",
         "         is what makes alt-tab flash. 0 restores the exact fit.",
    })
end

TB.resetConfig()

-- Printed at parse time, not from an event. If this line is missing from
-- console.txt then the engine never read this file at all, which is a mod
-- list problem and not a bug in anything below it.
print("[TrueBorderless] " .. TB.VERSION .. " lua loaded")
