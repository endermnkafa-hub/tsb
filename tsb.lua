-- // ========================================================================================
-- // ⚡ 4080 CUSTOM HUB v9.0 - SPECIALIST PRODUCTION FRAMEWORK
-- // Architecture: Modular Luau Service Architecture + IoC Container + FSM & Telemetry
-- // Pipeline: Automated CI/CD Verified Build
-- // ========================================================================================

local __modules = {}
local __cache = {}
local __loading = {}

local function require(modName)
    local normalized = modName:gsub("%.luau$", ""):gsub("%.lua$", ""):gsub("^src/", "")
    normalized = normalized:gsub("/", ".")
    
    if __cache[normalized] ~= nil then
        return __cache[normalized]
    end

    -- Exact or normalized match
    local modFunc = __modules[normalized] or __modules[modName] or __modules[normalized:gsub("%.", "/")]
    if not modFunc then
        for k, v in pairs(__modules) do
            if k:lower() == normalized:lower() or k:lower() == modName:lower() then
                modFunc = v
                normalized = k
                break
            end
        end
    end

    if not modFunc then
        error(string.format("[Bundler] Module '%s' not found!", tostring(modName)))
    end

    if __loading[normalized] then
        -- Circular require cycle guard: prevent infinite C-stack recursion
        if __cache[normalized] == nil then
            __cache[normalized] = {}
        end
        return __cache[normalized]
    end

    __loading[normalized] = true
    local exports = modFunc()
    __cache[normalized] = exports
    __loading[normalized] = nil

    return exports
end

-- ============================================================================
-- Module: Architecture.FeatureManager
-- ============================================================================
__modules["Architecture.FeatureManager"] = function()
--!strict
local Maid = require("Core.Maid")

export type Feature = {
    Name: string,
    Phase: string,
    Priority: number,
    Budget: number,
    Dependencies: { string },
    Enabled: boolean,
    Status: string, -- "INITIALIZED", "RUNNING", "STOPPED", "DEGRADED", "THROTTLED"
    DegradedReason: string?,
    OverBudgetCount: number,
    Maid: any,
    Init: ((self: Feature, ctx: any) -> ())?,
    Start: ((self: Feature, ctx: any) -> ())?,
    Update: ((self: Feature, dt: number, ctx: any) -> ())?,
    Stop: ((self: Feature, ctx: any) -> ())?,
    Destroy: ((self: Feature) -> ())?,
}

local FeatureManager = {}
FeatureManager.__index = FeatureManager

function FeatureManager.new(logger: any, profiler: any)
    local self = setmetatable({
        _logger = logger,
        _profiler = profiler,
        _features = {},
        _renderPipeline = {},
        _steppedPipeline = {},
        _heartbeatPipeline = {},
    }, FeatureManager)
    return self
end

function FeatureManager:Register(def: any): Feature
    assert(type(def.Name) == "string", "Feature must have a unique Name")
    local feat: Feature = {
        Name = def.Name,
        Phase = def.Phase or "Heartbeat",
        Priority = def.Priority or 50,
        Budget = def.Budget or 2.0, -- in ms
        Dependencies = def.Dependencies or {},
        Enabled = def.Enabled or false,
        Status = "INITIALIZED",
        DegradedReason = nil,
        OverBudgetCount = 0,
        Maid = Maid.new(),
        Init = def.Init,
        Start = def.Start,
        Update = def.Update,
        Stop = def.Stop,
        Destroy = def.Destroy,
    }

    self._features[feat.Name] = feat

    local list = self._heartbeatPipeline
    if feat.Phase == "RenderStepped" then list = self._renderPipeline
    elseif feat.Phase == "Stepped" then list = self._steppedPipeline end

    table.insert(list, feat)
    table.sort(list, function(a, b) return a.Priority > b.Priority end)
    return feat
end

function FeatureManager:ValidateDependencies(container: any): (boolean, { [string]: string })
    local report = {}
    local allValid = true

    for name, feat in pairs(self._features) do
        for _, dep in ipairs(feat.Dependencies) do
            if not container:Has(dep) and not self._features[dep] then
                local reason = string.format("Missing Required Dependency '%s'", dep)
                report[name] = reason
                feat.Status = "DEGRADED"
                feat.DegradedReason = reason
                feat.Enabled = false -- Isolate and prevent execution
                allValid = false
            end
        end
    end

    return allValid, report
end

function FeatureManager:InitAll(ctx: any)
    for name, feat in pairs(self._features) do
        if feat.Status == "DEGRADED" then
            self._logger:Warn("FeatureManager", string.format("Skipping Degraded Feature '%s': %s", name, tostring(feat.DegradedReason)))
            continue
        end

        if feat.Init then
            self._logger:SafeCall(name .. ".Init", feat.Init, feat, ctx)
        end

        if feat.Enabled then
            feat.Status = "RUNNING"
            if feat.Start then
                self._logger:SafeCall(name .. ".Start", feat.Start, feat, ctx)
            end
        end
    end
end

function FeatureManager:SetEnabled(name: string, enabled: boolean, ctx: any)
    local feat = self._features[name]
    if not feat or feat.Enabled == enabled then return end

    if feat.Status == "DEGRADED" and enabled then
        self._logger:Warn("FeatureManager", string.format("Cannot enable Degraded Feature '%s': %s", name, tostring(feat.DegradedReason)))
        return
    end

    feat.Enabled = enabled
    if enabled then
        feat.Status = "RUNNING"
        if feat.Start then
            self._logger:SafeCall(name .. ".Start", feat.Start, feat, ctx)
        end
    else
        feat.Status = "STOPPED"
        feat.Maid:DoCleaning()
        if feat.Stop then
            self._logger:SafeCall(name .. ".Stop", feat.Stop, feat, ctx)
        end
    end
end

function FeatureManager:ExecutePipeline(phase: string, dt: number, ctx: any)
    local list = self._heartbeatPipeline
    if phase == "RenderStepped" then list = self._renderPipeline
    elseif phase == "Stepped" then list = self._steppedPipeline end

    for _, feat in ipairs(list) do
        if feat.Enabled and feat.Status ~= "DEGRADED" and feat.Update then
            -- Active Throttling with Hysteresis
            local metric = self._profiler and self._profiler.Metrics[feat.Name]
            if metric and metric.Status == "OVER_BUDGET" then
                feat.OverBudgetCount += 1
                if feat.OverBudgetCount > 3 then
                    feat.Status = "THROTTLED"
                    if (feat.OverBudgetCount % 2) == 0 then
                        continue -- Frame skip
                    end
                end
            else
                feat.OverBudgetCount = 0
                if feat.Status == "THROTTLED" then
                    feat.Status = "RUNNING"
                end
            end

            local start = self._profiler and self._profiler:Begin(feat.Name, feat.Budget)
            self._logger:SafeCall(feat.Name .. ".Update", feat.Update, feat, dt, ctx)
            if self._profiler then
                self._profiler:End(feat.Name, start)
            end
        end
    end
end

function FeatureManager:DestroyAll()
    for _, feat in pairs(self._features) do
        feat.Enabled = false
        feat.Maid:DoCleaning()
        if feat.Destroy then
            pcall(feat.Destroy, feat)
        end
    end
    table.clear(self._features)
    table.clear(self._renderPipeline)
    table.clear(self._steppedPipeline)
    table.clear(self._heartbeatPipeline)
end

function FeatureManager:GetFeature(name: string): Feature?
    return self._features[name]
end

function FeatureManager:GetFeatureStates(): { [string]: { Enabled: boolean, Status: string, Budget: number, Priority: number, OverBudgetCount: number } }
    local states = {}
    for name, feat in pairs(self._features) do
        states[name] = {
            Enabled = feat.Enabled,
            Status = feat.Status,
            Budget = feat.Budget,
            Priority = feat.Priority,
            OverBudgetCount = feat.OverBudgetCount,
        }
    end
    return states
end

return FeatureManager

end
__modules["Architecture/FeatureManager"] = __modules["Architecture.FeatureManager"]

-- ============================================================================
-- Module: Architecture.StateMachine
-- ============================================================================
__modules["Architecture.StateMachine"] = function()
--!strict
local Signal = require("Core.Signal")

export type StateDefinition = {
    Priority: number?,
    Timeout: number?, -- Max duration in seconds before auto-recovering to fallback
    FallbackState: string?,
    OnEnter: ((self: any, prevState: string, ctx: any, reason: string?) -> ())?,
    OnUpdate: ((self: any, dt: number, ctx: any) -> ())?,
    OnExit: ((self: any, nextState: string, ctx: any) -> ())?,
    CanEnter: ((self: any, ctx: any) -> boolean)?,
    CanExit: ((self: any, ctx: any) -> boolean)?,
}

export type TransitionTelemetry = {
    From: string,
    To: string,
    Reason: string,
    Source: string,
    Timestamp: number,
    DurationInPrev: number,
}

local StateMachine = {}
StateMachine.__index = StateMachine

function StateMachine.new(initialState: string?, logger: any?)
    local self = setmetatable({
        CurrentState = initialState or "IDLE",
        PreviousState = "NONE",
        StateStartTime = os.clock(),
        TransitionsCount = 0,
        History = {},
        TelemetryLogs = {}, -- Structured Transition Telemetry
        MaxTelemetryLogs = 50,
        StateChanged = Signal.new(),
        _logger = logger,
        _states = {},
        _transitions = {},
        _priorities = {
            EMERGENCY_STOP = 100,
            SKY_ESCAPE     = 90,
            SKY_DODGE      = 80,
            VOID_KILL      = 70,
            MASS_BRING     = 60,
            BEHIND_TP      = 50,
            COMBAT         = 30,
            IDLE           = 0,
        },
    }, StateMachine)

    self:RegisterDefaultTransitions()
    return self
end

function StateMachine:RegisterState(name: string, def: StateDefinition)
    self._states[name] = def
    if def.Priority then
        self._priorities[name] = def.Priority
    end
end

function StateMachine:RegisterTransition(fromState: string | { string }, toState: string, condition: ((ctx: any) -> boolean)?)
    local fromList = type(fromState) == "table" and fromState or { fromState }
    for _, f in ipairs(fromList) do
        local key = f .. "->" .. toState
        self._transitions[key] = {
            From = f,
            To = toState,
            Condition = condition,
        }
    end
end

function StateMachine:RegisterDefaultTransitions()
    -- Explicit Strict Whitelist Transitions Graph
    self:RegisterTransition("IDLE", "COMBAT")
    self:RegisterTransition("IDLE", "BEHIND_TP")
    self:RegisterTransition("IDLE", "MASS_BRING")
    self:RegisterTransition("IDLE", "VOID_KILL")
    self:RegisterTransition("IDLE", "SKY_DODGE")
    self:RegisterTransition("IDLE", "SKY_ESCAPE")
    self:RegisterTransition("IDLE", "EMERGENCY_STOP")

    self:RegisterTransition("COMBAT", "IDLE")
    self:RegisterTransition("COMBAT", "BEHIND_TP")
    self:RegisterTransition("COMBAT", "MASS_BRING")
    self:RegisterTransition("COMBAT", "VOID_KILL")
    self:RegisterTransition("COMBAT", "SKY_DODGE")
    self:RegisterTransition("COMBAT", "SKY_ESCAPE")
    self:RegisterTransition("COMBAT", "EMERGENCY_STOP")

    self:RegisterTransition("BEHIND_TP", "IDLE")
    self:RegisterTransition("BEHIND_TP", "COMBAT")
    self:RegisterTransition("BEHIND_TP", "SKY_DODGE")
    self:RegisterTransition("BEHIND_TP", "SKY_ESCAPE")
    self:RegisterTransition("BEHIND_TP", "EMERGENCY_STOP")

    self:RegisterTransition("MASS_BRING", "IDLE")
    self:RegisterTransition("MASS_BRING", "COMBAT")
    self:RegisterTransition("MASS_BRING", "EMERGENCY_STOP")

    self:RegisterTransition("VOID_KILL", "IDLE")
    self:RegisterTransition("VOID_KILL", "EMERGENCY_STOP")

    self:RegisterTransition("SKY_DODGE", "IDLE")
    self:RegisterTransition("SKY_DODGE", "COMBAT")
    self:RegisterTransition("SKY_DODGE", "EMERGENCY_STOP")

    self:RegisterTransition("SKY_ESCAPE", "IDLE")
    self:RegisterTransition("SKY_ESCAPE", "EMERGENCY_STOP")

    self:RegisterTransition("EMERGENCY_STOP", "IDLE")
end

function StateMachine:CanTransitionTo(targetState: string, ctx: any): boolean
    if self.CurrentState == targetState then return false end

    if targetState == "EMERGENCY_STOP" then return true end
    if self.CurrentState == "EMERGENCY_STOP" and targetState ~= "IDLE" then return false end

    local transKey = self.CurrentState .. "->" .. targetState
    local transRule = self._transitions[transKey]
    if not transRule then
        return false -- Whitelist guard
    end

    if transRule.Condition and not transRule.Condition(ctx) then
        return false
    end

    local currentDef = self._states[self.CurrentState]
    if currentDef and currentDef.CanExit and not currentDef:CanExit(ctx) then
        return false
    end

    local currentPri = self._priorities[self.CurrentState] or 0
    local targetPri = self._priorities[targetState] or 0

    if targetPri < currentPri and currentPri >= 70 then
        return false
    end

    local targetDef = self._states[targetState]
    if targetDef and targetDef.CanEnter and not targetDef:CanEnter(ctx) then
        return false
    end

    return true
end

function StateMachine:TransitionTo(newState: string, ctx: any, reason: string?, source: string?, force: boolean?): boolean
    if not force and not self:CanTransitionTo(newState, ctx) then
        return false
    end

    local now = os.clock()
    local oldState = self.CurrentState
    local durationInPrev = now - self.StateStartTime

    local oldDef = self._states[oldState]
    if oldDef and oldDef.OnExit then
        if self._logger then
            self._logger:SafeCall("FSM.OnExit", oldDef.OnExit, oldDef, newState, ctx)
        else
            pcall(oldDef.OnExit, oldDef, newState, ctx)
        end
    end

    table.insert(self.History, 1, oldState)
    if #self.History > 20 then table.remove(self.History) end

    -- Record Structured Telemetry Entry
    local telemetry: TransitionTelemetry = {
        From = oldState,
        To = newState,
        Reason = reason or "Standard Transition",
        Source = source or "Engine",
        Timestamp = now,
        DurationInPrev = durationInPrev,
    }
    table.insert(self.TelemetryLogs, 1, telemetry)
    if #self.TelemetryLogs > self.MaxTelemetryLogs then
        table.remove(self.TelemetryLogs)
    end

    self.PreviousState = oldState
    self.CurrentState = newState
    self.StateStartTime = now
    self.TransitionsCount += 1

    local newDef = self._states[newState]
    if newDef and newDef.OnEnter then
        if self._logger then
            self._logger:SafeCall("FSM.OnEnter", newDef.OnEnter, newDef, oldState, ctx, reason)
        else
            pcall(newDef.OnEnter, newDef, oldState, ctx, reason)
        end
    end

    self.StateChanged:Fire(newState, oldState, telemetry)
    return true
end

function StateMachine:Rollback(ctx: any): boolean
    if #self.History > 0 then
        local prev = table.remove(self.History, 1)
        return self:TransitionTo(prev, ctx, "FSM Rollback", "FSM", true)
    end
    return false
end

function StateMachine:Update(dt: number, ctx: any)
    local def = self._states[self.CurrentState]
    if def then
        -- Timeout Auto-Recovery Guard (Prevents getting permanently stuck in transient special states)
        if def.Timeout and (os.clock() - self.StateStartTime) > def.Timeout then
            local fallback = def.FallbackState or "IDLE"
            if self._logger then
                self._logger:Warn("FSM", string.format("State '%s' timed out (> %.1fs), auto-recovering to '%s'", self.CurrentState, def.Timeout, fallback))
            end
            self:TransitionTo(fallback, ctx, "State Timeout Recovery", "FSM", true)
            return
        end

        if def.OnUpdate then
            if self._logger then
                self._logger:SafeCall("FSM.OnUpdate", def.OnUpdate, def, dt, ctx)
            else
                pcall(def.OnUpdate, def, dt, ctx)
            end
        end
    end
end

return StateMachine

end
__modules["Architecture/StateMachine"] = __modules["Architecture.StateMachine"]

-- ============================================================================
-- Module: Bootstrap
-- ============================================================================
__modules["Bootstrap"] = function()
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

end

-- ============================================================================
-- Module: Config.ConfigManager
-- ============================================================================
__modules["Config.ConfigManager"] = function()
--!strict
local ConfigSchema = require("Config.ConfigSchema")
local HttpService = game:GetService("HttpService")

local ConfigManager = {}
ConfigManager.__index = ConfigManager

function ConfigManager.new(logger: any)
    local self = setmetatable({
        FileName = "4080_Hub_TSB_Config.json",
        Config = {},
        RegisteredUI = {},
        _logger = logger,
        _degradedMode = false,
    }, ConfigManager)

    self:ResetToDefaults()

    if typeof(writefile) ~= "function" or typeof(readfile) ~= "function" then
        self._degradedMode = true
        if self._logger then
            self._logger:Warn("ConfigManager", "Running in In-Memory Degraded Mode (writefile API unsupported)")
        end
    end

    return self
end

function ConfigManager:ResetToDefaults()
    for catName, catSchema in pairs(ConfigSchema) do
        self.Config[catName] = {}
        for key, spec in pairs(catSchema) do
            self.Config[catName][key] = spec.Default
        end
    end
end

function ConfigManager:ValidateAndClamp(data: any): any
    -- Strict Runtime Schema Enforcement with EnumItem type validation
    for catName, catSchema in pairs(ConfigSchema) do
        if type(data[catName]) == "table" then
            for key, spec in pairs(catSchema) do
                local val = data[catName][key]
                if val ~= nil then
                    if spec.Type == "number" then
                        if type(val) == "number" then
                            if spec.Min and spec.Max then
                                data[catName][key] = math.clamp(val, spec.Min, spec.Max)
                            end
                        else
                            data[catName][key] = spec.Default
                        end
                    elseif spec.Type == "boolean" then
                        if type(val) ~= "boolean" then
                            data[catName][key] = spec.Default
                        end
                    elseif spec.Type == "string" then
                        if type(val) ~= "string" then
                            data[catName][key] = spec.Default
                        end
                    elseif spec.Type == "EnumItem" then
                        if typeof(val) == "EnumItem" then
                            if spec.EnumType and val.EnumType ~= spec.EnumType then
                                data[catName][key] = spec.Default
                            end
                        else
                            data[catName][key] = spec.Default
                        end
                    end
                else
                    data[catName][key] = spec.Default
                end
            end
        else
            data[catName] = {}
            for key, spec in pairs(catSchema) do
                data[catName][key] = spec.Default
            end
        end
    end
    return data
end

local function SerializeValue(val: any): any
    if typeof(val) == "Color3" then
        return { __type = "Color3", R = val.R, G = val.G, B = val.B }
    elseif typeof(val) == "EnumItem" then
        return { __type = "EnumItem", EnumType = tostring(val.EnumType), Name = val.Name }
    elseif type(val) == "table" then
        local t = {}
        for k, v in pairs(val) do t[tostring(k)] = SerializeValue(v) end
        return t
    else
        return val
    end
end

local function DeserializeValue(val: any): any
    if type(val) == "table" then
        if val.__type == "Color3" then
            return Color3.new(val.R or 0, val.G or 0, val.B or 0)
        elseif val.__type == "EnumItem" then
            local enumTypeStr = val.EnumType or ""
            local enumName = val.Name or ""
            if enumTypeStr:find("KeyCode") and Enum.KeyCode[enumName] then
                return Enum.KeyCode[enumName]
            elseif enumTypeStr:find("UserInputType") and Enum.UserInputType[enumName] then
                return Enum.UserInputType[enumName]
            end
            return val
        else
            local t = {}
            for k, v in pairs(val) do t[k] = DeserializeValue(v) end
            return t
        end
    else
        return val
    end
end

function ConfigManager:Save(): (boolean, string?)
    if self._degradedMode then
        return true, "In-Memory"
    end
    self:ValidateAndClamp(self.Config)

    local ok, err = pcall(function()
        local dataToSave = {}
        for cat, val in pairs(self.Config) do
            dataToSave[cat] = SerializeValue(val)
        end
        local json = HttpService:JSONEncode(dataToSave)
        writefile(self.FileName, json)
    end)
    if ok and self._logger then self._logger:Info("Config", "Saved validated config to disk.") end
    return ok, err
end

function ConfigManager:Load(): (boolean, string?)
    if self._degradedMode or not isfile(self.FileName) then
        return false, "Config file not found or degraded"
    end
    local ok, err = pcall(function()
        local raw = readfile(self.FileName)
        local rawData = HttpService:JSONDecode(raw)
        local decoded = DeserializeValue(rawData)
        self:ValidateAndClamp(decoded)
        self.Config = decoded
        self:RefreshUI()
    end)
    if ok and self._logger then self._logger:Info("Config", "Loaded and validated config from disk.") end
    return ok, err
end

function ConfigManager:RefreshUI()
    for _, item in ipairs(self.RegisteredUI) do
        if item.Getter and item.Setter then
            pcall(function()
                local val = item.Getter()
                if val ~= nil then item.Setter(val) end
            end)
        end
    end
end

function ConfigManager:Reset()
    if typeof(delfile) == "function" and isfile(self.FileName) then
        pcall(function() delfile(self.FileName) end)
    end
    self:ResetToDefaults()
    self:RefreshUI()
end

return ConfigManager

end
__modules["Config/ConfigManager"] = __modules["Config.ConfigManager"]

-- ============================================================================
-- Module: Config.ConfigSchema
-- ============================================================================
__modules["Config.ConfigSchema"] = function()
--!strict
local ConfigSchema = {
    Combat = {
        Aimlock            = { Type = "boolean", Default = false },
        AimlockMode        = { Type = "string",  Default = "Body Only (No Screen Spin)" },
        AimPart            = { Type = "string",  Default = "HumanoidRootPart" },
        AimMode            = { Type = "string",  Default = "Nearest" },
        AimMaxRange        = { Type = "number",  Default = 300, Min = 50, Max = 1000 },
        AutoM1             = { Type = "boolean", Default = false },
        AutoM1Delay        = { Type = "number",  Default = 0.12, Min = 0.05, Max = 0.5 },
        AutoParry          = { Type = "boolean", Default = false },
        AutoBlock          = { Type = "boolean", Default = false },
        PacketParry        = { Type = "boolean", Default = true },
        PredictiveAim      = { Type = "boolean", Default = true },
        AutoComboSequencer = { Type = "boolean", Default = false },
        ComboMode          = { Type = "string",  Default = "Saitama Max Damage" },
        FrameTrapWakeup    = { Type = "boolean", Default = true },
        HitboxExpander     = { Type = "boolean", Default = false },
        HitboxSize         = { Type = "number",  Default = 16, Min = 4, Max = 35 },
        AntiCounterBait    = { Type = "boolean", Default = true },
        AntiRagdoll        = { Type = "boolean", Default = false },
        AutoEvasive        = { Type = "boolean", Default = false },
        MassBringEnabled   = { Type = "boolean", Default = true },
        MassBringMode      = { Type = "string",  Default = "FE Real Damage (Blitz)" },
        MassBringDistance  = { Type = "number",  Default = 20, Min = 5, Max = 50 },
        MassBringDuration  = { Type = "number",  Default = 10, Min = 3, Max = 30 },
    },
    Target = {
        TargetMode         = { Type = "string",  Default = "Nearest" },
        SpecificPlayer     = { Type = "string",  Default = "None" },
        BehindTP           = { Type = "boolean", Default = false },
        BehindDistance     = { Type = "number",  Default = 3.5, Min = 1.0, Max = 15 },
        AutoM1OnTP         = { Type = "boolean", Default = true },
    },
    Skills = {
        AutoAim            = { Type = "boolean", Default = true },
        AutoSkillSpam      = { Type = "boolean", Default = false },
        SkillSpamDelay     = { Type = "number",  Default = 0.25, Min = 0.1, Max = 1.0 },
        AutoUltSpam        = { Type = "boolean", Default = false },
        VoidKill           = { Type = "boolean", Default = false },
        VoidDepth          = { Type = "number",  Default = -350, Min = -500, Max = -100 },
        VoidReturnDelay    = { Type = "number",  Default = 0.5, Min = 0.2, Max = 2.0 },
    },
    Survival = {
        SkyTeleport        = { Type = "boolean", Default = false },
        SkyEscapeHP        = { Type = "number",  Default = 30, Min = 10, Max = 60 },
        SkyReturnHP        = { Type = "number",  Default = 80, Min = 50, Max = 100 },
        SkyEscapeHeight    = { Type = "number",  Default = 180, Min = 50, Max = 400 },
        SkyDodge           = { Type = "boolean", Default = false },
        SkyDodgeHeight     = { Type = "number",  Default = 65, Min = 20, Max = 150 },
        SkyDodgeRange      = { Type = "number",  Default = 18, Min = 5, Max = 30 },
        SkyDodgeLockCamera = { Type = "boolean", Default = true },
    },
    Movement = {
        Fly                = { Type = "boolean", Default = false },
        FlySpeed           = { Type = "number",  Default = 60, Min = 10, Max = 200 },
        FlyMode            = { Type = "string",  Default = "CFrame" },
        SpeedBoost         = { Type = "boolean", Default = false },
        SpeedVal           = { Type = "number",  Default = 42, Min = 16, Max = 150 },
        InfiniteJump       = { Type = "boolean", Default = false },
        DoubleJump         = { Type = "boolean", Default = false },
        Noclip             = { Type = "boolean", Default = false },
        AntiVoid           = { Type = "boolean", Default = true },
    },
    Visuals = {
        HighlightESP       = { Type = "boolean", Default = false },
        BillboardESP       = { Type = "boolean", Default = false },
        ShowCharacterESP   = { Type = "boolean", Default = true },
        ShowUltiESP        = { Type = "boolean", Default = true },
        DeathCounterRisk   = { Type = "boolean", Default = true },
        Tracers            = { Type = "boolean", Default = false },
        TracerOrigin       = { Type = "string",  Default = "Bottom" },
        FOVCircle          = { Type = "boolean", Default = false },
    },
    World = {
        FullBright         = { Type = "boolean", Default = false },
        RemoveFog          = { Type = "boolean", Default = false },
        CustomFOV          = { Type = "boolean", Default = false },
        FOVValue           = { Type = "number",  Default = 90, Min = 60, Max = 120 },
        AntiAFK            = { Type = "boolean", Default = true },
        AutoServerHop      = { Type = "boolean", Default = true },
        AutoHopMinPlayers  = { Type = "number",  Default = 4, Min = 2, Max = 8 },
    },
    UI = {
        IsOpen             = { Type = "boolean", Default = true },
        AccentName         = { Type = "string",  Default = "Cyan Neon" },
    },
    Telemetry = {
        AutoRecordData     = { Type = "boolean", Default = true },
        AutoSaveInterval   = { Type = "number",  Default = 15, Min = 5, Max = 120 },
        RecordHitboxes     = { Type = "boolean", Default = true },
        RecordAnimations   = { Type = "boolean", Default = true },
        RecordAttributes   = { Type = "boolean", Default = true },
        RecordCooldowns    = { Type = "boolean", Default = true },
        RecordSounds       = { Type = "boolean", Default = true },
        RecordTools        = { Type = "boolean", Default = true },
        RecordRemotes      = { Type = "boolean", Default = true },
        RecordCorrelations = { Type = "boolean", Default = true },
        MaxCombatEvents    = { Type = "number",  Default = 1000, Min = 100, Max = 5000 },
    },
    Keybinds = {
        ToggleGUI          = { Type = "EnumItem", EnumType = Enum.KeyCode, Default = Enum.KeyCode.RightControl },
        ToggleFly          = { Type = "EnumItem", EnumType = Enum.KeyCode, Default = Enum.KeyCode.F5 },
        ToggleNoclip       = { Type = "EnumItem", EnumType = Enum.KeyCode, Default = Enum.KeyCode.F6 },
        ToggleAimlock      = { Type = "EnumItem", EnumType = Enum.KeyCode, Default = Enum.KeyCode.F7 },
        ToggleBehindTP     = { Type = "EnumItem", EnumType = Enum.KeyCode, Default = Enum.KeyCode.F9 },
        ToggleSkyDodge     = { Type = "EnumItem", EnumType = Enum.KeyCode, Default = Enum.KeyCode.H },
        EmergencyStop      = { Type = "EnumItem", EnumType = Enum.KeyCode, Default = Enum.KeyCode.Delete },
        MassBringKey       = { Type = "EnumItem", EnumType = Enum.KeyCode, Default = Enum.KeyCode.G },
    }
}

return ConfigSchema

end
__modules["Config/ConfigSchema"] = __modules["Config.ConfigSchema"]

-- ============================================================================
-- Module: Core.EventBus
-- ============================================================================
__modules["Core.EventBus"] = function()
--!strict
local Signal = require("Core.Signal")

local EventBus = {}
EventBus.__index = EventBus

function EventBus.new()
    local self = setmetatable({
        _events = {},
        _history = {},
        _maxHistory = 25,
    }, EventBus)
    return self
end

function EventBus:Subscribe(eventName: string, callback: (...any) -> ())
    if not self._events[eventName] then
        self._events[eventName] = Signal.new()
    end
    return self._events[eventName]:Connect(callback)
end

function EventBus:Publish(eventName: string, ...: any)
    if not self._history[eventName] then
        self._history[eventName] = {}
    end
    local entry = { Timestamp = os.clock(), Data = { ... } }
    table.insert(self._history[eventName], 1, entry)
    if #self._history[eventName] > self._maxHistory then
        table.remove(self._history[eventName])
    end

    if self._events[eventName] then
        self._events[eventName]:Fire(...)
    end
end

function EventBus:PublishSync(eventName: string, ...: any)
    if not self._history[eventName] then
        self._history[eventName] = {}
    end
    local entry = { Timestamp = os.clock(), Data = { ... } }
    table.insert(self._history[eventName], 1, entry)
    if #self._history[eventName] > self._maxHistory then
        table.remove(self._history[eventName])
    end

    if self._events[eventName] then
        self._events[eventName]:FireSync(...)
    end
end

function EventBus:GetHistory(eventName: string)
    return self._history[eventName] or {}
end

function EventBus:Clear()
    for _, sig in pairs(self._events) do
        sig:Destroy()
    end
    table.clear(self._events)
    table.clear(self._history)
end

return EventBus

end
__modules["Core/EventBus"] = __modules["Core.EventBus"]

-- ============================================================================
-- Module: Core.Logger
-- ============================================================================
__modules["Core.Logger"] = function()
--!strict
local Logger = {}
Logger.__index = Logger

local LevelNames = {
    [1] = "TRACE",
    [2] = "DEBUG",
    [3] = "INFO",
    [4] = "WARN",
    [5] = "ERROR",
    [6] = "FATAL"
}

function Logger.new(initialLevel: (number | string)?)
    local self = setmetatable({
        Level = 3,
        History = {},
        MaxHistory = 100,
        OnLog = nil,
    }, Logger)
    if initialLevel then
        self:SetLevel(initialLevel)
    end
    return self
end

function Logger:SetLevel(level: number | string)
    if type(level) == "string" then
        for k, v in pairs(LevelNames) do
            if v == level:upper() then
                self.Level = k
                return
            end
        end
    elseif type(level) == "number" then
        self.Level = math.clamp(level, 1, 6)
    end
end

function Logger:_Log(level: number, tag: string, message: any)
    if level < self.Level then return end
    local levelStr = LevelNames[level] or "INFO"
    local timestamp = os.date("%X")
    local formatted = string.format("[%s] [%s] [%s] %s", timestamp, levelStr, tag, tostring(message))

    table.insert(self.History, 1, formatted)
    if #self.History > self.MaxHistory then
        table.remove(self.History)
    end

    if level >= 5 then
        warn(formatted)
    else
        print(formatted)
    end

    if self.OnLog then
        pcall(self.OnLog, formatted, level, tag)
    end
end

function Logger:Trace(tag: string, message: any) self:_Log(1, tag, message) end
function Logger:Debug(tag: string, message: any) self:_Log(2, tag, message) end
function Logger:Info(tag: string, message: any)  self:_Log(3, tag, message) end
function Logger:Warn(tag: string, message: any)  self:_Log(4, tag, message) end
function Logger:Error(tag: string, message: any) self:_Log(5, tag, message) end
function Logger:Fatal(tag: string, message: any) self:_Log(6, tag, message) end

function Logger:SafeCall(tag: string, fn: (...any) -> ...any, ...: any): (boolean, ...any)
    local results = { pcall(fn, ...) }
    local success = results[1]
    if not success then
        local err = tostring(results[2])
        local trace = debug.traceback()
        self:Error(tag, string.format("SafeCall Failed: %s\nTrace: %s", err, trace))
    end
    return table.unpack(results)
end

return Logger

end
__modules["Core/Logger"] = __modules["Core.Logger"]

-- ============================================================================
-- Module: Core.Maid
-- ============================================================================
__modules["Core.Maid"] = function()
--!strict
local Maid = {}
Maid.__index = Maid

export type Task = (() -> ()) | RBXScriptConnection | { Disconnect: (any) -> () } | { Destroy: (any) -> () } | Instance

function Maid.new()
    local self = setmetatable({
        _tasks = {},
    }, Maid)
    return self
end

function Maid:GiveTask(taskItem: Task): any
    assert(taskItem ~= nil, "Task cannot be nil")
    local taskId = #self._tasks + 1
    self._tasks[taskId] = taskItem
    return taskId
end

function Maid:DoCleaning()
    local tasks = self._tasks
    for index, taskItem in pairs(tasks) do
        if typeof(taskItem) == "RBXScriptConnection" then
            taskItem:Disconnect()
        elseif type(taskItem) == "function" then
            pcall(taskItem)
        elseif typeof(taskItem) == "Instance" then
            pcall(function() taskItem:Destroy() end)
        elseif type(taskItem) == "table" then
            if type(taskItem.Destroy) == "function" then
                pcall(function() taskItem:Destroy() end)
            elseif type(taskItem.Disconnect) == "function" then
                pcall(function() taskItem:Disconnect() end)
            elseif type(taskItem.DoCleaning) == "function" then
                pcall(function() taskItem:DoCleaning() end)
            end
        end
        tasks[index] = nil
    end
end

function Maid:Destroy()
    self:DoCleaning()
end

return Maid

end
__modules["Core/Maid"] = __modules["Core.Maid"]

-- ============================================================================
-- Module: Core.Scheduler
-- ============================================================================
__modules["Core.Scheduler"] = function()
--!strict
local Scheduler = {}
Scheduler.__index = Scheduler

export type TaskDefinition = {
    Category: string,
    Callback: (dt: number) -> (),
    LastRun: number,
    Enabled: boolean,
    ExecutionCount: number,
}

function Scheduler.new()
    local self = setmetatable({
        _intervals = {
            Fast       = 1 / 60, -- Exact 60 Hz interval (~0.0166s)
            Normal     = 0.05,   -- 20 Hz
            Slow       = 0.5,    -- 2 Hz
            Background = 2.0,    -- 0.5 Hz
        },
        _tasks = {},
    }, Scheduler)
    return self
end

function Scheduler:Register(name: string, category: string, callback: (dt: number) -> (), enabled: boolean?)
    self._tasks[name] = {
        Category = category or "Normal",
        Callback = callback,
        LastRun = 0,
        Enabled = enabled ~= false,
        ExecutionCount = 0,
    }
end

function Scheduler:SetEnabled(name: string, enabled: boolean)
    if self._tasks[name] then
        self._tasks[name].Enabled = enabled
    end
end

function Scheduler:Step(dt: number)
    local now = os.clock()
    for _, taskItem in pairs(self._tasks) do
        if taskItem.Enabled then
            local interval = self._intervals[taskItem.Category] or 0.05
            if (now - taskItem.LastRun) >= interval then
                local taskDt = taskItem.LastRun == 0 and dt or (now - taskItem.LastRun)
                taskItem.LastRun = now
                taskItem.ExecutionCount += 1
                pcall(taskItem.Callback, taskDt)
            end
        end
    end
end

function Scheduler:GetTaskStats(): { [string]: { Category: string, Executions: number, Enabled: boolean } }
    local stats = {}
    for name, item in pairs(self._tasks) do
        stats[name] = {
            Category = item.Category,
            Executions = item.ExecutionCount,
            Enabled = item.Enabled,
        }
    end
    return stats
end

return Scheduler

end
__modules["Core/Scheduler"] = __modules["Core.Scheduler"]

-- ============================================================================
-- Module: Core.ServiceContainer
-- ============================================================================
__modules["Core.ServiceContainer"] = function()
--!strict
local ServiceContainer = {}
ServiceContainer.__index = ServiceContainer

export type ServiceEntry = {
    Name: string,
    Instance: any?,
    Factory: ((container: any) -> any)?,
    Dependencies: { string },
    Resolved: boolean,
}

function ServiceContainer.new()
    local self = setmetatable({
        _services = {},
        _factories = {},
        _dependencies = {}, -- Adjacency list for real DAG
        _resolving = {},
    }, ServiceContainer)
    return self
end

function ServiceContainer:Register(name: string, instanceOrFactory: any, dependencies: { string }?)
    assert(name and instanceOrFactory, "ServiceContainer:Register requires name and instance/factory")
    local deps = dependencies or {}
    self._dependencies[name] = deps

    if type(instanceOrFactory) == "function" then
        self._factories[name] = instanceOrFactory
    else
        self._services[name] = instanceOrFactory
    end
    return instanceOrFactory
end

function ServiceContainer:Get(name: string): any
    if self._services[name] then
        return self._services[name]
    end

    if self._factories[name] then
        if self._resolving[name] then
            error(string.format("[ServiceContainer] Circular dependency detected while resolving service '%s'!", name))
        end

        self._resolving[name] = true
        local factory = self._factories[name]
        local instance = factory(self)
        self._resolving[name] = nil

        self._services[name] = instance
        self._factories[name] = nil
        return instance
    end

    error(string.format("[ServiceContainer] Service '%s' is not registered!", tostring(name)))
end

function ServiceContainer:Has(name: string): boolean
    return self._services[name] ~= nil or self._factories[name] ~= nil
end

function ServiceContainer:BuildGraph(): { [string]: { string } }
    local graph = {}
    for name, deps in pairs(self._dependencies) do
        graph[name] = deps
    end
    return graph
end

-- Kahn's Algorithm / Topological Sort for Dependency Graph
-- Resolves services in dependency-first order and detects any cyclic dependencies
function ServiceContainer:TopologicalSort(): ({ string }, boolean, string?)
    local inDegree = {}
    local adjList = {}
    local allNodes = {}

    -- Collect all registered nodes
    for name, _ in pairs(self._dependencies) do
        allNodes[name] = true
        inDegree[name] = 0
        adjList[name] = {}
    end
    for name, _ in pairs(self._services) do
        if not allNodes[name] then
            allNodes[name] = true
            inDegree[name] = 0
            adjList[name] = {}
        end
    end
    for name, _ in pairs(self._factories) do
        if not allNodes[name] then
            allNodes[name] = true
            inDegree[name] = 0
            adjList[name] = {}
        end
    end

    -- Build adjacency list: if A depends on B, edge is B -> A (B must resolve before A)
    for node, deps in pairs(self._dependencies) do
        for _, dep in ipairs(deps) do
            if allNodes[dep] then
                table.insert(adjList[dep], node)
                inDegree[node] = (inDegree[node] or 0) + 1
            end
        end
    end

    -- Queue for nodes with in-degree 0 (no unresolved dependencies)
    local queue = {}
    for node, deg in pairs(inDegree) do
        if deg == 0 then
            table.insert(queue, node)
        end
    end

    local order = {}
    while #queue > 0 do
        local curr = table.remove(queue, 1)
        table.insert(order, curr)

        for _, neighbor in ipairs(adjList[curr] or {}) do
            inDegree[neighbor] -= 1
            if inDegree[neighbor] == 0 then
                table.insert(queue, neighbor)
            end
        end
    end

    -- If order contains all nodes, no cycles exist; otherwise a cycle was detected
    local totalCount = 0
    for _ in pairs(allNodes) do totalCount += 1 end

    local hasCycle = (#order < totalCount)
    local cycleNode = nil
    if hasCycle then
        for node, deg in pairs(inDegree) do
            if deg > 0 then
                cycleNode = node
                break
            end
        end
    end

    return order, not hasCycle, cycleNode
end

function ServiceContainer:ResolveAllInOrder(): { string }
    local order, noCycles, cycleNode = self:TopologicalSort()
    if not noCycles then
        error(string.format("[ServiceContainer] Cannot initialize services due to circular dependency involving '%s'!", tostring(cycleNode)))
    end

    for _, sName in ipairs(order) do
        self:Get(sName)
    end
    return order
end

return ServiceContainer

end
__modules["Core/ServiceContainer"] = __modules["Core.ServiceContainer"]

-- ============================================================================
-- Module: Core.Signal
-- ============================================================================
__modules["Core.Signal"] = function()
--!strict
local Signal = {}
Signal.__index = Signal

export type Connection = {
    Disconnect: (self: Connection) -> (),
    Connected: boolean,
}

export type Signal = {
    Connect: (self: Signal, callback: (...any) -> ()) -> Connection,
    Fire: (self: Signal, ...any) -> (),
    Wait: (self: Signal) -> ...any,
    Destroy: (self: Signal) -> (),
    GetListenerCount: (self: Signal) -> number,
}

function Signal.new(): Signal
    local self = setmetatable({
        _listeners = {},
        _listenerCount = 0,
    }, Signal)
    return (self :: any) :: Signal
end

function Signal:Connect(callback: (...any) -> ()): Connection
    assert(type(callback) == "function", "Signal:Connect requires a function")
    local connection = {
        _callback = callback,
        _signal = self,
        Connected = true,
    }
    function connection:Disconnect()
        if not self.Connected then return end
        self.Connected = false
        if self._signal then
            self._signal._listeners[self] = nil
            self._signal._listenerCount = math.max(0, self._signal._listenerCount - 1)
        end
    end
    self._listeners[connection] = true
    self._listenerCount += 1
    return connection
end

function Signal:Fire(...: any)
    for connection in pairs(self._listeners) do
        if connection.Connected and connection._callback then
            task.spawn(connection._callback, ...)
        end
    end
end

-- Synchronous Fire: executes callbacks immediately in the calling thread
function Signal:FireSync(...: any)
    for connection in pairs(self._listeners) do
        if connection.Connected and connection._callback then
            local ok, err = pcall(connection._callback, ...)
            if not ok then
                warn(string.format("[Signal] Error in synchronous listener: %s", tostring(err)))
            end
        end
    end
end

function Signal:Wait(): ...any
    local thread = coroutine.running()
    local conn
    conn = self:Connect(function(...)
        conn:Disconnect()
        task.spawn(thread, ...)
    end)
    return coroutine.yield()
end

function Signal:GetListenerCount(): number
    return self._listenerCount
end

function Signal:Destroy()
    for connection in pairs(self._listeners) do
        connection.Connected = false
    end
    table.clear(self._listeners)
    self._listenerCount = 0
end

return Signal

end
__modules["Core/Signal"] = __modules["Core.Signal"]

-- ============================================================================
-- Module: Diagnostics.SelfDiagnostics
-- ============================================================================
__modules["Diagnostics.SelfDiagnostics"] = function()
--!strict
local SelfDiagnostics = {}
SelfDiagnostics.__index = SelfDiagnostics

function SelfDiagnostics.new(logger: any)
    local self = setmetatable({
        _logger = logger,
        DegradedModes = {
            Network = false,
            Config = false,
            Visuals = false,
        }
    }, SelfDiagnostics)
    return self
end

function SelfDiagnostics:RunHealthCheck(): (boolean, { [string]: string })
    local report = {}
    local isHealthy = true

    local requiredServices = { "Players", "RunService", "UserInputService", "Workspace", "HttpService" }
    for _, sName in ipairs(requiredServices) do
        local ok, s = pcall(function() return game:GetService(sName) end)
        if ok and s then
            report["Service_" .. sName] = "OK"
        else
            report["Service_" .. sName] = "MISSING"
            isHealthy = false
        end
    end

    -- Real Degraded Fallback Assessment
    if typeof(hookmetamethod) ~= "function" then
        self.DegradedModes.Network = true
        report["API_hookmetamethod"] = "UNSUPPORTED (Degraded Network Mode)"
    else
        report["API_hookmetamethod"] = "AVAILABLE"
    end

    if typeof(writefile) ~= "function" then
        self.DegradedModes.Config = true
        report["API_writefile"] = "UNSUPPORTED (Degraded In-Memory Config)"
    else
        report["API_writefile"] = "AVAILABLE"
    end

    if typeof(Drawing) ~= "table" or Drawing.new == nil then
        self.DegradedModes.Visuals = true
        report["API_Drawing"] = "UNSUPPORTED (Degraded Visuals Mode)"
    else
        report["API_Drawing"] = "AVAILABLE"
    end

    self._logger:Info("SelfDiagnostics", string.format("Health Check Complete. Status: %s", isHealthy and "HEALTHY" or "DEGRADED"))
    return isHealthy, report
end

return SelfDiagnostics

end
__modules["Diagnostics/SelfDiagnostics"] = __modules["Diagnostics.SelfDiagnostics"]

-- ============================================================================
-- Module: Diagnostics.UnitTests
-- ============================================================================
__modules["Diagnostics.UnitTests"] = function()
--!strict
local Signal = require("Core.Signal")
local EventBus = require("Core.EventBus")
local Maid = require("Core.Maid")
local Scheduler = require("Core.Scheduler")
local ServiceContainer = require("Core.ServiceContainer")
local StateMachine = require("Architecture.StateMachine")
local FeatureManager = require("Architecture.FeatureManager")
local CacheEngine = require("Performance.Cache")
local ObjectPool = require("Performance.ObjectPool")
local Profiler = require("Performance.Profiler")
local ConfigManager = require("Config.ConfigManager")
local Logger = require("Core.Logger")

local UnitTests = {}

function UnitTests.RunAll(): (boolean, { [string]: boolean })
    local results = {}
    local logger = Logger.new(3)

    -- 1. Deterministic Signal Test (Synchronous & Async)
    local sig = Signal.new()
    local sigVal = nil
    local conn = sig:Connect(function(v) sigVal = v end)
    sig:FireSync(42) -- Deterministic immediate dispatch
    conn:Disconnect()
    sig:FireSync(99)
    sig:Destroy()
    results["Signal_DeterministicSyncTest"] = (sigVal == 42)

    -- 2. Deterministic EventBus Test
    local eb = EventBus.new()
    local ebReceived = false
    local ebConn = eb:Subscribe("Test.Event", function(d) if d == "OK" then ebReceived = true end end)
    eb:PublishSync("Test.Event", "OK")
    ebConn:Disconnect()
    eb:Clear()
    results["EventBus_DeterministicSyncTest"] = ebReceived

    -- 3. Maid Resource Cleanup Test
    local maid = Maid.new()
    local cleaned = false
    maid:GiveTask(function() cleaned = true end)
    maid:DoCleaning()
    results["MaidTest"] = cleaned

    -- 4. Isolated Strict Whitelist FSM Test
    local isolatedFSM = StateMachine.new("IDLE", logger)
    isolatedFSM:RegisterState("LOW_STATE",  { Priority = 20 })
    isolatedFSM:RegisterState("HIGH_STATE", { Priority = 90 })

    local unregBlocked = not isolatedFSM:CanTransitionTo("HIGH_STATE", nil)
    isolatedFSM:RegisterTransition("IDLE", "HIGH_STATE")
    local regAllowed = isolatedFSM:CanTransitionTo("HIGH_STATE", nil)
    isolatedFSM:TransitionTo("HIGH_STATE", nil, "Test Enter", "UnitTest")

    isolatedFSM:RegisterTransition("HIGH_STATE", "LOW_STATE")
    local lowBlocked = not isolatedFSM:CanTransitionTo("LOW_STATE", nil)
    isolatedFSM:TransitionTo("IDLE", nil, "Reset", "UnitTest", true)
    results["FSM_StrictWhitelistAndPriorityTest"] = (unregBlocked and regAllowed and lowBlocked and #isolatedFSM.TelemetryLogs >= 2)

    -- 5. Isolated 60 Hz Scheduler Test
    local sched = Scheduler.new()
    local schedCount = 0
    sched:Register("FastTask", "Fast", function() schedCount += 1 end)
    sched:Step(0.0166)
    results["Scheduler_60HzTest"] = (schedCount == 1)

    -- 6. ServiceContainer True Factory DI & Kahn's DAG Topological Sort Test
    local container = ServiceContainer.new()
    container:Register("ServiceA", function(c) return { Name = "A" } end, {})
    container:Register("ServiceB", function(c) return { Dep = c:Get("ServiceA") } end, { "ServiceA" })
    local order, noCycles = container:TopologicalSort()
    local resolvedB = container:Get("ServiceB")
    results["DependencyGraph_KahnTopologicalSortTest"] = (noCycles and resolvedB.Dep.Name == "A")

    -- 7. ObjectPool Double-Release Guard & Telemetry Test
    local pool = ObjectPool.new(function() return { active = true } end, function(o) o.active = false end, 2, 10)
    local item = pool:Acquire()
    pool:Release(item)
    pool:Release(item) -- Double-release attempt
    local telem = pool:GetTelemetry()
    results["ObjectPool_DoubleReleaseGuardTest"] = (item.active == false and telem.InvalidReleases == 1 and telem.AcquireCount == 1)
    pool:Destroy()

    -- 8. Cache Weak-Key Instance ID Map & Invalidation Test
    local cache = CacheEngine.new(0.08)
    cache:Clear()
    local partA = Instance.new("Part")
    local partB = Instance.new("Part")
    local los1 = cache:CachedRaycast(Vector3.new(0,0,0), Vector3.new(0,10,0), { partA })
    local los2 = cache:CachedRaycast(Vector3.new(0,0,0), Vector3.new(0,10,0), { partB })
    cache:InvalidateRaycasts()
    results["Cache_WeakKeyAndInvalidationTest"] = (cache.RaycastStats.Misses == 2 and cache.RaycastStats.Invalidations == 1)
    partA:Destroy()
    partB:Destroy()

    -- 9. Profiler Hysteresis Test
    local profiler = Profiler.new()
    local pStart = profiler:Begin("BudgetTask", 0.001)
    task.wait(0.004)
    profiler:End("BudgetTask", pStart)
    local metric = profiler.Metrics["BudgetTask"]
    results["Profiler_HysteresisTest"] = (metric and metric.Status == "OVER_BUDGET")

    -- 10. Config Strict EnumFamily & Clamping Runtime Validation Test
    local cfg = ConfigManager.new(logger)
    local dirtyData = {
        World = { FOVValue = 99999 },
        Keybinds = {
            ToggleFly = "CorruptedString",         -- String -> Default Enum.KeyCode.F5
            ToggleAimlock = Enum.Material.Plastic, -- Wrong Enum Family -> Default Enum.KeyCode.F7
        }
    }
    cfg:ValidateAndClamp(dirtyData)
    local isEnumCorrect = (dirtyData.Keybinds.ToggleFly == Enum.KeyCode.F5 and dirtyData.Keybinds.ToggleAimlock == Enum.KeyCode.F7)
    results["Config_StrictEnumFamilyValidationTest"] = (dirtyData.World.FOVValue == 120 and isEnumCorrect)

    -- 11. UI Presentation Layer Lifecycle & Idempotency Test
    local UIController = require("UI.UIController")
    local mockContainer = ServiceContainer.new()
    local testUI = UIController.new({
        ConfigManager = cfg,
        FeatureManager = FeatureManager.new(logger, profiler),
        StateMachine = isolatedFSM,
        Profiler = profiler,
        Cache = cache,
        NetworkEngine = { _isHooked = false, PacketCount = 0, LastGoal = nil },
        Logger = logger,
        Bootstrap = { GetDiagnostics = function() return {} end },
        Container = mockContainer,
    })
    
    local okInit, _ = pcall(function() testUI:Init() end)
    local okToggle, _ = pcall(function() testUI:Toggle() end)
    local okTab, _ = pcall(function() testUI:SelectTab("Movement") end)
    local okDestroy, _ = pcall(function() testUI:Destroy() end)
    local okReinit, _ = pcall(function()
        testUI:Init()
        testUI:Destroy()
    end)
    results["UI_LifecycleAndIdempotencyTest"] = (okInit and okToggle and okTab and okDestroy and okReinit)

    local allPassed = true
    for name, passed in pairs(results) do
        if not passed then
            allPassed = false
            logger:Error("UnitTests", "FAILED: " .. name)
        else
            logger:Info("UnitTests", "PASSED: " .. name)
        end
    end

    return allPassed, results
end

return UnitTests

end
__modules["Diagnostics/UnitTests"] = __modules["Diagnostics.UnitTests"]

-- ============================================================================
-- Module: Network.NetworkEngine
-- ============================================================================
__modules["Network.NetworkEngine"] = function()
--!strict
local NetworkEngine = {}
NetworkEngine.__index = NetworkEngine

function NetworkEngine.new(deps: { Logger: any, EventBus: any, RemoteResolver: any })
    local self = setmetatable({
        _logger = deps.Logger,
        _eventBus = deps.EventBus,
        _remoteResolver = deps.RemoteResolver,
        _isHooked = false,
        _oldNamecall = nil,
        OutgoingHooked = false,
        PacketCount = 0,
        LastPacketTick = 0,
        LastGoal = nil,
        _degradedMode = false,
    }, NetworkEngine)
    return self
end

function NetworkEngine:Init()
    if self._isHooked then return end -- Idempotency Guard

    pcall(function()
        if typeof(hookmetamethod) == "function" and typeof(getnamecallmethod) == "function" then
            local oldNamecall
            local this = self
            oldNamecall = hookmetamethod(game, "__namecall", function(selfRemote, ...)
                if not this._isHooked then
                    return oldNamecall(selfRemote, ...)
                end

                local method = getnamecallmethod()
                local args = {...}

                if method == "FireServer" and selfRemote:IsA("RemoteEvent") then
                    local name = selfRemote.Name:lower()
                    if name:find("comm") or name:find("combat") or name:find("action") then
                        this.PacketCount += 1
                        this.LastPacketTick = os.clock()

                        if type(args[1]) == "table" and args[1].Goal then
                            this.LastGoal = tostring(args[1].Goal)
                            this._eventBus:Publish("Network.OutgoingGoal", args[1].Goal, args[1])
                        end
                    end
                end
                return oldNamecall(selfRemote, ...)
            end)
            self._oldNamecall = oldNamecall
            self._isHooked = true
            self.OutgoingHooked = true
            self._logger:Info("NetworkEngine", "Metamethod Hook initialized successfully.")
        else
            self._degradedMode = true
            self._logger:Warn("NetworkEngine", "Running in Degraded Mode (hookmetamethod API unsupported)")
        end
    end)
end

function NetworkEngine:Unhook()
    if not self._isHooked then return end
    self._isHooked = false
    self.OutgoingHooked = false

    -- Attempt genuine metamethod restoration if environment supports it
    pcall(function()
        if self._oldNamecall then
            if typeof(hookmetamethod) == "function" then
                hookmetamethod(game, "__namecall", self._oldNamecall)
                self._logger:Info("NetworkEngine", "Metamethod Hook restored to original state.")
            elseif typeof(restorefunction) == "function" then
                restorefunction(self._oldNamecall)
            end
        end
    end)
end

function NetworkEngine:Destroy()
    self:Unhook()
    self._oldNamecall = nil
    self._isHooked = false
    self.OutgoingHooked = false
end

function NetworkEngine:SendAction(goalName: string, payload: any?): boolean
    local remote = self._remoteResolver:Resolve("Communicate")
    if remote then
        local data = payload or {}
        data.Goal = goalName
        local ok = pcall(function() remote:FireServer(data) end)
        return ok
    end
    return false
end

return NetworkEngine

end
__modules["Network/NetworkEngine"] = __modules["Network.NetworkEngine"]

-- ============================================================================
-- Module: Network.RemoteResolver
-- ============================================================================
__modules["Network.RemoteResolver"] = function()
--!strict
local RemoteResolver = {}
RemoteResolver.__index = RemoteResolver

function RemoteResolver.new(logger: any)
    local self = setmetatable({
        _logger = logger,
        _cache = {},
    }, RemoteResolver)
    return self
end

function RemoteResolver:Resolve(namePattern: string): RemoteEvent?
    if self._cache[namePattern] and (self._cache[namePattern] :: Instance).Parent then
        return self._cache[namePattern] :: RemoteEvent
    end

    local char = game:GetService("Players").LocalPlayer.Character
    if char then
        for _, child in ipairs(char:GetChildren()) do
            if child:IsA("RemoteEvent") and child.Name:lower():find(namePattern:lower()) then
                self._cache[namePattern] = child
                return child
            end
        end
    end

    local rep = game:GetService("ReplicatedStorage")
    for _, desc in ipairs(rep:GetDescendants()) do
        if desc:IsA("RemoteEvent") and desc.Name:lower():find(namePattern:lower()) then
            self._cache[namePattern] = desc
            return desc
        end
    end

    return nil
end

return RemoteResolver

end
__modules["Network/RemoteResolver"] = __modules["Network.RemoteResolver"]

-- ============================================================================
-- Module: Performance.Cache
-- ============================================================================
__modules["Performance.Cache"] = function()
--!strict
local CacheEngine = {}
CacheEngine.__index = CacheEngine

function CacheEngine.new(baseTTL: number?)
    local self = setmetatable({
        PlayerCache = {},
        RaycastCache = {},
        _instanceIdMap = setmetatable({}, { __mode = "k" }), -- Ephemeron Weak-Key ID Map (100% collision-free in standard scripts)
        _nextInstanceId = 1,
        BaseTTL = baseTTL or 0.08,
        PlayerStats = { Hits = 0, Misses = 0, Invalidations = 0 },
        RaycastStats = { Hits = 0, Misses = 0, Invalidations = 0 },
        _maxRaycastEntries = 200,
    }, CacheEngine)
    return self
end

function CacheEngine:_GetInstanceId(inst: Instance): number
    local id = self._instanceIdMap[inst]
    if not id then
        id = self._nextInstanceId
        self._nextInstanceId += 1
        self._instanceIdMap[inst] = id
    end
    return id
end

function CacheEngine:GetPlayerEntry(player: Player): any
    if not player or not player.Parent then return nil end
    local entry = self.PlayerCache[player]
    local now = os.clock()

    local ttl = self.BaseTTL
    local totalReq = self.PlayerStats.Hits + self.PlayerStats.Misses
    if totalReq > 50 then
        local hitRate = self.PlayerStats.Hits / totalReq
        if hitRate > 0.85 then ttl *= 1.25
        elseif hitRate < 0.40 then ttl *= 0.75 end
    end

    if entry and (now - entry.LastCheck) < ttl and entry.Character and entry.Character.Parent then
        self.PlayerStats.Hits += 1
        return entry
    end

    self.PlayerStats.Misses += 1
    local char = player.Character
    local root = char and (char:FindFirstChild("HumanoidRootPart") or char:FindFirstChild("Torso") or char:FindFirstChild("UpperTorso"))
    local hum = char and char:FindFirstChildWhichIsA("Humanoid")
    local anim = hum and hum:FindFirstChildWhichIsA("Animator")
    local isAlive = (char ~= nil and hum ~= nil and root ~= nil and hum.Health > 0 and char.Parent ~= nil)

    entry = {
        Player = player,
        Character = char,
        RootPart = root,
        Humanoid = hum,
        Animator = anim,
        IsAlive = isAlive,
        Team = player.Team,
        LastCheck = now,
    }
    self.PlayerCache[player] = entry
    return entry
end

function CacheEngine:CachedRaycast(origin: Vector3, targetPos: Vector3, filterList: { Instance }?): boolean
    -- Collision-free deterministic hash using weak-key instance map
    local filterStr = ""
    if filterList and #filterList > 0 then
        local ids = {}
        for _, inst in ipairs(filterList) do
            table.insert(ids, tostring(self:_GetInstanceId(inst)))
        end
        filterStr = table.concat(ids, ",")
    end

    local hash = string.format("%.1f_%.1f_%.1f_%.1f_%.1f_%.1f_[%s]", origin.X, origin.Y, origin.Z, targetPos.X, targetPos.Y, targetPos.Z, filterStr)
    local cached = self.RaycastCache[hash]
    local now = os.clock()

    if cached and (now - cached.Time) < 0.04 then
        self.RaycastStats.Hits += 1
        return cached.Result
    end

    self.RaycastStats.Misses += 1
    local direction = targetPos - origin
    if direction.Magnitude < 0.1 then return true end

    local params = RaycastParams.new()
    params.FilterDescendantsInstances = filterList or {game:GetService("Players").LocalPlayer.Character}
    params.FilterType = Enum.RaycastFilterType.Exclude

    local result = workspace:Raycast(origin, direction, params)
    local hasLOS = true
    if result and result.Instance then
        local hitChar = result.Instance:FindFirstAncestorWhichIsA("Model")
        local isPlayerModel = false
        for _, p in ipairs(game:GetService("Players"):GetPlayers()) do
            if p.Character == hitChar then
                isPlayerModel = true
                break
            end
        end
        if not isPlayerModel then
            hasLOS = false
        end
    end

    self.RaycastCache[hash] = { Result = hasLOS, Time = now }
    return hasLOS
end

function CacheEngine:InvalidatePlayer(player: Player)
    self.PlayerCache[player] = nil
    self.PlayerStats.Invalidations += 1
    self:InvalidateRaycasts()
end

function CacheEngine:InvalidateRaycasts()
    table.clear(self.RaycastCache)
    self.RaycastStats.Invalidations += 1
end

-- Event-driven cache invalidation for workspace topology changes & player lifecycle
function CacheEngine:HookWorkspaceEvents(maid: any)
    if not maid then return end

    local lastGeomInvalidate = 0
    local function onTopologyChange()
        local now = os.clock()
        if (now - lastGeomInvalidate) > 0.1 then -- Debounced invalidation (max 10 Hz)
            lastGeomInvalidate = now
            table.clear(self.RaycastCache)
            self.RaycastStats.Invalidations += 1
        end
    end

    local Players = game:GetService("Players")

    pcall(function()
        maid:GiveTask(Players.PlayerRemoving:Connect(function(player)
            self:InvalidatePlayer(player)
        end))
    end)

    pcall(function()
        for _, player in ipairs(Players:GetPlayers()) do
            maid:GiveTask(player.CharacterAdded:Connect(function()
                self:InvalidatePlayer(player)
            end))
            maid:GiveTask(player.CharacterRemoving:Connect(function()
                self:InvalidatePlayer(player)
            end))
        end
    end)

    pcall(function()
        maid:GiveTask(Players.PlayerAdded:Connect(function(player)
            self:InvalidatePlayer(player)
            maid:GiveTask(player.CharacterAdded:Connect(function()
                self:InvalidatePlayer(player)
            end))
            maid:GiveTask(player.CharacterRemoving:Connect(function()
                self:InvalidatePlayer(player)
            end))
        end))
    end)

    pcall(function()
        maid:GiveTask(workspace.DescendantAdded:Connect(onTopologyChange))
        maid:GiveTask(workspace.DescendantRemoving:Connect(onTopologyChange))
    end)
end

function CacheEngine:Clear()
    table.clear(self.PlayerCache)
    table.clear(self.RaycastCache)
    self.PlayerStats.Hits = 0
    self.PlayerStats.Misses = 0
    self.RaycastStats.Hits = 0
    self.RaycastStats.Misses = 0
end

return CacheEngine

end
__modules["Performance/Cache"] = __modules["Performance.Cache"]

-- ============================================================================
-- Module: Performance.ObjectPool
-- ============================================================================
__modules["Performance.ObjectPool"] = function()
--!strict
local ObjectPool = {}
ObjectPool.__index = ObjectPool

export type PoolTelemetry = {
    Available: number,
    Active: number,
    PeakUsage: number,
    MaxCapacity: number,
    AcquireCount: number,
    ReleaseCount: number,
    InvalidReleases: number,
}

function ObjectPool.new(factory: () -> any, resetFn: ((any) -> ())?, initialSize: number?, maxCapacity: number?)
    local self = setmetatable({
        _factory = factory,
        _reset = resetFn,
        _pool = {},
        _activeSet = setmetatable({}, { __mode = "k" }), -- Ownership & double-release protection
        MaxCapacity = maxCapacity or 32,
        Acquisitions = 0,
        Releases = 0,
        InvalidReleases = 0,
        PeakUsage = 0,
    }, ObjectPool)

    for i = 1, math.min(initialSize or 8, self.MaxCapacity) do
        table.insert(self._pool, factory())
    end
    return self
end

function ObjectPool:Acquire(): any
    self.Acquisitions += 1
    local obj = nil

    if #self._pool > 0 then
        obj = table.remove(self._pool)
    else
        obj = self._factory()
    end

    self._activeSet[obj] = true
    local activeCount = self:GetActiveCount()
    if activeCount > self.PeakUsage then
        self.PeakUsage = activeCount
    end

    return obj
end

function ObjectPool:Release(obj: any)
    -- Guard: Prevent double release of the exact same object
    if not self._activeSet[obj] then
        self.InvalidReleases += 1
        return
    end

    self._activeSet[obj] = nil
    self.Releases += 1

    if self._reset then
        pcall(self._reset, obj)
    end

    -- Respect maximum capacity bound to prevent unbounded pool growth
    if #self._pool < self.MaxCapacity then
        table.insert(self._pool, obj)
    elseif typeof(obj) == "Instance" then
        pcall(function() obj:Destroy() end)
    end
end

function ObjectPool:GetActiveCount(): number
    local count = 0
    for _ in pairs(self._activeSet) do count += 1 end
    return count
end

function ObjectPool:GetSize(): number
    return #self._pool
end

function ObjectPool:GetTelemetry(): PoolTelemetry
    return {
        Available = #self._pool,
        Active = self:GetActiveCount(),
        PeakUsage = self.PeakUsage,
        MaxCapacity = self.MaxCapacity,
        AcquireCount = self.Acquisitions,
        ReleaseCount = self.Releases,
        InvalidReleases = self.InvalidReleases,
    }
end

function ObjectPool:Destroy()
    for _, obj in ipairs(self._pool) do
        if typeof(obj) == "Instance" then
            pcall(function() obj:Destroy() end)
        end
    end
    table.clear(self._pool)
    table.clear(self._activeSet)
end

return ObjectPool

end
__modules["Performance/ObjectPool"] = __modules["Performance.ObjectPool"]

-- ============================================================================
-- Module: Performance.Profiler
-- ============================================================================
__modules["Performance.Profiler"] = function()
--!strict
local Profiler = {}
Profiler.__index = Profiler

export type ProfilerMetric = {
    TotalTime: number,
    Calls: number,
    MinTime: number,
    MaxTime: number,
    PeakMicroseconds: number,
    LastTime: number,
    AvgMicroseconds: number,
    EmaMicroseconds: number,
    Budget: number,
    Status: string,
}

function Profiler.new()
    local self = setmetatable({
        Enabled = true,
        Metrics = {},
        FrameSamples = 0,
        LastFpsCalc = os.clock(),
        CurrentFPS = 60,
        MemoryKB = 0,
        PingMS = 0,
    }, Profiler)
    return self
end

function Profiler:Begin(tag: string, budgetMs: number?): number?
    if not self.Enabled then return nil end
    if not self.Metrics[tag] then
        self.Metrics[tag] = {
            TotalTime = 0,
            Calls = 0,
            MinTime = math.huge,
            MaxTime = 0,
            PeakMicroseconds = 0,
            LastTime = 0,
            AvgMicroseconds = 0,
            EmaMicroseconds = 0,
            Budget = (budgetMs or 2.0) * 1000, -- microseconds
            Status = "OK",
        }
    end
    return os.clock()
end

function Profiler:End(tag: string, startTime: number?)
    if not self.Enabled or not startTime then return end
    local duration = (os.clock() - startTime) * 1000000 -- microseconds
    local metric: ProfilerMetric = self.Metrics[tag]
    if metric then
        metric.Calls += 1
        metric.TotalTime += duration
        metric.LastTime = duration
        if duration < metric.MinTime then metric.MinTime = duration end
        if duration > metric.MaxTime then metric.MaxTime = duration end
        if duration > metric.PeakMicroseconds then metric.PeakMicroseconds = duration end
        metric.AvgMicroseconds = metric.TotalTime / metric.Calls

        -- Real-Time Rolling EMA Calculation (Alpha = 0.20)
        metric.EmaMicroseconds = (metric.EmaMicroseconds == 0) and duration or (metric.EmaMicroseconds * 0.80 + duration * 0.20)

        -- Real-Time Budget Assessment with Hysteresis (Enter > 100%, Exit < 80%)
        if metric.Status == "OK" then
            if metric.EmaMicroseconds > metric.Budget then
                metric.Status = "OVER_BUDGET"
            end
        elseif metric.Status == "OVER_BUDGET" then
            if metric.EmaMicroseconds < (metric.Budget * 0.80) then
                metric.Status = "OK"
            end
        end
    end
end

function Profiler:UpdateSystemMetrics()
    self.FrameSamples += 1
    local now = os.clock()
    if (now - self.LastFpsCalc) >= 0.5 then
        self.CurrentFPS = math.floor(self.FrameSamples / (now - self.LastFpsCalc))
        self.FrameSamples = 0
        self.LastFpsCalc = now

        pcall(function()
            local stats = game:GetService("Stats")
            self.MemoryKB = math.floor(stats:GetTotalMemoryUsageMb() * 1024)
            local net = stats:FindFirstChild("PerformanceStats") and stats.PerformanceStats:FindFirstChild("Ping")
            if net then
                self.PingMS = math.floor(net:GetValue())
            end
        end)
    end
end

function Profiler:GetReport(): { [string]: any }
    return {
        FPS = self.CurrentFPS,
        MemoryKB = self.MemoryKB,
        PingMS = self.PingMS,
        Metrics = self.Metrics,
    }
end

return Profiler

end
__modules["Performance/Profiler"] = __modules["Performance.Profiler"]

-- ============================================================================
-- Module: Systems.Combat
-- ============================================================================
__modules["Systems.Combat"] = function()
--!strict
local Players = game:GetService("Players")
local LocalPlayer = Players.LocalPlayer

local Combat = {}
Combat.__index = Combat

function Combat.new(deps: { Cache: any, EventBus: any, Network: any, EnemyState: any, Logger: any, StateMachine: any })
    local self = setmetatable({
        _cache = deps.Cache,
        _eventBus = deps.EventBus,
        _network = deps.Network,
        _enemyState = deps.EnemyState,
        _logger = deps.Logger,
        _fsm = deps.StateMachine,
        CurrentTarget = nil,
        LastAttackTick = 0,
        LastParryTick = 0,
        M1ComboCount = 0,
        MassBringActive = false,
    }, Combat)
    return self
end

local function SafeMouseClick()
    local char = LocalPlayer.Character
    local comm = char and char:FindFirstChild("Communicate")
    if comm and comm:IsA("RemoteEvent") then
        pcall(function() comm:FireServer({ Goal = "m1" }) end)
        return
    end

    local vim = nil
    pcall(function() vim = game:GetService("VirtualInputManager") end)
    if vim then
        pcall(function()
            vim:SendMouseButtonEvent(0, 0, 0, true, game, 1)
            task.wait(0.02)
            vim:SendMouseButtonEvent(0, 0, 0, false, game, 1)
        end)
    elseif typeof(mouse1click) == "function" then
        pcall(function() mouse1click() end)
    end
end

local function SafeKeyClick(keyCode: Enum.KeyCode)
    local vim = nil
    pcall(function() vim = game:GetService("VirtualInputManager") end)
    if vim then
        pcall(function()
            vim:SendKeyEvent(true, keyCode, false, game)
            task.wait(0.03)
            vim:SendKeyEvent(false, keyCode, false, game)
        end)
    elseif typeof(keypress) == "function" and typeof(keyrelease) == "function" then
        pcall(function()
            keypress(keyCode.Value)
            task.wait(0.03)
            keyrelease(keyCode.Value)
        end)
    end
end

function Combat:GetTarget(config: any): Player?
    local myEntry = self._cache:GetPlayerEntry(LocalPlayer)
    if not myEntry or not myEntry.RootPart then return nil end
    local myPos = myEntry.RootPart.Position

    local targetCfg = config.Target or {}
    local mode = targetCfg.TargetMode or (config.Combat and config.Combat.AimMode) or "Nearest"
    local maxRange = (config.Combat and config.Combat.AimMaxRange) or 300

    -- 1. Specific Player Mode
    if mode == "Specific Player" and targetCfg.SpecificPlayer and targetCfg.SpecificPlayer ~= "None" then
        local p = Players:FindFirstChild(targetCfg.SpecificPlayer)
        if p and p ~= LocalPlayer then
            local entry = self._cache:GetPlayerEntry(p)
            if entry and entry.IsAlive and entry.RootPart then
                self.CurrentTarget = p
                return p
            end
        end
    end

    -- 2. Lowest HP Mode
    if mode == "Lowest HP" then
        local lowestHp = math.huge
        local lowestPlayer = nil
        for _, player in ipairs(Players:GetPlayers()) do
            if player == LocalPlayer then continue end
            local entry = self._cache:GetPlayerEntry(player)
            if not entry or not entry.IsAlive or not entry.RootPart or not entry.Humanoid then continue end
            local dist = (entry.RootPart.Position - myPos).Magnitude
            if dist <= maxRange then
                if entry.Humanoid.Health < lowestHp then
                    lowestHp = entry.Humanoid.Health
                    lowestPlayer = player
                end
            end
        end
        if lowestPlayer then
            self.CurrentTarget = lowestPlayer
            return lowestPlayer
        end
    end

    -- 3. Random Mode (sticks to target while alive and in range)
    if mode == "Random" then
        if self.CurrentTarget and self.CurrentTarget.Parent then
            local curEntry = self._cache:GetPlayerEntry(self.CurrentTarget)
            if curEntry and curEntry.IsAlive and curEntry.RootPart then
                local dist = (curEntry.RootPart.Position - myPos).Magnitude
                if dist <= maxRange then
                    return self.CurrentTarget
                end
            end
        end
        local candidates = {}
        for _, player in ipairs(Players:GetPlayers()) do
            if player == LocalPlayer then continue end
            local entry = self._cache:GetPlayerEntry(player)
            if entry and entry.IsAlive and entry.RootPart then
                local dist = (entry.RootPart.Position - myPos).Magnitude
                if dist <= maxRange then
                    table.insert(candidates, player)
                end
            end
        end
        if #candidates > 0 then
            local picked = candidates[math.random(1, #candidates)]
            self.CurrentTarget = picked
            return picked
        end
    end

    -- 4. Nearest Mode (Default)
    local bestPlayer = nil
    local bestDist = maxRange

    for _, player in ipairs(Players:GetPlayers()) do
        if player == LocalPlayer then continue end
        local entry = self._cache:GetPlayerEntry(player)
        if not entry or not entry.IsAlive or not entry.RootPart then continue end

        local targetPart = entry.Character:FindFirstChild(config.Combat and config.Combat.AimPart or "HumanoidRootPart") or entry.RootPart
        local dist = (targetPart.Position - myPos).Magnitude

        if dist < bestDist then
            if config.Combat and config.Combat.AimWallCheck and not self._cache:CachedRaycast(myPos, targetPart.Position) then
                continue
            end
            bestDist = dist
            bestPlayer = player
        end
    end

    self.CurrentTarget = bestPlayer
    return bestPlayer
end

function Combat:UpdateAimlock(config: any)
    if not config.Combat.Aimlock then return end
    local target = self:GetTarget(config)
    if not target then return end

    local myEntry = self._cache:GetPlayerEntry(LocalPlayer)
    local tEntry = self._cache:GetPlayerEntry(target)
    if not myEntry or not myEntry.RootPart or not tEntry or not tEntry.RootPart then return end

    local targetPos = tEntry.RootPart.Position
    if config.Combat.PredictiveAim then
        local vel = tEntry.RootPart.AssemblyLinearVelocity or Vector3.zero
        targetPos = targetPos + (vel * 0.05)
    end

    local myRoot = myEntry.RootPart
    pcall(function()
        myRoot.CFrame = CFrame.lookAt(myRoot.Position, Vector3.new(targetPos.X, myRoot.Position.Y, targetPos.Z))
    end)
end

function Combat:UpdateAutoM1(config: any)
    if not config.Combat.AutoM1 then return end
    local target = self.CurrentTarget or self:GetTarget(config)
    if not target then return end

    local myEntry = self._cache:GetPlayerEntry(LocalPlayer)
    local tEntry = self._cache:GetPlayerEntry(target)
    if not myEntry or not myEntry.RootPart or not tEntry or not tEntry.RootPart then return end

    -- AntiCounterBait: don't attack while enemy is in counter stance
    if config.Combat.AntiCounterBait and self._enemyState:IsEnemyInCounterStance(target) then
        return
    end

    local dist = (myEntry.RootPart.Position - tEntry.RootPart.Position).Magnitude
    if dist <= 14 then
        -- Natural FSM State Management
        if self._fsm.CurrentState == "IDLE" then
            self._fsm:TransitionTo("COMBAT")
        end

        local now = os.clock()
        local enemyData = self._enemyState and self._enemyState:Get(target)

        -- Frame Trap Wakeup: if enemy is ragdolled, wait for the exact getup recovery frame
        if enemyData and enemyData.IsRagdoll then
            if config.Combat.FrameTrapWakeup and enemyData.WakeupTime > 0 then
                if now >= (enemyData.WakeupTime - 0.15) and now <= (enemyData.WakeupTime + 0.35) then
                    if (now - self.LastAttackTick) >= (config.Combat.AutoM1Delay or 0.12) then
                        self.LastAttackTick = now
                        self.M1ComboCount = 1
                        SafeMouseClick()
                    end
                end
            end
            return -- Do not waste attacks while enemy is invincible on ground
        end

        if (now - self.LastAttackTick) >= (config.Combat.AutoM1Delay or 0.12) then
            self.LastAttackTick = now
            self.M1ComboCount = (self.M1ComboCount % 4) + 1

            -- AutoComboSequencer: execute combo timings (e.g. 3 M1s + pause / skill window)
            if config.Combat.AutoComboSequencer and self.M1ComboCount == 3 then
                -- 3rd M1 executed; delay 4th slightly or trigger downtilt/uptilt jump
                pcall(function()
                    if myEntry.Humanoid then
                        myEntry.Humanoid.Jump = true
                    end
                end)
            end

            SafeMouseClick()
        end
    end
end

function Combat:UpdateAutoBlock(config: any)
    if not config.Combat.AutoParry and not config.Combat.AutoBlock then return end
    local myEntry = self._cache:GetPlayerEntry(LocalPlayer)
    if not myEntry or not myEntry.RootPart then return end
    local myPos = myEntry.RootPart.Position

    local anyNearby = false

    for _, player in ipairs(Players:GetPlayers()) do
        if player == LocalPlayer then continue end
        local tEntry = self._cache:GetPlayerEntry(player)
        if not tEntry or not tEntry.IsAlive or not tEntry.RootPart then continue end

        local dist = (tEntry.RootPart.Position - myPos).Magnitude

        -- AutoParry: detect attack animations and press parry key with reaction delay
        if config.Combat.AutoParry and dist <= 18 then
            local isAttacking = false
            local tChar = tEntry.Character
            if tChar then
                if tChar:GetAttribute("HoldingM1") ~= nil or tChar:GetAttribute("HoldingNormalPunch") ~= nil or tChar:GetAttribute("HoldingConsecutivePunches") ~= nil or tChar:GetAttribute("HoldingFlashStrike") ~= nil or tChar:GetAttribute("HoldingVanishingKick") ~= nil then
                    isAttacking = true
                end
            end

            if not isAttacking and tEntry.Animator then
                for _, track in ipairs(tEntry.Animator:GetPlayingAnimationTracks()) do
                    local name = (track.Name or ""):lower()
                    if name:find("attack") or name:find("punch") or name:find("slash") or name:find("strike") then
                        isAttacking = true
                        break
                    end
                end
            end

            if isAttacking then
                local now = os.clock()
                if (now - self.LastParryTick) >= 0.08 then
                    self.LastParryTick = now
                    SafeKeyClick(Enum.KeyCode.F)
                    self._eventBus:Publish("Combat.ParryExecuted", player)
                    break
                end
            end
        end

        -- AutoBlock: track whether any enemy is within block range
        if config.Combat.AutoBlock and dist <= 22 then
            anyNearby = true
        end
    end

    -- AutoBlock: continuously hold block key (F) while enemies are near
    if config.Combat.AutoBlock then
        local now = os.clock()
        if anyNearby and (now - self.LastParryTick) >= 0.15 then
            self.LastParryTick = now
            SafeKeyClick(Enum.KeyCode.F)
        end
    end
end

function Combat:UpdateHitboxExpander(config: any)
    if not config.Combat.HitboxExpander then return end
    local sz = config.Combat.HitboxSize or 16
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= LocalPlayer then
            local entry = self._cache:GetPlayerEntry(p)
            if entry and entry.IsAlive and entry.RootPart then
                pcall(function()
                    entry.RootPart.Size = Vector3.new(sz, sz, sz)
                    entry.RootPart.Transparency = 0.85
                    entry.RootPart.CanCollide = false
                end)
            end
        end
    end
end

function Combat:ResetHitboxes()
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= LocalPlayer then
            local entry = self._cache:GetPlayerEntry(p)
            if entry and entry.RootPart then
                pcall(function()
                    entry.RootPart.Size = Vector3.new(2, 2, 1)
                    entry.RootPart.Transparency = 1
                end)
            end
        end
    end
end

function Combat:UpdateAntiRagdoll(config: any)
    if not config.Combat.AntiRagdoll then return end
    local entry = self._cache:GetPlayerEntry(LocalPlayer)
    if not entry or not entry.Humanoid then return end
    local state = entry.Humanoid:GetState()
    if state == Enum.HumanoidStateType.Physics or state == Enum.HumanoidStateType.FallingDown then
        pcall(function() entry.Humanoid:ChangeState(Enum.HumanoidStateType.Running) end)
    end
end

function Combat:UpdateAutoEvasive(config: any)
    if not config.Combat.AutoEvasive then return end
    local myEntry = self._cache:GetPlayerEntry(LocalPlayer)
    if not myEntry or not myEntry.RootPart then return end
    local myPos = myEntry.RootPart.Position
    local cam = game:GetService("Workspace").CurrentCamera
    if not cam then return end

    local now = os.clock()
    if (now - (self._lastEvasiveTick or 0)) < 0.5 then return end

    for _, player in ipairs(Players:GetPlayers()) do
        if player == LocalPlayer then continue end
        local tEntry = self._cache:GetPlayerEntry(player)
        if not tEntry or not tEntry.IsAlive or not tEntry.RootPart then continue end
        local dist = (tEntry.RootPart.Position - myPos).Magnitude
        if dist > 12 then continue end

        -- Check if enemy is actively attacking
        local isAttacking = false
        local tChar = tEntry.Character
        if tChar then
            if tChar:GetAttribute("HoldingM1") or tChar:GetAttribute("HoldingNormalPunch")
                or tChar:GetAttribute("HoldingConsecutivePunches") then
                isAttacking = true
            end
        end
        if not isAttacking and tEntry.Animator then
            for _, track in ipairs(tEntry.Animator:GetPlayingAnimationTracks()) do
                local name = (track.Name or ""):lower()
                if name:find("attack") or name:find("punch") or name:find("strike") then
                    isAttacking = true
                    break
                end
            end
        end

        if isAttacking then
            self._lastEvasiveTick = now
            -- Alternate dodge direction each time
            self._evasiveSide = not self._evasiveSide
            local sideDir = self._evasiveSide and cam.CFrame.RightVector or -cam.CFrame.RightVector
            pcall(function()
                myEntry.RootPart.AssemblyLinearVelocity = Vector3.new(
                    sideDir.X * 40,
                    myEntry.RootPart.AssemblyLinearVelocity.Y,
                    sideDir.Z * 40
                )
            end)
            break
        end
    end
end

function Combat:StartMassBring(config: any)
    if self.MassBringActive then return end
    self.MassBringActive = true
    self._massBringStart = os.clock()
    self._eventBus:Publish("Combat.MassBringStarted")
end

function Combat:StopMassBring()
    if not self.MassBringActive then return end
    self.MassBringActive = false
    self._massBringStart = nil
    self._eventBus:Publish("Combat.MassBringStopped")
end

function Combat:UpdateMassBring(config: any)
    if not self.MassBringActive then return end
    local myEntry = self._cache:GetPlayerEntry(LocalPlayer)
    if not myEntry or not myEntry.RootPart then self:StopMassBring() return end

    -- Auto-stop after duration
    local duration = config.Combat.MassBringDuration or 5
    if (os.clock() - (self._massBringStart or 0)) > duration then
        self:StopMassBring()
        return
    end

    local myPos = myEntry.RootPart.Position
    local radius = 6
    local idx = 0

    for _, player in ipairs(Players:GetPlayers()) do
        if player == LocalPlayer then continue end
        local tEntry = self._cache:GetPlayerEntry(player)
        if not tEntry or not tEntry.IsAlive or not tEntry.RootPart then continue end
        local dist = (tEntry.RootPart.Position - myPos).Magnitude
        if dist > (config.Combat.AimMaxRange or 300) then continue end

        -- Arrange players in a circle around local player
        local angle = (idx * (2 * math.pi)) / math.max(#Players:GetPlayers() - 1, 1)
        local targetPos = myPos + Vector3.new(math.cos(angle) * radius, 0, math.sin(angle) * radius)
        pcall(function()
            tEntry.RootPart.CFrame = CFrame.new(targetPos + Vector3.new(0, 3, 0))
        end)
        idx += 1
    end
end

return Combat

end
__modules["Systems/Combat"] = __modules["Systems.Combat"]

-- ============================================================================
-- Module: Systems.EnemyState
-- ============================================================================
__modules["Systems.EnemyState"] = function()
--!strict
export type EnemyData = {
    Cooldowns: { [string]: number },
    IsRagdoll: boolean,
    RagdollStart: number,
    WakeupTime: number,
    IsBlocking: boolean,
    LastSkill: string,
    LastSkillTick: number,
}

local EnemyState = {}
EnemyState.__index = EnemyState

local COUNTER_ATTRIBUTES = {
    "HoldingDeathCounter", "HoldingFlowingWater", "HoldingWaterStreamCuttingFist",
    "HoldingPreysPeril", "HoldingGodSlayer", "HoldingHuntersGrasp"
}

local ATTACK_ATTRIBUTES = {
    "HoldingM1", "HoldingNormalPunch", "HoldingConsecutivePunches", "HoldingSeriousPunch",
    "HoldingOmniDirectionalPunch", "HoldingGammaRayBurst", "HoldingAtomicSlash", "HoldingBeatdown",
    "HoldingGrandSlam", "HoldingHomerun", "HoldingIncinerate", "HoldingIgnitionBurst",
    "HoldingFlashStrike", "HoldingScatter", "HoldingVanishingKick", "HoldingHeadFirst",
    "HoldingSpeedblitzDropkick", "HoldingAtmosCleave", "HoldingSolarCleave", "HoldingTwinbladeRush",
    "HoldingDeathBlow", "HoldingTrinityTear", "HoldingCarnage", "HoldingExpulsivePush"
}

function EnemyState.new(deps: { Cache: any, EventBus: any, Logger: any })
    local self = setmetatable({
        _cache = deps.Cache,
        _eventBus = deps.EventBus,
        _logger = deps.Logger,
        _states = {},
        Profiles = {
            Saitama = { NormalPunch = 12, Consecutive = 15, Shove = 14, Uppercut = 16 },
            Garou = { FlowingWater = 14, LethalWhirlwind = 15, HuntersGrasp = 18, PreysPeril = 16 },
            Sonic = { FlashStrike = 12, WhirlwindKick = 14, Scatter = 16, Shuriken = 15 },
            Suiryu = { VanishingKick = 14, HeadFirst = 15, SweepingKick = 16, FistBarrage = 18 },
            Universal = { Skill1 = 14, Skill2 = 15, Skill3 = 16, Skill4 = 16 },
        }
    }, EnemyState)
    return self
end

function EnemyState:Get(player: Player): EnemyData
    local data = self._states[player]
    if not data then
        data = {
            Cooldowns = {},
            IsRagdoll = false,
            RagdollStart = 0,
            WakeupTime = 0,
            IsBlocking = false,
            LastSkill = "None",
            LastSkillTick = 0,
        }
        self._states[player] = data
    end
    return data
end

function EnemyState:Update(player: Player)
    local entry = self._cache:GetPlayerEntry(player)
    if not entry or not entry.IsAlive then return end

    local data = self:Get(player)
    local hum = entry.Humanoid
    local char = entry.Character
    local hState = hum:GetState()
    local isRag = (hState == Enum.HumanoidStateType.Physics or hState == Enum.HumanoidStateType.Ragdoll)

    if isRag and not data.IsRagdoll then
        data.IsRagdoll = true
        data.RagdollStart = os.clock()
        data.WakeupTime = data.RagdollStart + 2.25
        self._eventBus:Publish("Combat.EnemyRagdolled", player, data.WakeupTime)
    elseif not isRag and data.IsRagdoll then
        data.IsRagdoll = false
        self._eventBus:Publish("Combat.EnemyWakeup", player)
    end

    -- Real TSB Instant Attribute Block Detection
    local isBlock = false
    if char then
        local blkAttr = char:GetAttribute("Blocking")
        if blkAttr == true or blkAttr == "true" or (char:GetAttribute("BlockTime") and not char:GetAttribute("StoppedBlocking")) then
            isBlock = true
        end
    end

    if not isBlock then
        local anim = entry.Animator
        if anim then
            for _, t in ipairs(anim:GetPlayingAnimationTracks()) do
                local n = (t.Name or ""):lower()
                if n:find("block") or n:find("guard") or n:find("defend") then
                    isBlock = true
                    break
                end
            end
        end
    end
    data.IsBlocking = isBlock
end

function EnemyState:IsEnemyInCounterStance(player: Player): boolean
    local entry = self._cache:GetPlayerEntry(player)
    if not entry or not entry.IsAlive or not entry.Character then return false end
    local char = entry.Character

    for _, attr in ipairs(COUNTER_ATTRIBUTES) do
        if char:GetAttribute(attr) ~= nil then
            return true
        end
    end

    local anim = entry.Animator
    if anim then
        for _, t in ipairs(anim:GetPlayingAnimationTracks()) do
            local n = (t.Name or ""):lower()
            if n:find("counter") or n:find("flowing") or n:find("deflect") or n:find("reflect") then
                return true
            end
        end
    end
    return false
end

return EnemyState

end
__modules["Systems/EnemyState"] = __modules["Systems.EnemyState"]

-- ============================================================================
-- Module: Systems.Movement
-- ============================================================================
__modules["Systems.Movement"] = function()
--!strict
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")
local Players = game:GetService("Players")
local LocalPlayer = Players.LocalPlayer

local Maid = require("Core.Maid")

local Movement = {}
Movement.__index = Movement

function Movement.new(deps: { Cache: any, Logger: any })
    local self = setmetatable({
        _cache = deps.Cache,
        _logger = deps.Logger,
        LastSafePos = nil,
        LastBehindTPTick = 0,
        LastBehindAttackTick = 0,
        -- Jump system state
        _jumpMaid = nil :: any,
        _doubleJumpUsed = false,
        _isAirborne = false,
    }, Movement)
    return self
end

local function SafeAttackM1()
    local char = LocalPlayer.Character
    local comm = char and char:FindFirstChild("Communicate")
    if comm and comm:IsA("RemoteEvent") then
        pcall(function() comm:FireServer({ Goal = "m1" }) end)
        return
    end

    local vim = nil
    pcall(function() vim = game:GetService("VirtualInputManager") end)
    if vim then
        pcall(function()
            vim:SendMouseButtonEvent(0, 0, 0, true, game, 1)
            task.wait(0.02)
            vim:SendMouseButtonEvent(0, 0, 0, false, game, 1)
        end)
    elseif typeof(mouse1click) == "function" then
        pcall(function() mouse1click() end)
    end
end

function Movement:ToggleFly(enable: boolean, config: any)
    config.Movement.Fly = enable
    local entry = self._cache:GetPlayerEntry(LocalPlayer)
    if not entry or not entry.RootPart or not entry.Humanoid then return end
    if enable then
        pcall(function() entry.Humanoid:ChangeState(Enum.HumanoidStateType.Running) end)
    end
end

function Movement:UpdateFly(dt: number, config: any)
    if not config.Movement.Fly then return end
    local entry = self._cache:GetPlayerEntry(LocalPlayer)
    local cam = Workspace.CurrentCamera
    if not entry or not entry.RootPart or not cam then return end

    local speed = config.Movement.FlySpeed or 60
    local moveDir = Vector3.zero

    if UserInputService:IsKeyDown(Enum.KeyCode.W) then moveDir += cam.CFrame.LookVector end
    if UserInputService:IsKeyDown(Enum.KeyCode.S) then moveDir -= cam.CFrame.LookVector end
    if UserInputService:IsKeyDown(Enum.KeyCode.A) then moveDir -= cam.CFrame.RightVector end
    if UserInputService:IsKeyDown(Enum.KeyCode.D) then moveDir += cam.CFrame.RightVector end
    if UserInputService:IsKeyDown(Enum.KeyCode.Space) then moveDir += Vector3.new(0, 1, 0) end
    if UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) then moveDir -= Vector3.new(0, 1, 0) end

    local root = entry.RootPart
    root.AssemblyAngularVelocity = Vector3.zero

    if config.Movement.FlyMode == "Velocity" then
        -- Physics-based velocity flight (smoother, less warpy)
        if moveDir.Magnitude > 0 then
            root.AssemblyLinearVelocity = moveDir.Unit * speed
        else
            root.AssemblyLinearVelocity = root.AssemblyLinearVelocity * 0.85 -- dampen
        end
    else
        -- CFrame-based flight (default, precise)
        root.AssemblyLinearVelocity = Vector3.zero
        if moveDir.Magnitude > 0 then
            root.CFrame = root.CFrame + (moveDir.Unit * speed * (dt or 0.016))
        end
    end
end

function Movement:UpdateSpeed(dt: number, config: any)
    local entry = self._cache:GetPlayerEntry(LocalPlayer)
    if not entry or not entry.Humanoid or not entry.RootPart then return end

    if config.Movement.SpeedBoost then
        local moveDir = entry.Humanoid.MoveDirection
        if moveDir.Magnitude > 0 then
            local extra = (config.Movement.SpeedVal - 16) * (dt or 0.016)
            entry.RootPart.CFrame += (moveDir.Unit * extra)
        end
    end
end

function Movement:UpdateNoclip(config: any)
    if not config.Movement.Noclip then return end
    local char = LocalPlayer.Character
    if char then
        for _, part in ipairs(char:GetDescendants()) do
            if part:IsA("BasePart") then part.CanCollide = false end
        end
    end
end

function Movement:UpdateAntiVoid(config: any)
    if not config.Movement.AntiVoid then return end
    local entry = self._cache:GetPlayerEntry(LocalPlayer)
    if not entry or not entry.RootPart or not entry.Humanoid or entry.Humanoid.Health <= 0 then return end

    local root = entry.RootPart
    if root.Position.Y >= 0 and root.AssemblyLinearVelocity.Magnitude < 220 then
        self.LastSafePos = root.CFrame
    end

    if root.Position.Y < -60 or root.AssemblyLinearVelocity.Magnitude > 600 then
        if self.LastSafePos then
            root.CFrame = self.LastSafePos + Vector3.new(0, 6, 0)
            root.AssemblyLinearVelocity = Vector3.zero
        end
    end
end

-- ============================================================================
-- SAFE BEHIND TP (SINGLE EXECUTE TRIGGER)
-- ============================================================================
function Movement:ExecuteBehindTP(config: any, combatService: any): (boolean, string?)
    local myChar = LocalPlayer.Character
    if not myChar then return false, "Karakter hazır değil" end
    local myRoot = myChar:FindFirstChild("HumanoidRootPart") or myChar:FindFirstChild("Torso")
    local myHum = myChar:FindFirstChildOfClass("Humanoid")
    if not myRoot or not myHum or myHum.Health <= 0 then
        return false, "Karakter hazır değil"
    end

    local target = combatService and (combatService.CurrentTarget or combatService:GetTarget(config))
    if not target then
        local bestDist = 300
        local bestPlayer = nil
        for _, p in ipairs(Players:GetPlayers()) do
            if p ~= LocalPlayer and p.Character then
                local r = p.Character:FindFirstChild("HumanoidRootPart") or p.Character:FindFirstChild("Torso")
                local h = p.Character:FindFirstChildOfClass("Humanoid")
                if r and h and h.Health > 0 then
                    local d = (r.Position - (myRoot :: BasePart).Position).Magnitude
                    if d < bestDist then
                        bestDist = d
                        bestPlayer = p
                    end
                end
            end
        end
        target = bestPlayer
    end

    if not target or not target.Character then
        return false, "Hedef oyuncu bulunamadı"
    end

    local tChar = target.Character
    local tRoot = tChar:FindFirstChild("HumanoidRootPart") or tChar:FindFirstChild("Torso")
    local tHum = tChar:FindFirstChildOfClass("Humanoid")
    if not tRoot or not tHum or tHum.Health <= 0 then
        return false, "Hedef geçersiz"
    end

    -- Disable collision on body to prevent physics push
    for _, part in ipairs(myChar:GetChildren()) do
        if part:IsA("BasePart") then
            part.CanCollide = false
        end
    end

    local targetCF = (tRoot :: BasePart).CFrame
    local lookDir = targetCF.LookVector
    -- 100% Horizontal Flat Vector (Prevents sinking when enemy looks down)
    local flatLook = Vector3.new(lookDir.X, 0, lookDir.Z)
    flatLook = (flatLook.Magnitude > 0.001) and flatLook.Unit or Vector3.new(0, 0, -1)

    local behindDist = (config.Target and config.Target.BehindDistance) or 3.5
    local behindPos = (tRoot :: BasePart).Position - (flatLook * behindDist) + Vector3.new(0, 0.2, 0)
    local targetFacePos = (tRoot :: BasePart).Position + Vector3.new(0, 0.2, 0)

    pcall(function()
        (myRoot :: BasePart).AssemblyLinearVelocity = Vector3.zero
        (myRoot :: BasePart).AssemblyAngularVelocity = Vector3.zero
        (myRoot :: BasePart).CFrame = CFrame.lookAt(behindPos, targetFacePos)
    end)

    if config.Target and config.Target.AutoM1OnTP then
        SafeAttackM1()
    end

    self.LastBehindTPTick = os.clock()
    return true, target.Name
end

-- ============================================================================
-- CONTINUOUS SAFE BEHIND LOCK (GLUED TO ENEMY'S BACK, 100% ROTATION TRACKING)
-- ============================================================================
function Movement:UpdateBehindLock(dt: number, config: any, combatService: any)
    if not config.Target or not config.Target.BehindTP then return end

    local myChar = LocalPlayer.Character
    if not myChar then return end
    local myRoot = myChar:FindFirstChild("HumanoidRootPart") or myChar:FindFirstChild("Torso")
    local myHum = myChar:FindFirstChildOfClass("Humanoid")
    if not myRoot or not myHum or myHum.Health <= 0 then
        return
    end

    local hState = myHum:GetState()
    if hState == Enum.HumanoidStateType.Dead or hState == Enum.HumanoidStateType.Physics then
        return
    end

    local target = combatService and (combatService.CurrentTarget or combatService:GetTarget(config))
    if not target or not target.Parent then return end

    local tChar = target.Character
    if not tChar then return end
    local tRoot = tChar:FindFirstChild("HumanoidRootPart") or tChar:FindFirstChild("Torso")
    local tHum = tChar:FindFirstChildOfClass("Humanoid")
    if not tRoot or not tHum or tHum.Health <= 0 then
        if combatService then
            combatService.CurrentTarget = nil
            target = combatService:GetTarget(config)
            tChar = target and target.Character
            tRoot = tChar and (tChar:FindFirstChild("HumanoidRootPart") or tChar:FindFirstChild("Torso"))
        end
        if not tRoot then return end
    end

    -- Disable collision on body to prevent physics glitches
    for _, part in ipairs(myChar:GetChildren()) do
        if part:IsA("BasePart") then
            part.CanCollide = false
        end
    end

    local targetCF = (tRoot :: BasePart).CFrame
    local lookDir = targetCF.LookVector
    -- 100% Horizontal Flat Vector (Never sink into ground)
    local flatLook = Vector3.new(lookDir.X, 0, lookDir.Z)
    if flatLook.Magnitude > 0.001 then
        flatLook = flatLook.Unit
    else
        flatLook = Vector3.new(0, 0, -1)
    end

    local dtStep = (type(dt) == "number" and dt > 0) and dt or 0.016
    local targetVel = (tRoot :: BasePart).AssemblyLinearVelocity or Vector3.zero
    local predictedPos = (tRoot :: BasePart).Position + (targetVel * dtStep)

    local dist = (config.Target and config.Target.BehindDistance) or 3.5
    local behindPos = predictedPos - (flatLook * dist) + Vector3.new(0, 0.2, 0)
    local targetFacePos = predictedPos + Vector3.new(0, 0.2, 0)

    pcall(function()
        (myRoot :: BasePart).AssemblyLinearVelocity = Vector3.zero
        (myRoot :: BasePart).AssemblyAngularVelocity = Vector3.zero
        (myRoot :: BasePart).CFrame = CFrame.lookAt(behindPos, targetFacePos)
    end)

    -- Continuous Auto-M1 strike while locked behind
    if config.Target and config.Target.AutoM1OnTP then
        local now = os.clock()
        local delay = (config.Combat and config.Combat.AutoM1Delay) or 0.12
        if (now - (self.LastBehindAttackTick or 0)) >= delay then
            self.LastBehindAttackTick = now
            SafeAttackM1()
        end
    end
end

-- ============================================================================
-- INFINITE JUMP / DOUBLE JUMP (Event-Driven, Maid-Managed, Respawn-Safe)
-- ============================================================================
function Movement:ToggleJumpFeatures(config: any)
    -- Always clean up previous connections first (idempotent)
    if self._jumpMaid then
        self._jumpMaid:DoCleaning()
        self._jumpMaid = nil
    end

    local infiniteJump = config.Movement.InfiniteJump
    local doubleJump = config.Movement.DoubleJump
    if not infiniteJump and not doubleJump then return end

    self._jumpMaid = Maid.new()
    local maid = self._jumpMaid

    local function HookCharacter(char: Model?)
        if not char then return end
        local charMaid = Maid.new()
        maid:GiveTask(function() charMaid:DoCleaning() end)

        local hum = char:WaitForChild("Humanoid", 5) :: Humanoid?
        if not hum then return end

        -- InfiniteJump: on JumpRequest while landed, allow normal jump; prevents stuck state
        if infiniteJump then
            charMaid:GiveTask(UserInputService.JumpRequest:Connect(function()
                if not config.Movement.InfiniteJump then return end
                local h = char:FindFirstChildOfClass("Humanoid")
                if h and h.Health > 0 then
                    -- Allow jump from any grounded or falling state
                    local st = h:GetState()
                    if st == Enum.HumanoidStateType.Landed
                        or st == Enum.HumanoidStateType.Running
                        or st == Enum.HumanoidStateType.Freefall then
                        h:ChangeState(Enum.HumanoidStateType.Jumping)
                    end
                end
            end))
        end

        -- DoubleJump: grant one extra jump per airborne cycle
        if doubleJump then
            local isAirborne = false
            local djUsed = false

            charMaid:GiveTask(hum.StateChanged:Connect(function(_, newState)
                if newState == Enum.HumanoidStateType.Freefall then
                    isAirborne = true
                elseif newState == Enum.HumanoidStateType.Landed
                    or newState == Enum.HumanoidStateType.Running then
                    isAirborne = false
                    djUsed = false
                end
            end))

            charMaid:GiveTask(UserInputService.JumpRequest:Connect(function()
                if not config.Movement.DoubleJump then return end
                if isAirborne and not djUsed then
                    local h = char:FindFirstChildOfClass("Humanoid")
                    if h and h.Health > 0 then
                        djUsed = true
                        h:ChangeState(Enum.HumanoidStateType.Jumping)
                    end
                end
            end))
        end
    end

    -- Hook current character
    local char = LocalPlayer.Character
    if char then
        task.spawn(HookCharacter, char)
    end

    -- Hook future respawns
    maid:GiveTask(LocalPlayer.CharacterAdded:Connect(function(newChar)
        task.spawn(HookCharacter, newChar)
    end))
end

-- Called by Bootstrap/FeatureManager on config change or toggle
function Movement:RefreshJumpFeatures(config: any)
    self:ToggleJumpFeatures(config)
end

function Movement:Destroy()
    if self._jumpMaid then
        self._jumpMaid:DoCleaning()
        self._jumpMaid = nil
    end
end

return Movement

end
__modules["Systems/Movement"] = __modules["Systems.Movement"]

-- ============================================================================
-- Module: Systems.Skills
-- ============================================================================
__modules["Systems.Skills"] = function()
--!strict
local Players = game:GetService("Players")
local LocalPlayer = Players.LocalPlayer

local Skills = {}
Skills.__index = Skills

function Skills.new(deps: { Cache: any, Combat: any, Logger: any })
    local self = setmetatable({
        _cache = deps.Cache,
        _combat = deps.Combat,
        _logger = deps.Logger,
        LastSpamTick = 0,
        SpamIdx = 1,
        Keys = { Enum.KeyCode.One, Enum.KeyCode.Two, Enum.KeyCode.Three, Enum.KeyCode.Four },
    }, Skills)
    return self
end

local function SafeKeyClick(keyCode: Enum.KeyCode)
    local vim = nil
    pcall(function() vim = game:GetService("VirtualInputManager") end)
    if vim then
        pcall(function()
            vim:SendKeyEvent(true, keyCode, false, game)
            task.wait(0.03)
            vim:SendKeyEvent(false, keyCode, false, game)
        end)
    end
end

function Skills:OrientToTarget(config: any)
    local target = self._combat.CurrentTarget or self._combat:GetTarget(config)
    if not target then return end
    local myEntry = self._cache:GetPlayerEntry(LocalPlayer)
    local tEntry = self._cache:GetPlayerEntry(target)
    if not myEntry or not myEntry.RootPart or not tEntry or not tEntry.RootPart then return end

    local myRoot = myEntry.RootPart
    local tPos = tEntry.RootPart.Position
    pcall(function()
        myRoot.CFrame = CFrame.lookAt(myRoot.Position, Vector3.new(tPos.X, myRoot.Position.Y, tPos.Z))
    end)
end

function Skills:UpdateAutoSkillSpam(config: any)
    if not config.Skills.AutoSkillSpam and not config.Skills.AutoUltSpam then return end
    local target = self._combat.CurrentTarget or self._combat:GetTarget(config)
    if not target then return end

    if config.Skills.AutoUltSpam then
        SafeKeyClick(Enum.KeyCode.G)
    end

    if config.Skills.AutoSkillSpam then
        local now = os.clock()
        if (now - self.LastSpamTick) >= (config.Skills.SkillSpamDelay or 0.25) then
            self.LastSpamTick = now
            self:OrientToTarget(config)
            SafeKeyClick(self.Keys[self.SpamIdx])
            self.SpamIdx = (self.SpamIdx % #self.Keys) + 1
        end
    end
end

function Skills:UpdateVoidKill(config: any)
    if not config.Skills.VoidKill then return end
    local target = self._combat.CurrentTarget or self._combat:GetTarget(config)
    if not target then return end

    local tEntry = self._cache:GetPlayerEntry(target)
    if not tEntry or not tEntry.IsAlive or not tEntry.RootPart then return end

    -- Throttle: only trigger once every 3 seconds
    local now = os.clock()
    if (now - (self._lastVoidKillTick or 0)) < 3 then return end
    self._lastVoidKillTick = now

    local root = tEntry.RootPart
    local originalCFrame = root.CFrame
    local voidDepth = config.Skills.VoidDepth or -350

    pcall(function()
        root.CFrame = CFrame.new(originalCFrame.Position.X, voidDepth, originalCFrame.Position.Z)
    end)

    local returnDelay = config.Skills.VoidReturnDelay or 0.5
    task.delay(returnDelay, function()
        pcall(function()
            -- Only return if still in void and still alive
            if root and root.Parent and root.Position.Y < -100 then
                root.CFrame = originalCFrame
            end
        end)
    end)
end

return Skills

end
__modules["Systems/Skills"] = __modules["Systems.Skills"]

-- ============================================================================
-- Module: Systems.Survival
-- ============================================================================
__modules["Systems.Survival"] = function()
--!strict
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local LocalPlayer = Players.LocalPlayer

local Survival = {}
Survival.__index = Survival

function Survival.new(deps: { Cache: any, StateMachine: any, EventBus: any, Logger: any })
    local self = setmetatable({
        _cache = deps.Cache,
        _fsm = deps.StateMachine,
        _eventBus = deps.EventBus,
        _logger = deps.Logger,
        IsDodging = false,
        SavedGroundPos = nil,
        LockedCameraPos = nil,
        LastDodgeTick = 0,
        HasSkyEscaped = false,
        SavedEscapeGround = nil,
    }, Survival)
    return self
end

function Survival:CheckSkyEscape(config: any)
    if not config.Survival.SkyTeleport then return end
    local entry = self._cache:GetPlayerEntry(LocalPlayer)
    if not entry or not entry.Humanoid or not entry.RootPart or entry.Humanoid.Health <= 0 then return end

    local hpPct = (entry.Humanoid.Health / entry.Humanoid.MaxHealth) * 100

    if hpPct <= config.Survival.SkyEscapeHP then
        if not self.HasSkyEscaped then
            -- Clean FSM Priority Transition
            if self._fsm:TransitionTo("SKY_ESCAPE") then
                self.HasSkyEscaped = true
                self.SavedEscapeGround = entry.RootPart.CFrame

                local skyY = entry.RootPart.Position.Y + config.Survival.SkyEscapeHeight
                pcall(function()
                    entry.RootPart.CFrame = CFrame.new(entry.RootPart.Position.X, skyY, entry.RootPart.Position.Z)
                    entry.RootPart.AssemblyLinearVelocity = Vector3.zero
                end)
            end
        end
    elseif self.HasSkyEscaped and hpPct >= (config.Survival.SkyReturnHP or 80) then
        self.HasSkyEscaped = false
        if self.SavedEscapeGround and entry.RootPart then
            entry.RootPart.CFrame = self.SavedEscapeGround + Vector3.new(0, 3, 0)
        end
        self._fsm:TransitionTo("IDLE")
    end
end

function Survival:UpdateSkyDodge(dt: number, config: any)
    if not config.Survival.SkyDodge or self.HasSkyEscaped then return end
    local myEntry = self._cache:GetPlayerEntry(LocalPlayer)
    if not myEntry or not myEntry.RootPart or not myEntry.Humanoid or myEntry.Humanoid.Health <= 0 then return end

    local now = os.clock()
    if not self.IsDodging then
        if (now - self.LastDodgeTick) < 0.2 then return end
        for _, p in ipairs(Players:GetPlayers()) do
            if p == LocalPlayer then continue end
            local tEntry = self._cache:GetPlayerEntry(p)
            if not tEntry or not tEntry.IsAlive or not tEntry.RootPart or not tEntry.Animator then continue end

            local dist = (tEntry.RootPart.Position - myEntry.RootPart.Position).Magnitude
            if dist <= config.Survival.SkyDodgeRange then
                local attacking = false
                for _, track in ipairs(tEntry.Animator:GetPlayingAnimationTracks()) do
                    local n = (track.Name or ""):lower()
                    if n:find("attack") or n:find("punch") or n:find("strike") or n:find("slash") then
                        attacking = true
                        break
                    end
                end

                if attacking then
                    if self._fsm:TransitionTo("SKY_DODGE") then
                        self.IsDodging = true
                        self.LastDodgeTick = now
                        self.SavedGroundPos = myEntry.RootPart.CFrame
                        self.LockedCameraPos = Workspace.CurrentCamera and Workspace.CurrentCamera.CFrame or nil

                        local skyY = myEntry.RootPart.Position.Y + config.Survival.SkyDodgeHeight
                        myEntry.RootPart.CFrame = CFrame.new(myEntry.RootPart.Position.X, skyY, myEntry.RootPart.Position.Z)
                        break
                    end
                end
            end
        end
    else
        local anyAttacking = false
        for _, p in ipairs(Players:GetPlayers()) do
            if p == LocalPlayer then continue end
            local tEntry = self._cache:GetPlayerEntry(p)
            if tEntry and tEntry.IsAlive and tEntry.RootPart and self.SavedGroundPos then
                local d = (tEntry.RootPart.Position - self.SavedGroundPos.Position).Magnitude
                if d <= config.Survival.SkyDodgeRange and tEntry.Animator then
                    for _, track in ipairs(tEntry.Animator:GetPlayingAnimationTracks()) do
                        local n = (track.Name or ""):lower()
                        if n:find("attack") or n:find("punch") or n:find("strike") then
                            anyAttacking = true
                            break
                        end
                    end
                end
            end
        end

        if not anyAttacking then
            self.IsDodging = false
            if self.SavedGroundPos and myEntry.RootPart then
                myEntry.RootPart.CFrame = self.SavedGroundPos
            end
            self.SavedGroundPos = nil
            self.LockedCameraPos = nil
            self._fsm:TransitionTo("IDLE")
        end
    end
end

return Survival

end
__modules["Systems/Survival"] = __modules["Systems.Survival"]

-- ============================================================================
-- Module: Systems.TelemetryRecorder
-- ============================================================================
__modules["Systems.TelemetryRecorder"] = function()
--!strict
-- =============================================================================
-- TelemetryRecorder v10.0 — Comprehensive Multi-Category Data Collector
-- Normalized, deduplicated, multi-file persistent dataset for all players.
-- =============================================================================
local Players    = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local LocalPlayer = Players.LocalPlayer

local TelemetryRecorder = {}
TelemetryRecorder.__index = TelemetryRecorder

-- ============================================================================
-- HELPERS
-- ============================================================================
local function countKeys(t: any): number
    local n = 0
    for _ in pairs(t) do n += 1 end
    return n
end

local function setAdd(s: {[string]: boolean}, val: string)
    s[val] = true
end

local function isBehavioral(name: string): boolean
    local n = name:lower()
    return n:find("holding") ~= nil
        or n:find("blocking") ~= nil
        or n:find("skill") ~= nil
        or n:find("ulted") ~= nil
        or n:find("state") ~= nil
        or n:find("counter") ~= nil
        or n:find("dash") ~= nil
        or n:find("hurt") ~= nil
        or n:find("ragdoll") ~= nil
        or n:find("stun") ~= nil
end

local function getCharType(char: any): string
    if char then
        local attr = char:GetAttribute("Character")
        if type(attr) == "string" and #attr > 0 then return attr end
        return char.Name or "Unknown"
    end
    return "Unknown"
end

local function getRigType(char: any): string
    if char and char:FindFirstChild("UpperTorso") then
        return "R15"
    end
    return "R6"
end

local function getPath(inst: Instance): string
    local parts = {}
    local cur: Instance? = inst
    while cur and cur ~= game do
        table.insert(parts, 1, cur.Name)
        cur = cur.Parent
    end
    return table.concat(parts, ".")
end

local function JSONEncode(data: any): string
    local ok, result = pcall(function() return HttpService:JSONEncode(data) end)
    if ok then return result end
    return "{}"
end

local function JSONDecode(raw: string): any
    local ok, result = pcall(function() return HttpService:JSONDecode(raw) end)
    if ok then return result end
    return nil
end

local function safeReadFile(path: string): string?
    local ok, result = pcall(function()
        if isfile and isfile(path) then
            return readfile(path)
        end
    end)
    if ok then return result end
    return nil
end

local function safeWriteFile(path: string, content: string)
    pcall(function()
        if writefile then writefile(path, content) end
    end)
end

local function safeMakeFolder(path: string)
    pcall(function()
        if makefolder then makefolder(path) end
    end)
end

-- ============================================================================
-- CONSTRUCTOR
-- ============================================================================
function TelemetryRecorder.new(deps: { Logger: any, EventBus: any })
    local self = setmetatable({
        _logger    = deps.Logger,
        _eventBus  = deps.EventBus,

        -- Multi-category normalized data store
        Data = {
            Meta = {
                Version           = "10.0",
                Created           = os.time(),
                LastUpdated       = os.time(),
                TotalSessions     = 1,
                FrameworkVersion  = "9.0-SPECIALIST-PRODUCTION",
            },
            Animations    = {},
            Characters    = {},
            Hitboxes      = {},
            Attributes    = {},
            Correlations  = {},
            CombatEvents  = {},  -- ring buffer
            Cooldowns     = {},
            Sounds        = {},
            Tools         = {},
            Remotes       = {},
            World         = {},
        },

        _connections      = {},
        _playerTrackers   = {},  -- per-player state for correlation/cooldown
        _notifThrottle    = {},  -- key → last notif time
        _isDirty          = false,
        _lastSaveTick     = 0,
        _sessionStart     = os.clock(),
        _isRecording      = false,
        _maxCombatEvents  = 1000,  -- overwritten from config in Update
        _lastRemoteScan   = 0,
    }, TelemetryRecorder)

    return self
end

-- ============================================================================
-- NOTIFICATION THROTTLE
-- ============================================================================
function TelemetryRecorder:SendNotification(key: string, title: string, msg: string, duration: number?, kind: any?)
    local now = os.clock()
    if (now - (self._notifThrottle[key] or 0)) < 2 then return end
    self._notifThrottle[key] = now
    self._eventBus:Publish("Notification.Show", title, msg, duration or 3.0, kind or "Info")
end

-- ============================================================================
-- ANIMATION RECORDING
-- ============================================================================
function TelemetryRecorder:RecordAnimation(track: AnimationTrack, player: Player, char: any)
    if not track or not track.Animation then return end
    local animId = tostring(track.Animation.AnimationId or "")
    if animId == "" or animId == "0" then return end

    local charType = getCharType(char)
    local playerName = player.Name

    local now = os.time()
    local record = self.Data.Animations[animId]
    if not record then
        record = {
            Id              = animId,
            RawUrl          = animId,
            Name            = track.Name or "",
            Length          = track.Length or 0,
            Priority        = tostring(track.Priority or ""),
            Looped          = track.Looped or false,
            Speed           = track.Speed or 1,
            FirstSeen       = now,
            LastSeen        = now,
            PlayCount       = 0,
            TotalPlaytime   = 0,
            PlayersSeen     = {},
            CharactersSeen  = {},
        }
        self.Data.Animations[animId] = record
        self:SendNotification("anim_new", "📊 New Animation", "Discovered: " .. (track.Name or animId:sub(-12)), 2.5, "Info")
    end

    record.PlayCount += 1
    record.LastSeen = now
    record.TotalPlaytime += (track.Length or 0)
    setAdd(record.PlayersSeen, playerName)
    setAdd(record.CharactersSeen, charType)

    -- Link to character profile
    if self.Data.Characters[charType] then
        setAdd(self.Data.Characters[charType].AnimationsSeen, animId)
    end

    self._isDirty = true
end

-- ============================================================================
-- CHARACTER PROFILE RECORDING
-- ============================================================================
function TelemetryRecorder:RecordCharacterProfile(char: any, player: Player)
    if not char then return end
    local charType = getCharType(char)
    local rigType = getRigType(char)
    local now = os.time()

    local record = self.Data.Characters[charType]
    if not record then
        local attrList = {}
        pcall(function()
            for attrName, _ in pairs(char:GetAttributes()) do
                attrList[attrName] = true
            end
        end)
        record = {
            CharacterType  = charType,
            RigType        = rigType,
            PartCount      = 0,
            Attributes     = attrList,
            AnimationsSeen = {},
            FirstSeen      = now,
            LastSeen       = now,
            ObservedCount  = 0,
            PlayersSeen    = {},
        }
        self.Data.Characters[charType] = record
        self:SendNotification("char_" .. charType, "🎭 New Character", "Profiled: " .. charType .. " (" .. rigType .. ")", 3.0, "Info")
    end

    record.ObservedCount += 1
    record.LastSeen = now
    setAdd(record.PlayersSeen, player.Name)

    -- Update part count
    local partCount = 0
    pcall(function()
        for _, desc in ipairs(char:GetDescendants()) do
            if desc:IsA("BasePart") then partCount += 1 end
        end
    end)
    record.PartCount = partCount

    self._isDirty = true
end

-- ============================================================================
-- HITBOX PROFILE RECORDING
-- ============================================================================
function TelemetryRecorder:RecordHitboxProfile(char: any, player: Player)
    if not char then return end
    local charType = getCharType(char)
    local rigType = getRigType(char)
    local now = os.time()

    local hrp = char:FindFirstChild("HumanoidRootPart")
    if not hrp then return end
    local hrpPos = hrp.Position

    local record = self.Data.Hitboxes[charType]
    local shouldUpdate = not record or record.SampleCount == 0

    if not record then
        record = {
            CharacterType = charType,
            RigType       = rigType,
            Parts         = {},
            FirstSeen     = now,
            LastSeen      = now,
            SampleCount   = 0,
        }
        self.Data.Hitboxes[charType] = record
    end

    if shouldUpdate then
        -- Record all BaseParts
        pcall(function()
            for _, part in ipairs(char:GetDescendants()) do
                if part:IsA("BasePart") then
                    local rel = part.Position - hrpPos
                    record.Parts[part.Name] = {
                        Size             = { X = part.Size.X, Y = part.Size.Y, Z = part.Size.Z },
                        RelativePosition = { X = math.floor(rel.X * 100) / 100, Y = math.floor(rel.Y * 100) / 100, Z = math.floor(rel.Z * 100) / 100 },
                        CanCollide       = part.CanCollide,
                        Mass             = part.Mass,
                        Transparency     = part.Transparency,
                        Class            = part.ClassName,
                    }
                end
            end
        end)
        self:SendNotification("hitbox_" .. charType, "📐 Hitbox Mapped", charType .. " geometry captured (" .. countKeys(record.Parts) .. " parts)", 2.5, "Success")
    end

    record.SampleCount += 1
    record.LastSeen = now
    self._isDirty = true
end

-- ============================================================================
-- ATTRIBUTE RECORDING + CORRELATION
-- ============================================================================
function TelemetryRecorder:RecordAttribute(attrName: string, value: any, player: Player, char: any)
    if not attrName then return end
    local charType = getCharType(char)
    local now = os.time()

    local record = self.Data.Attributes[attrName]
    if not record then
        record = {
            Name           = attrName,
            ValueType      = typeof(value),
            ObservedValues = {},
            FirstSeen      = now,
            LastSeen       = now,
            ChangeCount    = 0,
            PlayersSeen    = {},
            CharactersSeen = {},
            IsBehavioral   = isBehavioral(attrName),
        }
        self.Data.Attributes[attrName] = record
    end

    record.ChangeCount += 1
    record.LastSeen = now
    setAdd(record.PlayersSeen, player.Name)
    setAdd(record.CharactersSeen, charType)

    -- Normalize observed values (handle different types)
    local valKey = tostring(value)
    if #valKey <= 32 then
        record.ObservedValues[valKey] = true
    end

    -- Track cooldown: time since last change
    if record.IsBehavioral then
        self:TrackCooldown(charType, attrName)
    end

    -- Correlation: check animations playing within 500ms
    self:CheckCorrelation(attrName, player)

    self._isDirty = true
end

-- ============================================================================
-- COOLDOWN ANALYSIS
-- ============================================================================
function TelemetryRecorder:TrackCooldown(charType: string, eventKey: string)
    local now = os.clock()
    local trackerKey = charType .. "_" .. eventKey
    local lastTime = self._playerTrackers[trackerKey]

    if lastTime then
        local interval = now - lastTime
        -- Only meaningful intervals (0.01s to 60s)
        if interval >= 0.01 and interval <= 60 then
            if not self.Data.Cooldowns[charType] then
                self.Data.Cooldowns[charType] = {}
            end
            local cd = self.Data.Cooldowns[charType][eventKey]
            if not cd then
                cd = { Min = math.huge, Max = 0, Avg = 0, Samples = {}, Count = 0 }
                self.Data.Cooldowns[charType][eventKey] = cd
            end
            cd.Count += 1
            if interval < cd.Min then cd.Min = interval end
            if interval > cd.Max then cd.Max = interval end
            table.insert(cd.Samples, math.floor(interval * 1000))  -- store in ms
            if #cd.Samples > 30 then table.remove(cd.Samples, 1) end
            -- Rolling average from samples
            local sum = 0
            for _, s in ipairs(cd.Samples) do sum += s end
            cd.Avg = math.floor(sum / #cd.Samples)
        end
    end
    self._playerTrackers[trackerKey] = now
end

-- ============================================================================
-- CORRELATION DETECTION
-- ============================================================================
function TelemetryRecorder:CheckCorrelation(attrName: string, player: Player)
    if not self.Data.Attributes[attrName] or not self.Data.Attributes[attrName].IsBehavioral then return end

    local char = player.Character
    if not char then return end
    local hum = char:FindFirstChildOfClass("Humanoid")
    if not hum then return end
    local anim = hum:FindFirstChildOfClass("Animator")
    if not anim then return end

    local now = os.time()
    local tracks = {}
    pcall(function() tracks = anim:GetPlayingAnimationTracks() end)

    for _, track in ipairs(tracks) do
        if not track.Animation then continue end
        local animId = tostring(track.Animation.AnimationId or "")
        if animId == "" or animId == "0" then continue end
        local corrKey = animId .. "_" .. attrName
        local corr = self.Data.Correlations[corrKey]
        if not corr then
            corr = {
                AnimationId     = animId,
                AttributeName   = attrName,
                CoOccurrenceCount = 0,
                WindowMs        = 500,
                FirstSeen       = now,
                LastSeen        = now,
            }
            self.Data.Correlations[corrKey] = corr
        end
        corr.CoOccurrenceCount += 1
        corr.LastSeen = now
    end
end

-- ============================================================================
-- COMBAT EVENT RECORDING (ring buffer)
-- ============================================================================
function TelemetryRecorder:RecordCombatEvent(eventType: string, player: Player?, char: any?, details: any?)
    local now = os.time()
    local charType = char and getCharType(char) or "Unknown"
    local playerName = player and player.Name or "Unknown"

    -- Get current animation and position from player
    local currentAnimation = nil
    local position = nil
    local velocity = nil
    pcall(function()
        if char then
            local hrp = char:FindFirstChild("HumanoidRootPart")
            if hrp then
                position = { X = math.floor(hrp.Position.X), Y = math.floor(hrp.Position.Y), Z = math.floor(hrp.Position.Z) }
                velocity = math.floor(hrp.AssemblyLinearVelocity.Magnitude * 10) / 10
            end
            local hum = char:FindFirstChildOfClass("Humanoid")
            local anim = hum and hum:FindFirstChildOfClass("Animator")
            if anim then
                local tracks = anim:GetPlayingAnimationTracks()
                if tracks and #tracks > 0 and tracks[1].Animation then
                    currentAnimation = tostring(tracks[1].Animation.AnimationId)
                end
            end
        end
    end)

    local event = {
        Type             = eventType,
        Timestamp        = now,
        Player           = playerName,
        Character        = charType,
        Position         = position,
        Velocity         = velocity,
        CurrentAnimation = currentAnimation,
        Details          = details or {},
    }

    table.insert(self.Data.CombatEvents, event)
    -- Enforce ring buffer limit
    local maxEv = self._maxCombatEvents
    while #self.Data.CombatEvents > maxEv do
        table.remove(self.Data.CombatEvents, 1)
    end

    self._isDirty = true
end

-- ============================================================================
-- SOUND RECORDING
-- ============================================================================
function TelemetryRecorder:RecordSound(sound: any, player: Player, char: any)
    if not sound or not sound:IsA("Sound") then return end
    local soundId = tostring(sound.SoundId or "")
    if soundId == "" or soundId == "0" then return end
    local charType = getCharType(char)
    local now = os.time()

    local record = self.Data.Sounds[soundId]
    if not record then
        record = {
            Id             = soundId,
            Name           = sound.Name or "",
            Volume         = sound.Volume or 0.5,
            PlaybackSpeed  = sound.PlaybackSpeed or 1,
            CharactersSeen = {},
            PlayersSeen    = {},
            PlayCount      = 0,
            FirstSeen      = now,
            LastSeen       = now,
        }
        self.Data.Sounds[soundId] = record
    end

    record.PlayCount += 1
    record.LastSeen = now
    setAdd(record.CharactersSeen, charType)
    setAdd(record.PlayersSeen, player.Name)
    self._isDirty = true
end

-- ============================================================================
-- TOOL / ACCESSORY / ATTACHMENT RECORDING
-- ============================================================================
function TelemetryRecorder:RecordTool(inst: any, player: Player, char: any)
    if not inst then return end
    local name = inst.Name or "Unknown"
    local class = inst.ClassName or "Unknown"
    local charType = getCharType(char)
    local now = os.time()
    local key = class .. "_" .. name

    local record = self.Data.Tools[key]
    if not record then
        record = {
            Name           = name,
            Class          = class,
            CharactersSeen = {},
            PlayersSeen    = {},
            Count          = 0,
            FirstSeen      = now,
            LastSeen       = now,
        }
        self.Data.Tools[key] = record
    end

    record.Count += 1
    record.LastSeen = now
    setAdd(record.CharactersSeen, charType)
    setAdd(record.PlayersSeen, player.Name)
    self._isDirty = true
end

-- ============================================================================
-- REMOTE DISCOVERY SCAN
-- ============================================================================
function TelemetryRecorder:ScanRemotes()
    local now = os.time()
    local scanTargets = { game:GetService("ReplicatedStorage"), game:GetService("Workspace") }

    for _, root in ipairs(scanTargets) do
        pcall(function()
            for _, desc in ipairs(root:GetDescendants()) do
                if desc:IsA("RemoteEvent") or desc:IsA("RemoteFunction") or desc:IsA("BindableEvent") then
                    local path = getPath(desc)
                    local record = self.Data.Remotes[path]
                    if not record then
                        record = {
                            Name      = desc.Name,
                            Class     = desc.ClassName,
                            Path      = path,
                            FirstSeen = now,
                            LastSeen  = now,
                        }
                        self.Data.Remotes[path] = record
                    else
                        record.LastSeen = now
                    end
                end
            end
        end)
    end

    self._isDirty = true
end

-- ============================================================================
-- HOOK CHARACTER (called for each player's character)
-- ============================================================================
function TelemetryRecorder:HookCharacter(player: Player, char: any)
    if not char then return end
    -- Wait for character to fully load
    local hrp = char:FindFirstChild("HumanoidRootPart")
    if not hrp then
        pcall(function()
            hrp = char:WaitForChild("HumanoidRootPart", 10)
        end)
        if not hrp then return end
    end

    local charType = getCharType(char)

    -- Record static profiles
    self:RecordCharacterProfile(char, player)
    self:RecordHitboxProfile(char, player)

    -- Hook AttributeChanged
    local attrConn = char.AttributeChanged:Connect(function(attrName: string)
        if not self._isRecording then return end
        pcall(function()
            local val = char:GetAttribute(attrName)
            self:RecordAttribute(attrName, val, player, char)
        end)
    end)
    local connKey = "AttrChanged_" .. player.UserId
    if self._connections[connKey] then
        pcall(function() self._connections[connKey]:Disconnect() end)
    end
    self._connections[connKey] = attrConn

    -- Do initial attribute scan
    pcall(function()
        for attrName, val in pairs(char:GetAttributes()) do
            self:RecordAttribute(attrName, val, player, char)
        end
    end)

    -- Hook HealthChanged
    local hum = char:FindFirstChildOfClass("Humanoid")
    if hum then
        local healthConn = hum.HealthChanged:Connect(function(newHp: number)
            if not self._isRecording then return end
            self:RecordCombatEvent("HealthChange", player, char, { HP = math.floor(newHp) })
        end)
        local hKey = "Health_" .. player.UserId
        if self._connections[hKey] then pcall(function() self._connections[hKey]:Disconnect() end) end
        self._connections[hKey] = healthConn

        -- Hook StateChanged for ragdoll events
        local stateConn = hum.StateChanged:Connect(function(_, newState: Enum.HumanoidStateType)
            if not self._isRecording then return end
            if newState == Enum.HumanoidStateType.Physics or newState == Enum.HumanoidStateType.FallingDown then
                self:RecordCombatEvent("RagdollEntered", player, char, { State = tostring(newState) })
            elseif newState == Enum.HumanoidStateType.Running or newState == Enum.HumanoidStateType.Landed then
                self:RecordCombatEvent("RagdollWakeup", player, char, { State = tostring(newState) })
            end
        end)
        local sKey = "State_" .. player.UserId
        if self._connections[sKey] then pcall(function() self._connections[sKey]:Disconnect() end) end
        self._connections[sKey] = stateConn
    end

    -- Hook Animator for animation events
    local anim = hum and hum:FindFirstChildOfClass("Animator")
    if anim then
        local animConn = anim.AnimationPlayed:Connect(function(track: AnimationTrack)
            if not self._isRecording then return end
            pcall(function() self:RecordAnimation(track, player, char) end)
        end)
        local aKey = "Anim_" .. player.UserId
        if self._connections[aKey] then pcall(function() self._connections[aKey]:Disconnect() end) end
        self._connections[aKey] = animConn
    end

    -- Hook DescendantAdded for sounds and tools
    local descConn = char.DescendantAdded:Connect(function(desc: Instance)
        if not self._isRecording then return end
        pcall(function()
            if desc:IsA("Sound") then
                self:RecordSound(desc, player, char)
            elseif desc:IsA("Tool") or desc:IsA("Accessory") then
                self:RecordTool(desc, player, char)
            end
        end)
    end)
    local dKey = "Desc_" .. player.UserId
    if self._connections[dKey] then pcall(function() self._connections[dKey]:Disconnect() end) end
    self._connections[dKey] = descConn

    -- Scan existing descendants
    pcall(function()
        for _, desc in ipairs(char:GetDescendants()) do
            if desc:IsA("Sound") then
                self:RecordSound(desc, player, char)
            elseif desc:IsA("Tool") or desc:IsA("Accessory") then
                self:RecordTool(desc, player, char)
            end
        end
    end)
end

-- ============================================================================
-- INIT HOOKS (called once at startup)
-- ============================================================================
function TelemetryRecorder:InitHooks()
    -- Hook existing players
    for _, p in ipairs(Players:GetPlayers()) do
        if p.Character then
            task.spawn(function() self:HookCharacter(p, p.Character) end)
        end
        local charAddedKey = "CharAdded_" .. tostring(p.UserId)
        self._connections[charAddedKey] = p.CharacterAdded:Connect(function(char)
            task.spawn(function() self:HookCharacter(p, char) end)
        end)
    end

    -- Hook newly joined players
    self._connections["PlayerAdded"] = Players.PlayerAdded:Connect(function(p)
        local charAddedKey = "CharAdded_" .. tostring(p.UserId)
        self._connections[charAddedKey] = p.CharacterAdded:Connect(function(char)
            task.spawn(function() self:HookCharacter(p, char) end)
        end)
    end)

    self._connections["PlayerRemoving"] = Players.PlayerRemoving:Connect(function(p)
        self._playerTrackers["target_" .. p.Name] = nil
        local charAddedKey = "CharAdded_" .. tostring(p.UserId)
        if self._connections[charAddedKey] then
            pcall(function() self._connections[charAddedKey]:Disconnect() end)
            self._connections[charAddedKey] = nil
        end
    end)

    -- Initial remote scan
    task.spawn(function() self:ScanRemotes() end)
end

-- ============================================================================
-- LOAD FROM DISK (multi-file first, single file fallback)
-- ============================================================================
function TelemetryRecorder:LoadFromDisk()
    -- Try multi-file first
    local metaRaw = safeReadFile("tsb_data/metadata.json")
    if metaRaw then
        local categories = {
            "metadata", "animations", "characters", "hitboxes",
            "attributes", "combat_events", "cooldowns", "sounds", "tools", "remotes"
        }
        local dataMap = {
            metadata      = "Meta",
            animations    = "Animations",
            characters    = "Characters",
            hitboxes      = "Hitboxes",
            attributes    = "Attributes",
            combat_events = "CombatEvents",
            cooldowns     = "Cooldowns",
            sounds        = "Sounds",
            tools         = "Tools",
            remotes       = "Remotes",
        }
        local loaded = false
        for _, cat in ipairs(categories) do
            local raw = safeReadFile("tsb_data/" .. cat .. ".json")
            if raw then
                local decoded = JSONDecode(raw)
                if decoded and type(decoded) == "table" then
                    local key = dataMap[cat]
                    if key then
                        if cat == "metadata" then
                            -- Merge meta: preserve session count
                            if type(decoded.TotalSessions) == "number" then
                                self.Data.Meta.TotalSessions = decoded.TotalSessions + 1
                            end
                            if type(decoded.Created) == "number" then
                                self.Data.Meta.Created = decoded.Created
                            end
                        elseif cat == "combat_events" then
                            if type(decoded) == "table" then
                                for _, ev in ipairs(decoded) do
                                    table.insert(self.Data.CombatEvents, ev)
                                end
                                -- Trim to max
                                while #self.Data.CombatEvents > self._maxCombatEvents do
                                    table.remove(self.Data.CombatEvents, 1)
                                end
                            end
                        else
                            -- Merge into existing data table
                            for k, v in pairs(decoded) do
                                if self.Data[key] then
                                    self.Data[key][k] = v
                                end
                            end
                        end
                        loaded = true
                    end
                end
            end
        end
        if loaded then
            self._logger:Info("TelemetryRecorder", "Loaded multi-file dataset from tsb_data/")
            return
        end
    end

    -- Fallback: single combined file
    local raw = safeReadFile("tsb_combat_data.json")
    if not raw then return end
    local decoded = JSONDecode(raw)
    if not decoded or type(decoded) ~= "table" then return end

    -- Merge each category
    for key, tbl in pairs(decoded) do
        if self.Data[key] and type(tbl) == "table" then
            if key == "Meta" then
                if type(tbl.TotalSessions) == "number" then
                    self.Data.Meta.TotalSessions = tbl.TotalSessions + 1
                end
            elseif key == "CombatEvents" then
                for _, ev in ipairs(tbl) do
                    table.insert(self.Data.CombatEvents, ev)
                end
            else
                for k, v in pairs(tbl) do
                    self.Data[key][k] = v
                end
            end
        end
    end

    self._logger:Info("TelemetryRecorder", "Loaded single-file dataset from tsb_combat_data.json")
end

-- ============================================================================
-- SAVE TO DISK (multi-file + combined fallback)
-- ============================================================================
function TelemetryRecorder:SaveToDisk(force: boolean?)
    if not force and not self._isDirty then return end
    self.Data.Meta.LastUpdated = os.time()

    -- Try multi-file save
    local multiOk = false
    pcall(function()
        if writefile and makefolder then
            safeMakeFolder("tsb_data")
            safeWriteFile("tsb_data/metadata.json", JSONEncode(self.Data.Meta))
            safeWriteFile("tsb_data/animations.json", JSONEncode(self.Data.Animations))
            safeWriteFile("tsb_data/characters.json", JSONEncode(self.Data.Characters))
            safeWriteFile("tsb_data/hitboxes.json", JSONEncode(self.Data.Hitboxes))
            safeWriteFile("tsb_data/attributes.json", JSONEncode(self.Data.Attributes))
            safeWriteFile("tsb_data/combat_events.json", JSONEncode(self.Data.CombatEvents))
            safeWriteFile("tsb_data/cooldowns.json", JSONEncode(self.Data.Cooldowns))
            safeWriteFile("tsb_data/sounds.json", JSONEncode(self.Data.Sounds))
            safeWriteFile("tsb_data/tools.json", JSONEncode(self.Data.Tools))
            safeWriteFile("tsb_data/remotes.json", JSONEncode(self.Data.Remotes))
            multiOk = true
        end
    end)

    -- Always also save combined file for backward compat
    safeWriteFile("tsb_combat_data.json", JSONEncode(self.Data))

    self._isDirty = false
    self._lastSaveTick = os.clock()
    self._logger:Debug("TelemetryRecorder", string.format("Saved dataset (multi=%s) — Anims:%d Chars:%d Attrs:%d Events:%d",
        tostring(multiOk),
        countKeys(self.Data.Animations),
        countKeys(self.Data.Characters),
        countKeys(self.Data.Attributes),
        #self.Data.CombatEvents
    ))
end

-- ============================================================================
-- UPDATE (called from scheduler)
-- ============================================================================
function TelemetryRecorder:Update(dt: number, config: any)
    local cfg = config and config.Telemetry
    if not cfg then return end

    self._isRecording = cfg.AutoRecordData ~= false
    self._maxCombatEvents = cfg.MaxCombatEvents or 1000

    -- Periodic remote scan (every 30s)
    local now = os.clock()
    if cfg.RecordRemotes ~= false and (now - self._lastRemoteScan) >= 30 then
        self._lastRemoteScan = now
        task.spawn(function() self:ScanRemotes() end)
    end

    -- Periodic animation scan for players (catch missed AnimationPlayed events)
    if self._isRecording and cfg.RecordAnimations ~= false then
        for _, p in ipairs(Players:GetPlayers()) do
            local char = p.Character
            if not char then continue end
            local hum = char:FindFirstChildOfClass("Humanoid")
            local anim = hum and hum:FindFirstChildOfClass("Animator")
            if anim then
                pcall(function()
                    for _, track in ipairs(anim:GetPlayingAnimationTracks()) do
                        if track.IsPlaying and track.Animation then
                            local animId = tostring(track.Animation.AnimationId or "")
                            if animId ~= "" and animId ~= "0" and not self.Data.Animations[animId] then
                                self:RecordAnimation(track, p, char)
                            end
                        end
                    end
                end)
            end
        end
    end

    -- Autosave
    local interval = cfg.AutoSaveInterval or 15
    if (now - self._lastSaveTick) >= interval then
        self:SaveToDisk(false)
    end
end

-- ============================================================================
-- STATS / EXPORT
-- ============================================================================
function TelemetryRecorder:GetStats(): any
    return {
        TotalAnimations       = countKeys(self.Data.Animations),
        TotalCharacters       = countKeys(self.Data.Characters),
        TotalHitboxProfiles   = countKeys(self.Data.Hitboxes),
        TotalAttributes       = countKeys(self.Data.Attributes),
        TotalCorrelations     = countKeys(self.Data.Correlations),
        TotalCombatEvents     = #self.Data.CombatEvents,
        TotalCooldownProfiles = countKeys(self.Data.Cooldowns),
        TotalSounds           = countKeys(self.Data.Sounds),
        TotalTools            = countKeys(self.Data.Tools),
        TotalRemotes          = countKeys(self.Data.Remotes),
        LastSaved             = self._lastSaveTick,
        IsRecording           = self._isRecording,
        SessionDuration       = os.clock() - self._sessionStart,
        SessionNumber         = self.Data.Meta.TotalSessions,
    }
end

function TelemetryRecorder:ExportSummary(): string
    local s = self:GetStats()
    return string.format(
        "=== TSB Data Collector v10.0 ===\nSession #%d | Runtime: %.0fs\nAnimations: %d | Characters: %d | Hitboxes: %d\nAttributes: %d | Correlations: %d | Events: %d\nCooldowns: %d | Sounds: %d | Tools: %d | Remotes: %d",
        s.SessionNumber, s.SessionDuration,
        s.TotalAnimations, s.TotalCharacters, s.TotalHitboxProfiles,
        s.TotalAttributes, s.TotalCorrelations, s.TotalCombatEvents,
        s.TotalCooldownProfiles, s.TotalSounds, s.TotalTools, s.TotalRemotes
    )
end

-- ============================================================================
-- DESTROY
-- ============================================================================
function TelemetryRecorder:Destroy()
    self._isRecording = false
    self:SaveToDisk(true)
    for key, conn in pairs(self._connections) do
        if conn and typeof(conn) == "RBXScriptConnection" then
            pcall(function() conn:Disconnect() end)
        end
        self._connections[key] = nil
    end
    table.clear(self._playerTrackers)
    table.clear(self._notifThrottle)
end

return TelemetryRecorder

end
__modules["Systems/TelemetryRecorder"] = __modules["Systems.TelemetryRecorder"]

-- ============================================================================
-- Module: Systems.Visuals
-- ============================================================================
__modules["Systems.Visuals"] = function()
--!strict
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local LocalPlayer = Players.LocalPlayer

local Visuals = {}
Visuals.__index = Visuals

export type PlayerVisuals = {
    Highlight: Highlight?,
    Billboard: BillboardGui?,
    HpBar: Frame?,
    NameLabel: TextLabel?,
    DistLabel: TextLabel?,
    BadgeLabel: TextLabel?,
}

function Visuals.new(deps: { Cache: any, ObjectPool: any, Logger: any })
    local self = setmetatable({
        _cache = deps.Cache,
        _logger = deps.Logger,
        _playerVisuals = {} :: { [Player]: PlayerVisuals },
        _connections = {} :: { [Player]: { RBXScriptConnection } },
    }, Visuals)

    self:InitPlayerHooks()
    return self
end

function Visuals:InitPlayerHooks()
    local function HookPlayer(p: Player)
        if p == LocalPlayer then return end
        self._connections[p] = {}

        local function OnCharAdded(c: Model)
            self:CleanupPlayerVisuals(p)
        end

        local function OnCharRemoving(c: Model)
            self:CleanupPlayerVisuals(p)
        end

        if p.Character then
            OnCharAdded(p.Character)
        end

        table.insert(self._connections[p], p.CharacterAdded:Connect(OnCharAdded))
        table.insert(self._connections[p], p.CharacterRemoving:Connect(OnCharRemoving))
    end

    for _, p in ipairs(Players:GetPlayers()) do
        HookPlayer(p)
    end

    Players.PlayerAdded:Connect(HookPlayer)
    Players.PlayerRemoving:Connect(function(p)
        self:CleanupPlayerVisuals(p)
        if self._connections[p] then
            for _, conn in ipairs(self._connections[p]) do
                pcall(function() conn:Disconnect() end)
            end
            self._connections[p] = nil
        end
    end)
end

function Visuals:CleanupPlayerVisuals(p: Player)
    local vis = self._playerVisuals[p]
    if vis then
        if vis.Highlight and vis.Highlight.Parent then
            pcall(function() vis.Highlight:Destroy() end)
        end
        if vis.Billboard and vis.Billboard.Parent then
            pcall(function() vis.Billboard:Destroy() end)
        end
        self._playerVisuals[p] = nil
    end
end

function Visuals:CreateBillboard(player: Player, char: Model, headOrRoot: BasePart): BillboardGui
    local bg = Instance.new("BillboardGui")
    bg.Name = "TSB_ESP_" .. player.UserId
    bg.Adornee = headOrRoot
    bg.Size = UDim2.new(0, 150, 0, 48)
    bg.StudsOffset = Vector3.new(0, 3.2, 0)
    bg.AlwaysOnTop = true
    bg.ResetOnSpawn = false

    local rootFrame = Instance.new("Frame")
    rootFrame.Size = UDim2.new(1, 0, 1, 0)
    rootFrame.BackgroundTransparency = 1
    rootFrame.Parent = bg

    local nameLbl = Instance.new("TextLabel")
    nameLbl.Name = "NameLabel"
    nameLbl.Size = UDim2.new(1, 0, 0, 16)
    nameLbl.Position = UDim2.new(0, 0, 0, 0)
    nameLbl.BackgroundTransparency = 1
    nameLbl.Text = player.DisplayName or player.Name
    nameLbl.TextColor3 = Color3.fromRGB(255, 255, 255)
    nameLbl.TextStrokeTransparency = 0.2
    nameLbl.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
    nameLbl.TextSize = 12
    nameLbl.Font = Enum.Font.GothamBold
    nameLbl.Parent = rootFrame

    local badgeLbl = Instance.new("TextLabel")
    badgeLbl.Name = "BadgeLabel"
    badgeLbl.Size = UDim2.new(1, 0, 0, 14)
    badgeLbl.Position = UDim2.new(0, 0, 0, 16)
    badgeLbl.BackgroundTransparency = 1
    badgeLbl.Text = ""
    badgeLbl.TextColor3 = Color3.fromRGB(255, 215, 0)
    badgeLbl.TextStrokeTransparency = 0.3
    badgeLbl.TextSize = 10
    badgeLbl.Font = Enum.Font.GothamMedium
    badgeLbl.Parent = rootFrame

    local hpBg = Instance.new("Frame")
    hpBg.Name = "HpBg"
    hpBg.Size = UDim2.new(0.85, 0, 0, 5)
    hpBg.Position = UDim2.new(0.075, 0, 0, 34)
    hpBg.BackgroundColor3 = Color3.fromRGB(20, 20, 25)
    hpBg.BorderSizePixel = 0
    hpBg.Parent = rootFrame
    Instance.new("UICorner", hpBg).CornerRadius = UDim.new(1, 0)

    local hpBar = Instance.new("Frame")
    hpBar.Name = "HpBar"
    hpBar.Size = UDim2.new(1, 0, 1, 0)
    hpBar.BackgroundColor3 = Color3.fromRGB(0, 230, 120)
    hpBar.BorderSizePixel = 0
    hpBar.Parent = hpBg
    Instance.new("UICorner", hpBar).CornerRadius = UDim.new(1, 0)

    local distLbl = Instance.new("TextLabel")
    distLbl.Name = "DistLabel"
    distLbl.Size = UDim2.new(1, 0, 0, 12)
    distLbl.Position = UDim2.new(0, 0, 0, 40)
    distLbl.BackgroundTransparency = 1
    distLbl.Text = "0m"
    distLbl.TextColor3 = Color3.fromRGB(180, 185, 200)
    distLbl.TextStrokeTransparency = 0.4
    distLbl.TextSize = 9
    distLbl.Font = Enum.Font.Gotham
    distLbl.Parent = rootFrame

    bg.Parent = char
    return bg
end

function Visuals:Update(config: any)
    local myEntry = self._cache:GetPlayerEntry(LocalPlayer)
    local myPos = (myEntry and myEntry.RootPart and myEntry.RootPart.Position) or Vector3.zero

    local hlEnabled = config.Visuals and config.Visuals.HighlightESP
    local bbEnabled = config.Visuals and config.Visuals.BillboardESP

    for _, player in ipairs(Players:GetPlayers()) do
        if player == LocalPlayer then continue end

        local entry = self._cache:GetPlayerEntry(player)
        local char = (entry and entry.Character) or player.Character
        local hum = (entry and entry.Humanoid) or (char and char:FindFirstChildOfClass("Humanoid"))
        local root = (entry and entry.RootPart) or (char and (char:FindFirstChild("HumanoidRootPart") or char:FindFirstChild("Torso")))
        local isAlive = (char and hum and root and hum.Health > 0 and char.Parent ~= nil)

        if isAlive and char and root and hum then
            local vis = self._playerVisuals[player]
            if not vis then
                vis = {
                    Highlight = nil,
                    Billboard = nil,
                    HpBar = nil,
                    NameLabel = nil,
                    DistLabel = nil,
                    BadgeLabel = nil,
                }
                self._playerVisuals[player] = vis
            end

            -- Check TSB attributes for real-time status indicators
            local isCounter = false
            local isUlt = false
            local charName = tostring(char:GetAttribute("Character") or "")
            if #charName > 0 then charName = "[" .. charName .. "] " end

            if char:GetAttribute("HoldingDeathCounter") or char:GetAttribute("HoldingFlowingWater") or char:GetAttribute("HoldingPreysPeril") or char:GetAttribute("HoldingGodSlayer") then
                isCounter = true
            end
            if char:GetAttribute("Ulted") or char:GetAttribute("JustUlted") or char:GetAttribute("UltimateName") then
                isUlt = true
            end

            -- 1. HIGHLIGHT CHAMS ESP
            if hlEnabled then
                local hl = vis.Highlight
                if not hl or not hl.Parent or hl.Adornee ~= char then
                    if hl and hl.Parent then hl:Destroy() end
                    hl = Instance.new("Highlight")
                    hl.Name = "TSB_HL_" .. player.UserId
                    hl.Adornee = char
                    hl.FillTransparency = 0.45
                    hl.OutlineTransparency = 0.1
                    hl.Parent = char
                    vis.Highlight = hl
                end

                -- Dynamic Color Coding
                if isCounter then
                    hl.FillColor = Color3.fromRGB(255, 30, 60)
                    hl.OutlineColor = Color3.fromRGB(255, 230, 0)
                elseif isUlt then
                    hl.FillColor = Color3.fromRGB(255, 190, 0)
                    hl.OutlineColor = Color3.fromRGB(255, 255, 255)
                else
                    hl.FillColor = Color3.fromRGB(0, 200, 255)
                    hl.OutlineColor = Color3.fromRGB(255, 255, 255)
                end
            else
                if vis.Highlight then
                    pcall(function() vis.Highlight:Destroy() end)
                    vis.Highlight = nil
                end
            end

            -- 2. BILLBOARD STATUS ESP
            if bbEnabled then
                local bb = vis.Billboard
                local targetPart = char:FindFirstChild("Head") or root
                if not bb or not bb.Parent or bb.Adornee ~= targetPart then
                    if bb and bb.Parent then bb:Destroy() end
                    bb = self:CreateBillboard(player, char, targetPart :: BasePart)
                    vis.Billboard = bb
                    vis.NameLabel = bb:FindFirstChild("NameLabel", true) :: TextLabel?
                    vis.DistLabel = bb:FindFirstChild("DistLabel", true) :: TextLabel?
                    vis.BadgeLabel = bb:FindFirstChild("BadgeLabel", true) :: TextLabel?
                    vis.HpBar = bb:FindFirstChild("HpBar", true) :: Frame?
                end

                -- Update dynamic overhead labels
                local dist = math.floor((root.Position - myPos).Magnitude)
                local hpPct = math.clamp(hum.Health / math.max(hum.MaxHealth, 1), 0, 1)

                if vis.NameLabel then
                    vis.NameLabel.Text = charName .. (player.DisplayName or player.Name)
                end

                if vis.DistLabel then
                    vis.DistLabel.Text = string.format("%dm", dist)
                end

                if vis.HpBar then
                    vis.HpBar.Size = UDim2.new(hpPct, 0, 1, 0)
                    if hpPct > 0.6 then
                        vis.HpBar.BackgroundColor3 = Color3.fromRGB(0, 230, 120)
                    elseif hpPct > 0.3 then
                        vis.HpBar.BackgroundColor3 = Color3.fromRGB(255, 200, 0)
                    else
                        vis.HpBar.BackgroundColor3 = Color3.fromRGB(255, 45, 60)
                    end
                end

                if vis.BadgeLabel then
                    if isCounter then
                        vis.BadgeLabel.Text = "⚠️ COUNTER RISK"
                        vis.BadgeLabel.TextColor3 = Color3.fromRGB(255, 45, 60)
                    elseif isUlt then
                        vis.BadgeLabel.Text = "⚡ ULT ACTIVE"
                        vis.BadgeLabel.TextColor3 = Color3.fromRGB(255, 215, 0)
                    elseif char:GetAttribute("Blocking") then
                        vis.BadgeLabel.Text = "🛡️ BLOCKING"
                        vis.BadgeLabel.TextColor3 = Color3.fromRGB(80, 180, 255)
                    else
                        vis.BadgeLabel.Text = ""
                    end
                end
            else
                if vis.Billboard then
                    pcall(function() vis.Billboard:Destroy() end)
                    vis.Billboard = nil
                end
            end
        else
            -- Clean up if dead or despawned
            self:CleanupPlayerVisuals(player)
        end
    end
end

function Visuals:Destroy()
    for p, _ in pairs(self._playerVisuals) do
        self:CleanupPlayerVisuals(p)
    end
    for _, conns in pairs(self._connections) do
        for _, c in ipairs(conns) do
            pcall(function() c:Disconnect() end)
        end
    end
    self._playerVisuals = {}
    self._connections = {}
end

return Visuals

end
__modules["Systems/Visuals"] = __modules["Systems.Visuals"]

-- ============================================================================
-- Module: Systems.World
-- ============================================================================
__modules["Systems.World"] = function()
--!strict
local Lighting = game:GetService("Lighting")
local TeleportService = game:GetService("TeleportService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")

local World = {}
World.__index = World

function World.new(deps: { ConfigManager: any, Logger: any })
    local self = setmetatable({
        _configManager = deps.ConfigManager,
        _logger = deps.Logger,
        OriginalLighting = {
            Ambient = Lighting.Ambient,
            OutdoorAmbient = Lighting.OutdoorAmbient,
            Brightness = Lighting.Brightness,
            FogEnd = Lighting.FogEnd,
        },
        LastHopCheck = 0,
        HopActive = false,
        _lastFullBright = nil :: boolean?,
        _lastRemoveFog = nil :: boolean?,
    }, World)
    return self
end

function World:ToggleFullBright(enable: boolean)
    if self._lastFullBright == enable then return end
    self._lastFullBright = enable
    if enable then
        Lighting.Ambient = Color3.new(1, 1, 1)
        Lighting.OutdoorAmbient = Color3.new(1, 1, 1)
        Lighting.Brightness = 2
    else
        Lighting.Ambient = self.OriginalLighting.Ambient
        Lighting.OutdoorAmbient = self.OriginalLighting.OutdoorAmbient
        Lighting.Brightness = self.OriginalLighting.Brightness
    end
end

function World:ToggleRemoveFog(enable: boolean)
    if self._lastRemoveFog == enable then return end
    self._lastRemoveFog = enable
    if enable then
        Lighting.FogEnd = 9e9
    else
        Lighting.FogEnd = self.OriginalLighting.FogEnd
    end
end

function World:ServerHop()
    if self.HopActive then return end
    self.HopActive = true

    task.spawn(function()
        local placeId = game.PlaceId
        local jobId = game.JobId
        local url = "https://games.roblox.com/v1/games/" .. placeId .. "/servers/Public?sortOrder=Desc&limit=100"

        local req = (typeof(syn) == "table" and syn.request) or (typeof(http_request) == "function" and http_request) or request
        local body = nil
        if req then
            local res = req({ Url = url, Method = "GET" })
            if res and res.Body then body = res.Body end
        elseif typeof(game.HttpGet) == "function" then
            pcall(function() body = game:HttpGet(url) end)
        end

        if body then
            local ok, data = pcall(function() return HttpService:JSONDecode(body) end)
            if ok and data and data.data then
                for _, s in ipairs(data.data) do
                    if s.id ~= jobId and s.playing and s.maxPlayers and s.playing < (s.maxPlayers - 1) and s.playing >= 4 then
                        TeleportService:TeleportToPlaceInstance(placeId, s.id, Players.LocalPlayer)
                        return
                    end
                end
            end
        end

        TeleportService:Teleport(placeId, Players.LocalPlayer)
    end)
end

function World:CheckAutoServerHop(config: any)
    if not config.World.AutoServerHop or self.HopActive then return end
    local now = os.clock()
    if (now - self.LastHopCheck) < 10 then return end
    self.LastHopCheck = now

    local count = #Players:GetPlayers()
    if count <= (config.World.AutoHopMinPlayers or 4) then
        self:ServerHop()
    end
end

return World

end
__modules["Systems/World"] = __modules["Systems.World"]

-- ============================================================================
-- Module: UI.Components
-- ============================================================================
__modules["UI.Components"] = function()
--!strict
local UserInputService = game:GetService("UserInputService")
local Theme = require("UI.Theme")

local Components = {}

-- -----------------------------------------------------------------------------
-- SECTION HEADER
-- -----------------------------------------------------------------------------
function Components.Section(parent: Instance, title: string, accentName: string?)
    local accent = Theme.GetAccent(accentName)

    local f = Instance.new("Frame")
    f.Name = "Section_" .. title
    f.Size = UDim2.new(1, 0, 0, 28)
    f.BackgroundTransparency = 1
    f.Parent = parent

    local bar = Instance.new("Frame")
    bar.Size = UDim2.new(0, 3, 0, 14)
    bar.Position = UDim2.new(0, 2, 0.5, -7)
    bar.BackgroundColor3 = accent.Primary
    bar.BorderSizePixel = 0
    bar.Parent = f
    Instance.new("UICorner", bar).CornerRadius = UDim.new(1, 0)

    local lbl = Instance.new("TextLabel")
    lbl.Size = UDim2.new(1, -20, 1, 0)
    lbl.Position = UDim2.new(0, 12, 0, 0)
    lbl.BackgroundTransparency = 1
    lbl.Text = string.upper(title)
    lbl.TextColor3 = accent.Primary
    lbl.TextSize = 11
    lbl.Font = Theme.Fonts.Bold
    lbl.TextXAlignment = Enum.TextXAlignment.Left
    lbl.Parent = f

    return f
end

-- -----------------------------------------------------------------------------
-- TOGGLE COMPONENT
-- -----------------------------------------------------------------------------
function Components.Toggle(parent: Instance, title: string, subtitle: string?, defaultVal: boolean, accentName: string?, callback: ((boolean) -> ())?)
    local accent = Theme.GetAccent(accentName)

    local frame = Instance.new("Frame")
    frame.Name = "Toggle_" .. title
    frame.Size = UDim2.new(1, 0, 0, subtitle and 44 or 38)
    frame.BackgroundColor3 = Theme.Colors.Card
    frame.BorderSizePixel = 0
    frame.Parent = parent
    Instance.new("UICorner", frame).CornerRadius = UDim.new(0, 7)

    local stroke = Instance.new("UIStroke")
    stroke.Color = Theme.Colors.BorderSubtle
    stroke.Thickness = 1
    stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
    stroke.Parent = frame

    local titleL = Instance.new("TextLabel")
    titleL.Size = UDim2.new(1, -68, 0, 18)
    titleL.Position = UDim2.new(0, 12, 0, subtitle and 5 or 10)
    titleL.BackgroundTransparency = 1
    titleL.Text = title
    titleL.TextColor3 = Theme.Colors.TextPrimary
    titleL.TextSize = 12
    titleL.Font = Theme.Fonts.Subtitle
    titleL.TextXAlignment = Enum.TextXAlignment.Left
    titleL.Parent = frame

    if subtitle then
        local subL = Instance.new("TextLabel")
        subL.Size = UDim2.new(1, -68, 0, 14)
        subL.Position = UDim2.new(0, 12, 0, 24)
        subL.BackgroundTransparency = 1
        subL.Text = subtitle
        subL.TextColor3 = Theme.Colors.TextSecondary
        subL.TextSize = 10
        subL.Font = Theme.Fonts.Body
        subL.TextXAlignment = Enum.TextXAlignment.Left
        subL.Parent = frame
    end

    local switchBg = Instance.new("Frame")
    switchBg.Size = UDim2.new(0, 40, 0, 20)
    switchBg.Position = UDim2.new(1, -52, 0.5, -10)
    switchBg.BackgroundColor3 = defaultVal and accent.Primary or Theme.Colors.CardHover
    switchBg.BorderSizePixel = 0
    switchBg.Parent = frame
    Instance.new("UICorner", switchBg).CornerRadius = UDim.new(1, 0)

    local switchCirc = Instance.new("Frame")
    switchCirc.Size = UDim2.new(0, 14, 0, 14)
    switchCirc.Position = defaultVal and UDim2.new(1, -17, 0.5, -7) or UDim2.new(0, 3, 0.5, -7)
    switchCirc.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
    switchCirc.BorderSizePixel = 0
    switchCirc.Parent = switchBg
    Instance.new("UICorner", switchCirc).CornerRadius = UDim.new(1, 0)

    local state = defaultVal
    local function SetOn(val: boolean, fireCallback: boolean?)
        state = val
        Theme.Tween(switchBg, 0.16, { BackgroundColor3 = state and accent.Primary or Theme.Colors.CardHover })
        Theme.Tween(switchCirc, 0.16, { Position = state and UDim2.new(1, -17, 0.5, -7) or UDim2.new(0, 3, 0.5, -7) })
        if fireCallback ~= false and callback then
            pcall(callback, state)
        end
    end

    local btn = Instance.new("TextButton")
    btn.Size = UDim2.new(1, 0, 1, 0)
    btn.BackgroundTransparency = 1
    btn.Text = ""
    btn.Parent = frame

    btn.MouseEnter:Connect(function()
        Theme.Tween(frame, 0.12, { BackgroundColor3 = Theme.Colors.CardHover })
        Theme.Tween(stroke, 0.12, { Color = Theme.Colors.BorderActive })
    end)
    btn.MouseLeave:Connect(function()
        Theme.Tween(frame, 0.12, { BackgroundColor3 = Theme.Colors.Card })
        Theme.Tween(stroke, 0.12, { Color = Theme.Colors.BorderSubtle })
    end)
    btn.MouseButton1Click:Connect(function()
        SetOn(not state, true)
    end)

    return {
        Frame = frame,
        SetOn = SetOn,
        GetState = function() return state end
    }
end

-- -----------------------------------------------------------------------------
-- SLIDER COMPONENT
-- -----------------------------------------------------------------------------
function Components.Slider(parent: Instance, title: string, minV: number, maxV: number, defaultV: number, suffix: string?, step: number?, accentName: string?, callback: ((number) -> ())?)
    local accent = Theme.GetAccent(accentName)
    local stepVal = step or 1

    local frame = Instance.new("Frame")
    frame.Name = "Slider_" .. title
    frame.Size = UDim2.new(1, 0, 0, 50)
    frame.BackgroundColor3 = Theme.Colors.Card
    frame.BorderSizePixel = 0
    frame.Parent = parent
    Instance.new("UICorner", frame).CornerRadius = UDim.new(0, 7)

    local stroke = Instance.new("UIStroke")
    stroke.Color = Theme.Colors.BorderSubtle
    stroke.Thickness = 1
    stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
    stroke.Parent = frame

    local titleL = Instance.new("TextLabel")
    titleL.Size = UDim2.new(1, -80, 0, 18)
    titleL.Position = UDim2.new(0, 12, 0, 8)
    titleL.BackgroundTransparency = 1
    titleL.Text = title
    titleL.TextColor3 = Theme.Colors.TextPrimary
    titleL.TextSize = 12
    titleL.Font = Theme.Fonts.Subtitle
    titleL.TextXAlignment = Enum.TextXAlignment.Left
    titleL.Parent = frame

    local valL = Instance.new("TextLabel")
    valL.Size = UDim2.new(0, 70, 0, 18)
    valL.Position = UDim2.new(1, -82, 0, 8)
    valL.BackgroundTransparency = 1
    valL.Text = tostring(defaultV) .. (suffix or "")
    valL.TextColor3 = accent.Primary
    valL.TextSize = 12
    valL.Font = Theme.Fonts.Bold
    valL.TextXAlignment = Enum.TextXAlignment.Right
    valL.Parent = frame

    local trackBg = Instance.new("Frame")
    trackBg.Size = UDim2.new(1, -24, 0, 6)
    trackBg.Position = UDim2.new(0, 12, 0, 34)
    trackBg.BackgroundColor3 = Theme.Colors.Header
    trackBg.BorderSizePixel = 0
    trackBg.Parent = frame
    Instance.new("UICorner", trackBg).CornerRadius = UDim.new(1, 0)

    local curVal = math.clamp(defaultV, minV, maxV)
    local initialPct = (curVal - minV) / (maxV - minV)

    local trackFill = Instance.new("Frame")
    trackFill.Size = UDim2.new(math.clamp(initialPct, 0, 1), 0, 1, 0)
    trackFill.BackgroundColor3 = accent.Primary
    trackFill.BorderSizePixel = 0
    trackFill.Parent = trackBg
    Instance.new("UICorner", trackFill).CornerRadius = UDim.new(1, 0)

    local knob = Instance.new("Frame")
    knob.Size = UDim2.new(0, 12, 0, 12)
    knob.Position = UDim2.new(1, -6, 0.5, -6)
    knob.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
    knob.BorderSizePixel = 0
    knob.Parent = trackFill
    Instance.new("UICorner", knob).CornerRadius = UDim.new(1, 0)

    local sliding = false
    local function SetValue(newVal: number, fireCallback: boolean?)
        curVal = math.clamp(newVal, minV, maxV)
        if stepVal >= 1 then
            curVal = math.floor(curVal / stepVal + 0.5) * stepVal
        else
            curVal = math.floor(curVal * 100 + 0.5) / 100
        end

        local pct = (curVal - minV) / (maxV - minV)
        trackFill.Size = UDim2.new(math.clamp(pct, 0, 1), 0, 1, 0)
        valL.Text = tostring(curVal) .. (suffix or "")

        if fireCallback ~= false and callback then
            pcall(callback, curVal)
        end
    end

    local function UpdateFromInput(inp: any)
        local rel = math.clamp((inp.Position.X - trackBg.AbsolutePosition.X) / trackBg.AbsoluteSize.X, 0, 1)
        local rawVal = minV + (maxV - minV) * rel
        SetValue(rawVal, true)
    end

    local connEnded: RBXScriptConnection? = nil
    local connChanged: RBXScriptConnection? = nil

    trackBg.InputBegan:Connect(function(inp)
        if inp.UserInputType == Enum.UserInputType.MouseButton1 or inp.UserInputType == Enum.UserInputType.Touch then
            sliding = true
            Theme.Tween(knob, 0.1, { Size = UDim2.new(0, 16, 0, 16), Position = UDim2.new(1, -8, 0.5, -8) })
            UpdateFromInput(inp)
        end
    end)

    connEnded = UserInputService.InputEnded:Connect(function(inp)
        if inp.UserInputType == Enum.UserInputType.MouseButton1 or inp.UserInputType == Enum.UserInputType.Touch then
            if sliding then
                sliding = false
                Theme.Tween(knob, 0.1, { Size = UDim2.new(0, 12, 0, 12), Position = UDim2.new(1, -6, 0.5, -6) })
            end
        end
    end)

    connChanged = UserInputService.InputChanged:Connect(function(inp)
        if sliding and (inp.UserInputType == Enum.UserInputType.MouseMovement or inp.UserInputType == Enum.UserInputType.Touch) then
            UpdateFromInput(inp)
        end
    end)

    -- Clean up global connections when this slider frame is destroyed
    frame.AncestryChanged:Connect(function()
        if not frame.Parent then
            if connEnded then connEnded:Disconnect() connEnded = nil end
            if connChanged then connChanged:Disconnect() connChanged = nil end
        end
    end)

    frame.MouseEnter:Connect(function()
        Theme.Tween(stroke, 0.12, { Color = Theme.Colors.BorderActive })
    end)
    frame.MouseLeave:Connect(function()
        Theme.Tween(stroke, 0.12, { Color = Theme.Colors.BorderSubtle })
    end)

    return {
        Frame = frame,
        SetValue = SetValue,
        GetValue = function() return curVal end,
    }
end

-- -----------------------------------------------------------------------------
-- DROPDOWN COMPONENT
-- -----------------------------------------------------------------------------
function Components.Dropdown(parent: Instance, title: string, options: { string }, defaultSelected: string, accentName: string?, callback: ((string) -> ())?)
    local accent = Theme.GetAccent(accentName)

    local frame = Instance.new("Frame")
    frame.Name = "Dropdown_" .. title
    frame.Size = UDim2.new(1, 0, 0, 42)
    frame.BackgroundColor3 = Theme.Colors.Card
    frame.BorderSizePixel = 0
    frame.ClipsDescendants = true
    frame.Parent = parent
    Instance.new("UICorner", frame).CornerRadius = UDim.new(0, 7)

    local stroke = Instance.new("UIStroke")
    stroke.Color = Theme.Colors.BorderSubtle
    stroke.Thickness = 1
    stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
    stroke.Parent = frame

    local titleL = Instance.new("TextLabel")
    titleL.Size = UDim2.new(0, 120, 0, 42)
    titleL.Position = UDim2.new(0, 12, 0, 0)
    titleL.BackgroundTransparency = 1
    titleL.Text = title
    titleL.TextColor3 = Theme.Colors.TextPrimary
    titleL.TextSize = 12
    titleL.Font = Theme.Fonts.Subtitle
    titleL.TextXAlignment = Enum.TextXAlignment.Left
    titleL.Parent = frame

    local selectBtn = Instance.new("TextButton")
    selectBtn.Size = UDim2.new(1, -145, 0, 26)
    selectBtn.Position = UDim2.new(0, 135, 0, 8)
    selectBtn.BackgroundColor3 = Theme.Colors.Header
    selectBtn.BorderSizePixel = 0
    selectBtn.Text = "  " .. tostring(defaultSelected)
    selectBtn.TextColor3 = accent.Primary
    selectBtn.TextSize = 11
    selectBtn.Font = Theme.Fonts.Subtitle
    selectBtn.TextXAlignment = Enum.TextXAlignment.Left
    selectBtn.Parent = frame
    Instance.new("UICorner", selectBtn).CornerRadius = UDim.new(0, 5)

    local arrow = Instance.new("TextLabel")
    arrow.Size = UDim2.new(0, 20, 1, 0)
    arrow.Position = UDim2.new(1, -22, 0, 0)
    arrow.BackgroundTransparency = 1
    arrow.Text = "▼"
    arrow.TextColor3 = Theme.Colors.TextSecondary
    arrow.TextSize = 9
    arrow.Font = Theme.Fonts.Bold
    arrow.Parent = selectBtn

    local listFrame = Instance.new("Frame")
    listFrame.Size = UDim2.new(1, -24, 0, #options * 26)
    listFrame.Position = UDim2.new(0, 12, 0, 44)
    listFrame.BackgroundTransparency = 1
    listFrame.Parent = frame

    local listLayout = Instance.new("UIListLayout")
    listLayout.SortOrder = Enum.SortOrder.LayoutOrder
    listLayout.Padding = UDim.new(0, 2)
    listLayout.Parent = listFrame

    local isOpen = false
    local currentSelected = defaultSelected

    local function RebuildOptions(opts: { string })
        for _, child in ipairs(listFrame:GetChildren()) do
            if child:IsA("TextButton") then
                child:Destroy()
            end
        end
        listFrame.Size = UDim2.new(1, -24, 0, #opts * 26)

        for idx, opt in ipairs(opts) do
            local optBtn = Instance.new("TextButton")
            optBtn.Size = UDim2.new(1, 0, 0, 26)
            optBtn.BackgroundColor3 = Theme.Colors.Header
            optBtn.BorderSizePixel = 0
            optBtn.Text = "  " .. opt
            optBtn.TextColor3 = (opt == currentSelected) and accent.Primary or Theme.Colors.TextSecondary
            optBtn.TextSize = 11
            optBtn.Font = Theme.Fonts.Body
            optBtn.TextXAlignment = Enum.TextXAlignment.Left
            optBtn.LayoutOrder = idx
            optBtn.Parent = listFrame
            Instance.new("UICorner", optBtn).CornerRadius = UDim.new(0, 4)

            optBtn.MouseEnter:Connect(function()
                Theme.Tween(optBtn, 0.1, { BackgroundColor3 = Theme.Colors.CardHover, TextColor3 = Theme.Colors.TextPrimary })
            end)
            optBtn.MouseLeave:Connect(function()
                local isSel = (opt == currentSelected)
                Theme.Tween(optBtn, 0.1, { BackgroundColor3 = Theme.Colors.Header, TextColor3 = isSel and accent.Primary or Theme.Colors.TextSecondary })
            end)
            optBtn.MouseButton1Click:Connect(function()
                SelectOption(opt)
            end)
        end
    end

    local currentOpts = options
    local function ToggleOpen()
        isOpen = not isOpen
        local targetH = isOpen and (48 + #currentOpts * 28) or 42
        arrow.Text = isOpen and "▲" or "▼"
        Theme.Tween(frame, 0.18, { Size = UDim2.new(1, 0, 0, targetH) })
    end

    local function SelectOption(opt: string)
        currentSelected = opt
        selectBtn.Text = "  " .. opt
        ToggleOpen()
        if callback then
            pcall(callback, opt)
        end
    end

    local function SetOptions(newOpts: { string })
        currentOpts = newOpts
        RebuildOptions(newOpts)
        if isOpen then
            local targetH = 48 + #newOpts * 28
            Theme.Tween(frame, 0.18, { Size = UDim2.new(1, 0, 0, targetH) })
        end
    end

    RebuildOptions(options)
    selectBtn.MouseButton1Click:Connect(ToggleOpen)

    return {
        Frame = frame,
        Select = SelectOption,
        SetOptions = SetOptions,
        GetSelected = function() return currentSelected end,
    }
end

-- -----------------------------------------------------------------------------
-- BUTTON COMPONENT
-- -----------------------------------------------------------------------------
function Components.Button(parent: Instance, title: string, btnText: string, kind: string?, accentName: string?, callback: (() -> ())?)
    local accent = Theme.GetAccent(accentName)
    local btnBgColor = accent.Primary
    if kind == "Danger" then btnBgColor = Theme.Colors.Danger
    elseif kind == "Secondary" then btnBgColor = Theme.Colors.CardHover
    elseif kind == "Success" then btnBgColor = Theme.Colors.Success end

    local frame = Instance.new("Frame")
    frame.Name = "Button_" .. title
    frame.Size = UDim2.new(1, 0, 0, 40)
    frame.BackgroundColor3 = Theme.Colors.Card
    frame.BorderSizePixel = 0
    frame.Parent = parent
    Instance.new("UICorner", frame).CornerRadius = UDim.new(0, 7)

    local stroke = Instance.new("UIStroke")
    stroke.Color = Theme.Colors.BorderSubtle
    stroke.Thickness = 1
    stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
    stroke.Parent = frame

    local titleL = Instance.new("TextLabel")
    titleL.Size = UDim2.new(1, -125, 1, 0)
    titleL.Position = UDim2.new(0, 12, 0, 0)
    titleL.BackgroundTransparency = 1
    titleL.Text = title
    titleL.TextColor3 = Theme.Colors.TextPrimary
    titleL.TextSize = 12
    titleL.Font = Theme.Fonts.Subtitle
    titleL.TextXAlignment = Enum.TextXAlignment.Left
    titleL.Parent = frame

    local btn = Instance.new("TextButton")
    btn.Size = UDim2.new(0, 105, 0, 26)
    btn.Position = UDim2.new(1, -117, 0.5, -13)
    btn.BackgroundColor3 = btnBgColor
    btn.BorderSizePixel = 0
    btn.Text = btnText
    btn.TextColor3 = Color3.fromRGB(255, 255, 255)
    btn.TextSize = 11
    btn.Font = Theme.Fonts.Bold
    btn.Parent = frame
    Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 5)

    btn.MouseEnter:Connect(function()
        Theme.Tween(btn, 0.1, { BackgroundTransparency = 0.15 })
    end)
    btn.MouseLeave:Connect(function()
        Theme.Tween(btn, 0.1, { BackgroundTransparency = 0 })
    end)
    btn.MouseButton1Down:Connect(function()
        Theme.Tween(btn, 0.05, { Size = UDim2.new(0, 101, 0, 24), Position = UDim2.new(1, -115, 0.5, -12) })
    end)
    btn.MouseButton1Up:Connect(function()
        Theme.Tween(btn, 0.1, { Size = UDim2.new(0, 105, 0, 26), Position = UDim2.new(1, -117, 0.5, -13) })
    end)
    btn.MouseButton1Click:Connect(function()
        if callback then pcall(callback) end
    end)

    return { Frame = frame, Button = btn }
end

-- -----------------------------------------------------------------------------
-- KEYBIND COMPONENT
-- -----------------------------------------------------------------------------
function Components.Keybind(parent: Instance, title: string, defaultKey: EnumItem, accentName: string?, callback: ((EnumItem) -> ())?)
    local accent = Theme.GetAccent(accentName)

    local frame = Instance.new("Frame")
    frame.Name = "Keybind_" .. title
    frame.Size = UDim2.new(1, 0, 0, 40)
    frame.BackgroundColor3 = Theme.Colors.Card
    frame.BorderSizePixel = 0
    frame.Parent = parent
    Instance.new("UICorner", frame).CornerRadius = UDim.new(0, 7)

    local stroke = Instance.new("UIStroke")
    stroke.Color = Theme.Colors.BorderSubtle
    stroke.Thickness = 1
    stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
    stroke.Parent = frame

    local titleL = Instance.new("TextLabel")
    titleL.Size = UDim2.new(1, -110, 1, 0)
    titleL.Position = UDim2.new(0, 12, 0, 0)
    titleL.BackgroundTransparency = 1
    titleL.Text = title
    titleL.TextColor3 = Theme.Colors.TextPrimary
    titleL.TextSize = 12
    titleL.Font = Theme.Fonts.Subtitle
    titleL.TextXAlignment = Enum.TextXAlignment.Left
    titleL.Parent = frame

    local keyBtn = Instance.new("TextButton")
    keyBtn.Size = UDim2.new(0, 90, 0, 24)
    keyBtn.Position = UDim2.new(1, -102, 0.5, -12)
    keyBtn.BackgroundColor3 = Theme.Colors.Header
    keyBtn.BorderSizePixel = 0
    keyBtn.Text = defaultKey.Name
    keyBtn.TextColor3 = accent.Primary
    keyBtn.TextSize = 11
    keyBtn.Font = Theme.Fonts.Bold
    keyBtn.Parent = frame
    Instance.new("UICorner", keyBtn).CornerRadius = UDim.new(0, 5)

    local keyStroke = Instance.new("UIStroke")
    keyStroke.Color = Theme.Colors.BorderSubtle
    keyStroke.Thickness = 1
    keyStroke.Parent = keyBtn

    local isListening = false
    local currentKey = defaultKey

    local function SetKey(key: EnumItem)
        currentKey = key
        keyBtn.Text = key.Name
        isListening = false
        keyStroke.Color = Theme.Colors.BorderSubtle
        keyBtn.TextColor3 = accent.Primary
        if callback then pcall(callback, key) end
    end

    keyBtn.MouseButton1Click:Connect(function()
        if isListening then return end
        isListening = true
        keyBtn.Text = "..."
        keyStroke.Color = accent.Primary
        keyBtn.TextColor3 = Theme.Colors.Warning

        local conn
        conn = UserInputService.InputBegan:Connect(function(input)
            if input.UserInputType == Enum.UserInputType.Keyboard then
                conn:Disconnect()
                SetKey(input.KeyCode)
            elseif input.UserInputType == Enum.UserInputType.MouseButton2 then
                -- Right-click cancels
                conn:Disconnect()
                SetKey(currentKey)
            end
        end)
    end)

    return {
        Frame = frame,
        SetKey = SetKey,
        GetKey = function() return currentKey end,
    }
end

-- -----------------------------------------------------------------------------
-- STATUS BADGE COMPONENT
-- -----------------------------------------------------------------------------
function Components.StatusBadge(parent: Instance, title: string, statusText: string, statusColor: Color3?)
    local frame = Instance.new("Frame")
    frame.Name = "Status_" .. title
    frame.Size = UDim2.new(1, 0, 0, 36)
    frame.BackgroundColor3 = Theme.Colors.Card
    frame.BorderSizePixel = 0
    frame.Parent = parent
    Instance.new("UICorner", frame).CornerRadius = UDim.new(0, 7)

    local stroke = Instance.new("UIStroke")
    stroke.Color = Theme.Colors.BorderSubtle
    stroke.Thickness = 1
    stroke.Parent = frame

    local titleL = Instance.new("TextLabel")
    titleL.Size = UDim2.new(1, -120, 1, 0)
    titleL.Position = UDim2.new(0, 12, 0, 0)
    titleL.BackgroundTransparency = 1
    titleL.Text = title
    titleL.TextColor3 = Theme.Colors.TextPrimary
    titleL.TextSize = 12
    titleL.Font = Theme.Fonts.Subtitle
    titleL.TextXAlignment = Enum.TextXAlignment.Left
    titleL.Parent = frame

    local badge = Instance.new("Frame")
    badge.Size = UDim2.new(0, 100, 0, 22)
    badge.Position = UDim2.new(1, -112, 0.5, -11)
    badge.BackgroundColor3 = Theme.Colors.Header
    badge.BorderSizePixel = 0
    badge.Parent = frame
    Instance.new("UICorner", badge).CornerRadius = UDim.new(0, 5)

    local badgeL = Instance.new("TextLabel")
    badgeL.Size = UDim2.new(1, 0, 1, 0)
    badgeL.BackgroundTransparency = 1
    badgeL.Text = statusText
    badgeL.TextColor3 = statusColor or Theme.Colors.Success
    badgeL.TextSize = 10
    badgeL.Font = Theme.Fonts.Bold
    badgeL.Parent = badge

    local function Update(newText: string, newColor: Color3?)
        badgeL.Text = newText
        if newColor then badgeL.TextColor3 = newColor end
    end

    return { Frame = frame, Update = Update }
end

return Components

end
__modules["UI/Components"] = __modules["UI.Components"]

-- ============================================================================
-- Module: UI.Notifications
-- ============================================================================
__modules["UI.Notifications"] = function()
--!strict
local Theme = require("UI.Theme")

local Notifications = {}
Notifications.__index = Notifications

export type NotificationType = "Info" | "Success" | "Warning" | "Error"

function Notifications.new(parentGui: Instance, accentName: string?)
    local container = Instance.new("Frame")
    container.Name = "NotificationsContainer"
    container.Size = UDim2.new(0, 280, 1, -20)
    container.Position = UDim2.new(1, -290, 0, 10)
    container.BackgroundTransparency = 1
    container.Parent = parentGui

    local layout = Instance.new("UIListLayout")
    layout.SortOrder = Enum.SortOrder.LayoutOrder
    layout.VerticalAlignment = Enum.VerticalAlignment.Bottom
    layout.Padding = UDim.new(0, 8)
    layout.Parent = container

    local self = setmetatable({
        _container = container,
        _accentName = accentName or "Cyan Neon",
        _count = 0,
    }, Notifications)
    return self
end

function Notifications:Show(title: string, message: string, duration: number?, kind: NotificationType?)
    local dur = duration or 2.8
    local k = kind or "Info"
    self._count += 1

    local accent = Theme.GetAccent(self._accentName)
    local barColor = accent.Primary
    if k == "Success" then barColor = Theme.Colors.Success
    elseif k == "Warning" then barColor = Theme.Colors.Warning
    elseif k == "Error" then barColor = Theme.Colors.Danger end

    local toast = Instance.new("Frame")
    toast.Name = "Toast_" .. tostring(self._count)
    toast.Size = UDim2.new(1, 0, 0, 54)
    toast.Position = UDim2.new(1, 40, 0, 0) -- starts off-screen right
    toast.BackgroundColor3 = Theme.Colors.Card
    toast.BorderSizePixel = 0
    toast.LayoutOrder = self._count
    toast.Parent = self._container
    Instance.new("UICorner", toast).CornerRadius = UDim.new(0, 8)

    local stroke = Instance.new("UIStroke")
    stroke.Color = Theme.Colors.Border
    stroke.Thickness = 1
    stroke.Parent = toast

    local sideBar = Instance.new("Frame")
    sideBar.Size = UDim2.new(0, 4, 1, -12)
    sideBar.Position = UDim2.new(0, 6, 0.5, -21)
    sideBar.BackgroundColor3 = barColor
    sideBar.BorderSizePixel = 0
    sideBar.Parent = toast
    Instance.new("UICorner", sideBar).CornerRadius = UDim.new(1, 0)

    local titleLbl = Instance.new("TextLabel")
    titleLbl.Size = UDim2.new(1, -26, 0, 18)
    titleLbl.Position = UDim2.new(0, 18, 0, 7)
    titleLbl.BackgroundTransparency = 1
    titleLbl.Text = title
    titleLbl.TextColor3 = Theme.Colors.TextPrimary
    titleLbl.TextSize = 12
    titleLbl.Font = Theme.Fonts.Bold
    titleLbl.TextXAlignment = Enum.TextXAlignment.Left
    titleLbl.Parent = toast

    local msgLbl = Instance.new("TextLabel")
    msgLbl.Size = UDim2.new(1, -26, 0, 18)
    msgLbl.Position = UDim2.new(0, 18, 0, 26)
    msgLbl.BackgroundTransparency = 1
    msgLbl.Text = message
    msgLbl.TextColor3 = Theme.Colors.TextSecondary
    msgLbl.TextSize = 10
    msgLbl.Font = Theme.Fonts.Body
    msgLbl.TextXAlignment = Enum.TextXAlignment.Left
    msgLbl.TextTruncate = Enum.TextTruncate.AtEnd
    msgLbl.Parent = toast

    -- Slide in animation
    Theme.Tween(toast, 0.22, { BackgroundTransparency = 0 })
    
    -- Lifetime countdown & Slide out
    task.delay(dur, function()
        if toast and toast.Parent then
            local tw = Theme.Tween(toast, 0.2, { BackgroundTransparency = 1 })
            Theme.Tween(titleLbl, 0.2, { TextTransparency = 1 })
            Theme.Tween(msgLbl, 0.2, { TextTransparency = 1 })
            Theme.Tween(sideBar, 0.2, { BackgroundTransparency = 1 })
            Theme.Tween(stroke, 0.2, { Transparency = 1 })
            tw.Completed:Connect(function()
                toast:Destroy()
            end)
        end
    end)
end

function Notifications:Destroy()
    if self._container then
        self._container:Destroy()
        self._container = nil :: any
    end
end

return Notifications

end
__modules["UI/Notifications"] = __modules["UI.Notifications"]

-- ============================================================================
-- Module: UI.Sidebar
-- ============================================================================
__modules["UI.Sidebar"] = function()
--!strict
local Theme = require("UI.Theme")

local Sidebar = {}
Sidebar.__index = Sidebar

export type TabDef = {
    Name: string,
    Icon: string?,
}

function Sidebar.new(parent: Instance, accentName: string?, onTabSelected: (string) -> ())
    local accent = Theme.GetAccent(accentName)

    local sidebarFrame = Instance.new("Frame")
    sidebarFrame.Name = "Sidebar"
    sidebarFrame.Size = UDim2.new(0, 160, 1, 0)
    sidebarFrame.BackgroundColor3 = Theme.Colors.Sidebar
    sidebarFrame.BorderSizePixel = 0
    sidebarFrame.Parent = parent

    -- Right separator line
    local sep = Instance.new("Frame")
    sep.Size = UDim2.new(0, 1, 1, 0)
    sep.Position = UDim2.new(1, -1, 0, 0)
    sep.BackgroundColor3 = Theme.Colors.BorderSubtle
    sep.BorderSizePixel = 0
    sep.Parent = sidebarFrame

    -- Branding Header
    local header = Instance.new("Frame")
    header.Size = UDim2.new(1, 0, 0, 56)
    header.BackgroundTransparency = 1
    header.Parent = sidebarFrame

    local title = Instance.new("TextLabel")
    title.Size = UDim2.new(1, -24, 0, 20)
    title.Position = UDim2.new(0, 16, 0, 12)
    title.BackgroundTransparency = 1
    title.Text = "TSB HUB"
    title.TextColor3 = Theme.Colors.TextPrimary
    title.TextSize = 15
    title.Font = Theme.Fonts.Title
    title.TextXAlignment = Enum.TextXAlignment.Left
    title.Parent = header

    local subtitle = Instance.new("TextLabel")
    subtitle.Size = UDim2.new(1, -24, 0, 14)
    subtitle.Position = UDim2.new(0, 16, 0, 32)
    subtitle.BackgroundTransparency = 1
    subtitle.Text = "v9.0 SPECIALIST"
    subtitle.TextColor3 = accent.Primary
    subtitle.TextSize = 9
    subtitle.Font = Theme.Fonts.Bold
    subtitle.TextXAlignment = Enum.TextXAlignment.Left
    subtitle.Parent = header

    local statusDot = Instance.new("Frame")
    statusDot.Size = UDim2.new(0, 7, 0, 7)
    statusDot.Position = UDim2.new(1, -20, 0, 18)
    statusDot.BackgroundColor3 = Theme.Colors.Success
    statusDot.BorderSizePixel = 0
    statusDot.Parent = header
    Instance.new("UICorner", statusDot).CornerRadius = UDim.new(1, 0)

    -- Tab Button Container
    local tabContainer = Instance.new("ScrollingFrame")
    tabContainer.Name = "TabButtons"
    tabContainer.Size = UDim2.new(1, 0, 1, -64)
    tabContainer.Position = UDim2.new(0, 0, 0, 60)
    tabContainer.BackgroundTransparency = 1
    tabContainer.BorderSizePixel = 0
    tabContainer.ScrollBarThickness = 0
    tabContainer.AutomaticCanvasSize = Enum.AutomaticSize.Y
    tabContainer.CanvasSize = UDim2.new(0, 0, 0, 0)
    tabContainer.Parent = sidebarFrame

    local layout = Instance.new("UIListLayout")
    layout.SortOrder = Enum.SortOrder.LayoutOrder
    layout.Padding = UDim.new(0, 4)
    layout.Parent = tabContainer

    local padding = Instance.new("UIPadding")
    padding.PaddingLeft = UDim.new(0, 8)
    padding.PaddingRight = UDim.new(0, 8)
    padding.Parent = tabContainer

    local self = setmetatable({
        _frame = sidebarFrame,
        _container = tabContainer,
        _accentName = accentName or "Cyan Neon",
        _buttons = {},
        _activeTab = nil :: string?,
        _onTabSelected = onTabSelected,
    }, Sidebar)

    return self
end

function Sidebar:AddTab(tabName: string, iconSymbol: string?, layoutOrder: number)
    local accent = Theme.GetAccent(self._accentName)

    local btn = Instance.new("TextButton")
    btn.Name = "Tab_" .. tabName
    btn.Size = UDim2.new(1, 0, 0, 36)
    btn.BackgroundColor3 = Theme.Colors.Sidebar
    btn.BorderSizePixel = 0
    btn.Text = ""
    btn.LayoutOrder = layoutOrder or 1
    btn.Parent = self._container
    Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 6)

    -- Active Indicator line
    local indicator = Instance.new("Frame")
    indicator.Name = "Indicator"
    indicator.Size = UDim2.new(0, 3, 0, 16)
    indicator.Position = UDim2.new(0, 4, 0.5, -8)
    indicator.BackgroundColor3 = accent.Primary
    indicator.BorderSizePixel = 0
    indicator.BackgroundTransparency = 1
    indicator.Parent = btn
    Instance.new("UICorner", indicator).CornerRadius = UDim.new(1, 0)

    local lbl = Instance.new("TextLabel")
    lbl.Size = UDim2.new(1, -24, 1, 0)
    lbl.Position = UDim2.new(0, 16, 0, 0)
    lbl.BackgroundTransparency = 1
    lbl.Text = (iconSymbol and (iconSymbol .. "  ") or "") .. tabName
    lbl.TextColor3 = Theme.Colors.TextSecondary
    lbl.TextSize = 12
    lbl.Font = Theme.Fonts.Subtitle
    lbl.TextXAlignment = Enum.TextXAlignment.Left
    lbl.Parent = btn

    local this = self
    btn.MouseEnter:Connect(function()
        if this._activeTab ~= tabName then
            Theme.Tween(btn, 0.12, { BackgroundColor3 = Theme.Colors.Card })
            Theme.Tween(lbl, 0.12, { TextColor3 = Theme.Colors.TextPrimary })
        end
    end)
    btn.MouseLeave:Connect(function()
        if this._activeTab ~= tabName then
            Theme.Tween(btn, 0.12, { BackgroundColor3 = Theme.Colors.Sidebar })
            Theme.Tween(lbl, 0.12, { TextColor3 = Theme.Colors.TextSecondary })
        end
    end)
    btn.MouseButton1Click:Connect(function()
        this:SetActive(tabName)
    end)

    self._buttons[tabName] = {
        Button = btn,
        Label = lbl,
        Indicator = indicator,
    }
end

function Sidebar:SetActive(tabName: string)
    self._activeTab = tabName
    local accent = Theme.GetAccent(self._accentName)

    for name, item in pairs(self._buttons) do
        if name == tabName then
            Theme.Tween(item.Button, 0.15, { BackgroundColor3 = Theme.Colors.Card })
            Theme.Tween(item.Label, 0.15, { TextColor3 = accent.Primary })
            Theme.Tween(item.Indicator, 0.15, { BackgroundTransparency = 0 })
        else
            Theme.Tween(item.Button, 0.15, { BackgroundColor3 = Theme.Colors.Sidebar })
            Theme.Tween(item.Label, 0.15, { TextColor3 = Theme.Colors.TextSecondary })
            Theme.Tween(item.Indicator, 0.15, { BackgroundTransparency = 1 })
        end
    end

    if self._onTabSelected then
        pcall(self._onTabSelected, tabName)
    end
end

function Sidebar:Destroy()
    if self._frame then
        self._frame:Destroy()
        self._frame = nil :: any
    end
    table.clear(self._buttons)
end

return Sidebar

end
__modules["UI/Sidebar"] = __modules["UI.Sidebar"]

-- ============================================================================
-- Module: UI.Tabs.Combat
-- ============================================================================
__modules["UI.Tabs.Combat"] = function()
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

end
__modules["UI/Tabs/Combat"] = __modules["UI.Tabs.Combat"]

-- ============================================================================
-- Module: UI.Tabs.Diagnostics
-- ============================================================================
__modules["UI.Tabs.Diagnostics"] = function()
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

end
__modules["UI/Tabs/Diagnostics"] = __modules["UI.Tabs.Diagnostics"]

-- ============================================================================
-- Module: UI.Tabs.Keybinds
-- ============================================================================
__modules["UI.Tabs.Keybinds"] = function()
--!strict
local Components = require("UI.Components")
local Theme = require("UI.Theme")

local KeybindsTab = {}

function KeybindsTab.Build(parent: Instance, ctx: any)
    local cfg = ctx.ConfigManager.Config
    local notifs = ctx.Notifications
    local accent = ctx.AccentName
    local kb = cfg.Keybinds or {}

    -- Section 1: Flank & Combat Keybinds
    Components.Section(parent, "Flank & Combat Hotkeys", accent)

    Components.Keybind(parent, "Toggle Safe Behind Lock (Continuous Flank)", kb.ToggleBehindTP or Enum.KeyCode.F9, accent, function(key)
        kb.ToggleBehindTP = key
        notifs:Show("Keybind Updated", "Safe Behind Lock set to " .. key.Name, 2.0, "Success")
    end)

    Components.Keybind(parent, "Toggle Aimlock", kb.ToggleAimlock or Enum.KeyCode.F7, accent, function(key)
        kb.ToggleAimlock = key
        notifs:Show("Keybind Updated", "Aimlock toggle set to " .. key.Name, 2.0, "Success")
    end)

    Components.Keybind(parent, "Mass Bring Hotkey", kb.MassBringKey or Enum.KeyCode.G, accent, function(key)
        kb.MassBringKey = key
        notifs:Show("Keybind Updated", "Mass Bring set to " .. key.Name, 2.0, "Success")
    end)

    Components.Keybind(parent, "Toggle Sky Dodge", kb.ToggleSkyDodge or Enum.KeyCode.H, accent, function(key)
        kb.ToggleSkyDodge = key
        notifs:Show("Keybind Updated", "Sky Dodge set to " .. key.Name, 2.0, "Success")
    end)

    -- Section 2: Movement & Mobility Keybinds
    Components.Section(parent, "Movement & Flight Hotkeys", accent)

    Components.Keybind(parent, "Toggle Fly", kb.ToggleFly or Enum.KeyCode.F5, accent, function(key)
        kb.ToggleFly = key
        notifs:Show("Keybind Updated", "Fly toggle set to " .. key.Name, 2.0, "Success")
    end)

    Components.Keybind(parent, "Toggle Noclip", kb.ToggleNoclip or Enum.KeyCode.F6, accent, function(key)
        kb.ToggleNoclip = key
        notifs:Show("Keybind Updated", "Noclip toggle set to " .. key.Name, 2.0, "Success")
    end)

    -- Section 3: Interface & Emergency Controls
    Components.Section(parent, "Interface & Emergency Controls", accent)

    Components.Keybind(parent, "Toggle GUI Window", kb.ToggleGUI or Enum.KeyCode.RightControl, accent, function(key)
        kb.ToggleGUI = key
        notifs:Show("Keybind Updated", "GUI toggle set to " .. key.Name, 2.0, "Success")
    end)

    Components.Keybind(parent, "Emergency Stop All", kb.EmergencyStop or Enum.KeyCode.Delete, accent, function(key)
        kb.EmergencyStop = key
        notifs:Show("Keybind Updated", "Emergency Stop set to " .. key.Name, 2.0, "Warning")
    end)
end

return KeybindsTab

end
__modules["UI/Tabs/Keybinds"] = __modules["UI.Tabs.Keybinds"]

-- ============================================================================
-- Module: UI.Tabs.Movement
-- ============================================================================
__modules["UI.Tabs.Movement"] = function()
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

end
__modules["UI/Tabs/Movement"] = __modules["UI.Tabs.Movement"]

-- ============================================================================
-- Module: UI.Tabs.Settings
-- ============================================================================
__modules["UI.Tabs.Settings"] = function()
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

end
__modules["UI/Tabs/Settings"] = __modules["UI.Tabs.Settings"]

-- ============================================================================
-- Module: UI.Tabs.Skills
-- ============================================================================
__modules["UI.Tabs.Skills"] = function()
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

end
__modules["UI/Tabs/Skills"] = __modules["UI.Tabs.Skills"]

-- ============================================================================
-- Module: UI.Tabs.Survival
-- ============================================================================
__modules["UI.Tabs.Survival"] = function()
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

end
__modules["UI/Tabs/Survival"] = __modules["UI.Tabs.Survival"]

-- ============================================================================
-- Module: UI.Tabs.Target
-- ============================================================================
__modules["UI.Tabs.Target"] = function()
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

end
__modules["UI/Tabs/Target"] = __modules["UI.Tabs.Target"]

-- ============================================================================
-- Module: UI.Tabs.Visuals
-- ============================================================================
__modules["UI.Tabs.Visuals"] = function()
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

end
__modules["UI/Tabs/Visuals"] = __modules["UI.Tabs.Visuals"]

-- ============================================================================
-- Module: UI.Tabs.World
-- ============================================================================
__modules["UI.Tabs.World"] = function()
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

end
__modules["UI/Tabs/World"] = __modules["UI.Tabs.World"]

-- ============================================================================
-- Module: UI.Theme
-- ============================================================================
__modules["UI.Theme"] = function()
--!strict
local TweenService = game:GetService("TweenService")

local Theme = {
    Accents = {
        ["Cyan Neon"] = {
            Primary = Color3.fromRGB(0, 220, 255),
            Hover = Color3.fromRGB(40, 235, 255),
            Glow = Color3.fromRGB(0, 170, 220),
            Dim = Color3.fromRGB(0, 90, 120),
        },
        ["Crimson Red"] = {
            Primary = Color3.fromRGB(255, 60, 80),
            Hover = Color3.fromRGB(255, 95, 115),
            Glow = Color3.fromRGB(210, 40, 60),
            Dim = Color3.fromRGB(120, 30, 45),
        },
        ["Purple Velvet"] = {
            Primary = Color3.fromRGB(170, 80, 255),
            Hover = Color3.fromRGB(195, 115, 255),
            Glow = Color3.fromRGB(140, 50, 220),
            Dim = Color3.fromRGB(80, 35, 125),
        },
        ["Emerald Green"] = {
            Primary = Color3.fromRGB(45, 220, 125),
            Hover = Color3.fromRGB(75, 240, 150),
            Glow = Color3.fromRGB(30, 180, 95),
            Dim = Color3.fromRGB(20, 95, 55),
        },
    },
    Colors = {
        Background = Color3.fromRGB(13, 15, 22),
        Header = Color3.fromRGB(18, 21, 30),
        Sidebar = Color3.fromRGB(16, 19, 28),
        Card = Color3.fromRGB(22, 26, 39),
        CardHover = Color3.fromRGB(28, 33, 50),
        CardActive = Color3.fromRGB(34, 40, 62),
        Border = Color3.fromRGB(36, 42, 64),
        BorderSubtle = Color3.fromRGB(28, 32, 48),
        BorderActive = Color3.fromRGB(60, 72, 108),
        
        TextPrimary = Color3.fromRGB(245, 248, 255),
        TextSecondary = Color3.fromRGB(152, 162, 192),
        TextMuted = Color3.fromRGB(92, 100, 128),
        TextDim = Color3.fromRGB(65, 72, 95),
        
        Success = Color3.fromRGB(46, 213, 115),
        Warning = Color3.fromRGB(255, 171, 0),
        Danger = Color3.fromRGB(255, 71, 87),
        Info = Color3.fromRGB(0, 180, 255),
    },
    Fonts = {
        Title = Enum.Font.GothamBold,
        Subtitle = Enum.Font.GothamMedium,
        Body = Enum.Font.Gotham,
        Bold = Enum.Font.GothamBold,
        Mono = Enum.Font.Code,
    },
}

function Theme.GetAccent(name: string?): { Primary: Color3, Hover: Color3, Glow: Color3, Dim: Color3 }
    local key = name or "Cyan Neon"
    return Theme.Accents[key] or Theme.Accents["Cyan Neon"]
end

function Theme.Tween(inst: Instance, duration: number?, props: { [string]: any }, style: Enum.EasingStyle?, dir: Enum.EasingDirection?): Tween
    local ti = TweenInfo.new(
        duration or 0.18,
        style or Enum.EasingStyle.Quart,
        dir or Enum.EasingDirection.Out
    )
    local tw = TweenService:Create(inst, ti, props)
    tw:Play()
    return tw
end

return Theme

end
__modules["UI/Theme"] = __modules["UI.Theme"]

-- ============================================================================
-- Module: UI.UIController
-- ============================================================================
__modules["UI.UIController"] = function()
--!strict
local UserInputService = game:GetService("UserInputService")
local Players = game:GetService("Players")
local CoreGui = game:GetService("CoreGui")

local Maid = require("Core.Maid")
local Window = require("UI.Window")
local Notifications = require("UI.Notifications")

-- Tabs
local CombatTab = require("UI.Tabs.Combat")
local TargetTab = require("UI.Tabs.Target")
local MovementTab = require("UI.Tabs.Movement")
local SkillsTab = require("UI.Tabs.Skills")
local SurvivalTab = require("UI.Tabs.Survival")
local VisualsTab = require("UI.Tabs.Visuals")
local WorldTab = require("UI.Tabs.World")
local KeybindsTab = require("UI.Tabs.Keybinds")
local SettingsTab = require("UI.Tabs.Settings")
local DiagnosticsTab = require("UI.Tabs.Diagnostics")

local UIController = {}
UIController.__index = UIController

export type UIDependencies = {
    ConfigManager: any,
    FeatureManager: any,
    StateMachine: any,
    Profiler: any,
    Cache: any,
    NetworkEngine: any,
    Logger: any,
    Bootstrap: any,
    Container: any,
}

function UIController.new(deps: UIDependencies)
    local self = setmetatable({
        _deps = deps,
        _maid = Maid.new(),
        _gui = nil :: ScreenGui?,
        _window = nil :: any,
        _notifications = nil :: any,
        _isInitialized = false,
        _accentName = "Cyan Neon",
    }, UIController)

    return self
end

function UIController:Init()
    if self._isInitialized then
        self:Destroy()
    end

    self._isInitialized = true
    local cfg = self._deps.ConfigManager.Config
    local accent = (cfg and cfg.UI and cfg.UI.AccentName) or "Cyan Neon"
    self._accentName = accent

    -- Target ScreenGui parent (gethui -> PlayerGui -> CoreGui)
    local function GetSafeGuiParent(): Instance
        if typeof(gethui) == "function" then
            local ok, h = pcall(gethui)
            if ok and h then return h end
        end

        local lp = Players.LocalPlayer
        if not lp then
            pcall(function()
                Players:GetPropertyChangedSignal("LocalPlayer"):Wait()
                lp = Players.LocalPlayer
            end)
        end

        if lp then
            local pg = lp:FindFirstChildOfClass("PlayerGui")
            if not pg then
                pcall(function() pg = lp:WaitForChild("PlayerGui", 4) end)
            end
            if pg then return pg end
        end

        local okCore, cg = pcall(function() return game:GetService("CoreGui") end)
        if okCore and cg then return cg end

        return game:GetService("Players").LocalPlayer:WaitForChild("PlayerGui")
    end

    local parentTarget = GetSafeGuiParent()

    -- Remove any old GUI instances to guarantee idempotency
    pcall(function()
        local oldGui = parentTarget:FindFirstChild("TSB_Framework_UI")
        if oldGui then oldGui:Destroy() end
    end)

    -- Create ScreenGui
    local screenGui = Instance.new("ScreenGui")
    screenGui.Name = "TSB_Framework_UI"
    screenGui.ResetOnSpawn = false
    screenGui.DisplayOrder = 999
    screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    screenGui.IgnoreGuiInset = true

    if typeof(syn) == "table" and typeof(syn.protect_gui) == "function" then
        pcall(syn.protect_gui, screenGui)
    end

    screenGui.Parent = parentTarget
    self._gui = screenGui

    self._maid:GiveTask(screenGui)

    -- Initialize Notifications
    local notifs = Notifications.new(screenGui, accent)
    self._notifications = notifs
    self._maid:GiveTask(function() notifs:Destroy() end)

    -- Initialize Window
    local window = Window.new(screenGui, accent, function()
        if cfg and cfg.UI then
            cfg.UI.IsOpen = false
        end
    end)
    self._window = window
    self._maid:GiveTask(function() window:Destroy() end)

    -- Shared Tab Context
    local tabCtx = {
        ConfigManager = self._deps.ConfigManager,
        FeatureManager = self._deps.FeatureManager,
        StateMachine = self._deps.StateMachine,
        Profiler = self._deps.Profiler,
        Cache = self._deps.Cache,
        NetworkEngine = self._deps.NetworkEngine,
        Logger = self._deps.Logger,
        Bootstrap = self._deps.Bootstrap,
        Container = self._deps.Container,
        Notifications = notifs,
        AccentName = accent,
        UIController = self,
    }

    -- Build Tabs
    local sidebar = window:GetSidebar()
    local tabs = {
        { Name = "Combat",      Icon = "⚔️", Builder = CombatTab.Build,      Order = 1 },
        { Name = "Target",      Icon = "🎯", Builder = TargetTab.Build,      Order = 2 },
        { Name = "Movement",    Icon = "⚡", Builder = MovementTab.Build,    Order = 3 },
        { Name = "Skills",      Icon = "🔥", Builder = SkillsTab.Build,      Order = 4 },
        { Name = "Survival",    Icon = "🛡️", Builder = SurvivalTab.Build,    Order = 5 },
        { Name = "Visuals",     Icon = "👁️", Builder = VisualsTab.Build,     Order = 6 },
        { Name = "World",       Icon = "🌐", Builder = WorldTab.Build,       Order = 7 },
        { Name = "Keybinds",    Icon = "⌨️", Builder = KeybindsTab.Build,    Order = 8 },
        { Name = "Settings",    Icon = "⚙️", Builder = SettingsTab.Build,    Order = 9 },
        { Name = "Diagnostics", Icon = "📊", Builder = DiagnosticsTab.Build, Order = 10 },
    }

    for _, t in ipairs(tabs) do
        sidebar:AddTab(t.Name, t.Icon, t.Order)
        local page = window:CreateTabPage(t.Name)
        t.Builder(page, tabCtx)
    end

    -- Default Active Tab
    sidebar:SetActive("Combat")

    -- EventBus Global Notification Listener
    if self._deps.Container and self._deps.Container:Has("EventBus") then
        local eb = self._deps.Container:Get("EventBus")
        local notifConn = eb:Subscribe("Notification.Show", function(title: string, msg: string, dur: number?, kind: any?)
            self:ShowNotification(title, msg, dur, kind)
        end)
        self._maid:GiveTask(notifConn)
    end

    -- Keybind Listeners (GUI Toggle, Continuous Safe Behind Lock, Aimlock, Fly, Noclip, Emergency Stop)
    local keybindConn = UserInputService.InputBegan:Connect(function(input, gpe)
        if gpe then return end
        if input.UserInputType == Enum.UserInputType.Keyboard then
            local kb = cfg and cfg.Keybinds or {}
            local toggleGUIBind = kb.ToggleGUI or Enum.KeyCode.RightControl
            local behindTPBind = kb.ToggleBehindTP or Enum.KeyCode.F9
            local aimlockBind = kb.ToggleAimlock or Enum.KeyCode.F7
            local flyBind = kb.ToggleFly or Enum.KeyCode.F5
            local noclipBind = kb.ToggleNoclip or Enum.KeyCode.F6
            local emerBind = kb.EmergencyStop or Enum.KeyCode.Delete

            if input.KeyCode == toggleGUIBind then
                self:Toggle()
            elseif input.KeyCode == behindTPBind then
                if not cfg.Target then cfg.Target = {} end
                local newState = not cfg.Target.BehindTP
                cfg.Target.BehindTP = newState
                if newState then
                    local combat = self._deps.Container:Get("Combat")
                    local t = combat and combat:GetTarget(cfg)
                    local tName = t and t.Name or "Opponent"
                    self:ShowNotification("⚡ Safe Behind Lock", "LOCKED behind " .. tName .. " (Continuous)", 2.0, "Success")
                else
                    self:ShowNotification("Safe Behind Lock", "Behind lock DISABLED", 2.0, "Warning")
                end
            elseif input.KeyCode == aimlockBind then
                if cfg.Combat then
                    cfg.Combat.Aimlock = not cfg.Combat.Aimlock
                    self:ShowNotification("Aimlock", cfg.Combat.Aimlock and "Aimlock ENABLED" or "Aimlock DISABLED", 2.0, cfg.Combat.Aimlock and "Success" or "Warning")
                end
            elseif input.KeyCode == flyBind then
                if cfg.Movement then
                    cfg.Movement.Fly = not cfg.Movement.Fly
                    local mov = self._deps.Container:Get("Movement")
                    if mov then mov:ToggleFly(cfg.Movement.Fly, cfg) end
                    self:ShowNotification("Flight", cfg.Movement.Fly and "Fly ENABLED" or "Fly DISABLED", 2.0, cfg.Movement.Fly and "Success" or "Warning")
                end
            elseif input.KeyCode == noclipBind then
                if cfg.Movement then
                    cfg.Movement.Noclip = not cfg.Movement.Noclip
                    self:ShowNotification("Noclip", cfg.Movement.Noclip and "Noclip ENABLED" or "Noclip DISABLED", 2.0, cfg.Movement.Noclip and "Success" or "Warning")
                end
            elseif input.KeyCode == emerBind then
                if cfg.Target then cfg.Target.BehindTP = false end
                if cfg.Movement then cfg.Movement.Fly = false; cfg.Movement.Noclip = false end
                if cfg.Combat then cfg.Combat.Aimlock = false; cfg.Combat.AutoM1 = false end
                self:ShowNotification("🛑 Emergency Stop", "All active combat & movement loops stopped.", 2.5, "Warning")
            elseif input.KeyCode == (kb.MassBringKey or Enum.KeyCode.G) then
                if self._deps.Container and self._deps.Container:Has("Combat") then
                    local combat = self._deps.Container:Get("Combat")
                    if combat.MassBringActive then
                        combat:StopMassBring()
                        self:ShowNotification("Mass Bring", "Mass Bring STOPPED", 2.0, "Warning")
                    else
                        combat:StartMassBring(cfg)
                        self:ShowNotification("Mass Bring", "Mass Bring STARTED", 2.0, "Success")
                    end
                end
            elseif input.KeyCode == (kb.ToggleSkyDodge or Enum.KeyCode.H) then
                if cfg.Survival then
                    cfg.Survival.SkyDodge = not cfg.Survival.SkyDodge
                    self:ShowNotification("Sky Dodge", cfg.Survival.SkyDodge and "Sky Dodge ENABLED" or "Sky Dodge DISABLED", 2.0, cfg.Survival.SkyDodge and "Success" or "Warning")
                end
            end
        end
    end)
    self._maid:GiveTask(keybindConn)

    -- Initial Window State
    if cfg and cfg.UI and cfg.UI.IsOpen == false then
        window:Minimize()
    else
        window:Open()
    end

    notifs:Show("TSB Framework", "System operational. Press RightControl to toggle UI.", 3.0, "Success")
    if self._deps.Logger then
        self._deps.Logger:Info("UIController", "GUI System Initialized successfully.")
    end
end

function UIController:Open()
    if self._window then
        self._window:Open()
    end
end

function UIController:Close()
    if self._window then
        self._window:Close()
    end
end

function UIController:Toggle()
    if self._window then
        self._window:Toggle()
    end
end

function UIController:ShowNotification(title: string, message: string, duration: number?, kind: any?)
    if self._notifications then
        self._notifications:Show(title, message, duration, kind)
    end
end

function UIController:SelectTab(tabName: string)
    if self._window and self._window:GetSidebar() then
        self._window:GetSidebar():SetActive(tabName)
    end
end

function UIController:Refresh()
    self:Init()
end

function UIController:Destroy()
    if self._maid then
        self._maid:DoCleaning()
    end
    self._gui = nil
    self._window = nil
    self._notifications = nil
    self._isInitialized = false
end

return UIController

end
__modules["UI/UIController"] = __modules["UI.UIController"]

-- ============================================================================
-- Module: UI.Window
-- ============================================================================
__modules["UI.Window"] = function()
--!strict
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")
local Theme = require("UI.Theme")
local Sidebar = require("UI.Sidebar")

local Window = {}
Window.__index = Window

function Window.new(parentGui: Instance, accentName: string?, onClosed: (() -> ())?)
    local accent = Theme.GetAccent(accentName)

    -- Floating Reopen Button (visible when window is minimized)
    local reopenBtn = Instance.new("TextButton")
    reopenBtn.Name = "TSB_ReopenButton"
    reopenBtn.Size = UDim2.new(0, 88, 0, 32)
    reopenBtn.Position = UDim2.new(0, 16, 0, 16)
    reopenBtn.BackgroundColor3 = Theme.Colors.Header
    reopenBtn.BorderSizePixel = 0
    reopenBtn.Text = "⚡ TSB HUB"
    reopenBtn.TextColor3 = accent.Primary
    reopenBtn.TextSize = 11
    reopenBtn.Font = Theme.Fonts.Bold
    reopenBtn.Visible = false
    reopenBtn.Parent = parentGui
    Instance.new("UICorner", reopenBtn).CornerRadius = UDim.new(1, 0)

    local reopenStroke = Instance.new("UIStroke")
    reopenStroke.Color = accent.Primary
    reopenStroke.Thickness = 1
    reopenStroke.Parent = reopenBtn

    -- Make reopen button draggable
    local draggingReopen = false
    local dragReopenStart: Vector3? = nil
    local startReopenPos: UDim2? = nil

    reopenBtn.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            draggingReopen = true
            dragReopenStart = input.Position
            startReopenPos = reopenBtn.Position
        end
    end)
    UserInputService.InputChanged:Connect(function(input)
        if draggingReopen and dragReopenStart and startReopenPos and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
            local delta = input.Position - dragReopenStart
            reopenBtn.Position = UDim2.new(
                startReopenPos.X.Scale,
                startReopenPos.X.Offset + delta.X,
                startReopenPos.Y.Scale,
                startReopenPos.Y.Offset + delta.Y
            )
        end
    end)
    UserInputService.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            draggingReopen = false
        end
    end)

    -- Main Window Frame
    local mainFrame = Instance.new("Frame")
    mainFrame.Name = "TSB_MainWindow"
    mainFrame.Size = UDim2.new(0, 650, 0, 440)
    mainFrame.Position = UDim2.new(0.5, -325, 0.5, -220)
    mainFrame.BackgroundColor3 = Theme.Colors.Background
    mainFrame.BorderSizePixel = 0
    mainFrame.ClipsDescendants = true
    mainFrame.Parent = parentGui
    Instance.new("UICorner", mainFrame).CornerRadius = UDim.new(0, 10)

    local mainStroke = Instance.new("UIStroke")
    mainStroke.Color = Theme.Colors.Border
    mainStroke.Thickness = 1
    mainStroke.Parent = mainFrame

    -- Header Bar
    local headerBar = Instance.new("Frame")
    headerBar.Name = "HeaderBar"
    headerBar.Size = UDim2.new(1, 0, 0, 40)
    headerBar.BackgroundColor3 = Theme.Colors.Header
    headerBar.BorderSizePixel = 0
    headerBar.Parent = mainFrame

    local headerSep = Instance.new("Frame")
    headerSep.Size = UDim2.new(1, 0, 0, 1)
    headerSep.Position = UDim2.new(0, 0, 1, -1)
    headerSep.BackgroundColor3 = Theme.Colors.BorderSubtle
    headerSep.BorderSizePixel = 0
    headerSep.Parent = headerBar

    local headerTitle = Instance.new("TextLabel")
    headerTitle.Name = "HeaderTitle"
    headerTitle.Size = UDim2.new(1, -220, 1, 0)
    headerTitle.Position = UDim2.new(0, 168, 0, 0)
    headerTitle.BackgroundTransparency = 1
    headerTitle.Text = "Combat Dashboard"
    headerTitle.TextColor3 = Theme.Colors.TextPrimary
    headerTitle.TextSize = 13
    headerTitle.Font = Theme.Fonts.Title
    headerTitle.TextXAlignment = Enum.TextXAlignment.Left
    headerTitle.Parent = headerBar

    -- Header Window Control Buttons (Minimize & Close)
    local minBtn = Instance.new("TextButton")
    minBtn.Name = "MinimizeButton"
    minBtn.Size = UDim2.new(0, 28, 0, 24)
    minBtn.Position = UDim2.new(1, -64, 0.5, -12)
    minBtn.BackgroundColor3 = Theme.Colors.Card
    minBtn.BorderSizePixel = 0
    minBtn.Text = "—"
    minBtn.TextColor3 = Theme.Colors.TextSecondary
    minBtn.TextSize = 12
    minBtn.Font = Theme.Fonts.Bold
    minBtn.Parent = headerBar
    Instance.new("UICorner", minBtn).CornerRadius = UDim.new(0, 5)

    local closeBtn = Instance.new("TextButton")
    closeBtn.Name = "CloseButton"
    closeBtn.Size = UDim2.new(0, 28, 0, 24)
    closeBtn.Position = UDim2.new(1, -32, 0.5, -12)
    closeBtn.BackgroundColor3 = Theme.Colors.Card
    closeBtn.BorderSizePixel = 0
    closeBtn.Text = "✕"
    closeBtn.TextColor3 = Theme.Colors.TextSecondary
    closeBtn.TextSize = 11
    closeBtn.Font = Theme.Fonts.Bold
    closeBtn.Parent = headerBar
    Instance.new("UICorner", closeBtn).CornerRadius = UDim.new(0, 5)

    closeBtn.MouseEnter:Connect(function()
        Theme.Tween(closeBtn, 0.1, { BackgroundColor3 = Theme.Colors.Danger, TextColor3 = Color3.fromRGB(255, 255, 255) })
    end)
    closeBtn.MouseLeave:Connect(function()
        Theme.Tween(closeBtn, 0.1, { BackgroundColor3 = Theme.Colors.Card, TextColor3 = Theme.Colors.TextSecondary })
    end)

    minBtn.MouseEnter:Connect(function()
        Theme.Tween(minBtn, 0.1, { BackgroundColor3 = Theme.Colors.CardHover, TextColor3 = Theme.Colors.TextPrimary })
    end)
    minBtn.MouseLeave:Connect(function()
        Theme.Tween(minBtn, 0.1, { BackgroundColor3 = Theme.Colors.Card, TextColor3 = Theme.Colors.TextSecondary })
    end)

    -- Content Area Frame
    local contentFrame = Instance.new("Frame")
    contentFrame.Name = "ContentFrame"
    contentFrame.Size = UDim2.new(1, -160, 1, -40)
    contentFrame.Position = UDim2.new(0, 160, 0, 40)
    contentFrame.BackgroundTransparency = 1
    contentFrame.Parent = mainFrame

    -- Dragging with Boundary Clamping
    local isDragging = false
    local dragStartPos: Vector3? = nil
    local frameStartPos: UDim2? = nil

    headerBar.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            isDragging = true
            dragStartPos = input.Position
            frameStartPos = mainFrame.Position
        end
    end)

    UserInputService.InputChanged:Connect(function(input)
        if isDragging and dragStartPos and frameStartPos and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
            local delta = input.Position - dragStartPos
            local cam = Workspace.CurrentCamera
            local vp = cam and cam.ViewportSize or Vector2.new(1920, 1080)

            local newX = frameStartPos.X.Offset + delta.X
            local newY = frameStartPos.Y.Offset + delta.Y

            -- Screen boundary clamping
            local absoluteW = mainFrame.AbsoluteSize.X
            local absoluteH = mainFrame.AbsoluteSize.Y
            local screenX = frameStartPos.X.Scale * vp.X + newX
            local screenY = frameStartPos.Y.Scale * vp.Y + newY

            if screenX < 0 then newX = -frameStartPos.X.Scale * vp.X end
            if screenY < 0 then newY = -frameStartPos.Y.Scale * vp.Y end
            if (screenX + absoluteW) > vp.X then newX = vp.X - absoluteW - (frameStartPos.X.Scale * vp.X) end
            if (screenY + absoluteH) > vp.Y then newY = vp.Y - absoluteH - (frameStartPos.Y.Scale * vp.Y) end

            mainFrame.Position = UDim2.new(frameStartPos.X.Scale, newX, frameStartPos.Y.Scale, newY)
        end
    end)

    UserInputService.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            isDragging = false
        end
    end)

    local self = setmetatable({
        _gui = parentGui,
        _mainFrame = mainFrame,
        _headerTitle = headerTitle,
        _contentFrame = contentFrame,
        _reopenBtn = reopenBtn,
        _minBtn = minBtn,
        _closeBtn = closeBtn,
        _accentName = accentName or "Cyan Neon",
        _isOpen = true,
        _isMinimized = false,
        _tabPages = {},
        _sidebar = nil :: any,
        _onClosed = onClosed,
    }, Window)

    -- Sidebar Integration
    self._sidebar = Sidebar.new(mainFrame, accentName, function(tabName)
        self:SelectTab(tabName)
    end)

    -- Minimize Action
    minBtn.MouseButton1Click:Connect(function()
        self:Minimize()
    end)

    -- Reopen Action
    reopenBtn.MouseButton1Click:Connect(function()
        self:Restore()
    end)

    -- Close Action
    closeBtn.MouseButton1Click:Connect(function()
        self:Close()
    end)

    return self
end

function Window:CreateTabPage(tabName: string): ScrollingFrame
    local scroll = Instance.new("ScrollingFrame")
    scroll.Name = "TabPage_" .. tabName
    scroll.Size = UDim2.new(1, 0, 1, 0)
    scroll.BackgroundTransparency = 1
    scroll.BorderSizePixel = 0
    scroll.ScrollBarThickness = 4
    scroll.ScrollBarImageColor3 = Theme.Colors.BorderActive
    scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
    scroll.CanvasSize = UDim2.new(0, 0, 0, 0)
    scroll.Visible = false
    scroll.Parent = self._contentFrame

    local listLayout = Instance.new("UIListLayout")
    listLayout.SortOrder = Enum.SortOrder.LayoutOrder
    listLayout.Padding = UDim.new(0, 6)
    listLayout.Parent = scroll

    local pad = Instance.new("UIPadding")
    pad.PaddingTop = UDim.new(0, 10)
    pad.PaddingBottom = UDim.new(0, 14)
    pad.PaddingLeft = UDim.new(0, 12)
    pad.PaddingRight = UDim.new(0, 14)
    pad.Parent = scroll

    self._tabPages[tabName] = scroll
    return scroll
end

function Window:SelectTab(tabName: string)
    self._headerTitle.Text = tabName .. " Dashboard"
    for name, page in pairs(self._tabPages) do
        page.Visible = (name == tabName)
    end
end

function Window:Minimize()
    self._isMinimized = true
    Theme.Tween(self._mainFrame, 0.18, { Size = UDim2.new(0, 650, 0, 0) })
    task.delay(0.18, function()
        if self._isMinimized then
            self._mainFrame.Visible = false
            self._reopenBtn.Visible = true
            Theme.Tween(self._reopenBtn, 0.15, { BackgroundTransparency = 0 })
        end
    end)
end

function Window:Restore()
    self._isMinimized = false
    self._reopenBtn.Visible = false
    self._mainFrame.Visible = true
    Theme.Tween(self._mainFrame, 0.2, { Size = UDim2.new(0, 650, 0, 440) })
end

function Window:Open()
    if self._isOpen and self._mainFrame.Visible then return end
    self._isOpen = true
    self._isMinimized = false
    self._reopenBtn.Visible = false
    self._mainFrame.Visible = true
    self._mainFrame.Size = UDim2.new(0, 600, 0, 400)
    Theme.Tween(self._mainFrame, 0.22, { Size = UDim2.new(0, 650, 0, 440) })
end

function Window:Close()
    self._isOpen = false
    Theme.Tween(self._mainFrame, 0.18, { Size = UDim2.new(0, 600, 0, 400) })
    task.delay(0.18, function()
        if not self._isOpen then
            self._mainFrame.Visible = false
            self._reopenBtn.Visible = true
            if self._onClosed then pcall(self._onClosed) end
        end
    end)
end

function Window:Toggle()
    if self._mainFrame.Visible then
        self:Close()
    else
        self:Open()
    end
end

function Window:GetSidebar(): any
    return self._sidebar
end

function Window:Destroy()
    if self._sidebar then
        self._sidebar:Destroy()
        self._sidebar = nil :: any
    end
    if self._mainFrame then
        self._mainFrame:Destroy()
        self._mainFrame = nil :: any
    end
    if self._reopenBtn then
        self._reopenBtn:Destroy()
        self._reopenBtn = nil :: any
    end
    table.clear(self._tabPages)
end

return Window

end
__modules["UI/Window"] = __modules["UI.Window"]

-- ============================================================================
-- FRAMEWORK PUBLIC RUNTIME SURFACE & ENTRYPOINT
-- ============================================================================
local Bootstrap = require("Bootstrap")
local UnitTests = require("Diagnostics.UnitTests")

local Framework = {
    Version = "9.0-SPECIALIST-PRODUCTION",
    Bootstrap = Bootstrap,
    
    Start = function(self)
        return Bootstrap:Init()
    end,
    
    Stop = function(self)
        return Bootstrap:Destroy()
    end,
    
    Destroy = function(self)
        return Bootstrap:Destroy()
    end,
    
    GetService = function(self, serviceName: string)
        if Bootstrap.Container and Bootstrap.Container:Has(serviceName) then
            return Bootstrap.Container:Get(serviceName)
        end
        return nil
    end,
    
    GetDiagnostics = function(self)
        return Bootstrap:GetDiagnostics()
    end,
    
    GetUI = function(self)
        if Bootstrap.Container and Bootstrap.Container:Has("UIController") then
            return Bootstrap.Container:Get("UIController")
        end
        return nil
    end,
    
    RunTests = function(self)
        return UnitTests.RunAll()
    end,
}

-- Expose Public Framework Handle to Global Environment for External Lifecycle Control
if typeof(_G) == "table" then
    _G.TSBFramework = Framework
end
if typeof(getgenv) == "function" then
    pcall(function()
        getgenv().TSBFramework = Framework
    end)
end

-- Automatic Framework Boot with Error Handling & Native Notification
print("[4080 HUB v9.0] Initializing Specialist Production Framework...")

local okBoot, bootErr = pcall(function()
    Bootstrap:Init()
end)

if not okBoot then
    warn("[4080 HUB v9.0] FATAL BOOT ERROR: " .. tostring(bootErr))
    pcall(function()
        game:GetService("StarterGui"):SetCore("SendNotification", {
            Title = "TSB HUB Error",
            Text = "Boot failed: " .. tostring(bootErr):sub(1, 80),
            Duration = 10,
        })
    end)
else
    print("[4080 HUB v9.0] Specialist Production Framework Booted Successfully.")
    pcall(function()
        game:GetService("StarterGui"):SetCore("SendNotification", {
            Title = "⚡ TSB HUB v9.0",
            Text = "Specialist Hub Loaded! Press RightControl to toggle UI.",
            Duration = 5,
        })
    end)
end

return Framework
