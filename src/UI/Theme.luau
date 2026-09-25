--!strict
local TweenService = game:GetService("TweenService")

local Theme = {
    Accents = {
        ["Cyan Neon"] = {
            Primary = Color3.fromRGB(0, 220, 255),
            Hover = Color3.fromRGB(40, 235, 255),
            Glow = Color3.fromRGB(0, 170, 220),
            Dim = Color3.fromRGB(0, 90, 120),
        },
        ["Crimson Red"] = {
            Primary = Color3.fromRGB(255, 60, 80),
            Hover = Color3.fromRGB(255, 95, 115),
            Glow = Color3.fromRGB(210, 40, 60),
            Dim = Color3.fromRGB(120, 30, 45),
        },
        ["Purple Velvet"] = {
            Primary = Color3.fromRGB(170, 80, 255),
            Hover = Color3.fromRGB(195, 115, 255),
            Glow = Color3.fromRGB(140, 50, 220),
            Dim = Color3.fromRGB(80, 35, 125),
        },
        ["Emerald Green"] = {
            Primary = Color3.fromRGB(45, 220, 125),
            Hover = Color3.fromRGB(75, 240, 150),
            Glow = Color3.fromRGB(30, 180, 95),
            Dim = Color3.fromRGB(20, 95, 55),
        },
    },
    Colors = {
        Background = Color3.fromRGB(13, 15, 22),
        Header = Color3.fromRGB(18, 21, 30),
        Sidebar = Color3.fromRGB(16, 19, 28),
        Card = Color3.fromRGB(22, 26, 39),
        CardHover = Color3.fromRGB(28, 33, 50),
        CardActive = Color3.fromRGB(34, 40, 62),
        Border = Color3.fromRGB(36, 42, 64),
        BorderSubtle = Color3.fromRGB(28, 32, 48),
        BorderActive = Color3.fromRGB(60, 72, 108),
        
        TextPrimary = Color3.fromRGB(245, 248, 255),
        TextSecondary = Color3.fromRGB(152, 162, 192),
        TextMuted = Color3.fromRGB(92, 100, 128),
        TextDim = Color3.fromRGB(65, 72, 95),
        
        Success = Color3.fromRGB(46, 213, 115),
        Warning = Color3.fromRGB(255, 171, 0),
        Danger = Color3.fromRGB(255, 71, 87),
        Info = Color3.fromRGB(0, 180, 255),
    },
    Fonts = {
        Title = Enum.Font.GothamBold,
        Subtitle = Enum.Font.GothamMedium,
        Body = Enum.Font.Gotham,
        Bold = Enum.Font.GothamBold,
        Mono = Enum.Font.Code,
    },
}

function Theme.GetAccent(name: string?): { Primary: Color3, Hover: Color3, Glow: Color3, Dim: Color3 }
    local key = name or "Cyan Neon"
    return Theme.Accents[key] or Theme.Accents["Cyan Neon"]
end

function Theme.Tween(inst: Instance, duration: number?, props: { [string]: any }, style: Enum.EasingStyle?, dir: Enum.EasingDirection?): Tween
    local ti = TweenInfo.new(
        duration or 0.18,
        style or Enum.EasingStyle.Quart,
        dir or Enum.EasingDirection.Out
    )
    local tw = TweenService:Create(inst, ti, props)
    tw:Play()
    return tw
end

return Theme
