--!strict
local Maid = {}
Maid.__index = Maid

export type Task = (() -> ()) | RBXScriptConnection | { Disconnect: (any) -> () } | { Destroy: (any) -> () } | Instance

function Maid.new()
    local self = setmetatable({
        _tasks = {},
    }, Maid)
    return self
end

function Maid:GiveTask(taskItem: Task): any
    assert(taskItem ~= nil, "Task cannot be nil")
    local taskId = #self._tasks + 1
    self._tasks[taskId] = taskItem
    return taskId
end

function Maid:DoCleaning()
    local tasks = self._tasks
    for index, taskItem in pairs(tasks) do
        if typeof(taskItem) == "RBXScriptConnection" then
            taskItem:Disconnect()
        elseif type(taskItem) == "function" then
            pcall(taskItem)
        elseif typeof(taskItem) == "Instance" then
            pcall(function() taskItem:Destroy() end)
        elseif type(taskItem) == "table" then
            if type(taskItem.Destroy) == "function" then
                pcall(function() taskItem:Destroy() end)
            elseif type(taskItem.Disconnect) == "function" then
                pcall(function() taskItem:Disconnect() end)
            elseif type(taskItem.DoCleaning) == "function" then
                pcall(function() taskItem:DoCleaning() end)
            end
        end
        tasks[index] = nil
    end
end

function Maid:Destroy()
    self:DoCleaning()
end

return Maid
