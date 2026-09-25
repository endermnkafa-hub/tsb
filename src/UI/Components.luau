--!strict
local UserInputService = game:GetService("UserInputService")
local Theme = require("UI.Theme")

local Components = {}

-- -----------------------------------------------------------------------------
-- SECTION HEADER
-- -----------------------------------------------------------------------------
function Components.Section(parent: Instance, title: string, accentName: string?)
    local accent = Theme.GetAccent(accentName)

    local f = Instance.new("Frame")
    f.Name = "Section_" .. title
    f.Size = UDim2.new(1, 0, 0, 28)
    f.BackgroundTransparency = 1
    f.Parent = parent

    local bar = Instance.new("Frame")
    bar.Size = UDim2.new(0, 3, 0, 14)
    bar.Position = UDim2.new(0, 2, 0.5, -7)
    bar.BackgroundColor3 = accent.Primary
    bar.BorderSizePixel = 0
    bar.Parent = f
    Instance.new("UICorner", bar).CornerRadius = UDim.new(1, 0)

    local lbl = Instance.new("TextLabel")
    lbl.Size = UDim2.new(1, -20, 1, 0)
    lbl.Position = UDim2.new(0, 12, 0, 0)
    lbl.BackgroundTransparency = 1
    lbl.Text = string.upper(title)
    lbl.TextColor3 = accent.Primary
    lbl.TextSize = 11
    lbl.Font = Theme.Fonts.Bold
    lbl.TextXAlignment = Enum.TextXAlignment.Left
    lbl.Parent = f

    return f
end

-- -----------------------------------------------------------------------------
-- TOGGLE COMPONENT
-- -----------------------------------------------------------------------------
function Components.Toggle(parent: Instance, title: string, subtitle: string?, defaultVal: boolean, accentName: string?, callback: ((boolean) -> ())?)
    local accent = Theme.GetAccent(accentName)

    local frame = Instance.new("Frame")
    frame.Name = "Toggle_" .. title
    frame.Size = UDim2.new(1, 0, 0, subtitle and 44 or 38)
    frame.BackgroundColor3 = Theme.Colors.Card
    frame.BorderSizePixel = 0
    frame.Parent = parent
    Instance.new("UICorner", frame).CornerRadius = UDim.new(0, 7)

    local stroke = Instance.new("UIStroke")
    stroke.Color = Theme.Colors.BorderSubtle
    stroke.Thickness = 1
    stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
    stroke.Parent = frame

    local titleL = Instance.new("TextLabel")
    titleL.Size = UDim2.new(1, -68, 0, 18)
    titleL.Position = UDim2.new(0, 12, 0, subtitle and 5 or 10)
    titleL.BackgroundTransparency = 1
    titleL.Text = title
    titleL.TextColor3 = Theme.Colors.TextPrimary
    titleL.TextSize = 12
    titleL.Font = Theme.Fonts.Subtitle
    titleL.TextXAlignment = Enum.TextXAlignment.Left
    titleL.Parent = frame

    if subtitle then
        local subL = Instance.new("TextLabel")
        subL.Size = UDim2.new(1, -68, 0, 14)
        subL.Position = UDim2.new(0, 12, 0, 24)
        subL.BackgroundTransparency = 1
        subL.Text = subtitle
        subL.TextColor3 = Theme.Colors.TextSecondary
        subL.TextSize = 10
        subL.Font = Theme.Fonts.Body
        subL.TextXAlignment = Enum.TextXAlignment.Left
        subL.Parent = frame
    end

    local switchBg = Instance.new("Frame")
    switchBg.Size = UDim2.new(0, 40, 0, 20)
    switchBg.Position = UDim2.new(1, -52, 0.5, -10)
    switchBg.BackgroundColor3 = defaultVal and accent.Primary or Theme.Colors.CardHover
    switchBg.BorderSizePixel = 0
    switchBg.Parent = frame
    Instance.new("UICorner", switchBg).CornerRadius = UDim.new(1, 0)

    local switchCirc = Instance.new("Frame")
    switchCirc.Size = UDim2.new(0, 14, 0, 14)
    switchCirc.Position = defaultVal and UDim2.new(1, -17, 0.5, -7) or UDim2.new(0, 3, 0.5, -7)
    switchCirc.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
    switchCirc.BorderSizePixel = 0
    switchCirc.Parent = switchBg
    Instance.new("UICorner", switchCirc).CornerRadius = UDim.new(1, 0)

    local state = defaultVal
    local function SetOn(val: boolean, fireCallback: boolean?)
        state = val
        Theme.Tween(switchBg, 0.16, { BackgroundColor3 = state and accent.Primary or Theme.Colors.CardHover })
        Theme.Tween(switchCirc, 0.16, { Position = state and UDim2.new(1, -17, 0.5, -7) or UDim2.new(0, 3, 0.5, -7) })
        if fireCallback ~= false and callback then
            pcall(callback, state)
        end
    end

    local btn = Instance.new("TextButton")
    btn.Size = UDim2.new(1, 0, 1, 0)
    btn.BackgroundTransparency = 1
    btn.Text = ""
    btn.Parent = frame

    btn.MouseEnter:Connect(function()
        Theme.Tween(frame, 0.12, { BackgroundColor3 = Theme.Colors.CardHover })
        Theme.Tween(stroke, 0.12, { Color = Theme.Colors.BorderActive })
    end)
    btn.MouseLeave:Connect(function()
        Theme.Tween(frame, 0.12, { BackgroundColor3 = Theme.Colors.Card })
        Theme.Tween(stroke, 0.12, { Color = Theme.Colors.BorderSubtle })
    end)
    btn.MouseButton1Click:Connect(function()
        SetOn(not state, true)
    end)

    return {
        Frame = frame,
        SetOn = SetOn,
        GetState = function() return state end
    }
end

-- -----------------------------------------------------------------------------
-- SLIDER COMPONENT
-- -----------------------------------------------------------------------------
function Components.Slider(parent: Instance, title: string, minV: number, maxV: number, defaultV: number, suffix: string?, step: number?, accentName: string?, callback: ((number) -> ())?)
    local accent = Theme.GetAccent(accentName)
    local stepVal = step or 1

    local frame = Instance.new("Frame")
    frame.Name = "Slider_" .. title
    frame.Size = UDim2.new(1, 0, 0, 50)
    frame.BackgroundColor3 = Theme.Colors.Card
    frame.BorderSizePixel = 0
    frame.Parent = parent
    Instance.new("UICorner", frame).CornerRadius = UDim.new(0, 7)

    local stroke = Instance.new("UIStroke")
    stroke.Color = Theme.Colors.BorderSubtle
    stroke.Thickness = 1
    stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
    stroke.Parent = frame

    local titleL = Instance.new("TextLabel")
    titleL.Size = UDim2.new(1, -80, 0, 18)
    titleL.Position = UDim2.new(0, 12, 0, 8)
    titleL.BackgroundTransparency = 1
    titleL.Text = title
    titleL.TextColor3 = Theme.Colors.TextPrimary
    titleL.TextSize = 12
    titleL.Font = Theme.Fonts.Subtitle
    titleL.TextXAlignment = Enum.TextXAlignment.Left
    titleL.Parent = frame

    local valL = Instance.new("TextLabel")
    valL.Size = UDim2.new(0, 70, 0, 18)
    valL.Position = UDim2.new(1, -82, 0, 8)
    valL.BackgroundTransparency = 1
    valL.Text = tostring(defaultV) .. (suffix or "")
    valL.TextColor3 = accent.Primary
    valL.TextSize = 12
    valL.Font = Theme.Fonts.Bold
    valL.TextXAlignment = Enum.TextXAlignment.Right
    valL.Parent = frame

    local trackBg = Instance.new("Frame")
    trackBg.Size = UDim2.new(1, -24, 0, 6)
    trackBg.Position = UDim2.new(0, 12, 0, 34)
    trackBg.BackgroundColor3 = Theme.Colors.Header
    trackBg.BorderSizePixel = 0
    trackBg.Parent = frame
    Instance.new("UICorner", trackBg).CornerRadius = UDim.new(1, 0)

    local curVal = math.clamp(defaultV, minV, maxV)
    local initialPct = (curVal - minV) / (maxV - minV)

    local trackFill = Instance.new("Frame")
    trackFill.Size = UDim2.new(math.clamp(initialPct, 0, 1), 0, 1, 0)
    trackFill.BackgroundColor3 = accent.Primary
    trackFill.BorderSizePixel = 0
    trackFill.Parent = trackBg
    Instance.new("UICorner", trackFill).CornerRadius = UDim.new(1, 0)

    local knob = Instance.new("Frame")
    knob.Size = UDim2.new(0, 12, 0, 12)
    knob.Position = UDim2.new(1, -6, 0.5, -6)
    knob.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
    knob.BorderSizePixel = 0
    knob.Parent = trackFill
    Instance.new("UICorner", knob).CornerRadius = UDim.new(1, 0)

    local sliding = false
    local function SetValue(newVal: number, fireCallback: boolean?)
        curVal = math.clamp(newVal, minV, maxV)
        if stepVal >= 1 then
            curVal = math.floor(curVal / stepVal + 0.5) * stepVal
        else
            curVal = math.floor(curVal * 100 + 0.5) / 100
        end

        local pct = (curVal - minV) / (maxV - minV)
        trackFill.Size = UDim2.new(math.clamp(pct, 0, 1), 0, 1, 0)
        valL.Text = tostring(curVal) .. (suffix or "")

        if fireCallback ~= false and callback then
            pcall(callback, curVal)
        end
    end

    local function UpdateFromInput(inp: any)
        local rel = math.clamp((inp.Position.X - trackBg.AbsolutePosition.X) / trackBg.AbsoluteSize.X, 0, 1)
        local rawVal = minV + (maxV - minV) * rel
        SetValue(rawVal, true)
    end

    local connEnded: RBXScriptConnection? = nil
    local connChanged: RBXScriptConnection? = nil

    trackBg.InputBegan:Connect(function(inp)
        if inp.UserInputType == Enum.UserInputType.MouseButton1 or inp.UserInputType == Enum.UserInputType.Touch then
            sliding = true
            Theme.Tween(knob, 0.1, { Size = UDim2.new(0, 16, 0, 16), Position = UDim2.new(1, -8, 0.5, -8) })
            UpdateFromInput(inp)
        end
    end)

    connEnded = UserInputService.InputEnded:Connect(function(inp)
        if inp.UserInputType == Enum.UserInputType.MouseButton1 or inp.UserInputType == Enum.UserInputType.Touch then
            if sliding then
                sliding = false
                Theme.Tween(knob, 0.1, { Size = UDim2.new(0, 12, 0, 12), Position = UDim2.new(1, -6, 0.5, -6) })
            end
        end
    end)

    connChanged = UserInputService.InputChanged:Connect(function(inp)
        if sliding and (inp.UserInputType == Enum.UserInputType.MouseMovement or inp.UserInputType == Enum.UserInputType.Touch) then
            UpdateFromInput(inp)
        end
    end)

    -- Clean up global connections when this slider frame is destroyed
    frame.AncestryChanged:Connect(function()
        if not frame.Parent then
            if connEnded then connEnded:Disconnect() connEnded = nil end
            if connChanged then connChanged:Disconnect() connChanged = nil end
        end
    end)

    frame.MouseEnter:Connect(function()
        Theme.Tween(stroke, 0.12, { Color = Theme.Colors.BorderActive })
    end)
    frame.MouseLeave:Connect(function()
        Theme.Tween(stroke, 0.12, { Color = Theme.Colors.BorderSubtle })
    end)

    return {
        Frame = frame,
        SetValue = SetValue,
        GetValue = function() return curVal end,
    }
end

-- -----------------------------------------------------------------------------
-- DROPDOWN COMPONENT
-- -----------------------------------------------------------------------------
function Components.Dropdown(parent: Instance, title: string, options: { string }, defaultSelected: string, accentName: string?, callback: ((string) -> ())?)
    local accent = Theme.GetAccent(accentName)

    local frame = Instance.new("Frame")
    frame.Name = "Dropdown_" .. title
    frame.Size = UDim2.new(1, 0, 0, 42)
    frame.BackgroundColor3 = Theme.Colors.Card
    frame.BorderSizePixel = 0
    frame.ClipsDescendants = true
    frame.Parent = parent
    Instance.new("UICorner", frame).CornerRadius = UDim.new(0, 7)

    local stroke = Instance.new("UIStroke")
    stroke.Color = Theme.Colors.BorderSubtle
    stroke.Thickness = 1
    stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
    stroke.Parent = frame

    local titleL = Instance.new("TextLabel")
    titleL.Size = UDim2.new(0, 120, 0, 42)
    titleL.Position = UDim2.new(0, 12, 0, 0)
    titleL.BackgroundTransparency = 1
    titleL.Text = title
    titleL.TextColor3 = Theme.Colors.TextPrimary
    titleL.TextSize = 12
    titleL.Font = Theme.Fonts.Subtitle
    titleL.TextXAlignment = Enum.TextXAlignment.Left
    titleL.Parent = frame

    local selectBtn = Instance.new("TextButton")
    selectBtn.Size = UDim2.new(1, -145, 0, 26)
    selectBtn.Position = UDim2.new(0, 135, 0, 8)
    selectBtn.BackgroundColor3 = Theme.Colors.Header
    selectBtn.BorderSizePixel = 0
    selectBtn.Text = "  " .. tostring(defaultSelected)
    selectBtn.TextColor3 = accent.Primary
    selectBtn.TextSize = 11
    selectBtn.Font = Theme.Fonts.Subtitle
    selectBtn.TextXAlignment = Enum.TextXAlignment.Left
    selectBtn.Parent = frame
    Instance.new("UICorner", selectBtn).CornerRadius = UDim.new(0, 5)

    local arrow = Instance.new("TextLabel")
    arrow.Size = UDim2.new(0, 20, 1, 0)
    arrow.Position = UDim2.new(1, -22, 0, 0)
    arrow.BackgroundTransparency = 1
    arrow.Text = "▼"
    arrow.TextColor3 = Theme.Colors.TextSecondary
    arrow.TextSize = 9
    arrow.Font = Theme.Fonts.Bold
    arrow.Parent = selectBtn

    local listFrame = Instance.new("Frame")
    listFrame.Size = UDim2.new(1, -24, 0, #options * 26)
    listFrame.Position = UDim2.new(0, 12, 0, 44)
    listFrame.BackgroundTransparency = 1
    listFrame.Parent = frame

    local listLayout = Instance.new("UIListLayout")
    listLayout.SortOrder = Enum.SortOrder.LayoutOrder
    listLayout.Padding = UDim.new(0, 2)
    listLayout.Parent = listFrame

    local isOpen = false
    local currentSelected = defaultSelected

    local function RebuildOptions(opts: { string })
        for _, child in ipairs(listFrame:GetChildren()) do
            if child:IsA("TextButton") then
                child:Destroy()
            end
        end
        listFrame.Size = UDim2.new(1, -24, 0, #opts * 26)

        for idx, opt in ipairs(opts) do
            local optBtn = Instance.new("TextButton")
            optBtn.Size = UDim2.new(1, 0, 0, 26)
            optBtn.BackgroundColor3 = Theme.Colors.Header
            optBtn.BorderSizePixel = 0
            optBtn.Text = "  " .. opt
            optBtn.TextColor3 = (opt == currentSelected) and accent.Primary or Theme.Colors.TextSecondary
            optBtn.TextSize = 11
            optBtn.Font = Theme.Fonts.Body
            optBtn.TextXAlignment = Enum.TextXAlignment.Left
            optBtn.LayoutOrder = idx
            optBtn.Parent = listFrame
            Instance.new("UICorner", optBtn).CornerRadius = UDim.new(0, 4)

            optBtn.MouseEnter:Connect(function()
                Theme.Tween(optBtn, 0.1, { BackgroundColor3 = Theme.Colors.CardHover, TextColor3 = Theme.Colors.TextPrimary })
            end)
            optBtn.MouseLeave:Connect(function()
                local isSel = (opt == currentSelected)
                Theme.Tween(optBtn, 0.1, { BackgroundColor3 = Theme.Colors.Header, TextColor3 = isSel and accent.Primary or Theme.Colors.TextSecondary })
            end)
            optBtn.MouseButton1Click:Connect(function()
                SelectOption(opt)
            end)
        end
    end

    local currentOpts = options
    local function ToggleOpen()
        isOpen = not isOpen
        local targetH = isOpen and (48 + #currentOpts * 28) or 42
        arrow.Text = isOpen and "▲" or "▼"
        Theme.Tween(frame, 0.18, { Size = UDim2.new(1, 0, 0, targetH) })
    end

    local function SelectOption(opt: string)
        currentSelected = opt
        selectBtn.Text = "  " .. opt
        ToggleOpen()
        if callback then
            pcall(callback, opt)
        end
    end

    local function SetOptions(newOpts: { string })
        currentOpts = newOpts
        RebuildOptions(newOpts)
        if isOpen then
            local targetH = 48 + #newOpts * 28
            Theme.Tween(frame, 0.18, { Size = UDim2.new(1, 0, 0, targetH) })
        end
    end

    RebuildOptions(options)
    selectBtn.MouseButton1Click:Connect(ToggleOpen)

    return {
        Frame = frame,
        Select = SelectOption,
        SetOptions = SetOptions,
        GetSelected = function() return currentSelected end,
    }
end

-- -----------------------------------------------------------------------------
-- BUTTON COMPONENT
-- -----------------------------------------------------------------------------
function Components.Button(parent: Instance, title: string, btnText: string, kind: string?, accentName: string?, callback: (() -> ())?)
    local accent = Theme.GetAccent(accentName)
    local btnBgColor = accent.Primary
    if kind == "Danger" then btnBgColor = Theme.Colors.Danger
    elseif kind == "Secondary" then btnBgColor = Theme.Colors.CardHover
    elseif kind == "Success" then btnBgColor = Theme.Colors.Success end

    local frame = Instance.new("Frame")
    frame.Name = "Button_" .. title
    frame.Size = UDim2.new(1, 0, 0, 40)
    frame.BackgroundColor3 = Theme.Colors.Card
    frame.BorderSizePixel = 0
    frame.Parent = parent
    Instance.new("UICorner", frame).CornerRadius = UDim.new(0, 7)

    local stroke = Instance.new("UIStroke")
    stroke.Color = Theme.Colors.BorderSubtle
    stroke.Thickness = 1
    stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
    stroke.Parent = frame

    local titleL = Instance.new("TextLabel")
    titleL.Size = UDim2.new(1, -125, 1, 0)
    titleL.Position = UDim2.new(0, 12, 0, 0)
    titleL.BackgroundTransparency = 1
    titleL.Text = title
    titleL.TextColor3 = Theme.Colors.TextPrimary
    titleL.TextSize = 12
    titleL.Font = Theme.Fonts.Subtitle
    titleL.TextXAlignment = Enum.TextXAlignment.Left
    titleL.Parent = frame

    local btn = Instance.new("TextButton")
    btn.Size = UDim2.new(0, 105, 0, 26)
    btn.Position = UDim2.new(1, -117, 0.5, -13)
    btn.BackgroundColor3 = btnBgColor
    btn.BorderSizePixel = 0
    btn.Text = btnText
    btn.TextColor3 = Color3.fromRGB(255, 255, 255)
    btn.TextSize = 11
    btn.Font = Theme.Fonts.Bold
    btn.Parent = frame
    Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 5)

    btn.MouseEnter:Connect(function()
        Theme.Tween(btn, 0.1, { BackgroundTransparency = 0.15 })
    end)
    btn.MouseLeave:Connect(function()
        Theme.Tween(btn, 0.1, { BackgroundTransparency = 0 })
    end)
    btn.MouseButton1Down:Connect(function()
        Theme.Tween(btn, 0.05, { Size = UDim2.new(0, 101, 0, 24), Position = UDim2.new(1, -115, 0.5, -12) })
    end)
    btn.MouseButton1Up:Connect(function()
        Theme.Tween(btn, 0.1, { Size = UDim2.new(0, 105, 0, 26), Position = UDim2.new(1, -117, 0.5, -13) })
    end)
    btn.MouseButton1Click:Connect(function()
        if callback then pcall(callback) end
    end)

    return { Frame = frame, Button = btn }
end

-- -----------------------------------------------------------------------------
-- KEYBIND COMPONENT
-- -----------------------------------------------------------------------------
function Components.Keybind(parent: Instance, title: string, defaultKey: EnumItem, accentName: string?, callback: ((EnumItem) -> ())?)
    local accent = Theme.GetAccent(accentName)

    local frame = Instance.new("Frame")
    frame.Name = "Keybind_" .. title
    frame.Size = UDim2.new(1, 0, 0, 40)
    frame.BackgroundColor3 = Theme.Colors.Card
    frame.BorderSizePixel = 0
    frame.Parent = parent
    Instance.new("UICorner", frame).CornerRadius = UDim.new(0, 7)

    local stroke = Instance.new("UIStroke")
    stroke.Color = Theme.Colors.BorderSubtle
    stroke.Thickness = 1
    stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
    stroke.Parent = frame

    local titleL = Instance.new("TextLabel")
    titleL.Size = UDim2.new(1, -110, 1, 0)
    titleL.Position = UDim2.new(0, 12, 0, 0)
    titleL.BackgroundTransparency = 1
    titleL.Text = title
    titleL.TextColor3 = Theme.Colors.TextPrimary
    titleL.TextSize = 12
    titleL.Font = Theme.Fonts.Subtitle
    titleL.TextXAlignment = Enum.TextXAlignment.Left
    titleL.Parent = frame

    local keyBtn = Instance.new("TextButton")
    keyBtn.Size = UDim2.new(0, 90, 0, 24)
    keyBtn.Position = UDim2.new(1, -102, 0.5, -12)
    keyBtn.BackgroundColor3 = Theme.Colors.Header
    keyBtn.BorderSizePixel = 0
    keyBtn.Text = defaultKey.Name
    keyBtn.TextColor3 = accent.Primary
    keyBtn.TextSize = 11
    keyBtn.Font = Theme.Fonts.Bold
    keyBtn.Parent = frame
    Instance.new("UICorner", keyBtn).CornerRadius = UDim.new(0, 5)

    local keyStroke = Instance.new("UIStroke")
    keyStroke.Color = Theme.Colors.BorderSubtle
    keyStroke.Thickness = 1
    keyStroke.Parent = keyBtn

    local isListening = false
    local currentKey = defaultKey

    local function SetKey(key: EnumItem)
        currentKey = key
        keyBtn.Text = key.Name
        isListening = false
        keyStroke.Color = Theme.Colors.BorderSubtle
        keyBtn.TextColor3 = accent.Primary
        if callback then pcall(callback, key) end
    end

    keyBtn.MouseButton1Click:Connect(function()
        if isListening then return end
        isListening = true
        keyBtn.Text = "..."
        keyStroke.Color = accent.Primary
        keyBtn.TextColor3 = Theme.Colors.Warning

        local conn
        conn = UserInputService.InputBegan:Connect(function(input)
            if input.UserInputType == Enum.UserInputType.Keyboard then
                conn:Disconnect()
                SetKey(input.KeyCode)
            elseif input.UserInputType == Enum.UserInputType.MouseButton2 then
                -- Right-click cancels
                conn:Disconnect()
                SetKey(currentKey)
            end
        end)
    end)

    return {
        Frame = frame,
        SetKey = SetKey,
        GetKey = function() return currentKey end,
    }
end

-- -----------------------------------------------------------------------------
-- STATUS BADGE COMPONENT
-- -----------------------------------------------------------------------------
function Components.StatusBadge(parent: Instance, title: string, statusText: string, statusColor: Color3?)
    local frame = Instance.new("Frame")
    frame.Name = "Status_" .. title
    frame.Size = UDim2.new(1, 0, 0, 36)
    frame.BackgroundColor3 = Theme.Colors.Card
    frame.BorderSizePixel = 0
    frame.Parent = parent
    Instance.new("UICorner", frame).CornerRadius = UDim.new(0, 7)

    local stroke = Instance.new("UIStroke")
    stroke.Color = Theme.Colors.BorderSubtle
    stroke.Thickness = 1
    stroke.Parent = frame

    local titleL = Instance.new("TextLabel")
    titleL.Size = UDim2.new(1, -120, 1, 0)
    titleL.Position = UDim2.new(0, 12, 0, 0)
    titleL.BackgroundTransparency = 1
    titleL.Text = title
    titleL.TextColor3 = Theme.Colors.TextPrimary
    titleL.TextSize = 12
    titleL.Font = Theme.Fonts.Subtitle
    titleL.TextXAlignment = Enum.TextXAlignment.Left
    titleL.Parent = frame

    local badge = Instance.new("Frame")
    badge.Size = UDim2.new(0, 100, 0, 22)
    badge.Position = UDim2.new(1, -112, 0.5, -11)
    badge.BackgroundColor3 = Theme.Colors.Header
    badge.BorderSizePixel = 0
    badge.Parent = frame
    Instance.new("UICorner", badge).CornerRadius = UDim.new(0, 5)

    local badgeL = Instance.new("TextLabel")
    badgeL.Size = UDim2.new(1, 0, 1, 0)
    badgeL.BackgroundTransparency = 1
    badgeL.Text = statusText
    badgeL.TextColor3 = statusColor or Theme.Colors.Success
    badgeL.TextSize = 10
    badgeL.Font = Theme.Fonts.Bold
    badgeL.Parent = badge

    local function Update(newText: string, newColor: Color3?)
        badgeL.Text = newText
        if newColor then badgeL.TextColor3 = newColor end
    end

    return { Frame = frame, Update = Update }
end

return Components
