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
