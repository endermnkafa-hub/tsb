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
