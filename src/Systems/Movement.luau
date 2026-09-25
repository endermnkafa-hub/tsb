--!strict
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")
local Players = game:GetService("Players")
local LocalPlayer = Players.LocalPlayer

local Maid = require("Core.Maid")

local Movement = {}
Movement.__index = Movement

function Movement.new(deps: { Cache: any, Logger: any })
    local self = setmetatable({
        _cache = deps.Cache,
        _logger = deps.Logger,
        LastSafePos = nil,
        LastBehindTPTick = 0,
        LastBehindAttackTick = 0,
        -- Jump system state
        _jumpMaid = nil :: any,
        _doubleJumpUsed = false,
        _isAirborne = false,
    }, Movement)
    return self
end

local function SafeAttackM1()
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

function Movement:ToggleFly(enable: boolean, config: any)
    config.Movement.Fly = enable
    local entry = self._cache:GetPlayerEntry(LocalPlayer)
    if not entry or not entry.RootPart or not entry.Humanoid then return end
    if enable then
        pcall(function() entry.Humanoid:ChangeState(Enum.HumanoidStateType.Running) end)
    end
end

function Movement:UpdateFly(dt: number, config: any)
    if not config.Movement.Fly then return end
    local entry = self._cache:GetPlayerEntry(LocalPlayer)
    local cam = Workspace.CurrentCamera
    if not entry or not entry.RootPart or not cam then return end

    local speed = config.Movement.FlySpeed or 60
    local moveDir = Vector3.zero

    if UserInputService:IsKeyDown(Enum.KeyCode.W) then moveDir += cam.CFrame.LookVector end
    if UserInputService:IsKeyDown(Enum.KeyCode.S) then moveDir -= cam.CFrame.LookVector end
    if UserInputService:IsKeyDown(Enum.KeyCode.A) then moveDir -= cam.CFrame.RightVector end
    if UserInputService:IsKeyDown(Enum.KeyCode.D) then moveDir += cam.CFrame.RightVector end
    if UserInputService:IsKeyDown(Enum.KeyCode.Space) then moveDir += Vector3.new(0, 1, 0) end
    if UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) then moveDir -= Vector3.new(0, 1, 0) end

    local root = entry.RootPart
    root.AssemblyLinearVelocity = Vector3.zero
    root.AssemblyAngularVelocity = Vector3.zero
    if moveDir.Magnitude > 0 then
        root.CFrame = root.CFrame + (moveDir.Unit * speed * (dt or 0.016))
    end
end

function Movement:UpdateSpeed(dt: number, config: any)
    local entry = self._cache:GetPlayerEntry(LocalPlayer)
    if not entry or not entry.Humanoid or not entry.RootPart then return end

    if config.Movement.SpeedBoost then
        local moveDir = entry.Humanoid.MoveDirection
        if moveDir.Magnitude > 0 then
            local extra = (config.Movement.SpeedVal - 16) * (dt or 0.016)
            entry.RootPart.CFrame += (moveDir.Unit * extra)
        end
    end
end

function Movement:UpdateNoclip(config: any)
    if not config.Movement.Noclip then return end
    local char = LocalPlayer.Character
    if char then
        for _, part in ipairs(char:GetDescendants()) do
            if part:IsA("BasePart") then part.CanCollide = false end
        end
    end
end

function Movement:UpdateAntiVoid(config: any)
    if not config.Movement.AntiVoid then return end
    local entry = self._cache:GetPlayerEntry(LocalPlayer)
    if not entry or not entry.RootPart or not entry.Humanoid or entry.Humanoid.Health <= 0 then return end

    local root = entry.RootPart
    if root.Position.Y >= 0 and root.AssemblyLinearVelocity.Magnitude < 220 then
        self.LastSafePos = root.CFrame
    end

    if root.Position.Y < -60 or root.AssemblyLinearVelocity.Magnitude > 600 then
        if self.LastSafePos then
            root.CFrame = self.LastSafePos + Vector3.new(0, 6, 0)
            root.AssemblyLinearVelocity = Vector3.zero
        end
    end
end

-- ============================================================================
-- SAFE BEHIND TP (SINGLE EXECUTE TRIGGER)
-- ============================================================================
function Movement:ExecuteBehindTP(config: any, combatService: any): (boolean, string?)
    local myChar = LocalPlayer.Character
    if not myChar then return false, "Karakter hazır değil" end
    local myRoot = myChar:FindFirstChild("HumanoidRootPart") or myChar:FindFirstChild("Torso")
    local myHum = myChar:FindFirstChildOfClass("Humanoid")
    if not myRoot or not myHum or myHum.Health <= 0 then
        return false, "Karakter hazır değil"
    end

    local target = combatService and (combatService.CurrentTarget or combatService:GetTarget(config))
    if not target then
        local bestDist = 300
        local bestPlayer = nil
        for _, p in ipairs(Players:GetPlayers()) do
            if p ~= LocalPlayer and p.Character then
                local r = p.Character:FindFirstChild("HumanoidRootPart") or p.Character:FindFirstChild("Torso")
                local h = p.Character:FindFirstChildOfClass("Humanoid")
                if r and h and h.Health > 0 then
                    local d = (r.Position - (myRoot :: BasePart).Position).Magnitude
                    if d < bestDist then
                        bestDist = d
                        bestPlayer = p
                    end
                end
            end
        end
        target = bestPlayer
    end

    if not target or not target.Character then
        return false, "Hedef oyuncu bulunamadı"
    end

    local tChar = target.Character
    local tRoot = tChar:FindFirstChild("HumanoidRootPart") or tChar:FindFirstChild("Torso")
    local tHum = tChar:FindFirstChildOfClass("Humanoid")
    if not tRoot or not tHum or tHum.Health <= 0 then
        return false, "Hedef geçersiz"
    end

    -- Disable collision on body to prevent physics push
    for _, part in ipairs(myChar:GetChildren()) do
        if part:IsA("BasePart") then
            part.CanCollide = false
        end
    end

    local targetCF = (tRoot :: BasePart).CFrame
    local lookDir = targetCF.LookVector
    -- 100% Horizontal Flat Vector (Prevents sinking when enemy looks down)
    local flatLook = Vector3.new(lookDir.X, 0, lookDir.Z)
    flatLook = (flatLook.Magnitude > 0.001) and flatLook.Unit or Vector3.new(0, 0, -1)

    local behindDist = (config.Target and config.Target.BehindDistance) or 3.5
    local behindPos = (tRoot :: BasePart).Position - (flatLook * behindDist) + Vector3.new(0, 0.2, 0)
    local targetFacePos = (tRoot :: BasePart).Position + Vector3.new(0, 0.2, 0)

    pcall(function()
        (myRoot :: BasePart).AssemblyLinearVelocity = Vector3.zero
        (myRoot :: BasePart).AssemblyAngularVelocity = Vector3.zero
        (myRoot :: BasePart).CFrame = CFrame.lookAt(behindPos, targetFacePos)
    end)

    if config.Target and config.Target.AutoM1OnTP then
        SafeAttackM1()
    end

    self.LastBehindTPTick = os.clock()
    return true, target.Name
end

-- ============================================================================
-- CONTINUOUS SAFE BEHIND LOCK (GLUED TO ENEMY'S BACK, 100% ROTATION TRACKING)
-- ============================================================================
function Movement:UpdateBehindLock(dt: number, config: any, combatService: any)
    if not config.Target or not config.Target.BehindTP then return end

    local myChar = LocalPlayer.Character
    if not myChar then return end
    local myRoot = myChar:FindFirstChild("HumanoidRootPart") or myChar:FindFirstChild("Torso")
    local myHum = myChar:FindFirstChildOfClass("Humanoid")
    if not myRoot or not myHum or myHum.Health <= 0 then
        return
    end

    local hState = myHum:GetState()
    if hState == Enum.HumanoidStateType.Dead or hState == Enum.HumanoidStateType.Physics then
        return
    end

    local target = combatService and (combatService.CurrentTarget or combatService:GetTarget(config))
    if not target or not target.Parent then return end

    local tChar = target.Character
    if not tChar then return end
    local tRoot = tChar:FindFirstChild("HumanoidRootPart") or tChar:FindFirstChild("Torso")
    local tHum = tChar:FindFirstChildOfClass("Humanoid")
    if not tRoot or not tHum or tHum.Health <= 0 then
        if combatService then
            combatService.CurrentTarget = nil
            target = combatService:GetTarget(config)
            tChar = target and target.Character
            tRoot = tChar and (tChar:FindFirstChild("HumanoidRootPart") or tChar:FindFirstChild("Torso"))
        end
        if not tRoot then return end
    end

    -- Disable collision on body to prevent physics glitches
    for _, part in ipairs(myChar:GetChildren()) do
        if part:IsA("BasePart") then
            part.CanCollide = false
        end
    end

    local targetCF = (tRoot :: BasePart).CFrame
    local lookDir = targetCF.LookVector
    -- 100% Horizontal Flat Vector (Never sink into ground)
    local flatLook = Vector3.new(lookDir.X, 0, lookDir.Z)
    if flatLook.Magnitude > 0.001 then
        flatLook = flatLook.Unit
    else
        flatLook = Vector3.new(0, 0, -1)
    end

    local dtStep = (type(dt) == "number" and dt > 0) and dt or 0.016
    local targetVel = (tRoot :: BasePart).AssemblyLinearVelocity or Vector3.zero
    local predictedPos = (tRoot :: BasePart).Position + (targetVel * dtStep)

    local dist = (config.Target and config.Target.BehindDistance) or 3.5
    local behindPos = predictedPos - (flatLook * dist) + Vector3.new(0, 0.2, 0)
    local targetFacePos = predictedPos + Vector3.new(0, 0.2, 0)

    pcall(function()
        (myRoot :: BasePart).AssemblyLinearVelocity = Vector3.zero
        (myRoot :: BasePart).AssemblyAngularVelocity = Vector3.zero
        (myRoot :: BasePart).CFrame = CFrame.lookAt(behindPos, targetFacePos)
    end)

    -- Continuous Auto-M1 strike while locked behind
    if config.Target and config.Target.AutoM1OnTP then
        local now = os.clock()
        local delay = (config.Combat and config.Combat.AutoM1Delay) or 0.12
        if (now - (self.LastBehindAttackTick or 0)) >= delay then
            self.LastBehindAttackTick = now
            SafeAttackM1()
        end
    end
end

-- ============================================================================
-- INFINITE JUMP / DOUBLE JUMP (Event-Driven, Maid-Managed, Respawn-Safe)
-- ============================================================================
function Movement:ToggleJumpFeatures(config: any)
    -- Always clean up previous connections first (idempotent)
    if self._jumpMaid then
        self._jumpMaid:DoCleaning()
        self._jumpMaid = nil
    end

    local infiniteJump = config.Movement.InfiniteJump
    local doubleJump = config.Movement.DoubleJump
    if not infiniteJump and not doubleJump then return end

    self._jumpMaid = Maid.new()
    local maid = self._jumpMaid

    local function HookCharacter(char: Model?)
        if not char then return end
        local charMaid = Maid.new()
        maid:GiveTask(function() charMaid:DoCleaning() end)

        local hum = char:WaitForChild("Humanoid", 5) :: Humanoid?
        if not hum then return end

        -- InfiniteJump: on JumpRequest while landed, allow normal jump; prevents stuck state
        if infiniteJump then
            charMaid:GiveTask(UserInputService.JumpRequest:Connect(function()
                if not config.Movement.InfiniteJump then return end
                local h = char:FindFirstChildOfClass("Humanoid")
                if h and h.Health > 0 then
                    -- Allow jump from any grounded or falling state
                    local st = h:GetState()
                    if st == Enum.HumanoidStateType.Landed
                        or st == Enum.HumanoidStateType.Running
                        or st == Enum.HumanoidStateType.Freefall then
                        h:ChangeState(Enum.HumanoidStateType.Jumping)
                    end
                end
            end))
        end

        -- DoubleJump: grant one extra jump per airborne cycle
        if doubleJump then
            local isAirborne = false
            local djUsed = false

            charMaid:GiveTask(hum.StateChanged:Connect(function(_, newState)
                if newState == Enum.HumanoidStateType.Freefall then
                    isAirborne = true
                elseif newState == Enum.HumanoidStateType.Landed
                    or newState == Enum.HumanoidStateType.Running then
                    isAirborne = false
                    djUsed = false
                end
            end))

            charMaid:GiveTask(UserInputService.JumpRequest:Connect(function()
                if not config.Movement.DoubleJump then return end
                if isAirborne and not djUsed then
                    local h = char:FindFirstChildOfClass("Humanoid")
                    if h and h.Health > 0 then
                        djUsed = true
                        h:ChangeState(Enum.HumanoidStateType.Jumping)
                    end
                end
            end))
        end
    end

    -- Hook current character
    local char = LocalPlayer.Character
    if char then
        task.spawn(HookCharacter, char)
    end

    -- Hook future respawns
    maid:GiveTask(LocalPlayer.CharacterAdded:Connect(function(newChar)
        task.spawn(HookCharacter, newChar)
    end))
end

-- Called by Bootstrap/FeatureManager on config change or toggle
function Movement:RefreshJumpFeatures(config: any)
    self:ToggleJumpFeatures(config)
end

function Movement:Destroy()
    if self._jumpMaid then
        self._jumpMaid:DoCleaning()
        self._jumpMaid = nil
    end
end

return Movement
