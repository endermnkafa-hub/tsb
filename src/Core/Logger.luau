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
