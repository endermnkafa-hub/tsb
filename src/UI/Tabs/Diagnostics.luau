--!strict
local Components = require("UI.Components")
local Theme = require("UI.Theme")

local DiagnosticsTab = {}

function DiagnosticsTab.Build(parent: Instance, ctx: any)
    local accent = ctx.AccentName
    local notifs = ctx.Notifications
    local bootstrap = ctx.Bootstrap

    Components.Section(parent, "Framework Telemetry & Runtime State", accent)

    local diag = bootstrap and bootstrap:GetDiagnostics() or {
        Status = "Operational",
        CurrentState = "IDLE",
        Network = { IsHooked = false, PacketCount = 0, LastGoal = nil },
        CacheStats = { Player = { Hits = 0, Misses = 0 }, Raycast = { Hits = 0, Misses = 0, Invalidations = 0 } },
        FeatureStates = {},
    }

    local fwStatusBadge = Components.StatusBadge(parent, "Framework Status", diag.Status or "Operational", Theme.Colors.Success)
    local fsmBadge = Components.StatusBadge(parent, "Active FSM State", tostring(diag.CurrentState or "IDLE"), Theme.Colors.Info)

    -- Network
    Components.Section(parent, "Network Interception & Packet Stats", accent)
    local netHookedStr = diag.Network.IsHooked and "ACTIVE (0-PING)" or "DEGRADED (FALLBACK)"
    local netHookedColor = diag.Network.IsHooked and Theme.Colors.Success or Theme.Colors.Warning
    local netBadge = Components.StatusBadge(parent, "Metamethod Hook", netHookedStr, netHookedColor)
    local packetBadge = Components.StatusBadge(parent, "Packets Intercepted", tostring(diag.Network.PacketCount or 0), Theme.Colors.TextPrimary)
    local goalBadge = Components.StatusBadge(parent, "Last Outgoing Goal", tostring(diag.Network.LastGoal or "None"), Theme.Colors.TextSecondary)

    -- Cache Stats
    Components.Section(parent, "Adaptive Ephemeron Cache Performance", accent)
    local pStats = diag.CacheStats.Player or { Hits = 0, Misses = 0 }
    local rStats = diag.CacheStats.Raycast or { Hits = 0, Misses = 0, Invalidations = 0 }
    
    local playerCacheBadge = Components.StatusBadge(parent, "Player Cache (Hits/Misses)", string.format("%d / %d", pStats.Hits, pStats.Misses), Theme.Colors.TextPrimary)
    local raycastCacheBadge = Components.StatusBadge(parent, "Raycast Cache (Hits/Misses)", string.format("%d / %d", rStats.Hits, rStats.Misses), Theme.Colors.TextPrimary)
    local invalBadge = Components.StatusBadge(parent, "Raycast Invalidations (Event-Driven)", tostring(rStats.Invalidations), Theme.Colors.Info)

    -- Feature Pipelines
    Components.Section(parent, "Feature Pipeline Isolation States", accent)
    local featureBadges = {}
    local featureList = { "FlyMovement", "CombatEngine", "MovementEngine", "SkillsEngine", "SurvivalEngine", "VisualsEngine" }
    for _, featName in ipairs(featureList) do
        local fState = diag.FeatureStates[featName]
        local stText = fState and fState.Status or (fState and fState.Enabled and "RUNNING" or "STOPPED")
        local stColor = (stText == "RUNNING") and Theme.Colors.Success or ((stText == "DEGRADED") and Theme.Colors.Danger or Theme.Colors.TextSecondary)
        featureBadges[featName] = Components.StatusBadge(parent, featName, stText, stColor)
    end

    -- TSB Live Telemetry & Game Data Auto-Recorder
    Components.Section(parent, "TSB Game Data & Comprehensive Combat Telemetry", accent)
    local teleStats = diag.Telemetry or {}
    
    local animBadge = Components.StatusBadge(parent, "Animations Logged", tostring(teleStats.TotalAnimations or 0), Theme.Colors.Success)
    local charBadge = Components.StatusBadge(parent, "Character Profiles", tostring(teleStats.TotalCharacters or 0), Theme.Colors.Info)
    local hitboxBadge = Components.StatusBadge(parent, "Hitbox Profiles (Rig/Parts)", tostring(teleStats.TotalHitboxProfiles or 0), Theme.Colors.Success)
    local attrBadge = Components.StatusBadge(parent, "Attributes Tracked", tostring(teleStats.TotalAttributes or 0), Theme.Colors.Info)
    local corrBadge = Components.StatusBadge(parent, "Correlations Discovered", tostring(teleStats.TotalCorrelations or 0), Theme.Colors.Success)
    local eventBadge = Components.StatusBadge(parent, "Combat & Ragdoll Events", tostring(teleStats.TotalCombatEvents or teleStats.TotalEvents or 0), Theme.Colors.Warning)
    local cdBadge = Components.StatusBadge(parent, "Skill Cooldown Profiles", tostring(teleStats.TotalCooldownProfiles or 0), Theme.Colors.TextPrimary)
    local soundBadge = Components.StatusBadge(parent, "Sounds Cataloged", tostring(teleStats.TotalSounds or 0), Theme.Colors.TextPrimary)
    local toolBadge = Components.StatusBadge(parent, "Tools & Accessories", tostring(teleStats.TotalTools or 0), Theme.Colors.TextSecondary)
    local remoteBadge = Components.StatusBadge(parent, "Remotes & Objects Found", tostring(teleStats.TotalRemotes or 0), Theme.Colors.Info)

    local cfg_diag = ctx.ConfigManager.Config
    Components.Toggle(parent, "Auto-Record All Player Data", "Enable continuous live telemetry capture from all players", cfg_diag.Telemetry and cfg_diag.Telemetry.AutoRecordData or false, accent, function(val)
        if cfg_diag.Telemetry then cfg_diag.Telemetry.AutoRecordData = val end
        notifs:Show("Telemetry", val and "Live combat data recording ACTIVE." or "Data recording paused.", 2.0, val and "Success" or "Warning")
    end)

    Components.Button(parent, "Force Save Data to Disk (tsb_data/ & tsb_combat_data.json)", "Save Telemetry Now", "Primary", accent, function()
        if bootstrap and bootstrap.Container and bootstrap.Container:Has("TelemetryRecorder") then
            local recorder = bootstrap.Container:Get("TelemetryRecorder")
            recorder:SaveToDisk(true)
            local st = recorder:GetStats()
            animBadge.Update(tostring(st.TotalAnimations), Theme.Colors.Success)
            charBadge.Update(tostring(st.TotalCharacters), Theme.Colors.Info)
            hitboxBadge.Update(tostring(st.TotalHitboxProfiles), Theme.Colors.Success)
            attrBadge.Update(tostring(st.TotalAttributes), Theme.Colors.Info)
            corrBadge.Update(tostring(st.TotalCorrelations), Theme.Colors.Success)
            eventBadge.Update(tostring(st.TotalCombatEvents), Theme.Colors.Warning)
            cdBadge.Update(tostring(st.TotalCooldownProfiles), Theme.Colors.TextPrimary)
            soundBadge.Update(tostring(st.TotalSounds), Theme.Colors.TextPrimary)
            toolBadge.Update(tostring(st.TotalTools), Theme.Colors.TextSecondary)
            remoteBadge.Update(tostring(st.TotalRemotes), Theme.Colors.Info)
            notifs:Show("Telemetry", string.format("Saved dataset (%d anims, %d chars, %d hitboxes) to disk!", st.TotalAnimations, st.TotalCharacters, st.TotalHitboxProfiles), 3.0, "Success")
        else
            notifs:Show("Telemetry", "TelemetryRecorder service not ready.", 2.5, "Error")
        end
    end)

    Components.Button(parent, "Export Telemetry Summary", "Export Summary", "Secondary", accent, function()
        if bootstrap and bootstrap.Container and bootstrap.Container:Has("TelemetryRecorder") then
            local recorder = bootstrap.Container:Get("TelemetryRecorder")
            local summary = recorder:ExportSummary()
            pcall(function()
                if typeof(setclipboard) == "function" then
                    setclipboard(summary)
                    notifs:Show("Telemetry Export", "Summary copied to clipboard!\n" .. summary, 4.0, "Success")
                    return
                end
            end)
            notifs:Show("Telemetry Export", summary, 4.0, "Info")
        end
    end)

    -- Diagnostics Actions & Test Suite
    Components.Section(parent, "Automated Diagnostic Verification", accent)

    local testResultBadge = Components.StatusBadge(parent, "Unit Test Suite", "NOT RUN (CLICK BELOW)", Theme.Colors.TextMuted)

    Components.Button(parent, "Run In-Memory Unit Tests", "Run Tests", "Primary", accent, function()
        testResultBadge.Update("RUNNING...", Theme.Colors.Warning)
        task.defer(function()
            local UnitTests = require("Diagnostics.UnitTests")
            local allPassed, testResults = UnitTests.RunAll()
            local passedCount = 0
            local totalCount = 0
            for _, passed in pairs(testResults) do
                totalCount += 1
                if passed then passedCount += 1 end
            end

            if allPassed then
                testResultBadge.Update(string.format("%d/%d PASSED (100%%)", passedCount, totalCount), Theme.Colors.Success)
                notifs:Show("Unit Tests", string.format("All %d automated tests passed flawlessly!", totalCount), 3.0, "Success")
            else
                testResultBadge.Update(string.format("%d/%d PASSED (FAILURES)", passedCount, totalCount), Theme.Colors.Danger)
                notifs:Show("Unit Tests", "Some unit tests reported failures.", 3.0, "Error")
            end
        end)
    end)

    Components.Button(parent, "Refresh Diagnostics Telemetry", "Refresh", "Secondary", accent, function()
        if bootstrap then
            local fresh = bootstrap:GetDiagnostics()
            fwStatusBadge.Update(fresh.Status or "Operational", Theme.Colors.Success)
            fsmBadge.Update(tostring(fresh.CurrentState or "IDLE"), Theme.Colors.Info)
            
            local nHooked = fresh.Network.IsHooked and "ACTIVE (0-PING)" or "DEGRADED (FALLBACK)"
            local nColor = fresh.Network.IsHooked and Theme.Colors.Success or Theme.Colors.Warning
            netBadge.Update(nHooked, nColor)
            packetBadge.Update(tostring(fresh.Network.PacketCount or 0), Theme.Colors.TextPrimary)
            goalBadge.Update(tostring(fresh.Network.LastGoal or "None"), Theme.Colors.TextSecondary)

            local freshP = fresh.CacheStats.Player or { Hits = 0, Misses = 0 }
            local freshR = fresh.CacheStats.Raycast or { Hits = 0, Misses = 0, Invalidations = 0 }
            playerCacheBadge.Update(string.format("%d / %d", freshP.Hits, freshP.Misses), Theme.Colors.TextPrimary)
            raycastCacheBadge.Update(string.format("%d / %d", freshR.Hits, freshR.Misses), Theme.Colors.TextPrimary)
            invalBadge.Update(tostring(freshR.Invalidations), Theme.Colors.Info)

            local freshTele = fresh.Telemetry or {}
            animBadge.Update(tostring(freshTele.TotalAnimations or 0), Theme.Colors.Success)
            charBadge.Update(tostring(freshTele.TotalCharacters or 0), Theme.Colors.Info)
            hitboxBadge.Update(tostring(freshTele.TotalHitboxProfiles or 0), Theme.Colors.Success)
            attrBadge.Update(tostring(freshTele.TotalAttributes or 0), Theme.Colors.Info)
            corrBadge.Update(tostring(freshTele.TotalCorrelations or 0), Theme.Colors.Success)
            eventBadge.Update(tostring(freshTele.TotalCombatEvents or freshTele.TotalEvents or 0), Theme.Colors.Warning)
            cdBadge.Update(tostring(freshTele.TotalCooldownProfiles or 0), Theme.Colors.TextPrimary)
            soundBadge.Update(tostring(freshTele.TotalSounds or 0), Theme.Colors.TextPrimary)
            toolBadge.Update(tostring(freshTele.TotalTools or 0), Theme.Colors.TextSecondary)
            remoteBadge.Update(tostring(freshTele.TotalRemotes or 0), Theme.Colors.Info)

            for fName, b in pairs(featureBadges) do
                local fs = fresh.FeatureStates[fName]
                local txt = fs and fs.Status or (fs and fs.Enabled and "RUNNING" or "STOPPED")
                local col = (txt == "RUNNING") and Theme.Colors.Success or ((txt == "DEGRADED") and Theme.Colors.Danger or Theme.Colors.TextSecondary)
                b.Update(txt, col)
            end

            notifs:Show("Diagnostics", "Telemetry metrics refreshed.", 1.8, "Info")
        end
    end)
end

return DiagnosticsTab
