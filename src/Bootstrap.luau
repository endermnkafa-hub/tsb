--!strict
local ServiceContainer = require("Core.ServiceContainer")
local Signal = require("Core.Signal")
local EventBus = require("Core.EventBus")
local Logger = require("Core.Logger")
local Maid = require("Core.Maid")
local Scheduler = require("Core.Scheduler")
local StateMachine = require("Architecture.StateMachine")
local FeatureManager = require("Architecture.FeatureManager")
local Profiler = require("Performance.Profiler")
local CacheEngine = require("Performance.Cache")
local ObjectPool = require("Performance.ObjectPool")
local ConfigManager = require("Config.ConfigManager")
local NetworkEngine = require("Network.NetworkEngine")
local RemoteResolver = require("Network.RemoteResolver")
local Combat = require("Systems.Combat")
local Movement = require("Systems.Movement")
local Survival = require("Systems.Survival")
local Skills = require("Systems.Skills")
local World = require("Systems.World")
local Visuals = require("Systems.Visuals")
local EnemyState = require("Systems.EnemyState")
local TelemetryRecorder = require("Systems.TelemetryRecorder")
local UnitTests = require("Diagnostics.UnitTests")
local SelfDiagnostics = require("Diagnostics.SelfDiagnostics")
local UIController = require("UI.UIController")

local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local Bootstrap = {
    _maid = nil :: any,
    _isInitialized = false,
    Container = nil :: any,
}

function Bootstrap:Init()
    if self._isInitialized then
        -- Prevent Duplicate Loops: Destroy previous instance symmetrically
        self:Destroy()
    end

    self._maid = Maid.new()
    self._isInitialized = true

    local logger = Logger.new(3)
    logger:Info("Bootstrap", "=== 4080 HUB v9.0 PRODUCTION SPECIALIST FRAMEWORK BOOTING ===")

    -- 1. Create Core Instances (Instance-based OOP Architecture)
    local container = ServiceContainer.new()
    self.Container = container
    local eventBus = EventBus.new()
    local scheduler = Scheduler.new()
    local profiler = Profiler.new()
    local cache = CacheEngine.new(0.08)
    local fsm = StateMachine.new("IDLE", logger)
    local featureManager = FeatureManager.new(logger, profiler)
    local configManager = ConfigManager.new(logger)
    local diagnostics = SelfDiagnostics.new(logger)

    -- 2. Register Core Singletons into IoC Container
    container:Register("Logger", logger, {})
    container:Register("EventBus", eventBus, { "Logger" })
    container:Register("Scheduler", scheduler, { "Logger" })
    container:Register("Profiler", profiler, {})
    container:Register("Cache", cache, {})
    container:Register("StateMachine", fsm, { "Logger" })
    container:Register("FeatureManager", featureManager, { "Logger", "Profiler" })
    container:Register("ConfigManager", configManager, { "Logger" })
    container:Register("Diagnostics", diagnostics, { "Logger" })
    container:Register("ObjectPool", ObjectPool, {})

    -- 3. Register Systems via True Constructor Dependency Injection with Explicit DAG Dependencies
    container:Register("RemoteResolver", function(c)
        return RemoteResolver.new(c:Get("Logger"))
    end, { "Logger" })

    container:Register("NetworkEngine", function(c)
        return NetworkEngine.new({
            Logger = c:Get("Logger"),
            EventBus = c:Get("EventBus"),
            RemoteResolver = c:Get("RemoteResolver"),
        })
    end, { "Logger", "EventBus", "RemoteResolver" })

    container:Register("EnemyState", function(c)
        return EnemyState.new({
            Cache = c:Get("Cache"),
            EventBus = c:Get("EventBus"),
            Logger = c:Get("Logger"),
        })
    end, { "Cache", "EventBus", "Logger" })

    container:Register("Combat", function(c)
        return Combat.new({
            Cache = c:Get("Cache"),
            EventBus = c:Get("EventBus"),
            Network = c:Get("NetworkEngine"),
            EnemyState = c:Get("EnemyState"),
            Logger = c:Get("Logger"),
            StateMachine = c:Get("StateMachine"),
        })
    end, { "Cache", "EventBus", "NetworkEngine", "EnemyState", "Logger", "StateMachine" })

    container:Register("Movement", function(c)
        return Movement.new({
            Cache = c:Get("Cache"),
            Logger = c:Get("Logger"),
        })
    end, { "Cache", "Logger" })

    container:Register("Survival", function(c)
        return Survival.new({
            Cache = c:Get("Cache"),
            StateMachine = c:Get("StateMachine"),
            EventBus = c:Get("EventBus"),
            Logger = c:Get("Logger"),
        })
    end, { "Cache", "StateMachine", "EventBus", "Logger" })

    container:Register("Skills", function(c)
        return Skills.new({
            Cache = c:Get("Cache"),
            Combat = c:Get("Combat"),
            Logger = c:Get("Logger"),
        })
    end, { "Cache", "Combat", "Logger" })

    container:Register("World", function(c)
        return World.new({
            ConfigManager = c:Get("ConfigManager"),
            Logger = c:Get("Logger"),
        })
    end, { "ConfigManager", "Logger" })

    container:Register("Visuals", function(c)
        return Visuals.new({
            Cache = c:Get("Cache"),
            ObjectPool = ObjectPool,
            Logger = c:Get("Logger"),
        })
    end, { "Cache", "ObjectPool", "Logger" })

    container:Register("TelemetryRecorder", function(c)
        return TelemetryRecorder.new({
            Cache = c:Get("Cache"),
            EventBus = c:Get("EventBus"),
            Logger = c:Get("Logger"),
        })
    end, { "Cache", "EventBus", "Logger" })

    local this = self
    container:Register("UIController", function(c)
        return UIController.new({
            ConfigManager = c:Get("ConfigManager"),
            FeatureManager = c:Get("FeatureManager"),
            StateMachine = c:Get("StateMachine"),
            Profiler = c:Get("Profiler"),
            Cache = c:Get("Cache"),
            NetworkEngine = c:Get("NetworkEngine"),
            Logger = c:Get("Logger"),
            Bootstrap = this,
            Container = c,
        })
    end, { "ConfigManager", "FeatureManager", "StateMachine", "Profiler", "Cache", "NetworkEngine", "Logger" })

    -- 4. Run Diagnostics Health Check
    pcall(function() diagnostics:RunHealthCheck() end)

    -- 5. Topological DAG Resolution of All Systems
    local initOrder = container:ResolveAllInOrder()
    logger:Info("Bootstrap", string.format("DAG Resolution Complete. Initialized %d services in topological order.", #initOrder))

    local network = container:Get("NetworkEngine")
    network:Init()
    self._maid:GiveTask(function() network:Destroy() end)

    -- Event-Driven Cache Invalidation connected to Root Maid
    cache:HookWorkspaceEvents(self._maid)

    local combat = container:Get("Combat")
    local movement = container:Get("Movement")
    local survival = container:Get("Survival")
    local skills = container:Get("Skills")
    local world = container:Get("World")
    local visuals = container:Get("Visuals")
    local enemyState = container:Get("EnemyState")
    local telemetryRecorder = container:Get("TelemetryRecorder")
    self._maid:GiveTask(function() telemetryRecorder:Destroy() end)
    self._maid:GiveTask(function() movement:Destroy() end)

    -- 6. Load Config
    configManager:Load()

    -- Wire jump features after config is loaded (event-driven, respawn-safe)
    movement:ToggleJumpFeatures(configManager.Config)
    -- Re-wire if config toggles change jump settings via UI (config reference is shared, so
    -- the toggle callbacks set config.Movement.InfiniteJump/DoubleJump directly. We also
    -- wire it once here so any persisted config is applied on boot.)

    -- 7. Active Scheduler Tasks Registration (Tiered Frequencies)
    scheduler:Register("Aimlock_Fast", "Fast", function(dt)
        combat:UpdateAimlock(configManager.Config)
    end)

    scheduler:Register("EnemyState_Normal", "Normal", function(dt)
        for _, p in ipairs(Players:GetPlayers()) do
            if p ~= Players.LocalPlayer then
                enemyState:Update(p)
            end
        end
    end)

    scheduler:Register("WorldHop_Slow", "Slow", function(dt)
        world:CheckAutoServerHop(configManager.Config)
    end)

    -- World environment features (FullBright, Fog, CustomFOV) — 2Hz sync
    scheduler:Register("WorldEnv_Slow", "Slow", function(dt)
        local cfg = configManager.Config
        if cfg.World then
            world:ToggleFullBright(cfg.World.FullBright or false)
            world:ToggleRemoveFog(cfg.World.RemoveFog or false)
            if cfg.World.CustomFOV and Workspace.CurrentCamera then
                Workspace.CurrentCamera.FieldOfView = cfg.World.FOVValue or 90
            end
        end
    end)

    -- AntiAFK: VirtualUser simulation — throttled to once per 60 seconds max
    local lastAntiAFKTick = 0
    scheduler:Register("AntiAFK_Background", "Background", function(dt)
        local cfg = configManager.Config
        if cfg.World and cfg.World.AntiAFK then
            local now = os.clock()
            if (now - lastAntiAFKTick) >= 60 then
                lastAntiAFKTick = now
                pcall(function()
                    local vu = game:GetService("VirtualUser")
                    if vu then vu:CaptureController() vu:ClickButton2(Vector2.new()) end
                end)
            end
        end
    end)

    scheduler:Register("Telemetry_Slow", "Slow", function(dt)
        profiler:UpdateSystemMetrics()
    end)

    scheduler:Register("CombatTelemetry_Background", "Background", function(dt)
        telemetryRecorder:Update(dt, configManager.Config)
    end)

    scheduler:Register("ConfigAutosave_Background", "Background", function(dt)
        configManager:Save()
    end)

    -- 8. Register and Validate Feature Pipelines
    featureManager:Register({
        Name = "FlyMovement",
        Phase = "RenderStepped",
        Priority = 90,
        Budget = 1.0,
        Dependencies = { "Movement", "Cache" },
        Enabled = true,
        Update = function(self, dt, ctx) movement:UpdateFly(dt, configManager.Config) end
    })

    featureManager:Register({
        Name = "CombatEngine",
        Phase = "Heartbeat",
        Priority = 100,
        Budget = 2.0,
        Dependencies = { "Combat", "Cache", "EnemyState" },
        Enabled = true,
        Update = function(self, dt, ctx)
            combat:UpdateAutoM1(configManager.Config)
            combat:UpdateAutoBlock(configManager.Config)
            combat:UpdateHitboxExpander(configManager.Config)
            combat:UpdateAutoEvasive(configManager.Config)
            combat:UpdateMassBring(configManager.Config)
            movement:UpdateBehindLock(dt, configManager.Config, combat)
        end
    })

    featureManager:Register({
        Name = "MovementEngine",
        Phase = "Heartbeat",
        Priority = 90,
        Budget = 1.0,
        Dependencies = { "Movement", "Combat" },
        Enabled = true,
        Update = function(self, dt, ctx)
            movement:UpdateSpeed(dt, configManager.Config)
            movement:UpdateAntiVoid(configManager.Config)
            combat:UpdateAntiRagdoll(configManager.Config)
        end
    })

    featureManager:Register({
        Name = "SkillsEngine",
        Phase = "Heartbeat",
        Priority = 80,
        Budget = 1.0,
        Dependencies = { "Skills", "Combat", "Cache" },
        Enabled = true,
        Update = function(self, dt, ctx)
            skills:UpdateAutoSkillSpam(configManager.Config)
            skills:UpdateVoidKill(configManager.Config)
        end
    })

    featureManager:Register({
        Name = "SurvivalEngine",
        Phase = "Heartbeat",
        Priority = 85,
        Budget = 1.5,
        Dependencies = { "Survival", "StateMachine" },
        Enabled = true,
        Update = function(self, dt, ctx)
            survival:UpdateSkyDodge(dt, configManager.Config)
            survival:CheckSkyEscape(configManager.Config)
        end
    })

    featureManager:Register({
        Name = "VisualsEngine",
        Phase = "Heartbeat",
        Priority = 70,
        Budget = 2.0,
        Dependencies = { "Visuals", "Cache" },
        Enabled = true,
        Update = function(self, dt, ctx)
            visuals:Update(configManager.Config)
        end
    })

    -- Validate all feature dependencies in DI container
    local depsOk, depReport = featureManager:ValidateDependencies(container)
    logger:Info("Bootstrap", string.format("Feature Dependency Graph: %s", depsOk and "ALL SATISFIED" or "DEGRADED ISOLATION ACTIVE"))

    featureManager:InitAll(container)
    self._maid:GiveTask(function() featureManager:DestroyAll() end)

    -- 9. Connect Game Loop Pipelines & Store Connections in Root Maid
    local rsConn = RunService.RenderStepped:Connect(function(dt)
        featureManager:ExecutePipeline("RenderStepped", dt, container)
    end)
    self._maid:GiveTask(rsConn)

    local stConn = RunService.Stepped:Connect(function()
        movement:UpdateNoclip(configManager.Config)
        featureManager:ExecutePipeline("Stepped", 1/60, container)
    end)
    self._maid:GiveTask(stConn)

    local hbConn = RunService.Heartbeat:Connect(function(dt)
        fsm:Update(dt, container)
        scheduler:Step(dt)
        featureManager:ExecutePipeline("Heartbeat", dt, container)
    end)
    self._maid:GiveTask(hbConn)

    -- 10. Initialize GUI Presentation Layer
    local okUI, uiOrErr = pcall(function()
        local uiController = container:Get("UIController")
        uiController:Init()
        self.UIController = uiController
        self._maid:GiveTask(function()
            uiController:Destroy()
            self.UIController = nil
        end)
    end)
    if not okUI then
        logger:Warn("Bootstrap", string.format("GUI Initialization warning: %s", tostring(uiOrErr)))
    end

    logger:Info("Bootstrap", "=== 4080 HUB FRAMEWORK FULLY OPERATIONAL (SPECIALIST PRODUCTION ARCHITECTURE) ===")
end

function Bootstrap:Destroy()
    if self._maid then
        self._maid:DoCleaning()
        self._maid = nil
    end
    self.UIController = nil
    self._isInitialized = false
end

function Bootstrap:GetDiagnostics(): { [string]: any }
    if not self._isInitialized or not self.Container then
        return { Status = "Uninitialized", Initialized = false }
    end

    local profiler = self.Container:Get("Profiler")
    local fsm = self.Container:Get("StateMachine")
    local featureManager = self.Container:Get("FeatureManager")
    local cache = self.Container:Get("Cache")
    local network = self.Container:Get("NetworkEngine")
    local telemetry = self.Container:Has("TelemetryRecorder") and self.Container:Get("TelemetryRecorder") or nil

    return {
        Status = "Operational",
        Initialized = true,
        CurrentState = fsm and fsm.CurrentState or "UNKNOWN",
        StateHistory = fsm and fsm.TelemetryLogs or {},
        FeatureStates = featureManager and featureManager:GetFeatureStates() or {},
        Network = {
            IsHooked = network and network._isHooked or false,
            PacketCount = network and network.PacketCount or 0,
            LastGoal = network and network.LastGoal or nil,
        },
        CacheStats = {
            Player = cache and cache.PlayerStats or {},
            Raycast = cache and cache.RaycastStats or {},
        },
        Telemetry = telemetry and telemetry:GetStats() or {},
        ProfilerReport = profiler and profiler:GetReport() or {},
    }
end

return Bootstrap
