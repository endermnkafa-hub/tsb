--!strict
-- =============================================================================
-- TelemetryRecorder v10.0 — Comprehensive Multi-Category Data Collector
-- Normalized, deduplicated, multi-file persistent dataset for all players.
-- =============================================================================
local Players    = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local LocalPlayer = Players.LocalPlayer

local TelemetryRecorder = {}
TelemetryRecorder.__index = TelemetryRecorder

-- ============================================================================
-- HELPERS
-- ============================================================================
local function countKeys(t: any): number
    local n = 0
    for _ in pairs(t) do n += 1 end
    return n
end

local function setAdd(s: {[string]: boolean}, val: string)
    s[val] = true
end

local function isBehavioral(name: string): boolean
    local n = name:lower()
    return n:find("holding") ~= nil
        or n:find("blocking") ~= nil
        or n:find("skill") ~= nil
        or n:find("ulted") ~= nil
        or n:find("state") ~= nil
        or n:find("counter") ~= nil
        or n:find("dash") ~= nil
        or n:find("hurt") ~= nil
        or n:find("ragdoll") ~= nil
        or n:find("stun") ~= nil
end

local function getCharType(char: any): string
    if char then
        local attr = char:GetAttribute("Character")
        if type(attr) == "string" and #attr > 0 then return attr end
        return char.Name or "Unknown"
    end
    return "Unknown"
end

local function getRigType(char: any): string
    if char and char:FindFirstChild("UpperTorso") then
        return "R15"
    end
    return "R6"
end

local function getPath(inst: Instance): string
    local parts = {}
    local cur: Instance? = inst
    while cur and cur ~= game do
        table.insert(parts, 1, cur.Name)
        cur = cur.Parent
    end
    return table.concat(parts, ".")
end

local function JSONEncode(data: any): string
    local ok, result = pcall(function() return HttpService:JSONEncode(data) end)
    if ok then return result end
    return "{}"
end

local function JSONDecode(raw: string): any
    local ok, result = pcall(function() return HttpService:JSONDecode(raw) end)
    if ok then return result end
    return nil
end

local function safeReadFile(path: string): string?
    local ok, result = pcall(function()
        if isfile and isfile(path) then
            return readfile(path)
        end
    end)
    if ok then return result end
    return nil
end

local function safeWriteFile(path: string, content: string)
    pcall(function()
        if writefile then writefile(path, content) end
    end)
end

local function safeMakeFolder(path: string)
    pcall(function()
        if makefolder then makefolder(path) end
    end)
end

-- ============================================================================
-- CONSTRUCTOR
-- ============================================================================
function TelemetryRecorder.new(deps: { Logger: any, EventBus: any })
    local self = setmetatable({
        _logger    = deps.Logger,
        _eventBus  = deps.EventBus,

        -- Multi-category normalized data store
        Data = {
            Meta = {
                Version           = "10.0",
                Created           = os.time(),
                LastUpdated       = os.time(),
                TotalSessions     = 1,
                FrameworkVersion  = "9.0-SPECIALIST-PRODUCTION",
            },
            Animations    = {},
            Characters    = {},
            Hitboxes      = {},
            Attributes    = {},
            Correlations  = {},
            CombatEvents  = {},  -- ring buffer
            Cooldowns     = {},
            Sounds        = {},
            Tools         = {},
            Remotes       = {},
            World         = {},
        },

        _connections      = {},
        _playerTrackers   = {},  -- per-player state for correlation/cooldown
        _notifThrottle    = {},  -- key → last notif time
        _isDirty          = false,
        _lastSaveTick     = 0,
        _sessionStart     = os.clock(),
        _isRecording      = false,
        _maxCombatEvents  = 1000,  -- overwritten from config in Update
        _lastRemoteScan   = 0,
    }, TelemetryRecorder)

    return self
end

-- ============================================================================
-- NOTIFICATION THROTTLE
-- ============================================================================
function TelemetryRecorder:SendNotification(key: string, title: string, msg: string, duration: number?, kind: any?)
    local now = os.clock()
    if (now - (self._notifThrottle[key] or 0)) < 2 then return end
    self._notifThrottle[key] = now
    self._eventBus:Publish("Notification.Show", title, msg, duration or 3.0, kind or "Info")
end

-- ============================================================================
-- ANIMATION RECORDING
-- ============================================================================
function TelemetryRecorder:RecordAnimation(track: AnimationTrack, player: Player, char: any)
    if not track or not track.Animation then return end
    local animId = tostring(track.Animation.AnimationId or "")
    if animId == "" or animId == "0" then return end

    local charType = getCharType(char)
    local playerName = player.Name

    local now = os.time()
    local record = self.Data.Animations[animId]
    if not record then
        record = {
            Id              = animId,
            RawUrl          = animId,
            Name            = track.Name or "",
            Length          = track.Length or 0,
            Priority        = tostring(track.Priority or ""),
            Looped          = track.Looped or false,
            Speed           = track.Speed or 1,
            FirstSeen       = now,
            LastSeen        = now,
            PlayCount       = 0,
            TotalPlaytime   = 0,
            PlayersSeen     = {},
            CharactersSeen  = {},
        }
        self.Data.Animations[animId] = record
        self:SendNotification("anim_new", "📊 New Animation", "Discovered: " .. (track.Name or animId:sub(-12)), 2.5, "Info")
    end

    record.PlayCount += 1
    record.LastSeen = now
    record.TotalPlaytime += (track.Length or 0)
    setAdd(record.PlayersSeen, playerName)
    setAdd(record.CharactersSeen, charType)

    -- Link to character profile
    if self.Data.Characters[charType] then
        setAdd(self.Data.Characters[charType].AnimationsSeen, animId)
    end

    self._isDirty = true
end

-- ============================================================================
-- CHARACTER PROFILE RECORDING
-- ============================================================================
function TelemetryRecorder:RecordCharacterProfile(char: any, player: Player)
    if not char then return end
    local charType = getCharType(char)
    local rigType = getRigType(char)
    local now = os.time()

    local record = self.Data.Characters[charType]
    if not record then
        local attrList = {}
        pcall(function()
            for attrName, _ in pairs(char:GetAttributes()) do
                attrList[attrName] = true
            end
        end)
        record = {
            CharacterType  = charType,
            RigType        = rigType,
            PartCount      = 0,
            Attributes     = attrList,
            AnimationsSeen = {},
            FirstSeen      = now,
            LastSeen       = now,
            ObservedCount  = 0,
            PlayersSeen    = {},
        }
        self.Data.Characters[charType] = record
        self:SendNotification("char_" .. charType, "🎭 New Character", "Profiled: " .. charType .. " (" .. rigType .. ")", 3.0, "Info")
    end

    record.ObservedCount += 1
    record.LastSeen = now
    setAdd(record.PlayersSeen, player.Name)

    -- Update part count
    local partCount = 0
    pcall(function()
        for _, desc in ipairs(char:GetDescendants()) do
            if desc:IsA("BasePart") then partCount += 1 end
        end
    end)
    record.PartCount = partCount

    self._isDirty = true
end

-- ============================================================================
-- HITBOX PROFILE RECORDING
-- ============================================================================
function TelemetryRecorder:RecordHitboxProfile(char: any, player: Player)
    if not char then return end
    local charType = getCharType(char)
    local rigType = getRigType(char)
    local now = os.time()

    local hrp = char:FindFirstChild("HumanoidRootPart")
    if not hrp then return end
    local hrpPos = hrp.Position

    local record = self.Data.Hitboxes[charType]
    local shouldUpdate = not record or record.SampleCount == 0

    if not record then
        record = {
            CharacterType = charType,
            RigType       = rigType,
            Parts         = {},
            FirstSeen     = now,
            LastSeen      = now,
            SampleCount   = 0,
        }
        self.Data.Hitboxes[charType] = record
    end

    if shouldUpdate then
        -- Record all BaseParts
        pcall(function()
            for _, part in ipairs(char:GetDescendants()) do
                if part:IsA("BasePart") then
                    local rel = part.Position - hrpPos
                    record.Parts[part.Name] = {
                        Size             = { X = part.Size.X, Y = part.Size.Y, Z = part.Size.Z },
                        RelativePosition = { X = math.floor(rel.X * 100) / 100, Y = math.floor(rel.Y * 100) / 100, Z = math.floor(rel.Z * 100) / 100 },
                        CanCollide       = part.CanCollide,
                        Mass             = part.Mass,
                        Transparency     = part.Transparency,
                        Class            = part.ClassName,
                    }
                end
            end
        end)
        self:SendNotification("hitbox_" .. charType, "📐 Hitbox Mapped", charType .. " geometry captured (" .. countKeys(record.Parts) .. " parts)", 2.5, "Success")
    end

    record.SampleCount += 1
    record.LastSeen = now
    self._isDirty = true
end

-- ============================================================================
-- ATTRIBUTE RECORDING + CORRELATION
-- ============================================================================
function TelemetryRecorder:RecordAttribute(attrName: string, value: any, player: Player, char: any)
    if not attrName then return end
    local charType = getCharType(char)
    local now = os.time()

    local record = self.Data.Attributes[attrName]
    if not record then
        record = {
            Name           = attrName,
            ValueType      = typeof(value),
            ObservedValues = {},
            FirstSeen      = now,
            LastSeen       = now,
            ChangeCount    = 0,
            PlayersSeen    = {},
            CharactersSeen = {},
            IsBehavioral   = isBehavioral(attrName),
        }
        self.Data.Attributes[attrName] = record
    end

    record.ChangeCount += 1
    record.LastSeen = now
    setAdd(record.PlayersSeen, player.Name)
    setAdd(record.CharactersSeen, charType)

    -- Normalize observed values (handle different types)
    local valKey = tostring(value)
    if #valKey <= 32 then
        record.ObservedValues[valKey] = true
    end

    -- Track cooldown: time since last change
    if record.IsBehavioral then
        self:TrackCooldown(charType, attrName)
    end

    -- Correlation: check animations playing within 500ms
    self:CheckCorrelation(attrName, player)

    self._isDirty = true
end

-- ============================================================================
-- COOLDOWN ANALYSIS
-- ============================================================================
function TelemetryRecorder:TrackCooldown(charType: string, eventKey: string)
    local now = os.clock()
    local trackerKey = charType .. "_" .. eventKey
    local lastTime = self._playerTrackers[trackerKey]

    if lastTime then
        local interval = now - lastTime
        -- Only meaningful intervals (0.01s to 60s)
        if interval >= 0.01 and interval <= 60 then
            if not self.Data.Cooldowns[charType] then
                self.Data.Cooldowns[charType] = {}
            end
            local cd = self.Data.Cooldowns[charType][eventKey]
            if not cd then
                cd = { Min = math.huge, Max = 0, Avg = 0, Samples = {}, Count = 0 }
                self.Data.Cooldowns[charType][eventKey] = cd
            end
            cd.Count += 1
            if interval < cd.Min then cd.Min = interval end
            if interval > cd.Max then cd.Max = interval end
            table.insert(cd.Samples, math.floor(interval * 1000))  -- store in ms
            if #cd.Samples > 30 then table.remove(cd.Samples, 1) end
            -- Rolling average from samples
            local sum = 0
            for _, s in ipairs(cd.Samples) do sum += s end
            cd.Avg = math.floor(sum / #cd.Samples)
        end
    end
    self._playerTrackers[trackerKey] = now
end

-- ============================================================================
-- CORRELATION DETECTION
-- ============================================================================
function TelemetryRecorder:CheckCorrelation(attrName: string, player: Player)
    if not self.Data.Attributes[attrName] or not self.Data.Attributes[attrName].IsBehavioral then return end

    local char = player.Character
    if not char then return end
    local hum = char:FindFirstChildOfClass("Humanoid")
    if not hum then return end
    local anim = hum:FindFirstChildOfClass("Animator")
    if not anim then return end

    local now = os.time()
    local tracks = {}
    pcall(function() tracks = anim:GetPlayingAnimationTracks() end)

    for _, track in ipairs(tracks) do
        if not track.Animation then continue end
        local animId = tostring(track.Animation.AnimationId or "")
        if animId == "" or animId == "0" then continue end
        local corrKey = animId .. "_" .. attrName
        local corr = self.Data.Correlations[corrKey]
        if not corr then
            corr = {
                AnimationId     = animId,
                AttributeName   = attrName,
                CoOccurrenceCount = 0,
                WindowMs        = 500,
                FirstSeen       = now,
                LastSeen        = now,
            }
            self.Data.Correlations[corrKey] = corr
        end
        corr.CoOccurrenceCount += 1
        corr.LastSeen = now
    end
end

-- ============================================================================
-- COMBAT EVENT RECORDING (ring buffer)
-- ============================================================================
function TelemetryRecorder:RecordCombatEvent(eventType: string, player: Player?, char: any?, details: any?)
    local now = os.time()
    local charType = char and getCharType(char) or "Unknown"
    local playerName = player and player.Name or "Unknown"

    -- Get current animation and position from player
    local currentAnimation = nil
    local position = nil
    local velocity = nil
    pcall(function()
        if char then
            local hrp = char:FindFirstChild("HumanoidRootPart")
            if hrp then
                position = { X = math.floor(hrp.Position.X), Y = math.floor(hrp.Position.Y), Z = math.floor(hrp.Position.Z) }
                velocity = math.floor(hrp.AssemblyLinearVelocity.Magnitude * 10) / 10
            end
            local hum = char:FindFirstChildOfClass("Humanoid")
            local anim = hum and hum:FindFirstChildOfClass("Animator")
            if anim then
                local tracks = anim:GetPlayingAnimationTracks()
                if tracks and #tracks > 0 and tracks[1].Animation then
                    currentAnimation = tostring(tracks[1].Animation.AnimationId)
                end
            end
        end
    end)

    local event = {
        Type             = eventType,
        Timestamp        = now,
        Player           = playerName,
        Character        = charType,
        Position         = position,
        Velocity         = velocity,
        CurrentAnimation = currentAnimation,
        Details          = details or {},
    }

    table.insert(self.Data.CombatEvents, event)
    -- Enforce ring buffer limit
    local maxEv = self._maxCombatEvents
    while #self.Data.CombatEvents > maxEv do
        table.remove(self.Data.CombatEvents, 1)
    end

    self._isDirty = true
end

-- ============================================================================
-- SOUND RECORDING
-- ============================================================================
function TelemetryRecorder:RecordSound(sound: any, player: Player, char: any)
    if not sound or not sound:IsA("Sound") then return end
    local soundId = tostring(sound.SoundId or "")
    if soundId == "" or soundId == "0" then return end
    local charType = getCharType(char)
    local now = os.time()

    local record = self.Data.Sounds[soundId]
    if not record then
        record = {
            Id             = soundId,
            Name           = sound.Name or "",
            Volume         = sound.Volume or 0.5,
            PlaybackSpeed  = sound.PlaybackSpeed or 1,
            CharactersSeen = {},
            PlayersSeen    = {},
            PlayCount      = 0,
            FirstSeen      = now,
            LastSeen       = now,
        }
        self.Data.Sounds[soundId] = record
    end

    record.PlayCount += 1
    record.LastSeen = now
    setAdd(record.CharactersSeen, charType)
    setAdd(record.PlayersSeen, player.Name)
    self._isDirty = true
end

-- ============================================================================
-- TOOL / ACCESSORY / ATTACHMENT RECORDING
-- ============================================================================
function TelemetryRecorder:RecordTool(inst: any, player: Player, char: any)
    if not inst then return end
    local name = inst.Name or "Unknown"
    local class = inst.ClassName or "Unknown"
    local charType = getCharType(char)
    local now = os.time()
    local key = class .. "_" .. name

    local record = self.Data.Tools[key]
    if not record then
        record = {
            Name           = name,
            Class          = class,
            CharactersSeen = {},
            PlayersSeen    = {},
            Count          = 0,
            FirstSeen      = now,
            LastSeen       = now,
        }
        self.Data.Tools[key] = record
    end

    record.Count += 1
    record.LastSeen = now
    setAdd(record.CharactersSeen, charType)
    setAdd(record.PlayersSeen, player.Name)
    self._isDirty = true
end

-- ============================================================================
-- REMOTE DISCOVERY SCAN
-- ============================================================================
function TelemetryRecorder:ScanRemotes()
    local now = os.time()
    local scanTargets = { game:GetService("ReplicatedStorage"), game:GetService("Workspace") }

    for _, root in ipairs(scanTargets) do
        pcall(function()
            for _, desc in ipairs(root:GetDescendants()) do
                if desc:IsA("RemoteEvent") or desc:IsA("RemoteFunction") or desc:IsA("BindableEvent") then
                    local path = getPath(desc)
                    local record = self.Data.Remotes[path]
                    if not record then
                        record = {
                            Name      = desc.Name,
                            Class     = desc.ClassName,
                            Path      = path,
                            FirstSeen = now,
                            LastSeen  = now,
                        }
                        self.Data.Remotes[path] = record
                    else
                        record.LastSeen = now
                    end
                end
            end
        end)
    end

    self._isDirty = true
end

-- ============================================================================
-- HOOK CHARACTER (called for each player's character)
-- ============================================================================
function TelemetryRecorder:HookCharacter(player: Player, char: any)
    if not char then return end
    -- Wait for character to fully load
    local hrp = char:FindFirstChild("HumanoidRootPart")
    if not hrp then
        pcall(function()
            hrp = char:WaitForChild("HumanoidRootPart", 10)
        end)
        if not hrp then return end
    end

    local charType = getCharType(char)

    -- Record static profiles
    self:RecordCharacterProfile(char, player)
    self:RecordHitboxProfile(char, player)

    -- Hook AttributeChanged
    local attrConn = char.AttributeChanged:Connect(function(attrName: string)
        if not self._isRecording then return end
        pcall(function()
            local val = char:GetAttribute(attrName)
            self:RecordAttribute(attrName, val, player, char)
        end)
    end)
    local connKey = "AttrChanged_" .. player.UserId
    if self._connections[connKey] then
        pcall(function() self._connections[connKey]:Disconnect() end)
    end
    self._connections[connKey] = attrConn

    -- Do initial attribute scan
    pcall(function()
        for attrName, val in pairs(char:GetAttributes()) do
            self:RecordAttribute(attrName, val, player, char)
        end
    end)

    -- Hook HealthChanged
    local hum = char:FindFirstChildOfClass("Humanoid")
    if hum then
        local healthConn = hum.HealthChanged:Connect(function(newHp: number)
            if not self._isRecording then return end
            self:RecordCombatEvent("HealthChange", player, char, { HP = math.floor(newHp) })
        end)
        local hKey = "Health_" .. player.UserId
        if self._connections[hKey] then pcall(function() self._connections[hKey]:Disconnect() end) end
        self._connections[hKey] = healthConn

        -- Hook StateChanged for ragdoll events
        local stateConn = hum.StateChanged:Connect(function(_, newState: Enum.HumanoidStateType)
            if not self._isRecording then return end
            if newState == Enum.HumanoidStateType.Physics or newState == Enum.HumanoidStateType.FallingDown then
                self:RecordCombatEvent("RagdollEntered", player, char, { State = tostring(newState) })
            elseif newState == Enum.HumanoidStateType.Running or newState == Enum.HumanoidStateType.Landed then
                self:RecordCombatEvent("RagdollWakeup", player, char, { State = tostring(newState) })
            end
        end)
        local sKey = "State_" .. player.UserId
        if self._connections[sKey] then pcall(function() self._connections[sKey]:Disconnect() end) end
        self._connections[sKey] = stateConn
    end

    -- Hook Animator for animation events
    local anim = hum and hum:FindFirstChildOfClass("Animator")
    if anim then
        local animConn = anim.AnimationPlayed:Connect(function(track: AnimationTrack)
            if not self._isRecording then return end
            pcall(function() self:RecordAnimation(track, player, char) end)
        end)
        local aKey = "Anim_" .. player.UserId
        if self._connections[aKey] then pcall(function() self._connections[aKey]:Disconnect() end) end
        self._connections[aKey] = animConn
    end

    -- Hook DescendantAdded for sounds and tools
    local descConn = char.DescendantAdded:Connect(function(desc: Instance)
        if not self._isRecording then return end
        pcall(function()
            if desc:IsA("Sound") then
                self:RecordSound(desc, player, char)
            elseif desc:IsA("Tool") or desc:IsA("Accessory") then
                self:RecordTool(desc, player, char)
            end
        end)
    end)
    local dKey = "Desc_" .. player.UserId
    if self._connections[dKey] then pcall(function() self._connections[dKey]:Disconnect() end) end
    self._connections[dKey] = descConn

    -- Scan existing descendants
    pcall(function()
        for _, desc in ipairs(char:GetDescendants()) do
            if desc:IsA("Sound") then
                self:RecordSound(desc, player, char)
            elseif desc:IsA("Tool") or desc:IsA("Accessory") then
                self:RecordTool(desc, player, char)
            end
        end
    end)
end

-- ============================================================================
-- INIT HOOKS (called once at startup)
-- ============================================================================
function TelemetryRecorder:InitHooks()
    -- Hook existing players
    for _, p in ipairs(Players:GetPlayers()) do
        if p.Character then
            task.spawn(function() self:HookCharacter(p, p.Character) end)
        end
        local charAddedKey = "CharAdded_" .. tostring(p.UserId)
        self._connections[charAddedKey] = p.CharacterAdded:Connect(function(char)
            task.spawn(function() self:HookCharacter(p, char) end)
        end)
    end

    -- Hook newly joined players
    self._connections["PlayerAdded"] = Players.PlayerAdded:Connect(function(p)
        local charAddedKey = "CharAdded_" .. tostring(p.UserId)
        self._connections[charAddedKey] = p.CharacterAdded:Connect(function(char)
            task.spawn(function() self:HookCharacter(p, char) end)
        end)
    end)

    self._connections["PlayerRemoving"] = Players.PlayerRemoving:Connect(function(p)
        self._playerTrackers["target_" .. p.Name] = nil
        local charAddedKey = "CharAdded_" .. tostring(p.UserId)
        if self._connections[charAddedKey] then
            pcall(function() self._connections[charAddedKey]:Disconnect() end)
            self._connections[charAddedKey] = nil
        end
    end)

    -- Initial remote scan
    task.spawn(function() self:ScanRemotes() end)
end

-- ============================================================================
-- LOAD FROM DISK (multi-file first, single file fallback)
-- ============================================================================
function TelemetryRecorder:LoadFromDisk()
    -- Try multi-file first
    local metaRaw = safeReadFile("tsb_data/metadata.json")
    if metaRaw then
        local categories = {
            "metadata", "animations", "characters", "hitboxes",
            "attributes", "combat_events", "cooldowns", "sounds", "tools", "remotes"
        }
        local dataMap = {
            metadata      = "Meta",
            animations    = "Animations",
            characters    = "Characters",
            hitboxes      = "Hitboxes",
            attributes    = "Attributes",
            combat_events = "CombatEvents",
            cooldowns     = "Cooldowns",
            sounds        = "Sounds",
            tools         = "Tools",
            remotes       = "Remotes",
        }
        local loaded = false
        for _, cat in ipairs(categories) do
            local raw = safeReadFile("tsb_data/" .. cat .. ".json")
            if raw then
                local decoded = JSONDecode(raw)
                if decoded and type(decoded) == "table" then
                    local key = dataMap[cat]
                    if key then
                        if cat == "metadata" then
                            -- Merge meta: preserve session count
                            if type(decoded.TotalSessions) == "number" then
                                self.Data.Meta.TotalSessions = decoded.TotalSessions + 1
                            end
                            if type(decoded.Created) == "number" then
                                self.Data.Meta.Created = decoded.Created
                            end
                        elseif cat == "combat_events" then
                            if type(decoded) == "table" then
                                for _, ev in ipairs(decoded) do
                                    table.insert(self.Data.CombatEvents, ev)
                                end
                                -- Trim to max
                                while #self.Data.CombatEvents > self._maxCombatEvents do
                                    table.remove(self.Data.CombatEvents, 1)
                                end
                            end
                        else
                            -- Merge into existing data table
                            for k, v in pairs(decoded) do
                                if self.Data[key] then
                                    self.Data[key][k] = v
                                end
                            end
                        end
                        loaded = true
                    end
                end
            end
        end
        if loaded then
            self._logger:Info("TelemetryRecorder", "Loaded multi-file dataset from tsb_data/")
            return
        end
    end

    -- Fallback: single combined file
    local raw = safeReadFile("tsb_combat_data.json")
    if not raw then return end
    local decoded = JSONDecode(raw)
    if not decoded or type(decoded) ~= "table" then return end

    -- Merge each category
    for key, tbl in pairs(decoded) do
        if self.Data[key] and type(tbl) == "table" then
            if key == "Meta" then
                if type(tbl.TotalSessions) == "number" then
                    self.Data.Meta.TotalSessions = tbl.TotalSessions + 1
                end
            elseif key == "CombatEvents" then
                for _, ev in ipairs(tbl) do
                    table.insert(self.Data.CombatEvents, ev)
                end
            else
                for k, v in pairs(tbl) do
                    self.Data[key][k] = v
                end
            end
        end
    end

    self._logger:Info("TelemetryRecorder", "Loaded single-file dataset from tsb_combat_data.json")
end

-- ============================================================================
-- SAVE TO DISK (multi-file + combined fallback)
-- ============================================================================
function TelemetryRecorder:SaveToDisk(force: boolean?)
    if not force and not self._isDirty then return end
    self.Data.Meta.LastUpdated = os.time()

    -- Try multi-file save
    local multiOk = false
    pcall(function()
        if writefile and makefolder then
            safeMakeFolder("tsb_data")
            safeWriteFile("tsb_data/metadata.json", JSONEncode(self.Data.Meta))
            safeWriteFile("tsb_data/animations.json", JSONEncode(self.Data.Animations))
            safeWriteFile("tsb_data/characters.json", JSONEncode(self.Data.Characters))
            safeWriteFile("tsb_data/hitboxes.json", JSONEncode(self.Data.Hitboxes))
            safeWriteFile("tsb_data/attributes.json", JSONEncode(self.Data.Attributes))
            safeWriteFile("tsb_data/combat_events.json", JSONEncode(self.Data.CombatEvents))
            safeWriteFile("tsb_data/cooldowns.json", JSONEncode(self.Data.Cooldowns))
            safeWriteFile("tsb_data/sounds.json", JSONEncode(self.Data.Sounds))
            safeWriteFile("tsb_data/tools.json", JSONEncode(self.Data.Tools))
            safeWriteFile("tsb_data/remotes.json", JSONEncode(self.Data.Remotes))
            multiOk = true
        end
    end)

    -- Always also save combined file for backward compat
    safeWriteFile("tsb_combat_data.json", JSONEncode(self.Data))

    self._isDirty = false
    self._lastSaveTick = os.clock()
    self._logger:Debug("TelemetryRecorder", string.format("Saved dataset (multi=%s) — Anims:%d Chars:%d Attrs:%d Events:%d",
        tostring(multiOk),
        countKeys(self.Data.Animations),
        countKeys(self.Data.Characters),
        countKeys(self.Data.Attributes),
        #self.Data.CombatEvents
    ))
end

-- ============================================================================
-- UPDATE (called from scheduler)
-- ============================================================================
function TelemetryRecorder:Update(dt: number, config: any)
    local cfg = config and config.Telemetry
    if not cfg then return end

    self._isRecording = cfg.AutoRecordData ~= false
    self._maxCombatEvents = cfg.MaxCombatEvents or 1000

    -- Periodic remote scan (every 30s)
    local now = os.clock()
    if cfg.RecordRemotes ~= false and (now - self._lastRemoteScan) >= 30 then
        self._lastRemoteScan = now
        task.spawn(function() self:ScanRemotes() end)
    end

    -- Periodic animation scan for players (catch missed AnimationPlayed events)
    if self._isRecording and cfg.RecordAnimations ~= false then
        for _, p in ipairs(Players:GetPlayers()) do
            local char = p.Character
            if not char then continue end
            local hum = char:FindFirstChildOfClass("Humanoid")
            local anim = hum and hum:FindFirstChildOfClass("Animator")
            if anim then
                pcall(function()
                    for _, track in ipairs(anim:GetPlayingAnimationTracks()) do
                        if track.IsPlaying and track.Animation then
                            local animId = tostring(track.Animation.AnimationId or "")
                            if animId ~= "" and animId ~= "0" and not self.Data.Animations[animId] then
                                self:RecordAnimation(track, p, char)
                            end
                        end
                    end
                end)
            end
        end
    end

    -- Autosave
    local interval = cfg.AutoSaveInterval or 15
    if (now - self._lastSaveTick) >= interval then
        self:SaveToDisk(false)
    end
end

-- ============================================================================
-- STATS / EXPORT
-- ============================================================================
function TelemetryRecorder:GetStats(): any
    return {
        TotalAnimations       = countKeys(self.Data.Animations),
        TotalCharacters       = countKeys(self.Data.Characters),
        TotalHitboxProfiles   = countKeys(self.Data.Hitboxes),
        TotalAttributes       = countKeys(self.Data.Attributes),
        TotalCorrelations     = countKeys(self.Data.Correlations),
        TotalCombatEvents     = #self.Data.CombatEvents,
        TotalCooldownProfiles = countKeys(self.Data.Cooldowns),
        TotalSounds           = countKeys(self.Data.Sounds),
        TotalTools            = countKeys(self.Data.Tools),
        TotalRemotes          = countKeys(self.Data.Remotes),
        LastSaved             = self._lastSaveTick,
        IsRecording           = self._isRecording,
        SessionDuration       = os.clock() - self._sessionStart,
        SessionNumber         = self.Data.Meta.TotalSessions,
    }
end

function TelemetryRecorder:ExportSummary(): string
    local s = self:GetStats()
    return string.format(
        "=== TSB Data Collector v10.0 ===\nSession #%d | Runtime: %.0fs\nAnimations: %d | Characters: %d | Hitboxes: %d\nAttributes: %d | Correlations: %d | Events: %d\nCooldowns: %d | Sounds: %d | Tools: %d | Remotes: %d",
        s.SessionNumber, s.SessionDuration,
        s.TotalAnimations, s.TotalCharacters, s.TotalHitboxProfiles,
        s.TotalAttributes, s.TotalCorrelations, s.TotalCombatEvents,
        s.TotalCooldownProfiles, s.TotalSounds, s.TotalTools, s.TotalRemotes
    )
end

-- ============================================================================
-- DESTROY
-- ============================================================================
function TelemetryRecorder:Destroy()
    self._isRecording = false
    self:SaveToDisk(true)
    for key, conn in pairs(self._connections) do
        if conn and typeof(conn) == "RBXScriptConnection" then
            pcall(function() conn:Disconnect() end)
        end
        self._connections[key] = nil
    end
    table.clear(self._playerTrackers)
    table.clear(self._notifThrottle)
end

return TelemetryRecorder
