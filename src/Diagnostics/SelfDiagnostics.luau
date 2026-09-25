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
