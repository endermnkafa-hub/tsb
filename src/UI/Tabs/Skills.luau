--!strict
local Components = require("UI.Components")

local SkillsTab = {}

function SkillsTab.Build(parent: Instance, ctx: any)
    local cfg = ctx.ConfigManager.Config
    local accent = ctx.AccentName

    Components.Section(parent, "Skill Aiming & Automation", accent)
    Components.Toggle(parent, "Auto Aim Skills", "Rotate character to target on skill cast", cfg.Skills.AutoAim, accent, function(val)
        cfg.Skills.AutoAim = val
    end)

    Components.Toggle(parent, "Auto Skill Spam", "Fire skills as soon as cooldown finishes", cfg.Skills.AutoSkillSpam, accent, function(val)
        cfg.Skills.AutoSkillSpam = val
    end)

    Components.Slider(parent, "Skill Spam Delay", 0.1, 1.0, cfg.Skills.SkillSpamDelay or 0.25, "s", 0.05, accent, function(val)
        cfg.Skills.SkillSpamDelay = val
    end)

    Components.Toggle(parent, "Auto Ultimate Spam", "Instantly trigger awakening when gauge is full", cfg.Skills.AutoUltSpam, accent, function(val)
        cfg.Skills.AutoUltSpam = val
    end)

    Components.Section(parent, "Void Elimination", accent)
    Components.Toggle(parent, "Void Kill", "Teleport grabbed enemy into the void", cfg.Skills.VoidKill, accent, function(val)
        cfg.Skills.VoidKill = val
    end)

    Components.Slider(parent, "Void Depth", -500, -100, cfg.Skills.VoidDepth or -350, " studs", 10, accent, function(val)
        cfg.Skills.VoidDepth = val
    end)

    Components.Slider(parent, "Void Return Delay", 0.2, 2.0, cfg.Skills.VoidReturnDelay or 0.5, "s", 0.1, accent, function(val)
        cfg.Skills.VoidReturnDelay = val
    end)
end

return SkillsTab
