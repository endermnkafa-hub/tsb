--!strict
local Lighting = game:GetService("Lighting")
local TeleportService = game:GetService("TeleportService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")

local World = {}
World.__index = World

function World.new(deps: { ConfigManager: any, Logger: any })
    local self = setmetatable({
        _configManager = deps.ConfigManager,
        _logger = deps.Logger,
        OriginalLighting = {
            Ambient = Lighting.Ambient,
            OutdoorAmbient = Lighting.OutdoorAmbient,
            Brightness = Lighting.Brightness,
            FogEnd = Lighting.FogEnd,
        },
        LastHopCheck = 0,
        HopActive = false,
    }, World)
    return self
end

function World:ToggleFullBright(enable: boolean)
    if enable then
        Lighting.Ambient = Color3.new(1, 1, 1)
        Lighting.OutdoorAmbient = Color3.new(1, 1, 1)
        Lighting.Brightness = 2
    else
        Lighting.Ambient = self.OriginalLighting.Ambient
        Lighting.OutdoorAmbient = self.OriginalLighting.OutdoorAmbient
        Lighting.Brightness = self.OriginalLighting.Brightness
    end
end

function World:ToggleRemoveFog(enable: boolean)
    if enable then
        Lighting.FogEnd = 9e9
    else
        Lighting.FogEnd = self.OriginalLighting.FogEnd
    end
end

function World:ServerHop()
    if self.HopActive then return end
    self.HopActive = true

    task.spawn(function()
        local placeId = game.PlaceId
        local jobId = game.JobId
        local url = "https://games.roblox.com/v1/games/" .. placeId .. "/servers/Public?sortOrder=Desc&limit=100"

        local req = (typeof(syn) == "table" and syn.request) or (typeof(http_request) == "function" and http_request) or request
        local body = nil
        if req then
            local res = req({ Url = url, Method = "GET" })
            if res and res.Body then body = res.Body end
        elseif typeof(game.HttpGet) == "function" then
            pcall(function() body = game:HttpGet(url) end)
        end

        if body then
            local ok, data = pcall(function() return HttpService:JSONDecode(body) end)
            if ok and data and data.data then
                for _, s in ipairs(data.data) do
                    if s.id ~= jobId and s.playing and s.maxPlayers and s.playing < (s.maxPlayers - 1) and s.playing >= 4 then
                        TeleportService:TeleportToPlaceInstance(placeId, s.id, Players.LocalPlayer)
                        return
                    end
                end
            end
        end

        TeleportService:Teleport(placeId, Players.LocalPlayer)
    end)
end

function World:CheckAutoServerHop(config: any)
    if not config.World.AutoServerHop or self.HopActive then return end
    local now = os.clock()
    if (now - self.LastHopCheck) < 10 then return end
    self.LastHopCheck = now

    local count = #Players:GetPlayers()
    if count <= (config.World.AutoHopMinPlayers or 4) then
        self:ServerHop()
    end
end

return World
