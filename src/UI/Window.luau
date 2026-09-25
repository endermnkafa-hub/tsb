--!strict
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")
local Theme = require("UI.Theme")
local Sidebar = require("UI.Sidebar")

local Window = {}
Window.__index = Window

function Window.new(parentGui: Instance, accentName: string?, onClosed: (() -> ())?)
    local accent = Theme.GetAccent(accentName)

    -- Floating Reopen Button (visible when window is minimized)
    local reopenBtn = Instance.new("TextButton")
    reopenBtn.Name = "TSB_ReopenButton"
    reopenBtn.Size = UDim2.new(0, 88, 0, 32)
    reopenBtn.Position = UDim2.new(0, 16, 0, 16)
    reopenBtn.BackgroundColor3 = Theme.Colors.Header
    reopenBtn.BorderSizePixel = 0
    reopenBtn.Text = "⚡ TSB HUB"
    reopenBtn.TextColor3 = accent.Primary
    reopenBtn.TextSize = 11
    reopenBtn.Font = Theme.Fonts.Bold
    reopenBtn.Visible = false
    reopenBtn.Parent = parentGui
    Instance.new("UICorner", reopenBtn).CornerRadius = UDim.new(1, 0)

    local reopenStroke = Instance.new("UIStroke")
    reopenStroke.Color = accent.Primary
    reopenStroke.Thickness = 1
    reopenStroke.Parent = reopenBtn

    -- Make reopen button draggable
    local draggingReopen = false
    local dragReopenStart: Vector3? = nil
    local startReopenPos: UDim2? = nil

    reopenBtn.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            draggingReopen = true
            dragReopenStart = input.Position
            startReopenPos = reopenBtn.Position
        end
    end)
    UserInputService.InputChanged:Connect(function(input)
        if draggingReopen and dragReopenStart and startReopenPos and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
            local delta = input.Position - dragReopenStart
            reopenBtn.Position = UDim2.new(
                startReopenPos.X.Scale,
                startReopenPos.X.Offset + delta.X,
                startReopenPos.Y.Scale,
                startReopenPos.Y.Offset + delta.Y
            )
        end
    end)
    UserInputService.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            draggingReopen = false
        end
    end)

    -- Main Window Frame
    local mainFrame = Instance.new("Frame")
    mainFrame.Name = "TSB_MainWindow"
    mainFrame.Size = UDim2.new(0, 650, 0, 440)
    mainFrame.Position = UDim2.new(0.5, -325, 0.5, -220)
    mainFrame.BackgroundColor3 = Theme.Colors.Background
    mainFrame.BorderSizePixel = 0
    mainFrame.ClipsDescendants = true
    mainFrame.Parent = parentGui
    Instance.new("UICorner", mainFrame).CornerRadius = UDim.new(0, 10)

    local mainStroke = Instance.new("UIStroke")
    mainStroke.Color = Theme.Colors.Border
    mainStroke.Thickness = 1
    mainStroke.Parent = mainFrame

    -- Header Bar
    local headerBar = Instance.new("Frame")
    headerBar.Name = "HeaderBar"
    headerBar.Size = UDim2.new(1, 0, 0, 40)
    headerBar.BackgroundColor3 = Theme.Colors.Header
    headerBar.BorderSizePixel = 0
    headerBar.Parent = mainFrame

    local headerSep = Instance.new("Frame")
    headerSep.Size = UDim2.new(1, 0, 0, 1)
    headerSep.Position = UDim2.new(0, 0, 1, -1)
    headerSep.BackgroundColor3 = Theme.Colors.BorderSubtle
    headerSep.BorderSizePixel = 0
    headerSep.Parent = headerBar

    local headerTitle = Instance.new("TextLabel")
    headerTitle.Name = "HeaderTitle"
    headerTitle.Size = UDim2.new(1, -220, 1, 0)
    headerTitle.Position = UDim2.new(0, 168, 0, 0)
    headerTitle.BackgroundTransparency = 1
    headerTitle.Text = "Combat Dashboard"
    headerTitle.TextColor3 = Theme.Colors.TextPrimary
    headerTitle.TextSize = 13
    headerTitle.Font = Theme.Fonts.Title
    headerTitle.TextXAlignment = Enum.TextXAlignment.Left
    headerTitle.Parent = headerBar

    -- Header Window Control Buttons (Minimize & Close)
    local minBtn = Instance.new("TextButton")
    minBtn.Name = "MinimizeButton"
    minBtn.Size = UDim2.new(0, 28, 0, 24)
    minBtn.Position = UDim2.new(1, -64, 0.5, -12)
    minBtn.BackgroundColor3 = Theme.Colors.Card
    minBtn.BorderSizePixel = 0
    minBtn.Text = "—"
    minBtn.TextColor3 = Theme.Colors.TextSecondary
    minBtn.TextSize = 12
    minBtn.Font = Theme.Fonts.Bold
    minBtn.Parent = headerBar
    Instance.new("UICorner", minBtn).CornerRadius = UDim.new(0, 5)

    local closeBtn = Instance.new("TextButton")
    closeBtn.Name = "CloseButton"
    closeBtn.Size = UDim2.new(0, 28, 0, 24)
    closeBtn.Position = UDim2.new(1, -32, 0.5, -12)
    closeBtn.BackgroundColor3 = Theme.Colors.Card
    closeBtn.BorderSizePixel = 0
    closeBtn.Text = "✕"
    closeBtn.TextColor3 = Theme.Colors.TextSecondary
    closeBtn.TextSize = 11
    closeBtn.Font = Theme.Fonts.Bold
    closeBtn.Parent = headerBar
    Instance.new("UICorner", closeBtn).CornerRadius = UDim.new(0, 5)

    closeBtn.MouseEnter:Connect(function()
        Theme.Tween(closeBtn, 0.1, { BackgroundColor3 = Theme.Colors.Danger, TextColor3 = Color3.fromRGB(255, 255, 255) })
    end)
    closeBtn.MouseLeave:Connect(function()
        Theme.Tween(closeBtn, 0.1, { BackgroundColor3 = Theme.Colors.Card, TextColor3 = Theme.Colors.TextSecondary })
    end)

    minBtn.MouseEnter:Connect(function()
        Theme.Tween(minBtn, 0.1, { BackgroundColor3 = Theme.Colors.CardHover, TextColor3 = Theme.Colors.TextPrimary })
    end)
    minBtn.MouseLeave:Connect(function()
        Theme.Tween(minBtn, 0.1, { BackgroundColor3 = Theme.Colors.Card, TextColor3 = Theme.Colors.TextSecondary })
    end)

    -- Content Area Frame
    local contentFrame = Instance.new("Frame")
    contentFrame.Name = "ContentFrame"
    contentFrame.Size = UDim2.new(1, -160, 1, -40)
    contentFrame.Position = UDim2.new(0, 160, 0, 40)
    contentFrame.BackgroundTransparency = 1
    contentFrame.Parent = mainFrame

    -- Dragging with Boundary Clamping
    local isDragging = false
    local dragStartPos: Vector3? = nil
    local frameStartPos: UDim2? = nil

    headerBar.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            isDragging = true
            dragStartPos = input.Position
            frameStartPos = mainFrame.Position
        end
    end)

    UserInputService.InputChanged:Connect(function(input)
        if isDragging and dragStartPos and frameStartPos and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
            local delta = input.Position - dragStartPos
            local cam = Workspace.CurrentCamera
            local vp = cam and cam.ViewportSize or Vector2.new(1920, 1080)

            local newX = frameStartPos.X.Offset + delta.X
            local newY = frameStartPos.Y.Offset + delta.Y

            -- Screen boundary clamping
            local absoluteW = mainFrame.AbsoluteSize.X
            local absoluteH = mainFrame.AbsoluteSize.Y
            local screenX = frameStartPos.X.Scale * vp.X + newX
            local screenY = frameStartPos.Y.Scale * vp.Y + newY

            if screenX < 0 then newX = -frameStartPos.X.Scale * vp.X end
            if screenY < 0 then newY = -frameStartPos.Y.Scale * vp.Y end
            if (screenX + absoluteW) > vp.X then newX = vp.X - absoluteW - (frameStartPos.X.Scale * vp.X) end
            if (screenY + absoluteH) > vp.Y then newY = vp.Y - absoluteH - (frameStartPos.Y.Scale * vp.Y) end

            mainFrame.Position = UDim2.new(frameStartPos.X.Scale, newX, frameStartPos.Y.Scale, newY)
        end
    end)

    UserInputService.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            isDragging = false
        end
    end)

    local self = setmetatable({
        _gui = parentGui,
        _mainFrame = mainFrame,
        _headerTitle = headerTitle,
        _contentFrame = contentFrame,
        _reopenBtn = reopenBtn,
        _minBtn = minBtn,
        _closeBtn = closeBtn,
        _accentName = accentName or "Cyan Neon",
        _isOpen = true,
        _isMinimized = false,
        _tabPages = {},
        _sidebar = nil :: any,
        _onClosed = onClosed,
    }, Window)

    -- Sidebar Integration
    self._sidebar = Sidebar.new(mainFrame, accentName, function(tabName)
        self:SelectTab(tabName)
    end)

    -- Minimize Action
    minBtn.MouseButton1Click:Connect(function()
        self:Minimize()
    end)

    -- Reopen Action
    reopenBtn.MouseButton1Click:Connect(function()
        self:Restore()
    end)

    -- Close Action
    closeBtn.MouseButton1Click:Connect(function()
        self:Close()
    end)

    return self
end

function Window:CreateTabPage(tabName: string): ScrollingFrame
    local scroll = Instance.new("ScrollingFrame")
    scroll.Name = "TabPage_" .. tabName
    scroll.Size = UDim2.new(1, 0, 1, 0)
    scroll.BackgroundTransparency = 1
    scroll.BorderSizePixel = 0
    scroll.ScrollBarThickness = 4
    scroll.ScrollBarImageColor3 = Theme.Colors.BorderActive
    scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
    scroll.CanvasSize = UDim2.new(0, 0, 0, 0)
    scroll.Visible = false
    scroll.Parent = self._contentFrame

    local listLayout = Instance.new("UIListLayout")
    listLayout.SortOrder = Enum.SortOrder.LayoutOrder
    listLayout.Padding = UDim.new(0, 6)
    listLayout.Parent = scroll

    local pad = Instance.new("UIPadding")
    pad.PaddingTop = UDim.new(0, 10)
    pad.PaddingBottom = UDim.new(0, 14)
    pad.PaddingLeft = UDim.new(0, 12)
    pad.PaddingRight = UDim.new(0, 14)
    pad.Parent = scroll

    self._tabPages[tabName] = scroll
    return scroll
end

function Window:SelectTab(tabName: string)
    self._headerTitle.Text = tabName .. " Dashboard"
    for name, page in pairs(self._tabPages) do
        page.Visible = (name == tabName)
    end
end

function Window:Minimize()
    self._isMinimized = true
    Theme.Tween(self._mainFrame, 0.18, { Size = UDim2.new(0, 650, 0, 0) })
    task.delay(0.18, function()
        if self._isMinimized then
            self._mainFrame.Visible = false
            self._reopenBtn.Visible = true
            Theme.Tween(self._reopenBtn, 0.15, { BackgroundTransparency = 0 })
        end
    end)
end

function Window:Restore()
    self._isMinimized = false
    self._reopenBtn.Visible = false
    self._mainFrame.Visible = true
    Theme.Tween(self._mainFrame, 0.2, { Size = UDim2.new(0, 650, 0, 440) })
end

function Window:Open()
    if self._isOpen and self._mainFrame.Visible then return end
    self._isOpen = true
    self._isMinimized = false
    self._reopenBtn.Visible = false
    self._mainFrame.Visible = true
    self._mainFrame.Size = UDim2.new(0, 600, 0, 400)
    Theme.Tween(self._mainFrame, 0.22, { Size = UDim2.new(0, 650, 0, 440) })
end

function Window:Close()
    self._isOpen = false
    Theme.Tween(self._mainFrame, 0.18, { Size = UDim2.new(0, 600, 0, 400) })
    task.delay(0.18, function()
        if not self._isOpen then
            self._mainFrame.Visible = false
            self._reopenBtn.Visible = true
            if self._onClosed then pcall(self._onClosed) end
        end
    end)
end

function Window:Toggle()
    if self._mainFrame.Visible then
        self:Close()
    else
        self:Open()
    end
end

function Window:GetSidebar(): any
    return self._sidebar
end

function Window:Destroy()
    if self._sidebar then
        self._sidebar:Destroy()
        self._sidebar = nil :: any
    end
    if self._mainFrame then
        self._mainFrame:Destroy()
        self._mainFrame = nil :: any
    end
    if self._reopenBtn then
        self._reopenBtn:Destroy()
        self._reopenBtn = nil :: any
    end
    table.clear(self._tabPages)
end

return Window
