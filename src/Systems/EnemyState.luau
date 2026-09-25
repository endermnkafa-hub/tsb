--!strict
export type EnemyData = {
    Cooldowns: { [string]: number },
    IsRagdoll: boolean,
    RagdollStart: number,
    WakeupTime: number,
    IsBlocking: boolean,
    LastSkill: string,
    LastSkillTick: number,
}

local EnemyState = {}
EnemyState.__index = EnemyState

local COUNTER_ATTRIBUTES = {
    "HoldingDeathCounter", "HoldingFlowingWater", "HoldingWaterStreamCuttingFist",
    "HoldingPreysPeril", "HoldingGodSlayer", "HoldingHuntersGrasp"
}

local ATTACK_ATTRIBUTES = {
    "HoldingM1", "HoldingNormalPunch", "HoldingConsecutivePunches", "HoldingSeriousPunch",
    "HoldingOmniDirectionalPunch", "HoldingGammaRayBurst", "HoldingAtomicSlash", "HoldingBeatdown",
    "HoldingGrandSlam", "HoldingHomerun", "HoldingIncinerate", "HoldingIgnitionBurst",
    "HoldingFlashStrike", "HoldingScatter", "HoldingVanishingKick", "HoldingHeadFirst",
    "HoldingSpeedblitzDropkick", "HoldingAtmosCleave", "HoldingSolarCleave", "HoldingTwinbladeRush",
    "HoldingDeathBlow", "HoldingTrinityTear", "HoldingCarnage", "HoldingExpulsivePush"
}

function EnemyState.new(deps: { Cache: any, EventBus: any, Logger: any })
    local self = setmetatable({
        _cache = deps.Cache,
        _eventBus = deps.EventBus,
        _logger = deps.Logger,
        _states = {},
        Profiles = {
            Saitama = { NormalPunch = 12, Consecutive = 15, Shove = 14, Uppercut = 16 },
            Garou = { FlowingWater = 14, LethalWhirlwind = 15, HuntersGrasp = 18, PreysPeril = 16 },
            Sonic = { FlashStrike = 12, WhirlwindKick = 14, Scatter = 16, Shuriken = 15 },
            Suiryu = { VanishingKick = 14, HeadFirst = 15, SweepingKick = 16, FistBarrage = 18 },
            Universal = { Skill1 = 14, Skill2 = 15, Skill3 = 16, Skill4 = 16 },
        }
    }, EnemyState)
    return self
end

function EnemyState:Get(player: Player): EnemyData
    local data = self._states[player]
    if not data then
        data = {
            Cooldowns = {},
            IsRagdoll = false,
            RagdollStart = 0,
            WakeupTime = 0,
            IsBlocking = false,
            LastSkill = "None",
            LastSkillTick = 0,
        }
        self._states[player] = data
    end
    return data
end

function EnemyState:Update(player: Player)
    local entry = self._cache:GetPlayerEntry(player)
    if not entry or not entry.IsAlive then return end

    local data = self:Get(player)
    local hum = entry.Humanoid
    local char = entry.Character
    local hState = hum:GetState()
    local isRag = (hState == Enum.HumanoidStateType.Physics or hState == Enum.HumanoidStateType.Ragdoll)

    if isRag and not data.IsRagdoll then
        data.IsRagdoll = true
        data.RagdollStart = os.clock()
        data.WakeupTime = data.RagdollStart + 2.25
        self._eventBus:Publish("Combat.EnemyRagdolled", player, data.WakeupTime)
    elseif not isRag and data.IsRagdoll then
        data.IsRagdoll = false
        self._eventBus:Publish("Combat.EnemyWakeup", player)
    end

    -- Real TSB Instant Attribute Block Detection
    local isBlock = false
    if char then
        local blkAttr = char:GetAttribute("Blocking")
        if blkAttr == true or blkAttr == "true" or (char:GetAttribute("BlockTime") and not char:GetAttribute("StoppedBlocking")) then
            isBlock = true
        end
    end

    if not isBlock then
        local anim = entry.Animator
        if anim then
            for _, t in ipairs(anim:GetPlayingAnimationTracks()) do
                local n = (t.Name or ""):lower()
                if n:find("block") or n:find("guard") or n:find("defend") then
                    isBlock = true
                    break
                end
            end
        end
    end
    data.IsBlocking = isBlock
end

function EnemyState:IsEnemyInCounterStance(player: Player): boolean
    local entry = self._cache:GetPlayerEntry(player)
    if not entry or not entry.IsAlive or not entry.Character then return false end
    local char = entry.Character

    for _, attr in ipairs(COUNTER_ATTRIBUTES) do
        if char:GetAttribute(attr) ~= nil then
            return true
        end
    end

    local anim = entry.Animator
    if anim then
        for _, t in ipairs(anim:GetPlayingAnimationTracks()) do
            local n = (t.Name or ""):lower()
            if n:find("counter") or n:find("flowing") or n:find("deflect") or n:find("reflect") then
                return true
            end
        end
    end
    return false
end

return EnemyState
