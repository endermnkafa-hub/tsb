--!strict
local Components = require("UI.Components")

local MovementTab = {}

function MovementTab.Build(parent: Instance, ctx: any)
    local cfg = ctx.ConfigManager.Config
    local fm = ctx.FeatureManager
    local notifs = ctx.Notifications
    local accent = ctx.AccentName

    -- Master Pipeline Controls
    Components.Section(parent, "Master Pipeline Controls", accent)
    
    local flyFeat = fm:GetFeature("FlyMovement")
    local flyFeatEnabled = flyFeat and flyFeat.Enabled or false
    Components.Toggle(parent, "Fly Pipeline (RenderStepped)", "High-priority camera-aligned fly loop", flyFeatEnabled, accent, function(val)
        fm:SetEnabled("FlyMovement", val, ctx.Container)
        notifs:Show("Fly Movement", val and "Pipeline Started" or "Pipeline Stopped", 2.0, val and "Success" or "Warning")
    end)

    local movFeat = fm:GetFeature("MovementEngine")
    local movFeatEnabled = movFeat and movFeat.Enabled or true
    Components.Toggle(parent, "Movement Engine (Heartbeat)", "Core physics speed and anti-void loop", movFeatEnabled, accent, function(val)
        fm:SetEnabled("MovementEngine", val, ctx.Container)
        notifs:Show("Movement Engine", val and "Pipeline Started" or "Pipeline Stopped", 2.0, val and "Success" or "Warning")
    end)

    -- Fly Mode
    Components.Section(parent, "Flight Controls", accent)
    Components.Toggle(parent, "Enable Fly", "Free 6-axis flight (WASD + Space/Shift)", cfg.Movement.Fly, accent, function(val)
        cfg.Movement.Fly = val
        local f = fm:GetFeature("FlyMovement")
        if val and f and not f.Enabled then
            fm:SetEnabled("FlyMovement", true, ctx.Container)
        end
    end)

    Components.Slider(parent, "Fly Speed", 10, 200, cfg.Movement.FlySpeed or 60, " studs/s", 5, accent, function(val)
        cfg.Movement.FlySpeed = val
    end)

    Components.Dropdown(parent, "Fly Mode", { "CFrame", "Velocity" }, cfg.Movement.FlyMode or "CFrame", accent, function(val)
        cfg.Movement.FlyMode = val
    end)

    -- Speed & Mobility
    Components.Section(parent, "Mobility & Jump", accent)
    Components.Toggle(parent, "Speed Boost", "Enhanced movement velocity", cfg.Movement.SpeedBoost, accent, function(val)
        cfg.Movement.SpeedBoost = val
    end)

    Components.Slider(parent, "Speed Value", 16, 150, cfg.Movement.SpeedVal or 42, " studs/s", 2, accent, function(val)
        cfg.Movement.SpeedVal = val
    end)

    Components.Toggle(parent, "Infinite Jump", "Jump infinitely in mid-air", cfg.Movement.InfiniteJump, accent, function(val)
        cfg.Movement.InfiniteJump = val
        if ctx.Container and ctx.Container:Has("Movement") then
            local mov = ctx.Container:Get("Movement")
            mov:ToggleJumpFeatures(cfg)
        end
    end)

    Components.Toggle(parent, "Double Jump", "Air boost jump assistance", cfg.Movement.DoubleJump, accent, function(val)
        cfg.Movement.DoubleJump = val
        if ctx.Container and ctx.Container:Has("Movement") then
            local mov = ctx.Container:Get("Movement")
            mov:ToggleJumpFeatures(cfg)
        end
    end)

    -- Safe Behind TP (Anti-Floor Clipping)
    Components.Section(parent, "Safe Behind TP (Target Flank)", accent)
    Components.Slider(parent, "Behind Distance", 1.5, 8.0, cfg.Target and cfg.Target.BehindDistance or 3.5, " studs", 0.5, accent, function(val)
        if not cfg.Target then cfg.Target = {} end
        cfg.Target.BehindDistance = val
    end)

    Components.Toggle(parent, "Auto M1 on Teleport", "Instantly strike target upon behind teleport", cfg.Target and cfg.Target.AutoM1OnTP ~= false, accent, function(val)
        if not cfg.Target then cfg.Target = {} end
        cfg.Target.AutoM1OnTP = val
    end)

    Components.Button(parent, "Teleport Behind Target (F9)", "Teleport Behind", "Primary", accent, function()
        if ctx.Container and ctx.Container:Has("Movement") and ctx.Container:Has("Combat") then
            local movement = ctx.Container:Get("Movement")
            local combat = ctx.Container:Get("Combat")
            local success, targetName = movement:ExecuteBehindTP(cfg, combat)
            if success then
                notifs:Show("⚡ Safe Behind TP", "Teleported safely behind " .. tostring(targetName), 2.0, "Success")
            else
                notifs:Show("Safe Behind TP", tostring(targetName), 2.0, "Warning")
            end
        end
    end)

    -- Physics & Void
    Components.Section(parent, "Collision & Bounds", accent)
    Components.Toggle(parent, "Noclip", "Disable character collision with map geometry", cfg.Movement.Noclip, accent, function(val)
        cfg.Movement.Noclip = val
    end)

    Components.Toggle(parent, "Anti-Void", "Teleport back to safety when falling into void", cfg.Movement.AntiVoid, accent, function(val)
        cfg.Movement.AntiVoid = val
    end)
end

return MovementTab
