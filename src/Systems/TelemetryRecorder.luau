--!strict
local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local LocalPlayer = Players.LocalPlayer

local TelemetryRecorder = {}
TelemetryRecorder.__index = TelemetryRecorder

export type TelemetryStats = {
    TotalAnimations: number,
    TotalAttributes: number,
    TotalEvents: number,
    TotalHitboxProfiles: number,
    TotalCooldownProfiles: number,
    TotalSounds: number,
    TotalRemotes: number,
    LastSaved: number,
    IsRecording: boolean,
}

function TelemetryRecorder.new(deps: { Cache: any, EventBus: any, Logger: any })
    local self = setmetatable({
        _cache = deps.Cache,
        _eventBus = deps.EventBus,
        _logger = deps.Logger,
        _isDirty = false,
        _lastSaveTick = os.clock(),
        _connections = {} :: { [string]: any },
        _playerTrackers = {} :: { [Player]: any },
        _notifThrottle = {} :: { [string]: number },
        
        -- Master Accumulated Combat Telemetry Database
        Data = {
            Metadata = {
                FrameworkVersion = "9.0-SPECIALIST-PRODUCTION",
                Created = os.time(),
                LastUpdated = os.time(),
                TotalSessions = 1,
            },
            Animations = {} :: { [string]: any },
            Attributes = {} :: { [string]: any },
            HitboxProfiles = {} :: { [string]: any },
            Cooldowns = {} :: { [string]: any },
            Sounds = {} :: { [string]: any },
            Remotes = {} :: { [string]: any },
            Events = {} :: { any },
        },
    }, TelemetryRecorder)

    -- Load existing persistent dataset
    self:LoadFromDisk()
    self:ScanRemotes()
    self:InitHooks()

    return self
end

function TelemetryRecorder:SendNotification(title: string, message: string, kind: string?)
    local now = os.clock()
    local key = title .. ":" .. message:sub(1, 20)
    if self._notifThrottle[key] and (now - self._notifThrottle[key]) < 2.0 then
        return
    end
    self._notifThrottle[key] = now

    pcall(function()
        if self._eventBus then
            self._eventBus:Publish("Notification.Show", title, message, 2.5, kind or "Info")
        end
    end)
end

function TelemetryRecorder:LoadFromDisk()
    pcall(function()
        if typeof(readfile) == "function" and typeof(isfile) == "function" then
            if isfile("tsb_combat_data.json") then
                local content = readfile("tsb_combat_data.json")
                if content and #content > 5 then
                    local parsed = HttpService:JSONDecode(content)
                    if typeof(parsed) == "table" then
                        if parsed.Animations and typeof(parsed.Animations) == "table" then
                            for k, v in pairs(parsed.Animations) do
                                if typeof(v) == "table" then
                                    self.Data.Animations[k] = v
                                else
                                    self.Data.Animations[k] = { Id = tostring(k), Name = tostring(v), Count = 1, FirstSeen = os.time() }
                                end
                            end
                        end
                        if parsed.Attributes and typeof(parsed.Attributes) == "table" then
                            for k, v in pairs(parsed.Attributes) do
                                if typeof(v) == "table" then
                                    self.Data.Attributes[k] = v
                                else
                                    self.Data.Attributes[k] = { Name = tostring(k), SampleValues = { [tostring(v)] = true }, Count = 1, FirstSeen = os.time(), LastPlayer = "Legacy" }
                                end
                            end
                        end
                        if parsed.HitboxProfiles and typeof(parsed.HitboxProfiles) == "table" then
                            for k, v in pairs(parsed.HitboxProfiles) do if typeof(v) == "table" then self.Data.HitboxProfiles[k] = v end end
                        end
                        if parsed.Cooldowns and typeof(parsed.Cooldowns) == "table" then
                            for k, v in pairs(parsed.Cooldowns) do if typeof(v) == "table" then self.Data.Cooldowns[k] = v end end
                        end
                        if parsed.Sounds and typeof(parsed.Sounds) == "table" then
                            for k, v in pairs(parsed.Sounds) do if typeof(v) == "table" then self.Data.Sounds[k] = v end end
                        end
                        if parsed.Remotes and typeof(parsed.Remotes) == "table" then
                            for k, v in pairs(parsed.Remotes) do if typeof(v) == "table" then self.Data.Remotes[k] = v end end
                        end
                        if parsed.Metadata and typeof(parsed.Metadata) == "table" and typeof(parsed.Metadata.TotalSessions) == "number" then
                            self.Data.Metadata.TotalSessions = parsed.Metadata.TotalSessions + 1
                        end
                        self._logger:Info("TelemetryRecorder", string.format("Loaded existing data: %d anims, %d attrs from tsb_combat_data.json", self:CountKeys(self.Data.Animations), self:CountKeys(self.Data.Attributes)))
                    end
                end
            end
        end
    end)
end

function TelemetryRecorder:CountKeys(tbl: any): number
    if typeof(tbl) ~= "table" then return 0 end
    local c = 0
    for _ in pairs(tbl) do c += 1 end
    return c
end

function TelemetryRecorder:SaveToDisk(force: boolean?)
    if not self._isDirty and not force then return end
    self._isDirty = false
    self._lastSaveTick = os.clock()
    self.Data.Metadata.LastUpdated = os.time()

    pcall(function()
        if typeof(writefile) == "function" then
            local encoded = HttpService:JSONEncode(self.Data)
            writefile("tsb_combat_data.json", encoded)
            self._logger:Info("TelemetryRecorder", string.format("Saved combat telemetry (%d anims, %d attrs, %d events) to tsb_combat_data.json", self:CountKeys(self.Data.Animations), self:CountKeys(self.Data.Attributes), #self.Data.Events))
        end
    end)
end

function TelemetryRecorder:RecordAnimation(animTrack: AnimationTrack, player: Player)
    if not animTrack then return end
    local anim = animTrack.Animation
    local animId = anim and anim.AnimationId or ""
    local cleanId = animId:match("%d+") or animTrack.Name or "Unknown"

    local existing = self.Data.Animations[cleanId]
    local now = os.clock()

    if not existing or typeof(existing) ~= "table" then
        local keyframeNames = {}
        pcall(function()
            if animTrack.GetTimeOfKeyframe then
                for _, name in ipairs({ "hit", "strike", "damage", "parry", "counter", "block", "release", "fire", "slam", "kick" }) do
                    local t = animTrack:GetTimeOfKeyframe(name)
                    if t and t > 0 then
                        keyframeNames[name] = t
                    end
                end
            end
        end)

        local trackName = animTrack.Name or "Unnamed"
        self.Data.Animations[cleanId] = {
            Id = cleanId,
            RawUrl = animId,
            Name = trackName,
            Length = animTrack.Length or 0,
            Speed = animTrack.Speed or 1,
            Priority = tostring(animTrack.Priority),
            Keyframes = keyframeNames,
            DiscoveredBy = player.Name,
            FirstSeen = os.time(),
            Count = 1,
            LastUsed = now,
        }
        self._isDirty = true

        -- Live Toast Notification
        self:SendNotification("🔔 Yeni Animasyon", string.format("%s: %s (ID: %s)", player.Name, trackName, cleanId), "Success")
    else
        existing.Count = (tonumber(existing.Count) or 1) + 1
        existing.LastUsed = now
        self._isDirty = true
    end
end

function TelemetryRecorder:RecordAttribute(attrName: string, value: any, player: Player)
    if not attrName then return end
    local existing = self.Data.Attributes[attrName]
    local valStr = tostring(value)

    if not existing or typeof(existing) ~= "table" then
        self.Data.Attributes[attrName] = {
            Name = attrName,
            FirstSeen = os.time(),
            SampleValues = { [valStr] = true },
            Count = 1,
            LastPlayer = player.Name,
        }
        self._isDirty = true

        -- Live Toast Notification
        self:SendNotification("⚡ Yeni Oyun Özelliği", string.format("%s -> %s = %s", player.Name, attrName, valStr), "Info")
    else
        existing.Count = (tonumber(existing.Count) or 1) + 1
        if not existing.SampleValues or typeof(existing.SampleValues) ~= "table" then
            existing.SampleValues = {}
        end
        existing.SampleValues[valStr] = true
        existing.LastPlayer = player.Name
        self._isDirty = true
    end
end

function TelemetryRecorder:RecordHitboxProfile(char: Model, player: Player)
    if not char then return end
    local root = char:FindFirstChild("HumanoidRootPart") :: BasePart?
    local head = char:FindFirstChild("Head") :: BasePart?
    local torso = (char:FindFirstChild("Torso") or char:FindFirstChild("UpperTorso")) :: BasePart?

    local charKey = player.Name
    local charAttr = char:GetAttribute("Character")
    if charAttr and typeof(charAttr) == "string" then
        charKey = charAttr
    end

    if root and torso then
        local isNew = not self.Data.HitboxProfiles[charKey]
        self.Data.HitboxProfiles[charKey] = {
            Character = charKey,
            RootPartSize = { X = root.Size.X, Y = root.Size.Y, Z = root.Size.Z },
            TorsoSize = { X = torso.Size.X, Y = torso.Size.Y, Z = torso.Size.Z },
            HeadSize = head and { X = head.Size.X, Y = head.Size.Y, Z = head.Size.Z } or nil,
            CanCollideRoot = root.CanCollide,
            Updated = os.time(),
        }
        self._isDirty = true

        if isNew then
            self:SendNotification("🎯 Yeni Hitbox Profili", string.format("Karakter: %s (%s)", charKey, player.Name), "Success")
        end
    end
end

function TelemetryRecorder:RecordSound(sound: Sound, player: Player)
    if not sound or not sound.SoundId then return end
    local soundId = sound.SoundId:match("%d+") or sound.SoundId
    if not soundId or #soundId == 0 then return end

    if not self.Data.Sounds[soundId] then
        self.Data.Sounds[soundId] = {
            Id = soundId,
            Name = sound.Name,
            Volume = sound.Volume,
            Pitch = sound.PlaybackSpeed,
            Player = player.Name,
            FirstSeen = os.time(),
            Count = 1,
        }
        self._isDirty = true
        self:SendNotification("🔊 Yeni Ses Kaydedildi", string.format("%s: %s (ID: %s)", player.Name, sound.Name, soundId), "Info")
    else
        self.Data.Sounds[soundId].Count += 1
        self._isDirty = true
    end
end

function TelemetryRecorder:ScanRemotes()
    pcall(function()
        local function CheckDescendant(inst: Instance)
            if inst:IsA("RemoteEvent") or inst:IsA("RemoteFunction") then
                local path = inst:GetFullName()
                if not self.Data.Remotes[path] then
                    self.Data.Remotes[path] = {
                        Name = inst.Name,
                        Class = inst.ClassName,
                        Path = path,
                        Discovered = os.time(),
                    }
                    self._isDirty = true
                end
            end
        end

        for _, d in ipairs(ReplicatedStorage:GetDescendants()) do CheckDescendant(d) end
        for _, d in ipairs(game:GetService("Workspace"):GetDescendants()) do
            if d:IsA("RemoteEvent") or d:IsA("RemoteFunction") then CheckDescendant(d) end
        end
    end)
end

function TelemetryRecorder:RecordCombatEvent(eventType: string, details: any)
    local evt = {
        Type = eventType,
        Timestamp = os.time(),
        Details = details,
    }
    table.insert(self.Data.Events, evt)
    if #self.Data.Events > 500 then
        table.remove(self.Data.Events, 1)
    end
    self._isDirty = true
end

function TelemetryRecorder:HookCharacter(player: Player, char: Model)
    if not char then return end
    local tracker = {
        LastHealth = 100,
        LastState = Enum.HumanoidStateType.Running,
        RagdollStart = 0,
        SkillTimestamps = {} :: { [string]: number },
    }
    self._playerTrackers[player] = tracker

    -- 1. Hitbox Profile Recording
    self:RecordHitboxProfile(char, player)

    -- 2. Attribute Change Hook (0ms instantaneous capture)
    char.AttributeChanged:Connect(function(attrName)
        pcall(function()
            local val = char:GetAttribute(attrName)
            self:RecordAttribute(attrName, val, player)

            -- Track Cooldowns if attribute is a skill hold
            if attrName:find("Holding") or attrName:find("Skill") or attrName == "Blocking" then
                local now = os.clock()
                local last = tracker.SkillTimestamps[attrName]
                if last then
                    local interval = now - last
                    if interval >= 0.5 and interval <= 60 then
                        local charKey = tostring(char:GetAttribute("Character") or "Universal")
                        if not self.Data.Cooldowns[charKey] then
                            self.Data.Cooldowns[charKey] = {}
                        end
                        local cdData = self.Data.Cooldowns[charKey][attrName]
                        local isNewCD = (cdData == nil)
                        if not cdData then
                            self.Data.Cooldowns[charKey][attrName] = {
                                Min = interval,
                                Max = interval,
                                Avg = interval,
                                Samples = { interval },
                                Count = 1,
                            }
                        else
                            cdData.Min = math.min(cdData.Min, interval)
                            cdData.Max = math.max(cdData.Max, interval)
                            cdData.Count += 1
                            table.insert(cdData.Samples, interval)
                            if #cdData.Samples > 20 then
                                table.remove(cdData.Samples, 1)
                            end
                            local sum = 0
                            for _, s in ipairs(cdData.Samples) do sum += s end
                            cdData.Avg = sum / #cdData.Samples
                        end
                        self._isDirty = true

                        if isNewCD or cdData.Count % 5 == 0 then
                            self:SendNotification("⏱️ Cooldown Ölçüldü", string.format("%s -> %s (%.1fs)", charKey, attrName, interval), "Warning")
                        end
                    end
                end
                tracker.SkillTimestamps[attrName] = now
            end
        end)
    end)

    -- 3. Humanoid Events Hook (Damage & Ragdoll Duration Tracking)
    local hum = char:WaitForChild("Humanoid", 4) :: Humanoid?
    if hum then
        tracker.LastHealth = hum.Health
        hum.HealthChanged:Connect(function(newHealth)
            local diff = tracker.LastHealth - newHealth
            tracker.LastHealth = newHealth
            if diff > 1 then
                self:RecordCombatEvent("DamageDealt", {
                    Victim = player.Name,
                    Damage = diff,
                    RemainingHP = newHealth,
                })
            end
        end)

        hum.StateChanged:Connect(function(oldState, newState)
            if newState == Enum.HumanoidStateType.Physics or newState == Enum.HumanoidStateType.Ragdoll then
                tracker.RagdollStart = os.clock()
                self:RecordCombatEvent("RagdollEntered", {
                    Player = player.Name,
                    State = tostring(newState),
                })
            elseif oldState == Enum.HumanoidStateType.Physics or oldState == Enum.HumanoidStateType.Ragdoll then
                if tracker.RagdollStart > 0 then
                    local ragDuration = os.clock() - tracker.RagdollStart
                    tracker.RagdollStart = 0
                    self:RecordCombatEvent("RagdollWakeup", {
                        Player = player.Name,
                        Duration = ragDuration,
                    })
                end
            end
        end)

        -- 4. Animator Track Playing Hook
        local animator = hum:WaitForChild("Animator", 4) :: Animator?
        if animator then
            animator.AnimationPlayed:Connect(function(track)
                self:RecordAnimation(track, player)
            end)

            pcall(function()
                for _, tr in ipairs(animator:GetPlayingAnimationTracks()) do
                    self:RecordAnimation(tr, player)
                end
            end)
        end
    end

    -- 5. Sounds & Tools Hook
    char.DescendantAdded:Connect(function(desc)
        if desc:IsA("Sound") then
            desc.Played:Connect(function()
                self:RecordSound(desc, player)
            end)
        elseif desc:IsA("Tool") or desc:IsA("Model") then
            self:RecordAttribute("ToolEquipped_" .. desc.Name, desc.ClassName, player)
        end
    end)
end

function TelemetryRecorder:InitHooks()
    -- Hook existing players
    for _, p in ipairs(Players:GetPlayers()) do
        if p.Character then
            task.spawn(function()
                self:HookCharacter(p, p.Character)
            end)
        end
        local charAddedKey = "CharAdded_" .. tostring(p.UserId)
        self._connections[charAddedKey] = p.CharacterAdded:Connect(function(c)
            task.spawn(function()
                self:HookCharacter(p, c)
            end)
        end)
    end

    -- Hook newly joined players
    self._connections["PlayerAdded"] = Players.PlayerAdded:Connect(function(p)
        local charAddedKey = "CharAdded_" .. tostring(p.UserId)
        self._connections[charAddedKey] = p.CharacterAdded:Connect(function(c)
            task.spawn(function()
                self:HookCharacter(p, c)
            end)
        end)
    end)

    self._connections["PlayerRemoving"] = Players.PlayerRemoving:Connect(function(p)
        self._playerTrackers[p] = nil
        -- Clean up per-player CharacterAdded connection
        local charAddedKey = "CharAdded_" .. tostring(p.UserId)
        if self._connections[charAddedKey] then
            pcall(function() self._connections[charAddedKey]:Disconnect() end)
            self._connections[charAddedKey] = nil
        end
    end)
end

function TelemetryRecorder:Update(dt: number, config: any)
    if not config.Telemetry or not config.Telemetry.AutoRecordData then return end

    -- Periodic scan of playing animations across all active players
    for _, p in ipairs(Players:GetPlayers()) do
        local char = p.Character
        if char then
            local hum = char:FindFirstChildOfClass("Humanoid")
            local animator = hum and hum:FindFirstChildOfClass("Animator")
            if animator then
                pcall(function()
                    for _, tr in ipairs(animator:GetPlayingAnimationTracks()) do
                        self:RecordAnimation(tr, p)
                    end
                end)
            end
        end
    end

    -- Periodic Autosave Check
    local interval = (config.Telemetry and config.Telemetry.AutoSaveInterval) or 15
    if (os.clock() - self._lastSaveTick) >= interval then
        self:SaveToDisk(false)
    end
end

function TelemetryRecorder:GetStats(): TelemetryStats
    return {
        TotalAnimations = self:CountKeys(self.Data.Animations),
        TotalAttributes = self:CountKeys(self.Data.Attributes),
        TotalEvents = #self.Data.Events,
        TotalHitboxProfiles = self:CountKeys(self.Data.HitboxProfiles),
        TotalCooldownProfiles = self:CountKeys(self.Data.Cooldowns),
        TotalSounds = self:CountKeys(self.Data.Sounds),
        TotalRemotes = self:CountKeys(self.Data.Remotes),
        LastSaved = self._lastSaveTick,
        IsRecording = true,
    }
end

function TelemetryRecorder:Destroy()
    self:SaveToDisk(true)
    for _, conn in pairs(self._connections) do
        pcall(function() conn:Disconnect() end)
    end
    self._connections = {}
    self._playerTrackers = {}
end

return TelemetryRecorder
