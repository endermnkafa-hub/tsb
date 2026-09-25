--!strict
local Components = require("UI.Components")

local CombatTab = {}

function CombatTab.Build(parent: Instance, ctx: any)
    local cfg = ctx.ConfigManager.Config
    local fm = ctx.FeatureManager
    local notifs = ctx.Notifications
    local accent = ctx.AccentName

    -- Master Pipeline Toggle
    local feat = fm:GetFeature("CombatEngine")
    local isEngineRunning = feat and feat.Enabled or true

    Components.Section(parent, "Master Pipeline Control", accent)
    Components.Toggle(parent, "Combat Engine Pipeline", "Controls Heartbeat execution loop for all combat systems", isEngineRunning, accent, function(val)
        fm:SetEnabled("CombatEngine", val, ctx.Container)
        notifs:Show("Combat Engine", val and "Pipeline Activated" or "Pipeline Deactivated", 2.2, val and "Success" or "Warning")
    end)

    -- Aimlock & Targeting
    Components.Section(parent, "Aimlock & Targeting", accent)
    Components.Toggle(parent, "Aimlock", "Lock camera/body facing nearest enemy", cfg.Combat.Aimlock, accent, function(val)
        cfg.Combat.Aimlock = val
    end)

    Components.Dropdown(parent, "Aim Mode", { "Nearest", "Lowest HP", "Mouse Nearest" }, cfg.Combat.AimMode or "Nearest", accent, function(val)
        cfg.Combat.AimMode = val
    end)

    Components.Dropdown(parent, "Aim Part", { "HumanoidRootPart", "Head", "Torso" }, cfg.Combat.AimPart or "HumanoidRootPart", accent, function(val)
        cfg.Combat.AimPart = val
    end)

    Components.Slider(parent, "Aim Max Range", 50, 1000, cfg.Combat.AimMaxRange or 300, " studs", 10, accent, function(val)
        cfg.Combat.AimMaxRange = val
    end)

    Components.Toggle(parent, "Predictive Aim", "Compensate for opponent velocity & ping", cfg.Combat.PredictiveAim, accent, function(val)
        cfg.Combat.PredictiveAim = val
    end)

    Components.Button(parent, "⚡ Safe Behind TP (F9)", "Teleport Behind Target", "Primary", accent, function()
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

    -- Attack Automation
    Components.Section(parent, "Attack Automation & Combos", accent)
    Components.Toggle(parent, "Auto M1 Strike", "Automatic basic attack strike loop", cfg.Combat.AutoM1, accent, function(val)
        cfg.Combat.AutoM1 = val
    end)

    Components.Slider(parent, "Auto M1 Delay", 0.05, 0.50, cfg.Combat.AutoM1Delay or 0.12, "s", 0.01, accent, function(val)
        cfg.Combat.AutoM1Delay = val
    end)

    Components.Toggle(parent, "Auto Combo Sequencer", "Optimal character combo sequence execution", cfg.Combat.AutoComboSequencer, accent, function(val)
        cfg.Combat.AutoComboSequencer = val
    end)

    Components.Dropdown(parent, "Combo Mode", { "Saitama Max Damage", "Garou Infinite Stun", "Genos Rapid Burst" }, cfg.Combat.ComboMode or "Saitama Max Damage", accent, function(val)
        cfg.Combat.ComboMode = val
    end)

    Components.Toggle(parent, "Frame Trap Wakeup", "Immediate strike on opponent getup recovery frame", cfg.Combat.FrameTrapWakeup, accent, function(val)
        cfg.Combat.FrameTrapWakeup = val
    end)

    -- Defense & Counter
    Components.Section(parent, "Defense & Counters", accent)
    Components.Toggle(parent, "Auto Parry / Block", "Block when opponent triggers attack animation", cfg.Combat.AutoParry, accent, function(val)
        cfg.Combat.AutoParry = val
    end)

    Components.Toggle(parent, "Auto Block (Hold Guard)", "Continuously hold block key when enemies are nearby", cfg.Combat.AutoBlock, accent, function(val)
        cfg.Combat.AutoBlock = val
    end)

    Components.Toggle(parent, "Packet Parry (0-Ping)", "Instant network packet level reaction", cfg.Combat.PacketParry, accent, function(val)
        cfg.Combat.PacketParry = val
    end)

    Components.Toggle(parent, "Anti-Counter Bait", "Pause attack when enemy enters counter stance", cfg.Combat.AntiCounterBait, accent, function(val)
        cfg.Combat.AntiCounterBait = val
    end)

    Components.Toggle(parent, "Anti-Ragdoll", "Quick recovery from ragdoll knockout", cfg.Combat.AntiRagdoll, accent, function(val)
        cfg.Combat.AntiRagdoll = val
    end)

    Components.Toggle(parent, "Auto Evasive Dash", "Auto side dash to evade heavy unblockables", cfg.Combat.AutoEvasive, accent, function(val)
        cfg.Combat.AutoEvasive = val
    end)

    -- Hitbox Expander & Mass Bring
    Components.Section(parent, "Hitbox & Range Expansions", accent)
    Components.Toggle(parent, "Hitbox Expander", "Expand opponent root hitbox size", cfg.Combat.HitboxExpander, accent, function(val)
        cfg.Combat.HitboxExpander = val
    end)

    Components.Slider(parent, "Hitbox Size", 4, 35, cfg.Combat.HitboxSize or 16, " studs", 1, accent, function(val)
        cfg.Combat.HitboxSize = val
    end)

    Components.Toggle(parent, "Mass Bring (FE Blitz)", "Teleport and concentrate all targets", cfg.Combat.MassBringEnabled, accent, function(val)
        cfg.Combat.MassBringEnabled = val
    end)

    Components.Slider(parent, "Mass Bring Distance", 5, 50, cfg.Combat.MassBringDistance or 20, " studs", 1, accent, function(val)
        cfg.Combat.MassBringDistance = val
    end)

    Components.Slider(parent, "Mass Bring Duration", 3, 30, cfg.Combat.MassBringDuration or 10, "s", 1, accent, function(val)
        cfg.Combat.MassBringDuration = val
    end)
end

return CombatTab
