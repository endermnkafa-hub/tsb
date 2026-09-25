--!strict
local Players = game:GetService("Players")
local LocalPlayer = Players.LocalPlayer

local Components = require("UI.Components")
local Theme = require("UI.Theme")

local TargetTab = {}

function TargetTab.Build(parent: Instance, ctx: any)
    local cfg = ctx.ConfigManager.Config
    local notifs = ctx.Notifications
    local accent = ctx.AccentName
    if not cfg.Target then cfg.Target = {} end

    -- Section 1: Target Selection & Targeting Mode
    Components.Section(parent, "Target Selection & Filtering", accent)

    Components.Dropdown(parent, "Targeting Mode", { "Nearest", "Lowest HP", "Random", "Specific Player" }, cfg.Target.TargetMode or "Nearest", accent, function(val)
        cfg.Target.TargetMode = val
        if cfg.Combat then cfg.Combat.AimMode = val end
        notifs:Show("Target Mode", "Targeting mode set to: " .. val, 2.0, "Info")
    end)

    -- Specific Player Dynamic List Generator
    local function GetPlayerNames(): { string }
        local list = { "None" }
        for _, p in ipairs(Players:GetPlayers()) do
            if p ~= LocalPlayer then
                table.insert(list, p.Name)
            end
        end
        return list
    end

    local playerList = GetPlayerNames()
    local curSpecific = cfg.Target.SpecificPlayer or "None"
    local playerDropdownRef = Components.Dropdown(parent, "Select Specific Player", playerList, curSpecific, accent, function(val)
        cfg.Target.SpecificPlayer = val
        notifs:Show("Target Locked", "Specific target set to: " .. val, 2.0, "Success")
    end)

    Components.Button(parent, "Refresh Online Player List", "Refresh Players", "Secondary", accent, function()
        local freshList = GetPlayerNames()
        if playerDropdownRef and playerDropdownRef.SetOptions then
            playerDropdownRef.SetOptions(freshList)
        end
        notifs:Show("Player List", string.format("Refreshed! Found %d players.", #freshList - 1), 2.0, "Info")
    end)

    -- Section 2: Continuous Safe Behind Lock (Continuous Flank)
    Components.Section(parent, "Continuous Safe Behind Lock (F9)", accent)

    Components.Toggle(parent, "Continuous Behind Lock (F9)", "Stay glued behind enemy back continuously until turned off", cfg.Target.BehindTP or false, accent, function(val)
        cfg.Target.BehindTP = val
        if val then
            local combat = ctx.Container and ctx.Container:Get("Combat")
            local t = combat and combat:GetTarget(cfg)
            local tName = t and t.Name or "Opponent"
            notifs:Show("⚡ Safe Behind Lock", "LOCKED behind " .. tName .. " (Continuous)", 2.5, "Success")
        else
            notifs:Show("Safe Behind Lock", "Unlocked from opponent.", 2.0, "Warning")
        end
    end)

    Components.Slider(parent, "Behind Distance (Studs)", 1.0, 15.0, cfg.Target.BehindDistance or 3.5, " studs", 0.5, accent, function(val)
        cfg.Target.BehindDistance = val
    end)

    Components.Toggle(parent, "Auto M1 While Behind", "Repeatedly strike enemy with basic attack while glued behind", cfg.Target.AutoM1OnTP ~= false, accent, function(val)
        cfg.Target.AutoM1OnTP = val
    end)

    Components.Button(parent, "⚡ Instant Behind Snap (Single Tap)", "Behind Snap", "Primary", accent, function()
        if ctx.Container and ctx.Container:Has("Movement") and ctx.Container:Has("Combat") then
            local movement = ctx.Container:Get("Movement")
            local combat = ctx.Container:Get("Combat")
            local success, targetName = movement:ExecuteBehindTP(cfg, combat)
            if success then
                notifs:Show("⚡ Behind Snap", "Teleported safely behind " .. tostring(targetName), 2.0, "Success")
            else
                notifs:Show("Behind Snap", tostring(targetName), 2.0, "Warning")
            end
        end
    end)
end

return TargetTab
