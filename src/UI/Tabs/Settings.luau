--!strict
local Components = require("UI.Components")
local Theme = require("UI.Theme")

local SettingsTab = {}

function SettingsTab.Build(parent: Instance, ctx: any)
    local cfgMgr = ctx.ConfigManager
    local cfg = cfgMgr.Config
    local notifs = ctx.Notifications
    local accent = ctx.AccentName

    -- Config Storage
    Components.Section(parent, "Configuration Profile Management", accent)
    
    local storageStatus = (typeof(writefile) == "function") and "FILE DISK (OK)" or "IN-MEMORY (DEGRADED)"
    local storageColor = (typeof(writefile) == "function") and Theme.Colors.Success or Theme.Colors.Warning
    Components.StatusBadge(parent, "Storage Engine", storageStatus, storageColor)

    Components.Button(parent, "Save Configuration", "Save", "Success", accent, function()
        cfgMgr:Save()
        notifs:Show("Configuration", "Profile saved successfully to disk.", 2.5, "Success")
    end)

    Components.Button(parent, "Reload From Disk", "Reload", "Secondary", accent, function()
        cfgMgr:Load()
        notifs:Show("Configuration", "Profile reloaded from disk.", 2.5, "Info")
        if ctx.UIController and ctx.UIController.Refresh then
            ctx.UIController:Refresh()
        end
    end)

    Components.Button(parent, "Reset To Defaults", "Reset", "Danger", accent, function()
        cfgMgr:ResetToDefaults()
        notifs:Show("Configuration", "Settings reset to framework defaults.", 2.5, "Warning")
        if ctx.UIController and ctx.UIController.Refresh then
            ctx.UIController:Refresh()
        end
    end)

    -- Appearance
    Components.Section(parent, "Appearance & Interface", accent)
    Components.Dropdown(parent, "Color Accent", { "Cyan Neon", "Crimson Red", "Purple Velvet", "Emerald Green" }, cfg.UI.AccentName or "Cyan Neon", accent, function(val)
        cfg.UI.AccentName = val
        notifs:Show("Theme", "Accent set to " .. val .. ". (Reopen GUI to view full theme update)", 2.5, "Info")
    end)

    -- Keybinds
    Components.Section(parent, "Global Keybindings", accent)
    
    Components.Keybind(parent, "Toggle GUI Window", cfg.Keybinds.ToggleGUI or Enum.KeyCode.RightControl, accent, function(key)
        cfg.Keybinds.ToggleGUI = key
        notifs:Show("Keybind Updated", "Toggle GUI bind set to " .. key.Name, 2.0, "Info")
    end)

    Components.Keybind(parent, "Toggle Fly", cfg.Keybinds.ToggleFly or Enum.KeyCode.F5, accent, function(key)
        cfg.Keybinds.ToggleFly = key
    end)

    Components.Keybind(parent, "Toggle Noclip", cfg.Keybinds.ToggleNoclip or Enum.KeyCode.F6, accent, function(key)
        cfg.Keybinds.ToggleNoclip = key
    end)

    Components.Keybind(parent, "Toggle Aimlock", cfg.Keybinds.ToggleAimlock or Enum.KeyCode.F7, accent, function(key)
        cfg.Keybinds.ToggleAimlock = key
    end)

    Components.Keybind(parent, "Toggle Behind TP", cfg.Keybinds.ToggleBehindTP or Enum.KeyCode.F9, accent, function(key)
        cfg.Keybinds.ToggleBehindTP = key
    end)

    Components.Keybind(parent, "Toggle Sky Dodge", cfg.Keybinds.ToggleSkyDodge or Enum.KeyCode.H, accent, function(key)
        cfg.Keybinds.ToggleSkyDodge = key
    end)

    Components.Keybind(parent, "Emergency Stop All", cfg.Keybinds.EmergencyStop or Enum.KeyCode.Delete, accent, function(key)
        cfg.Keybinds.EmergencyStop = key
    end)

    Components.Keybind(parent, "Mass Bring Key", cfg.Keybinds.MassBringKey or Enum.KeyCode.G, accent, function(key)
        cfg.Keybinds.MassBringKey = key
    end)
end

return SettingsTab
