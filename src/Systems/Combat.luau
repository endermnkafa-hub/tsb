--!strict
local Players = game:GetService("Players")
local LocalPlayer = Players.LocalPlayer

local Combat = {}
Combat.__index = Combat

function Combat.new(deps: { Cache: any, EventBus: any, Network: any, EnemyState: any, Logger: any, StateMachine: any })
    local self = setmetatable({
        _cache = deps.Cache,
        _eventBus = deps.EventBus,
        _network = deps.Network,
        _enemyState = deps.EnemyState,
        _logger = deps.Logger,
        _fsm = deps.StateMachine,
        CurrentTarget = nil,
        LastAttackTick = 0,
        LastParryTick = 0,
        M1ComboCount = 0,
        MassBringActive = false,
    }, Combat)
    return self
end

local function SafeMouseClick()
    local char = LocalPlayer.Character
    local comm = char and char:FindFirstChild("Communicate")
    if comm and comm:IsA("RemoteEvent") then
        pcall(function() comm:FireServer({ Goal = "m1" }) end)
        return
    end

    local vim = nil
    pcall(function() vim = game:GetService("VirtualInputManager") end)
    if vim then
        pcall(function()
            vim:SendMouseButtonEvent(0, 0, 0, true, game, 1)
            task.wait(0.02)
            vim:SendMouseButtonEvent(0, 0, 0, false, game, 1)
        end)
    elseif typeof(mouse1click) == "function" then
        pcall(function() mouse1click() end)
    end
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
    elseif typeof(keypress) == "function" and typeof(keyrelease) == "function" then
        pcall(function()
            keypress(keyCode.Value)
            task.wait(0.03)
            keyrelease(keyCode.Value)
        end)
    end
end

function Combat:GetTarget(config: any): Player?
    local myEntry = self._cache:GetPlayerEntry(LocalPlayer)
    if not myEntry or not myEntry.RootPart then return nil end
    local myPos = myEntry.RootPart.Position

    local targetCfg = config.Target or {}
    local mode = targetCfg.TargetMode or (config.Combat and config.Combat.AimMode) or "Nearest"
    local maxRange = (config.Combat and config.Combat.AimMaxRange) or 300

    -- 1. Specific Player Mode
    if mode == "Specific Player" and targetCfg.SpecificPlayer and targetCfg.SpecificPlayer ~= "None" then
        local p = Players:FindFirstChild(targetCfg.SpecificPlayer)
        if p and p ~= LocalPlayer then
            local entry = self._cache:GetPlayerEntry(p)
            if entry and entry.IsAlive and entry.RootPart then
                self.CurrentTarget = p
                return p
            end
        end
    end

    -- 2. Lowest HP Mode
    if mode == "Lowest HP" then
        local lowestHp = math.huge
        local lowestPlayer = nil
        for _, player in ipairs(Players:GetPlayers()) do
            if player == LocalPlayer then continue end
            local entry = self._cache:GetPlayerEntry(player)
            if not entry or not entry.IsAlive or not entry.RootPart or not entry.Humanoid then continue end
            local dist = (entry.RootPart.Position - myPos).Magnitude
            if dist <= maxRange then
                if entry.Humanoid.Health < lowestHp then
                    lowestHp = entry.Humanoid.Health
                    lowestPlayer = player
                end
            end
        end
        if lowestPlayer then
            self.CurrentTarget = lowestPlayer
            return lowestPlayer
        end
    end

    -- 3. Random Mode (sticks to target while alive and in range)
    if mode == "Random" then
        if self.CurrentTarget and self.CurrentTarget.Parent then
            local curEntry = self._cache:GetPlayerEntry(self.CurrentTarget)
            if curEntry and curEntry.IsAlive and curEntry.RootPart then
                local dist = (curEntry.RootPart.Position - myPos).Magnitude
                if dist <= maxRange then
                    return self.CurrentTarget
                end
            end
        end
        local candidates = {}
        for _, player in ipairs(Players:GetPlayers()) do
            if player == LocalPlayer then continue end
            local entry = self._cache:GetPlayerEntry(player)
            if entry and entry.IsAlive and entry.RootPart then
                local dist = (entry.RootPart.Position - myPos).Magnitude
                if dist <= maxRange then
                    table.insert(candidates, player)
                end
            end
        end
        if #candidates > 0 then
            local picked = candidates[math.random(1, #candidates)]
            self.CurrentTarget = picked
            return picked
        end
    end

    -- 4. Nearest Mode (Default)
    local bestPlayer = nil
    local bestDist = maxRange

    for _, player in ipairs(Players:GetPlayers()) do
        if player == LocalPlayer then continue end
        local entry = self._cache:GetPlayerEntry(player)
        if not entry or not entry.IsAlive or not entry.RootPart then continue end

        local targetPart = entry.Character:FindFirstChild(config.Combat and config.Combat.AimPart or "HumanoidRootPart") or entry.RootPart
        local dist = (targetPart.Position - myPos).Magnitude

        if dist < bestDist then
            if config.Combat and config.Combat.AimWallCheck and not self._cache:CachedRaycast(myPos, targetPart.Position) then
                continue
            end
            bestDist = dist
            bestPlayer = player
        end
    end

    self.CurrentTarget = bestPlayer
    return bestPlayer
end

function Combat:UpdateAimlock(config: any)
    if not config.Combat.Aimlock then return end
    local target = self:GetTarget(config)
    if not target then return end

    local myEntry = self._cache:GetPlayerEntry(LocalPlayer)
    local tEntry = self._cache:GetPlayerEntry(target)
    if not myEntry or not myEntry.RootPart or not tEntry or not tEntry.RootPart then return end

    local targetPos = tEntry.RootPart.Position
    if config.Combat.PredictiveAim then
        local vel = tEntry.RootPart.AssemblyLinearVelocity or Vector3.zero
        targetPos = targetPos + (vel * 0.05)
    end

    local myRoot = myEntry.RootPart
    pcall(function()
        myRoot.CFrame = CFrame.lookAt(myRoot.Position, Vector3.new(targetPos.X, myRoot.Position.Y, targetPos.Z))
    end)
end

function Combat:UpdateAutoM1(config: any)
    if not config.Combat.AutoM1 then return end
    local target = self.CurrentTarget or self:GetTarget(config)
    if not target then return end

    local myEntry = self._cache:GetPlayerEntry(LocalPlayer)
    local tEntry = self._cache:GetPlayerEntry(target)
    if not myEntry or not myEntry.RootPart or not tEntry or not tEntry.RootPart then return end

    -- AntiCounterBait: don't attack while enemy is in counter stance
    if config.Combat.AntiCounterBait and self._enemyState:IsEnemyInCounterStance(target) then
        return
    end

    local dist = (myEntry.RootPart.Position - tEntry.RootPart.Position).Magnitude
    if dist <= 14 then
        -- Natural FSM State Management
        if self._fsm.CurrentState == "IDLE" then
            self._fsm:TransitionTo("COMBAT")
        end

        local now = os.clock()
        local enemyData = self._enemyState and self._enemyState:Get(target)

        -- Frame Trap Wakeup: if enemy is ragdolled, wait for the exact getup recovery frame
        if enemyData and enemyData.IsRagdoll then
            if config.Combat.FrameTrapWakeup and enemyData.WakeupTime > 0 then
                if now >= (enemyData.WakeupTime - 0.15) and now <= (enemyData.WakeupTime + 0.35) then
                    if (now - self.LastAttackTick) >= (config.Combat.AutoM1Delay or 0.12) then
                        self.LastAttackTick = now
                        self.M1ComboCount = 1
                        SafeMouseClick()
                    end
                end
            end
            return -- Do not waste attacks while enemy is invincible on ground
        end

        if (now - self.LastAttackTick) >= (config.Combat.AutoM1Delay or 0.12) then
            self.LastAttackTick = now
            self.M1ComboCount = (self.M1ComboCount % 4) + 1

            -- AutoComboSequencer: execute combo timings (e.g. 3 M1s + pause / skill window)
            if config.Combat.AutoComboSequencer and self.M1ComboCount == 3 then
                -- 3rd M1 executed; delay 4th slightly or trigger downtilt/uptilt jump
                pcall(function()
                    if myEntry.Humanoid then
                        myEntry.Humanoid.Jump = true
                    end
                end)
            end

            SafeMouseClick()
        end
    end
end

function Combat:UpdateAutoBlock(config: any)
    if not config.Combat.AutoParry and not config.Combat.AutoBlock then return end
    local myEntry = self._cache:GetPlayerEntry(LocalPlayer)
    if not myEntry or not myEntry.RootPart then return end
    local myPos = myEntry.RootPart.Position

    local anyNearby = false

    for _, player in ipairs(Players:GetPlayers()) do
        if player == LocalPlayer then continue end
        local tEntry = self._cache:GetPlayerEntry(player)
        if not tEntry or not tEntry.IsAlive or not tEntry.RootPart then continue end

        local dist = (tEntry.RootPart.Position - myPos).Magnitude

        -- AutoParry: detect attack animations and press parry key with reaction delay
        if config.Combat.AutoParry and dist <= 18 then
            local isAttacking = false
            local tChar = tEntry.Character
            if tChar then
                if tChar:GetAttribute("HoldingM1") ~= nil or tChar:GetAttribute("HoldingNormalPunch") ~= nil or tChar:GetAttribute("HoldingConsecutivePunches") ~= nil or tChar:GetAttribute("HoldingFlashStrike") ~= nil or tChar:GetAttribute("HoldingVanishingKick") ~= nil then
                    isAttacking = true
                end
            end

            if not isAttacking and tEntry.Animator then
                for _, track in ipairs(tEntry.Animator:GetPlayingAnimationTracks()) do
                    local name = (track.Name or ""):lower()
                    if name:find("attack") or name:find("punch") or name:find("slash") or name:find("strike") then
                        isAttacking = true
                        break
                    end
                end
            end

            if isAttacking then
                local now = os.clock()
                if (now - self.LastParryTick) >= 0.08 then
                    self.LastParryTick = now
                    SafeKeyClick(Enum.KeyCode.F)
                    self._eventBus:Publish("Combat.ParryExecuted", player)
                    break
                end
            end
        end

        -- AutoBlock: track whether any enemy is within block range
        if config.Combat.AutoBlock and dist <= 22 then
            anyNearby = true
        end
    end

    -- AutoBlock: continuously hold block key (F) while enemies are near
    if config.Combat.AutoBlock then
        local now = os.clock()
        if anyNearby and (now - self.LastParryTick) >= 0.15 then
            self.LastParryTick = now
            SafeKeyClick(Enum.KeyCode.F)
        end
    end
end

function Combat:UpdateHitboxExpander(config: any)
    if not config.Combat.HitboxExpander then return end
    local sz = config.Combat.HitboxSize or 16
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= LocalPlayer then
            local entry = self._cache:GetPlayerEntry(p)
            if entry and entry.IsAlive and entry.RootPart then
                pcall(function()
                    entry.RootPart.Size = Vector3.new(sz, sz, sz)
                    entry.RootPart.Transparency = 0.85
                    entry.RootPart.CanCollide = false
                end)
            end
        end
    end
end

function Combat:ResetHitboxes()
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= LocalPlayer then
            local entry = self._cache:GetPlayerEntry(p)
            if entry and entry.RootPart then
                pcall(function()
                    entry.RootPart.Size = Vector3.new(2, 2, 1)
                    entry.RootPart.Transparency = 1
                end)
            end
        end
    end
end

function Combat:UpdateAntiRagdoll(config: any)
    if not config.Combat.AntiRagdoll then return end
    local entry = self._cache:GetPlayerEntry(LocalPlayer)
    if not entry or not entry.Humanoid then return end
    local state = entry.Humanoid:GetState()
    if state == Enum.HumanoidStateType.Physics or state == Enum.HumanoidStateType.FallingDown then
        pcall(function() entry.Humanoid:ChangeState(Enum.HumanoidStateType.Running) end)
    end
end

function Combat:UpdateAutoEvasive(config: any)
    if not config.Combat.AutoEvasive then return end
    local myEntry = self._cache:GetPlayerEntry(LocalPlayer)
    if not myEntry or not myEntry.RootPart then return end
    local myPos = myEntry.RootPart.Position
    local cam = game:GetService("Workspace").CurrentCamera
    if not cam then return end

    local now = os.clock()
    if (now - (self._lastEvasiveTick or 0)) < 0.5 then return end

    for _, player in ipairs(Players:GetPlayers()) do
        if player == LocalPlayer then continue end
        local tEntry = self._cache:GetPlayerEntry(player)
        if not tEntry or not tEntry.IsAlive or not tEntry.RootPart then continue end
        local dist = (tEntry.RootPart.Position - myPos).Magnitude
        if dist > 12 then continue end

        -- Check if enemy is actively attacking
        local isAttacking = false
        local tChar = tEntry.Character
        if tChar then
            if tChar:GetAttribute("HoldingM1") or tChar:GetAttribute("HoldingNormalPunch")
                or tChar:GetAttribute("HoldingConsecutivePunches") then
                isAttacking = true
            end
        end
        if not isAttacking and tEntry.Animator then
            for _, track in ipairs(tEntry.Animator:GetPlayingAnimationTracks()) do
                local name = (track.Name or ""):lower()
                if name:find("attack") or name:find("punch") or name:find("strike") then
                    isAttacking = true
                    break
                end
            end
        end

        if isAttacking then
            self._lastEvasiveTick = now
            -- Alternate dodge direction each time
            self._evasiveSide = not self._evasiveSide
            local sideDir = self._evasiveSide and cam.CFrame.RightVector or -cam.CFrame.RightVector
            pcall(function()
                myEntry.RootPart.AssemblyLinearVelocity = Vector3.new(
                    sideDir.X * 40,
                    myEntry.RootPart.AssemblyLinearVelocity.Y,
                    sideDir.Z * 40
                )
            end)
            break
        end
    end
end

function Combat:StartMassBring(config: any)
    if self.MassBringActive then return end
    self.MassBringActive = true
    self._massBringStart = os.clock()
    self._eventBus:Publish("Combat.MassBringStarted")
end

function Combat:StopMassBring()
    if not self.MassBringActive then return end
    self.MassBringActive = false
    self._massBringStart = nil
    self._eventBus:Publish("Combat.MassBringStopped")
end

function Combat:UpdateMassBring(config: any)
    if not self.MassBringActive then return end
    local myEntry = self._cache:GetPlayerEntry(LocalPlayer)
    if not myEntry or not myEntry.RootPart then self:StopMassBring() return end

    -- Auto-stop after duration
    local duration = config.Combat.MassBringDuration or 5
    if (os.clock() - (self._massBringStart or 0)) > duration then
        self:StopMassBring()
        return
    end

    local myPos = myEntry.RootPart.Position
    local radius = 6
    local idx = 0

    for _, player in ipairs(Players:GetPlayers()) do
        if player == LocalPlayer then continue end
        local tEntry = self._cache:GetPlayerEntry(player)
        if not tEntry or not tEntry.IsAlive or not tEntry.RootPart then continue end
        local dist = (tEntry.RootPart.Position - myPos).Magnitude
        if dist > (config.Combat.AimMaxRange or 300) then continue end

        -- Arrange players in a circle around local player
        local angle = (idx * (2 * math.pi)) / math.max(#Players:GetPlayers() - 1, 1)
        local targetPos = myPos + Vector3.new(math.cos(angle) * radius, 0, math.sin(angle) * radius)
        pcall(function()
            tEntry.RootPart.CFrame = CFrame.new(targetPos + Vector3.new(0, 3, 0))
        end)
        idx += 1
    end
end

return Combat
