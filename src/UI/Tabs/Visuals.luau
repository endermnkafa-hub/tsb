--!strict
local Components = require("UI.Components")

local VisualsTab = {}

function VisualsTab.Build(parent: Instance, ctx: any)
    local cfg = ctx.ConfigManager.Config
    local fm = ctx.FeatureManager
    local notifs = ctx.Notifications
    local accent = ctx.AccentName

    local feat = fm:GetFeature("VisualsEngine")
    local isEngineRunning = feat and feat.Enabled or true

    Components.Section(parent, "Master Pipeline Control", accent)
    Components.Toggle(parent, "Visuals Engine Pipeline", "Controls Heartbeat visual ESP and drawing updates", isEngineRunning, accent, function(val)
        fm:SetEnabled("VisualsEngine", val, ctx.Container)
        notifs:Show("Visuals Engine", val and "Pipeline Activated" or "Pipeline Deactivated", 2.0, val and "Success" or "Warning")
    end)

    Components.Section(parent, "Player ESP & Silhouettes", accent)
    Components.Toggle(parent, "Highlight Chams ESP", "Color-coded character silhouette visible through walls", cfg.Visuals.HighlightESP, accent, function(val)
        cfg.Visuals.HighlightESP = val
    end)

    Components.Toggle(parent, "Billboard ESP", "Overhead status badges with HP and distance", cfg.Visuals.BillboardESP, accent, function(val)
        cfg.Visuals.BillboardESP = val
    end)

    Components.Toggle(parent, "Display Character Class", "Show fighter archetype (Garou, Saitama, etc.)", cfg.Visuals.ShowCharacterESP, accent, function(val)
        cfg.Visuals.ShowCharacterESP = val
    end)

    Components.Toggle(parent, "Display Ultimate Status", "Alert when opponent gauge reaches 100%", cfg.Visuals.ShowUltiESP, accent, function(val)
        cfg.Visuals.ShowUltiESP = val
    end)

    Components.Toggle(parent, "Death Counter Warning", "High-priority danger alert for lethal counters", cfg.Visuals.DeathCounterRisk, accent, function(val)
        cfg.Visuals.DeathCounterRisk = val
    end)

    Components.Section(parent, "Tracers & Reticles", accent)
    Components.Toggle(parent, "Tracers", "Directional lines to target roots", cfg.Visuals.Tracers, accent, function(val)
        cfg.Visuals.Tracers = val
    end)

    Components.Dropdown(parent, "Tracer Origin", { "Bottom", "Center", "Mouse" }, cfg.Visuals.TracerOrigin or "Bottom", accent, function(val)
        cfg.Visuals.TracerOrigin = val
    end)

    Components.Toggle(parent, "FOV Circle", "Show visual aimlock target acquisition boundary", cfg.Visuals.FOVCircle, accent, function(val)
        cfg.Visuals.FOVCircle = val
    end)
end

return VisualsTab
