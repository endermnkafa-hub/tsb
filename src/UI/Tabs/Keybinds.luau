--!strict
local Components = require("UI.Components")
local Theme = require("UI.Theme")

local KeybindsTab = {}

function KeybindsTab.Build(parent: Instance, ctx: any)
    local cfg = ctx.ConfigManager.Config
    local notifs = ctx.Notifications
    local accent = ctx.AccentName
    local kb = cfg.Keybinds or {}

    -- Section 1: Flank & Combat Keybinds
    Components.Section(parent, "Flank & Combat Hotkeys", accent)

    Components.Keybind(parent, "Toggle Safe Behind Lock (Continuous Flank)", kb.ToggleBehindTP or Enum.KeyCode.F9, accent, function(key)
        kb.ToggleBehindTP = key
        notifs:Show("Keybind Updated", "Safe Behind Lock set to " .. key.Name, 2.0, "Success")
    end)

    Components.Keybind(parent, "Toggle Aimlock", kb.ToggleAimlock or Enum.KeyCode.F7, accent, function(key)
        kb.ToggleAimlock = key
        notifs:Show("Keybind Updated", "Aimlock toggle set to " .. key.Name, 2.0, "Success")
    end)

    Components.Keybind(parent, "Mass Bring Hotkey", kb.MassBringKey or Enum.KeyCode.G, accent, function(key)
        kb.MassBringKey = key
        notifs:Show("Keybind Updated", "Mass Bring set to " .. key.Name, 2.0, "Success")
    end)

    Components.Keybind(parent, "Toggle Sky Dodge", kb.ToggleSkyDodge or Enum.KeyCode.H, accent, function(key)
        kb.ToggleSkyDodge = key
        notifs:Show("Keybind Updated", "Sky Dodge set to " .. key.Name, 2.0, "Success")
    end)

    -- Section 2: Movement & Mobility Keybinds
    Components.Section(parent, "Movement & Flight Hotkeys", accent)

    Components.Keybind(parent, "Toggle Fly", kb.ToggleFly or Enum.KeyCode.F5, accent, function(key)
        kb.ToggleFly = key
        notifs:Show("Keybind Updated", "Fly toggle set to " .. key.Name, 2.0, "Success")
    end)

    Components.Keybind(parent, "Toggle Noclip", kb.ToggleNoclip or Enum.KeyCode.F6, accent, function(key)
        kb.ToggleNoclip = key
        notifs:Show("Keybind Updated", "Noclip toggle set to " .. key.Name, 2.0, "Success")
    end)

    -- Section 3: Interface & Emergency Controls
    Components.Section(parent, "Interface & Emergency Controls", accent)

    Components.Keybind(parent, "Toggle GUI Window", kb.ToggleGUI or Enum.KeyCode.RightControl, accent, function(key)
        kb.ToggleGUI = key
        notifs:Show("Keybind Updated", "GUI toggle set to " .. key.Name, 2.0, "Success")
    end)

    Components.Keybind(parent, "Emergency Stop All", kb.EmergencyStop or Enum.KeyCode.Delete, accent, function(key)
        kb.EmergencyStop = key
        notifs:Show("Keybind Updated", "Emergency Stop set to " .. key.Name, 2.0, "Warning")
    end)
end

return KeybindsTab
