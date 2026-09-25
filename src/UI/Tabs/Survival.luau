--!strict
local Components = require("UI.Components")

local SurvivalTab = {}

function SurvivalTab.Build(parent: Instance, ctx: any)
    local cfg = ctx.ConfigManager.Config
    local fm = ctx.FeatureManager
    local notifs = ctx.Notifications
    local accent = ctx.AccentName

    local feat = fm:GetFeature("SurvivalEngine")
    local isEngineRunning = feat and feat.Enabled or true

    Components.Section(parent, "Master Pipeline Control", accent)
    Components.Toggle(parent, "Survival Engine Pipeline", "Controls Heartbeat survival and FSM evasion checks", isEngineRunning, accent, function(val)
        fm:SetEnabled("SurvivalEngine", val, ctx.Container)
        notifs:Show("Survival Engine", val and "Pipeline Activated" or "Pipeline Deactivated", 2.0, val and "Success" or "Warning")
    end)

    Components.Section(parent, "Sky Teleport Emergency Escape", accent)
    Components.Toggle(parent, "Sky Teleport", "Escape into the sky upon critical health", cfg.Survival.SkyTeleport, accent, function(val)
        cfg.Survival.SkyTeleport = val
    end)

    Components.Slider(parent, "Escape HP Threshold", 10, 60, cfg.Survival.SkyEscapeHP or 30, " HP", 5, accent, function(val)
        cfg.Survival.SkyEscapeHP = val
    end)

    Components.Slider(parent, "Return HP Threshold", 50, 100, cfg.Survival.SkyReturnHP or 80, " HP", 5, accent, function(val)
        cfg.Survival.SkyReturnHP = val
    end)

    Components.Slider(parent, "Escape Height", 50, 400, cfg.Survival.SkyEscapeHeight or 180, " studs", 10, accent, function(val)
        cfg.Survival.SkyEscapeHeight = val
    end)

    Components.Section(parent, "Sky Dodge Reflex", accent)
    Components.Toggle(parent, "Sky Dodge", "Automatic vertical hop to dodge unblockable strikes", cfg.Survival.SkyDodge, accent, function(val)
        cfg.Survival.SkyDodge = val
    end)

    Components.Slider(parent, "Dodge Height", 20, 150, cfg.Survival.SkyDodgeHeight or 65, " studs", 5, accent, function(val)
        cfg.Survival.SkyDodgeHeight = val
    end)

    Components.Slider(parent, "Trigger Range", 5, 30, cfg.Survival.SkyDodgeRange or 18, " studs", 1, accent, function(val)
        cfg.Survival.SkyDodgeRange = val
    end)

    Components.Toggle(parent, "Lock Camera During Dodge", "Keep camera tracking target while in mid-air", cfg.Survival.SkyDodgeLockCamera, accent, function(val)
        cfg.Survival.SkyDodgeLockCamera = val
    end)
end

return SurvivalTab
