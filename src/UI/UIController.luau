--!strict
local UserInputService = game:GetService("UserInputService")
local Players = game:GetService("Players")
local CoreGui = game:GetService("CoreGui")

local Maid = require("Core.Maid")
local Window = require("UI.Window")
local Notifications = require("UI.Notifications")

-- Tabs
local CombatTab = require("UI.Tabs.Combat")
local TargetTab = require("UI.Tabs.Target")
local MovementTab = require("UI.Tabs.Movement")
local SkillsTab = require("UI.Tabs.Skills")
local SurvivalTab = require("UI.Tabs.Survival")
local VisualsTab = require("UI.Tabs.Visuals")
local WorldTab = require("UI.Tabs.World")
local KeybindsTab = require("UI.Tabs.Keybinds")
local SettingsTab = require("UI.Tabs.Settings")
local DiagnosticsTab = require("UI.Tabs.Diagnostics")

local UIController = {}
UIController.__index = UIController

export type UIDependencies = {
    ConfigManager: any,
    FeatureManager: any,
    StateMachine: any,
    Profiler: any,
    Cache: any,
    NetworkEngine: any,
    Logger: any,
    Bootstrap: any,
    Container: any,
}

function UIController.new(deps: UIDependencies)
    local self = setmetatable({
        _deps = deps,
        _maid = Maid.new(),
        _gui = nil :: ScreenGui?,
        _window = nil :: any,
        _notifications = nil :: any,
        _isInitialized = false,
        _accentName = "Cyan Neon",
    }, UIController)

    return self
end

function UIController:Init()
    if self._isInitialized then
        self:Destroy()
    end

    self._isInitialized = true
    local cfg = self._deps.ConfigManager.Config
    local accent = (cfg and cfg.UI and cfg.UI.AccentName) or "Cyan Neon"
    self._accentName = accent

    -- Target ScreenGui parent (gethui -> PlayerGui -> CoreGui)
    local function GetSafeGuiParent(): Instance
        if typeof(gethui) == "function" then
            local ok, h = pcall(gethui)
            if ok and h then return h end
        end

        local lp = Players.LocalPlayer
        if not lp then
            pcall(function()
                Players:GetPropertyChangedSignal("LocalPlayer"):Wait()
                lp = Players.LocalPlayer
            end)
        end

        if lp then
            local pg = lp:FindFirstChildOfClass("PlayerGui")
            if not pg then
                pcall(function() pg = lp:WaitForChild("PlayerGui", 4) end)
            end
            if pg then return pg end
        end

        local okCore, cg = pcall(function() return game:GetService("CoreGui") end)
        if okCore and cg then return cg end

        return game:GetService("Players").LocalPlayer:WaitForChild("PlayerGui")
    end

    local parentTarget = GetSafeGuiParent()

    -- Remove any old GUI instances to guarantee idempotency
    pcall(function()
        local oldGui = parentTarget:FindFirstChild("TSB_Framework_UI")
        if oldGui then oldGui:Destroy() end
    end)

    -- Create ScreenGui
    local screenGui = Instance.new("ScreenGui")
    screenGui.Name = "TSB_Framework_UI"
    screenGui.ResetOnSpawn = false
    screenGui.DisplayOrder = 999
    screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    screenGui.IgnoreGuiInset = true

    if typeof(syn) == "table" and typeof(syn.protect_gui) == "function" then
        pcall(syn.protect_gui, screenGui)
    end

    screenGui.Parent = parentTarget
    self._gui = screenGui

    self._maid:GiveTask(screenGui)

    -- Initialize Notifications
    local notifs = Notifications.new(screenGui, accent)
    self._notifications = notifs
    self._maid:GiveTask(function() notifs:Destroy() end)

    -- Initialize Window
    local window = Window.new(screenGui, accent, function()
        if cfg and cfg.UI then
            cfg.UI.IsOpen = false
        end
    end)
    self._window = window
    self._maid:GiveTask(function() window:Destroy() end)

    -- Shared Tab Context
    local tabCtx = {
        ConfigManager = self._deps.ConfigManager,
        FeatureManager = self._deps.FeatureManager,
        StateMachine = self._deps.StateMachine,
        Profiler = self._deps.Profiler,
        Cache = self._deps.Cache,
        NetworkEngine = self._deps.NetworkEngine,
        Logger = self._deps.Logger,
        Bootstrap = self._deps.Bootstrap,
        Container = self._deps.Container,
        Notifications = notifs,
        AccentName = accent,
        UIController = self,
    }

    -- Build Tabs
    local sidebar = window:GetSidebar()
    local tabs = {
        { Name = "Combat",      Icon = "⚔️", Builder = CombatTab.Build,      Order = 1 },
        { Name = "Target",      Icon = "🎯", Builder = TargetTab.Build,      Order = 2 },
        { Name = "Movement",    Icon = "⚡", Builder = MovementTab.Build,    Order = 3 },
        { Name = "Skills",      Icon = "🔥", Builder = SkillsTab.Build,      Order = 4 },
        { Name = "Survival",    Icon = "🛡️", Builder = SurvivalTab.Build,    Order = 5 },
        { Name = "Visuals",     Icon = "👁️", Builder = VisualsTab.Build,     Order = 6 },
        { Name = "World",       Icon = "🌐", Builder = WorldTab.Build,       Order = 7 },
        { Name = "Keybinds",    Icon = "⌨️", Builder = KeybindsTab.Build,    Order = 8 },
        { Name = "Settings",    Icon = "⚙️", Builder = SettingsTab.Build,    Order = 9 },
        { Name = "Diagnostics", Icon = "📊", Builder = DiagnosticsTab.Build, Order = 10 },
    }

    for _, t in ipairs(tabs) do
        sidebar:AddTab(t.Name, t.Icon, t.Order)
        local page = window:CreateTabPage(t.Name)
        t.Builder(page, tabCtx)
    end

    -- Default Active Tab
    sidebar:SetActive("Combat")

    -- EventBus Global Notification Listener
    if self._deps.Container and self._deps.Container:Has("EventBus") then
        local eb = self._deps.Container:Get("EventBus")
        local notifConn = eb:Subscribe("Notification.Show", function(title: string, msg: string, dur: number?, kind: any?)
            self:ShowNotification(title, msg, dur, kind)
        end)
        self._maid:GiveTask(notifConn)
    end

    -- Keybind Listeners (GUI Toggle, Continuous Safe Behind Lock, Aimlock, Fly, Noclip, Emergency Stop)
    local keybindConn = UserInputService.InputBegan:Connect(function(input, gpe)
        if gpe then return end
        if input.UserInputType == Enum.UserInputType.Keyboard then
            local kb = cfg and cfg.Keybinds or {}
            local toggleGUIBind = kb.ToggleGUI or Enum.KeyCode.RightControl
            local behindTPBind = kb.ToggleBehindTP or Enum.KeyCode.F9
            local aimlockBind = kb.ToggleAimlock or Enum.KeyCode.F7
            local flyBind = kb.ToggleFly or Enum.KeyCode.F5
            local noclipBind = kb.ToggleNoclip or Enum.KeyCode.F6
            local emerBind = kb.EmergencyStop or Enum.KeyCode.Delete

            if input.KeyCode == toggleGUIBind then
                self:Toggle()
            elseif input.KeyCode == behindTPBind then
                if not cfg.Target then cfg.Target = {} end
                local newState = not cfg.Target.BehindTP
                cfg.Target.BehindTP = newState
                if newState then
                    local combat = self._deps.Container:Get("Combat")
                    local t = combat and combat:GetTarget(cfg)
                    local tName = t and t.Name or "Opponent"
                    self:ShowNotification("⚡ Safe Behind Lock", "LOCKED behind " .. tName .. " (Continuous)", 2.0, "Success")
                else
                    self:ShowNotification("Safe Behind Lock", "Behind lock DISABLED", 2.0, "Warning")
                end
            elseif input.KeyCode == aimlockBind then
                if cfg.Combat then
                    cfg.Combat.Aimlock = not cfg.Combat.Aimlock
                    self:ShowNotification("Aimlock", cfg.Combat.Aimlock and "Aimlock ENABLED" or "Aimlock DISABLED", 2.0, cfg.Combat.Aimlock and "Success" or "Warning")
                end
            elseif input.KeyCode == flyBind then
                if cfg.Movement then
                    cfg.Movement.Fly = not cfg.Movement.Fly
                    local mov = self._deps.Container:Get("Movement")
                    if mov then mov:ToggleFly(cfg.Movement.Fly, cfg) end
                    self:ShowNotification("Flight", cfg.Movement.Fly and "Fly ENABLED" or "Fly DISABLED", 2.0, cfg.Movement.Fly and "Success" or "Warning")
                end
            elseif input.KeyCode == noclipBind then
                if cfg.Movement then
                    cfg.Movement.Noclip = not cfg.Movement.Noclip
                    self:ShowNotification("Noclip", cfg.Movement.Noclip and "Noclip ENABLED" or "Noclip DISABLED", 2.0, cfg.Movement.Noclip and "Success" or "Warning")
                end
            elseif input.KeyCode == emerBind then
                if cfg.Target then cfg.Target.BehindTP = false end
                if cfg.Movement then cfg.Movement.Fly = false; cfg.Movement.Noclip = false end
                if cfg.Combat then cfg.Combat.Aimlock = false; cfg.Combat.AutoM1 = false end
                self:ShowNotification("🛑 Emergency Stop", "All active combat & movement loops stopped.", 2.5, "Warning")
            end
        end
    end)
    self._maid:GiveTask(keybindConn)

    -- Initial Window State
    if cfg and cfg.UI and cfg.UI.IsOpen == false then
        window:Minimize()
    else
        window:Open()
    end

    notifs:Show("TSB Framework", "System operational. Press RightControl to toggle UI.", 3.0, "Success")
    if self._deps.Logger then
        self._deps.Logger:Info("UIController", "GUI System Initialized successfully.")
    end
end

function UIController:Open()
    if self._window then
        self._window:Open()
    end
end

function UIController:Close()
    if self._window then
        self._window:Close()
    end
end

function UIController:Toggle()
    if self._window then
        self._window:Toggle()
    end
end

function UIController:ShowNotification(title: string, message: string, duration: number?, kind: any?)
    if self._notifications then
        self._notifications:Show(title, message, duration, kind)
    end
end

function UIController:SelectTab(tabName: string)
    if self._window and self._window:GetSidebar() then
        self._window:GetSidebar():SetActive(tabName)
    end
end

function UIController:Refresh()
    self:Init()
end

function UIController:Destroy()
    if self._maid then
        self._maid:DoCleaning()
    end
    self._gui = nil
    self._window = nil
    self._notifications = nil
    self._isInitialized = false
end

return UIController
