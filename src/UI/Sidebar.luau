--!strict
local Theme = require("UI.Theme")

local Sidebar = {}
Sidebar.__index = Sidebar

export type TabDef = {
    Name: string,
    Icon: string?,
}

function Sidebar.new(parent: Instance, accentName: string?, onTabSelected: (string) -> ())
    local accent = Theme.GetAccent(accentName)

    local sidebarFrame = Instance.new("Frame")
    sidebarFrame.Name = "Sidebar"
    sidebarFrame.Size = UDim2.new(0, 160, 1, 0)
    sidebarFrame.BackgroundColor3 = Theme.Colors.Sidebar
    sidebarFrame.BorderSizePixel = 0
    sidebarFrame.Parent = parent

    -- Right separator line
    local sep = Instance.new("Frame")
    sep.Size = UDim2.new(0, 1, 1, 0)
    sep.Position = UDim2.new(1, -1, 0, 0)
    sep.BackgroundColor3 = Theme.Colors.BorderSubtle
    sep.BorderSizePixel = 0
    sep.Parent = sidebarFrame

    -- Branding Header
    local header = Instance.new("Frame")
    header.Size = UDim2.new(1, 0, 0, 56)
    header.BackgroundTransparency = 1
    header.Parent = sidebarFrame

    local title = Instance.new("TextLabel")
    title.Size = UDim2.new(1, -24, 0, 20)
    title.Position = UDim2.new(0, 16, 0, 12)
    title.BackgroundTransparency = 1
    title.Text = "TSB HUB"
    title.TextColor3 = Theme.Colors.TextPrimary
    title.TextSize = 15
    title.Font = Theme.Fonts.Title
    title.TextXAlignment = Enum.TextXAlignment.Left
    title.Parent = header

    local subtitle = Instance.new("TextLabel")
    subtitle.Size = UDim2.new(1, -24, 0, 14)
    subtitle.Position = UDim2.new(0, 16, 0, 32)
    subtitle.BackgroundTransparency = 1
    subtitle.Text = "v9.0 SPECIALIST"
    subtitle.TextColor3 = accent.Primary
    subtitle.TextSize = 9
    subtitle.Font = Theme.Fonts.Bold
    subtitle.TextXAlignment = Enum.TextXAlignment.Left
    subtitle.Parent = header

    local statusDot = Instance.new("Frame")
    statusDot.Size = UDim2.new(0, 7, 0, 7)
    statusDot.Position = UDim2.new(1, -20, 0, 18)
    statusDot.BackgroundColor3 = Theme.Colors.Success
    statusDot.BorderSizePixel = 0
    statusDot.Parent = header
    Instance.new("UICorner", statusDot).CornerRadius = UDim.new(1, 0)

    -- Tab Button Container
    local tabContainer = Instance.new("ScrollingFrame")
    tabContainer.Name = "TabButtons"
    tabContainer.Size = UDim2.new(1, 0, 1, -64)
    tabContainer.Position = UDim2.new(0, 0, 0, 60)
    tabContainer.BackgroundTransparency = 1
    tabContainer.BorderSizePixel = 0
    tabContainer.ScrollBarThickness = 0
    tabContainer.AutomaticCanvasSize = Enum.AutomaticSize.Y
    tabContainer.CanvasSize = UDim2.new(0, 0, 0, 0)
    tabContainer.Parent = sidebarFrame

    local layout = Instance.new("UIListLayout")
    layout.SortOrder = Enum.SortOrder.LayoutOrder
    layout.Padding = UDim.new(0, 4)
    layout.Parent = tabContainer

    local padding = Instance.new("UIPadding")
    padding.PaddingLeft = UDim.new(0, 8)
    padding.PaddingRight = UDim.new(0, 8)
    padding.Parent = tabContainer

    local self = setmetatable({
        _frame = sidebarFrame,
        _container = tabContainer,
        _accentName = accentName or "Cyan Neon",
        _buttons = {},
        _activeTab = nil :: string?,
        _onTabSelected = onTabSelected,
    }, Sidebar)

    return self
end

function Sidebar:AddTab(tabName: string, iconSymbol: string?, layoutOrder: number)
    local accent = Theme.GetAccent(self._accentName)

    local btn = Instance.new("TextButton")
    btn.Name = "Tab_" .. tabName
    btn.Size = UDim2.new(1, 0, 0, 36)
    btn.BackgroundColor3 = Theme.Colors.Sidebar
    btn.BorderSizePixel = 0
    btn.Text = ""
    btn.LayoutOrder = layoutOrder or 1
    btn.Parent = self._container
    Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 6)

    -- Active Indicator line
    local indicator = Instance.new("Frame")
    indicator.Name = "Indicator"
    indicator.Size = UDim2.new(0, 3, 0, 16)
    indicator.Position = UDim2.new(0, 4, 0.5, -8)
    indicator.BackgroundColor3 = accent.Primary
    indicator.BorderSizePixel = 0
    indicator.BackgroundTransparency = 1
    indicator.Parent = btn
    Instance.new("UICorner", indicator).CornerRadius = UDim.new(1, 0)

    local lbl = Instance.new("TextLabel")
    lbl.Size = UDim2.new(1, -24, 1, 0)
    lbl.Position = UDim2.new(0, 16, 0, 0)
    lbl.BackgroundTransparency = 1
    lbl.Text = (iconSymbol and (iconSymbol .. "  ") or "") .. tabName
    lbl.TextColor3 = Theme.Colors.TextSecondary
    lbl.TextSize = 12
    lbl.Font = Theme.Fonts.Subtitle
    lbl.TextXAlignment = Enum.TextXAlignment.Left
    lbl.Parent = btn

    local this = self
    btn.MouseEnter:Connect(function()
        if this._activeTab ~= tabName then
            Theme.Tween(btn, 0.12, { BackgroundColor3 = Theme.Colors.Card })
            Theme.Tween(lbl, 0.12, { TextColor3 = Theme.Colors.TextPrimary })
        end
    end)
    btn.MouseLeave:Connect(function()
        if this._activeTab ~= tabName then
            Theme.Tween(btn, 0.12, { BackgroundColor3 = Theme.Colors.Sidebar })
            Theme.Tween(lbl, 0.12, { TextColor3 = Theme.Colors.TextSecondary })
        end
    end)
    btn.MouseButton1Click:Connect(function()
        this:SetActive(tabName)
    end)

    self._buttons[tabName] = {
        Button = btn,
        Label = lbl,
        Indicator = indicator,
    }
end

function Sidebar:SetActive(tabName: string)
    self._activeTab = tabName
    local accent = Theme.GetAccent(self._accentName)

    for name, item in pairs(self._buttons) do
        if name == tabName then
            Theme.Tween(item.Button, 0.15, { BackgroundColor3 = Theme.Colors.Card })
            Theme.Tween(item.Label, 0.15, { TextColor3 = accent.Primary })
            Theme.Tween(item.Indicator, 0.15, { BackgroundTransparency = 0 })
        else
            Theme.Tween(item.Button, 0.15, { BackgroundColor3 = Theme.Colors.Sidebar })
            Theme.Tween(item.Label, 0.15, { TextColor3 = Theme.Colors.TextSecondary })
            Theme.Tween(item.Indicator, 0.15, { BackgroundTransparency = 1 })
        end
    end

    if self._onTabSelected then
        pcall(self._onTabSelected, tabName)
    end
end

function Sidebar:Destroy()
    if self._frame then
        self._frame:Destroy()
        self._frame = nil :: any
    end
    table.clear(self._buttons)
end

return Sidebar
