--!strict
local Components = require("UI.Components")

local WorldTab = {}

function WorldTab.Build(parent: Instance, ctx: any)
    local cfg = ctx.ConfigManager.Config
    local accent = ctx.AccentName
    local notifs = ctx.Notifications

    local function GetWorld(): any?
        if ctx.Container and ctx.Container:Has("World") then
            return ctx.Container:Get("World")
        end
        return nil
    end

    Components.Section(parent, "Lighting & Atmosphere", accent)
    Components.Toggle(parent, "FullBright", "Amplify world ambient lighting to maximum", cfg.World.FullBright, accent, function(val)
        cfg.World.FullBright = val
        local w = GetWorld()
        if w then w:ToggleFullBright(val) end
    end)

    Components.Toggle(parent, "Remove Fog", "Clear atmosphere fog, blur and distance haze", cfg.World.RemoveFog, accent, function(val)
        cfg.World.RemoveFog = val
        local w = GetWorld()
        if w then w:ToggleRemoveFog(val) end
    end)

    Components.Toggle(parent, "Custom Field of View", "Override camera rendering angle", cfg.World.CustomFOV, accent, function(val)
        cfg.World.CustomFOV = val
        if not val then
            -- Restore default FOV when disabled
            local cam = game:GetService("Workspace").CurrentCamera
            if cam then cam.FieldOfView = 70 end
        end
    end)

    Components.Slider(parent, "FOV Value", 60, 120, cfg.World.FOVValue or 90, "°", 1, accent, function(val)
        cfg.World.FOVValue = val
        if cfg.World.CustomFOV then
            local cam = game:GetService("Workspace").CurrentCamera
            if cam then cam.FieldOfView = val end
        end
    end)

    Components.Section(parent, "Server & Anti-Disconnect", accent)
    Components.Toggle(parent, "Anti-AFK Protection", "Bypass Roblox 20-minute idle disconnection", cfg.World.AntiAFK, accent, function(val)
        cfg.World.AntiAFK = val
        notifs:Show("Anti-AFK", val and "Anti-AFK ENABLED" or "Anti-AFK DISABLED", 2.0, val and "Success" or "Warning")
    end)

    Components.Toggle(parent, "Auto Server Hop", "Find and hop to full server when match empties", cfg.World.AutoServerHop, accent, function(val)
        cfg.World.AutoServerHop = val
    end)

    Components.Slider(parent, "Hop Trigger Min Players", 2, 8, cfg.World.AutoHopMinPlayers or 4, " players", 1, accent, function(val)
        cfg.World.AutoHopMinPlayers = val
    end)

    Components.Button(parent, "Force Server Hop Now", "Hop Now", "Danger", accent, function()
        local w = GetWorld()
        if w then
            w.HopActive = false
            w:ServerHop()
            notifs:Show("Server Hop", "Searching for new server...", 2.5, "Warning")
        end
    end)
end

return WorldTab
