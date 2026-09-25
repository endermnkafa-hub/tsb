--!strict
local ConfigSchema = require("Config.ConfigSchema")
local HttpService = game:GetService("HttpService")

local ConfigManager = {}
ConfigManager.__index = ConfigManager

function ConfigManager.new(logger: any)
    local self = setmetatable({
        FileName = "4080_Hub_TSB_Config.json",
        Config = {},
        RegisteredUI = {},
        _logger = logger,
        _degradedMode = false,
    }, ConfigManager)

    self:ResetToDefaults()

    if typeof(writefile) ~= "function" or typeof(readfile) ~= "function" then
        self._degradedMode = true
        if self._logger then
            self._logger:Warn("ConfigManager", "Running in In-Memory Degraded Mode (writefile API unsupported)")
        end
    end

    return self
end

function ConfigManager:ResetToDefaults()
    for catName, catSchema in pairs(ConfigSchema) do
        self.Config[catName] = {}
        for key, spec in pairs(catSchema) do
            self.Config[catName][key] = spec.Default
        end
    end
end

function ConfigManager:ValidateAndClamp(data: any): any
    -- Strict Runtime Schema Enforcement with EnumItem type validation
    for catName, catSchema in pairs(ConfigSchema) do
        if type(data[catName]) == "table" then
            for key, spec in pairs(catSchema) do
                local val = data[catName][key]
                if val ~= nil then
                    if spec.Type == "number" then
                        if type(val) == "number" then
                            if spec.Min and spec.Max then
                                data[catName][key] = math.clamp(val, spec.Min, spec.Max)
                            end
                        else
                            data[catName][key] = spec.Default
                        end
                    elseif spec.Type == "boolean" then
                        if type(val) ~= "boolean" then
                            data[catName][key] = spec.Default
                        end
                    elseif spec.Type == "string" then
                        if type(val) ~= "string" then
                            data[catName][key] = spec.Default
                        end
                    elseif spec.Type == "EnumItem" then
                        if typeof(val) == "EnumItem" then
                            if spec.EnumType and val.EnumType ~= spec.EnumType then
                                data[catName][key] = spec.Default
                            end
                        else
                            data[catName][key] = spec.Default
                        end
                    end
                else
                    data[catName][key] = spec.Default
                end
            end
        else
            data[catName] = {}
            for key, spec in pairs(catSchema) do
                data[catName][key] = spec.Default
            end
        end
    end
    return data
end

local function SerializeValue(val: any): any
    if typeof(val) == "Color3" then
        return { __type = "Color3", R = val.R, G = val.G, B = val.B }
    elseif typeof(val) == "EnumItem" then
        return { __type = "EnumItem", EnumType = tostring(val.EnumType), Name = val.Name }
    elseif type(val) == "table" then
        local t = {}
        for k, v in pairs(val) do t[tostring(k)] = SerializeValue(v) end
        return t
    else
        return val
    end
end

local function DeserializeValue(val: any): any
    if type(val) == "table" then
        if val.__type == "Color3" then
            return Color3.new(val.R or 0, val.G or 0, val.B or 0)
        elseif val.__type == "EnumItem" then
            local enumTypeStr = val.EnumType or ""
            local enumName = val.Name or ""
            if enumTypeStr:find("KeyCode") and Enum.KeyCode[enumName] then
                return Enum.KeyCode[enumName]
            elseif enumTypeStr:find("UserInputType") and Enum.UserInputType[enumName] then
                return Enum.UserInputType[enumName]
            end
            return val
        else
            local t = {}
            for k, v in pairs(val) do t[k] = DeserializeValue(v) end
            return t
        end
    else
        return val
    end
end

function ConfigManager:Save(): (boolean, string?)
    if self._degradedMode then
        return true, "In-Memory"
    end
    self:ValidateAndClamp(self.Config)

    local ok, err = pcall(function()
        local dataToSave = {}
        for cat, val in pairs(self.Config) do
            dataToSave[cat] = SerializeValue(val)
        end
        local json = HttpService:JSONEncode(dataToSave)
        writefile(self.FileName, json)
    end)
    if ok and self._logger then self._logger:Info("Config", "Saved validated config to disk.") end
    return ok, err
end

function ConfigManager:Load(): (boolean, string?)
    if self._degradedMode or not isfile(self.FileName) then
        return false, "Config file not found or degraded"
    end
    local ok, err = pcall(function()
        local raw = readfile(self.FileName)
        local rawData = HttpService:JSONDecode(raw)
        local decoded = DeserializeValue(rawData)
        self:ValidateAndClamp(decoded)
        self.Config = decoded
        self:RefreshUI()
    end)
    if ok and self._logger then self._logger:Info("Config", "Loaded and validated config from disk.") end
    return ok, err
end

function ConfigManager:RefreshUI()
    for _, item in ipairs(self.RegisteredUI) do
        if item.Getter and item.Setter then
            pcall(function()
                local val = item.Getter()
                if val ~= nil then item.Setter(val) end
            end)
        end
    end
end

function ConfigManager:Reset()
    if typeof(delfile) == "function" and isfile(self.FileName) then
        pcall(function() delfile(self.FileName) end)
    end
    self:ResetToDefaults()
    self:RefreshUI()
end

return ConfigManager
