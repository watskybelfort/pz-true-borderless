--[[ ============================================================
     TrueBorderless - Client bootstrap

     Wires the display state machine to the engine's lifecycle and to a
     rebindable key.

     Timing matters here.  OnGameBoot is the first moment the window and
     the Core options both exist, and it fires at the main menu rather
     than when a save loads, which is what we want: the player should
     never see a decorated window at all, not even on the menu.
     ============================================================ ]]

TrueBorderless = TrueBorderless or {}
local TB = TrueBorderless

local KEYBIND_NAME = "Toggle True Borderless"

local booted = false

-- ------------------------------------------------------------------
-- Boot
-- ------------------------------------------------------------------
local function boot()
    if booted then return end
    booted = true

    TB.loadPrefs()
    TB.Display.captureBaseline()

    local seen = TB.Display.enforcerSeen()
    if not seen then
        -- Not fatal. Without the enforcer we can still cover the primary
        -- monitor, because that is the one layout the engine describes
        -- correctly by itself. Say so rather than silently doing less.
        TB.info("enforcer not detected; primary monitor only until it runs")
    end

    if TB.cfg.enabled and TB.cfg.mode ~= "off" then
        TB.Display.apply(false)
    else
        TB.Display.publishRequest("off", nil)
        TB.info("disabled by settings")
    end
end

Events.OnGameBoot.Add(boot)

-- A save loading or the player returning to the menu are both moments
-- where the engine may have touched the display on its own. Re-assert,
-- but never force: apply() is a no-op when the state already matches, so
-- this cannot cause a mode flip mid-session.
local function reassert()
    if not booted then return end
    if not TB.cfg.enabled or TB.cfg.mode == "off" then return end
    -- Only act if we have not already got the display where we want it.
    -- The engine deduplicates a redundant mode change anyway, but without
    -- this the boot apply and the menu apply both claim to have done the
    -- work and the log reads as if the mode flipped twice.
    if TB.Display.applied then return end
    TB.Display.apply(false)
end

Events.OnGameStart.Add(reassert)
if Events.OnMainMenuEnter then
    Events.OnMainMenuEnter.Add(reassert)
end

-- ------------------------------------------------------------------
-- Keybind
--
-- Registered into the global keyBinding table at load time so it shows
-- up in Options > Key Bindings and the player can move it, instead of
-- being an invisible hardcoded key.  F10 because OnzaPerf already owns
-- F7 and the two mods are usually installed together.
-- ------------------------------------------------------------------
do
    local exists = false
    if type(keyBinding) == "table" then
        for _, b in ipairs(keyBinding) do
            if b.value == KEYBIND_NAME then exists = true break end
        end
        if not exists then
            table.insert(keyBinding, { value = "[TrueBorderless]" })
            table.insert(keyBinding, { value = KEYBIND_NAME, key = Keyboard.KEY_F10 })
        end
    end
end

--- Flip between "covering the monitor" and "whatever the player had".
function TB.toggle()
    if TB.Display.applied then
        TB.Display.restore()
    else
        if TB.cfg.mode == "off" then TB.cfg.mode = TB.defaults.mode end
        TB.cfg.enabled = true
        TB.savePrefs()
        TB.Display.apply(true)
    end
end

Events.OnKeyPressed.Add(function(key)
    local ok, bound = pcall(function() return getCore():getKey(KEYBIND_NAME) end)
    if ok and bound and key == bound then
        TB.toggle()
    end
end)
