--!strict
local Theme = require("UI.Theme")

local Notifications = {}
Notifications.__index = Notifications

export type NotificationType = "Info" | "Success" | "Warning" | "Error"

function Notifications.new(parentGui: Instance, accentName: string?)
    local container = Instance.new("Frame")
    container.Name = "NotificationsContainer"
    container.Size = UDim2.new(0, 280, 1, -20)
    container.Position = UDim2.new(1, -290, 0, 10)
    container.BackgroundTransparency = 1
    container.Parent = parentGui

    local layout = Instance.new("UIListLayout")
    layout.SortOrder = Enum.SortOrder.LayoutOrder
    layout.VerticalAlignment = Enum.VerticalAlignment.Bottom
    layout.Padding = UDim.new(0, 8)
    layout.Parent = container

    local self = setmetatable({
        _container = container,
        _accentName = accentName or "Cyan Neon",
        _count = 0,
    }, Notifications)
    return self
end

function Notifications:Show(title: string, message: string, duration: number?, kind: NotificationType?)
    local dur = duration or 2.8
    local k = kind or "Info"
    self._count += 1

    local accent = Theme.GetAccent(self._accentName)
    local barColor = accent.Primary
    if k == "Success" then barColor = Theme.Colors.Success
    elseif k == "Warning" then barColor = Theme.Colors.Warning
    elseif k == "Error" then barColor = Theme.Colors.Danger end

    local toast = Instance.new("Frame")
    toast.Name = "Toast_" .. tostring(self._count)
    toast.Size = UDim2.new(1, 0, 0, 54)
    toast.Position = UDim2.new(1, 40, 0, 0) -- starts off-screen right
    toast.BackgroundColor3 = Theme.Colors.Card
    toast.BorderSizePixel = 0
    toast.LayoutOrder = self._count
    toast.Parent = self._container
    Instance.new("UICorner", toast).CornerRadius = UDim.new(0, 8)

    local stroke = Instance.new("UIStroke")
    stroke.Color = Theme.Colors.Border
    stroke.Thickness = 1
    stroke.Parent = toast

    local sideBar = Instance.new("Frame")
    sideBar.Size = UDim2.new(0, 4, 1, -12)
    sideBar.Position = UDim2.new(0, 6, 0.5, -21)
    sideBar.BackgroundColor3 = barColor
    sideBar.BorderSizePixel = 0
    sideBar.Parent = toast
    Instance.new("UICorner", sideBar).CornerRadius = UDim.new(1, 0)

    local titleLbl = Instance.new("TextLabel")
    titleLbl.Size = UDim2.new(1, -26, 0, 18)
    titleLbl.Position = UDim2.new(0, 18, 0, 7)
    titleLbl.BackgroundTransparency = 1
    titleLbl.Text = title
    titleLbl.TextColor3 = Theme.Colors.TextPrimary
    titleLbl.TextSize = 12
    titleLbl.Font = Theme.Fonts.Bold
    titleLbl.TextXAlignment = Enum.TextXAlignment.Left
    titleLbl.Parent = toast

    local msgLbl = Instance.new("TextLabel")
    msgLbl.Size = UDim2.new(1, -26, 0, 18)
    msgLbl.Position = UDim2.new(0, 18, 0, 26)
    msgLbl.BackgroundTransparency = 1
    msgLbl.Text = message
    msgLbl.TextColor3 = Theme.Colors.TextSecondary
    msgLbl.TextSize = 10
    msgLbl.Font = Theme.Fonts.Body
    msgLbl.TextXAlignment = Enum.TextXAlignment.Left
    msgLbl.TextTruncate = Enum.TextTruncate.AtEnd
    msgLbl.Parent = toast

    -- Slide in animation
    Theme.Tween(toast, 0.22, { BackgroundTransparency = 0 })
    
    -- Lifetime countdown & Slide out
    task.delay(dur, function()
        if toast and toast.Parent then
            local tw = Theme.Tween(toast, 0.2, { BackgroundTransparency = 1 })
            Theme.Tween(titleLbl, 0.2, { TextTransparency = 1 })
            Theme.Tween(msgLbl, 0.2, { TextTransparency = 1 })
            Theme.Tween(sideBar, 0.2, { BackgroundTransparency = 1 })
            Theme.Tween(stroke, 0.2, { Transparency = 1 })
            tw.Completed:Connect(function()
                toast:Destroy()
            end)
        end
    end)
end

function Notifications:Destroy()
    if self._container then
        self._container:Destroy()
        self._container = nil :: any
    end
end

return Notifications
