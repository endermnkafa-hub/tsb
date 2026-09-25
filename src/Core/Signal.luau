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
