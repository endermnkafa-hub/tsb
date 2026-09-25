--!strict
local Players = game:GetService("Players")
local LocalPlayer = Players.LocalPlayer

local Skills = {}
Skills.__index = Skills

function Skills.new(deps: { Cache: any, Combat: any, Logger: any })
    local self = setmetatable({
        _cache = deps.Cache,
        _combat = deps.Combat,
        _logger = deps.Logger,
        LastSpamTick = 0,
        SpamIdx = 1,
        Keys = { Enum.KeyCode.One, Enum.KeyCode.Two, Enum.KeyCode.Three, Enum.KeyCode.Four },
    }, Skills)
    return self
end

local function SafeKeyClick(keyCode: Enum.KeyCode)
    local vim = nil
    pcall(function() vim = game:GetService("VirtualInputManager") end)
    if vim then
        pcall(function()
            vim:SendKeyEvent(true, keyCode, false, game)
            task.wait(0.03)
            vim:SendKeyEvent(false, keyCode, false, game)
        end)
    end
end

function Skills:OrientToTarget(config: any)
    local target = self._combat.CurrentTarget or self._combat:GetTarget(config)
    if not target then return end
    local myEntry = self._cache:GetPlayerEntry(LocalPlayer)
    local tEntry = self._cache:GetPlayerEntry(target)
    if not myEntry or not myEntry.RootPart or not tEntry or not tEntry.RootPart then return end

    local myRoot = myEntry.RootPart
    local tPos = tEntry.RootPart.Position
    pcall(function()
        myRoot.CFrame = CFrame.lookAt(myRoot.Position, Vector3.new(tPos.X, myRoot.Position.Y, tPos.Z))
    end)
end

function Skills:UpdateAutoSkillSpam(config: any)
    if not config.Skills.AutoSkillSpam and not config.Skills.AutoUltSpam then return end
    local target = self._combat.CurrentTarget or self._combat:GetTarget(config)
    if not target then return end

    if config.Skills.AutoUltSpam then
        SafeKeyClick(Enum.KeyCode.G)
    end

    if config.Skills.AutoSkillSpam then
        local now = os.clock()
        if (now - self.LastSpamTick) >= (config.Skills.SkillSpamDelay or 0.25) then
            self.LastSpamTick = now
            self:OrientToTarget(config)
            SafeKeyClick(self.Keys[self.SpamIdx])
            self.SpamIdx = (self.SpamIdx % #self.Keys) + 1
        end
    end
end

return Skills
