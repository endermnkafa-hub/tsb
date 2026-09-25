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
