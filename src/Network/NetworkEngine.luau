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
