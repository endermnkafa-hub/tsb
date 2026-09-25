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
