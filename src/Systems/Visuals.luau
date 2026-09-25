--!strict
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local LocalPlayer = Players.LocalPlayer

local Visuals = {}
Visuals.__index = Visuals

export type PlayerVisuals = {
    Highlight: Highlight?,
    Billboard: BillboardGui?,
    HpBar: Frame?,
    NameLabel: TextLabel?,
    DistLabel: TextLabel?,
    BadgeLabel: TextLabel?,
}

function Visuals.new(deps: { Cache: any, ObjectPool: any, Logger: any })
    local self = setmetatable({
        _cache = deps.Cache,
        _logger = deps.Logger,
        _playerVisuals = {} :: { [Player]: PlayerVisuals },
        _connections = {} :: { [Player]: { RBXScriptConnection } },
    }, Visuals)

    self:InitPlayerHooks()
    return self
end

function Visuals:InitPlayerHooks()
    local function HookPlayer(p: Player)
        if p == LocalPlayer then return end
        self._connections[p] = {}

        local function OnCharAdded(c: Model)
            self:CleanupPlayerVisuals(p)
        end

        local function OnCharRemoving(c: Model)
            self:CleanupPlayerVisuals(p)
        end

        if p.Character then
            OnCharAdded(p.Character)
        end

        table.insert(self._connections[p], p.CharacterAdded:Connect(OnCharAdded))
        table.insert(self._connections[p], p.CharacterRemoving:Connect(OnCharRemoving))
    end

    for _, p in ipairs(Players:GetPlayers()) do
        HookPlayer(p)
    end

    Players.PlayerAdded:Connect(HookPlayer)
    Players.PlayerRemoving:Connect(function(p)
        self:CleanupPlayerVisuals(p)
        if self._connections[p] then
            for _, conn in ipairs(self._connections[p]) do
                pcall(function() conn:Disconnect() end)
            end
            self._connections[p] = nil
        end
    end)
end

function Visuals:CleanupPlayerVisuals(p: Player)
    local vis = self._playerVisuals[p]
    if vis then
        if vis.Highlight and vis.Highlight.Parent then
            pcall(function() vis.Highlight:Destroy() end)
        end
        if vis.Billboard and vis.Billboard.Parent then
            pcall(function() vis.Billboard:Destroy() end)
        end
        self._playerVisuals[p] = nil
    end
end

function Visuals:CreateBillboard(player: Player, char: Model, headOrRoot: BasePart): BillboardGui
    local bg = Instance.new("BillboardGui")
    bg.Name = "TSB_ESP_" .. player.UserId
    bg.Adornee = headOrRoot
    bg.Size = UDim2.new(0, 150, 0, 48)
    bg.StudsOffset = Vector3.new(0, 3.2, 0)
    bg.AlwaysOnTop = true
    bg.ResetOnSpawn = false

    local rootFrame = Instance.new("Frame")
    rootFrame.Size = UDim2.new(1, 0, 1, 0)
    rootFrame.BackgroundTransparency = 1
    rootFrame.Parent = bg

    local nameLbl = Instance.new("TextLabel")
    nameLbl.Name = "NameLabel"
    nameLbl.Size = UDim2.new(1, 0, 0, 16)
    nameLbl.Position = UDim2.new(0, 0, 0, 0)
    nameLbl.BackgroundTransparency = 1
    nameLbl.Text = player.DisplayName or player.Name
    nameLbl.TextColor3 = Color3.fromRGB(255, 255, 255)
    nameLbl.TextStrokeTransparency = 0.2
    nameLbl.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
    nameLbl.TextSize = 12
    nameLbl.Font = Enum.Font.GothamBold
    nameLbl.Parent = rootFrame

    local badgeLbl = Instance.new("TextLabel")
    badgeLbl.Name = "BadgeLabel"
    badgeLbl.Size = UDim2.new(1, 0, 0, 14)
    badgeLbl.Position = UDim2.new(0, 0, 0, 16)
    badgeLbl.BackgroundTransparency = 1
    badgeLbl.Text = ""
    badgeLbl.TextColor3 = Color3.fromRGB(255, 215, 0)
    badgeLbl.TextStrokeTransparency = 0.3
    badgeLbl.TextSize = 10
    badgeLbl.Font = Enum.Font.GothamMedium
    badgeLbl.Parent = rootFrame

    local hpBg = Instance.new("Frame")
    hpBg.Name = "HpBg"
    hpBg.Size = UDim2.new(0.85, 0, 0, 5)
    hpBg.Position = UDim2.new(0.075, 0, 0, 34)
    hpBg.BackgroundColor3 = Color3.fromRGB(20, 20, 25)
    hpBg.BorderSizePixel = 0
    hpBg.Parent = rootFrame
    Instance.new("UICorner", hpBg).CornerRadius = UDim.new(1, 0)

    local hpBar = Instance.new("Frame")
    hpBar.Name = "HpBar"
    hpBar.Size = UDim2.new(1, 0, 1, 0)
    hpBar.BackgroundColor3 = Color3.fromRGB(0, 230, 120)
    hpBar.BorderSizePixel = 0
    hpBar.Parent = hpBg
    Instance.new("UICorner", hpBar).CornerRadius = UDim.new(1, 0)

    local distLbl = Instance.new("TextLabel")
    distLbl.Name = "DistLabel"
    distLbl.Size = UDim2.new(1, 0, 0, 12)
    distLbl.Position = UDim2.new(0, 0, 0, 40)
    distLbl.BackgroundTransparency = 1
    distLbl.Text = "0m"
    distLbl.TextColor3 = Color3.fromRGB(180, 185, 200)
    distLbl.TextStrokeTransparency = 0.4
    distLbl.TextSize = 9
    distLbl.Font = Enum.Font.Gotham
    distLbl.Parent = rootFrame

    bg.Parent = char
    return bg
end

function Visuals:Update(config: any)
    local myEntry = self._cache:GetPlayerEntry(LocalPlayer)
    local myPos = (myEntry and myEntry.RootPart and myEntry.RootPart.Position) or Vector3.zero

    local hlEnabled = config.Visuals and config.Visuals.HighlightESP
    local bbEnabled = config.Visuals and config.Visuals.BillboardESP

    for _, player in ipairs(Players:GetPlayers()) do
        if player == LocalPlayer then continue end

        local entry = self._cache:GetPlayerEntry(player)
        local char = (entry and entry.Character) or player.Character
        local hum = (entry and entry.Humanoid) or (char and char:FindFirstChildOfClass("Humanoid"))
        local root = (entry and entry.RootPart) or (char and (char:FindFirstChild("HumanoidRootPart") or char:FindFirstChild("Torso")))
        local isAlive = (char and hum and root and hum.Health > 0 and char.Parent ~= nil)

        if isAlive and char and root and hum then
            local vis = self._playerVisuals[player]
            if not vis then
                vis = {
                    Highlight = nil,
                    Billboard = nil,
                    HpBar = nil,
                    NameLabel = nil,
                    DistLabel = nil,
                    BadgeLabel = nil,
                }
                self._playerVisuals[player] = vis
            end

            -- Check TSB attributes for real-time status indicators
            local isCounter = false
            local isUlt = false
            local charName = tostring(char:GetAttribute("Character") or "")
            if #charName > 0 then charName = "[" .. charName .. "] " end

            if char:GetAttribute("HoldingDeathCounter") or char:GetAttribute("HoldingFlowingWater") or char:GetAttribute("HoldingPreysPeril") or char:GetAttribute("HoldingGodSlayer") then
                isCounter = true
            end
            if char:GetAttribute("Ulted") or char:GetAttribute("JustUlted") or char:GetAttribute("UltimateName") then
                isUlt = true
            end

            -- 1. HIGHLIGHT CHAMS ESP
            if hlEnabled then
                local hl = vis.Highlight
                if not hl or not hl.Parent or hl.Adornee ~= char then
                    if hl and hl.Parent then hl:Destroy() end
                    hl = Instance.new("Highlight")
                    hl.Name = "TSB_HL_" .. player.UserId
                    hl.Adornee = char
                    hl.FillTransparency = 0.45
                    hl.OutlineTransparency = 0.1
                    hl.Parent = char
                    vis.Highlight = hl
                end

                -- Dynamic Color Coding
                if isCounter then
                    hl.FillColor = Color3.fromRGB(255, 30, 60)
                    hl.OutlineColor = Color3.fromRGB(255, 230, 0)
                elseif isUlt then
                    hl.FillColor = Color3.fromRGB(255, 190, 0)
                    hl.OutlineColor = Color3.fromRGB(255, 255, 255)
                else
                    hl.FillColor = Color3.fromRGB(0, 200, 255)
                    hl.OutlineColor = Color3.fromRGB(255, 255, 255)
                end
            else
                if vis.Highlight then
                    pcall(function() vis.Highlight:Destroy() end)
                    vis.Highlight = nil
                end
            end

            -- 2. BILLBOARD STATUS ESP
            if bbEnabled then
                local bb = vis.Billboard
                local targetPart = char:FindFirstChild("Head") or root
                if not bb or not bb.Parent or bb.Adornee ~= targetPart then
                    if bb and bb.Parent then bb:Destroy() end
                    bb = self:CreateBillboard(player, char, targetPart :: BasePart)
                    vis.Billboard = bb
                    vis.NameLabel = bb:FindFirstChild("NameLabel", true) :: TextLabel?
                    vis.DistLabel = bb:FindFirstChild("DistLabel", true) :: TextLabel?
                    vis.BadgeLabel = bb:FindFirstChild("BadgeLabel", true) :: TextLabel?
                    vis.HpBar = bb:FindFirstChild("HpBar", true) :: Frame?
                end

                -- Update dynamic overhead labels
                local dist = math.floor((root.Position - myPos).Magnitude)
                local hpPct = math.clamp(hum.Health / math.max(hum.MaxHealth, 1), 0, 1)

                if vis.NameLabel then
                    vis.NameLabel.Text = charName .. (player.DisplayName or player.Name)
                end

                if vis.DistLabel then
                    vis.DistLabel.Text = string.format("%dm", dist)
                end

                if vis.HpBar then
                    vis.HpBar.Size = UDim2.new(hpPct, 0, 1, 0)
                    if hpPct > 0.6 then
                        vis.HpBar.BackgroundColor3 = Color3.fromRGB(0, 230, 120)
                    elseif hpPct > 0.3 then
                        vis.HpBar.BackgroundColor3 = Color3.fromRGB(255, 200, 0)
                    else
                        vis.HpBar.BackgroundColor3 = Color3.fromRGB(255, 45, 60)
                    end
                end

                if vis.BadgeLabel then
                    if isCounter then
                        vis.BadgeLabel.Text = "⚠️ COUNTER RISK"
                        vis.BadgeLabel.TextColor3 = Color3.fromRGB(255, 45, 60)
                    elseif isUlt then
                        vis.BadgeLabel.Text = "⚡ ULT ACTIVE"
                        vis.BadgeLabel.TextColor3 = Color3.fromRGB(255, 215, 0)
                    elseif char:GetAttribute("Blocking") then
                        vis.BadgeLabel.Text = "🛡️ BLOCKING"
                        vis.BadgeLabel.TextColor3 = Color3.fromRGB(80, 180, 255)
                    else
                        vis.BadgeLabel.Text = ""
                    end
                end
            else
                if vis.Billboard then
                    pcall(function() vis.Billboard:Destroy() end)
                    vis.Billboard = nil
                end
            end
        else
            -- Clean up if dead or despawned
            self:CleanupPlayerVisuals(player)
        end
    end
end

function Visuals:Destroy()
    for p, _ in pairs(self._playerVisuals) do
        self:CleanupPlayerVisuals(p)
    end
    for _, conns in pairs(self._connections) do
        for _, c in ipairs(conns) do
            pcall(function() c:Disconnect() end)
        end
    end
    self._playerVisuals = {}
    self._connections = {}
end

return Visuals
