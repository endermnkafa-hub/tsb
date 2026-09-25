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
