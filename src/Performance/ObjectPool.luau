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
