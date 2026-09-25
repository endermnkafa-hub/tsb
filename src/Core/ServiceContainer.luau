--!strict
local ServiceContainer = {}
ServiceContainer.__index = ServiceContainer

export type ServiceEntry = {
    Name: string,
    Instance: any?,
    Factory: ((container: any) -> any)?,
    Dependencies: { string },
    Resolved: boolean,
}

function ServiceContainer.new()
    local self = setmetatable({
        _services = {},
        _factories = {},
        _dependencies = {}, -- Adjacency list for real DAG
        _resolving = {},
    }, ServiceContainer)
    return self
end

function ServiceContainer:Register(name: string, instanceOrFactory: any, dependencies: { string }?)
    assert(name and instanceOrFactory, "ServiceContainer:Register requires name and instance/factory")
    local deps = dependencies or {}
    self._dependencies[name] = deps

    if type(instanceOrFactory) == "function" then
        self._factories[name] = instanceOrFactory
    else
        self._services[name] = instanceOrFactory
    end
    return instanceOrFactory
end

function ServiceContainer:Get(name: string): any
    if self._services[name] then
        return self._services[name]
    end

    if self._factories[name] then
        if self._resolving[name] then
            error(string.format("[ServiceContainer] Circular dependency detected while resolving service '%s'!", name))
        end

        self._resolving[name] = true
        local factory = self._factories[name]
        local instance = factory(self)
        self._resolving[name] = nil

        self._services[name] = instance
        self._factories[name] = nil
        return instance
    end

    error(string.format("[ServiceContainer] Service '%s' is not registered!", tostring(name)))
end

function ServiceContainer:Has(name: string): boolean
    return self._services[name] ~= nil or self._factories[name] ~= nil
end

function ServiceContainer:BuildGraph(): { [string]: { string } }
    local graph = {}
    for name, deps in pairs(self._dependencies) do
        graph[name] = deps
    end
    return graph
end

-- Kahn's Algorithm / Topological Sort for Dependency Graph
-- Resolves services in dependency-first order and detects any cyclic dependencies
function ServiceContainer:TopologicalSort(): ({ string }, boolean, string?)
    local inDegree = {}
    local adjList = {}
    local allNodes = {}

    -- Collect all registered nodes
    for name, _ in pairs(self._dependencies) do
        allNodes[name] = true
        inDegree[name] = 0
        adjList[name] = {}
    end
    for name, _ in pairs(self._services) do
        if not allNodes[name] then
            allNodes[name] = true
            inDegree[name] = 0
            adjList[name] = {}
        end
    end
    for name, _ in pairs(self._factories) do
        if not allNodes[name] then
            allNodes[name] = true
            inDegree[name] = 0
            adjList[name] = {}
        end
    end

    -- Build adjacency list: if A depends on B, edge is B -> A (B must resolve before A)
    for node, deps in pairs(self._dependencies) do
        for _, dep in ipairs(deps) do
            if allNodes[dep] then
                table.insert(adjList[dep], node)
                inDegree[node] = (inDegree[node] or 0) + 1
            end
        end
    end

    -- Queue for nodes with in-degree 0 (no unresolved dependencies)
    local queue = {}
    for node, deg in pairs(inDegree) do
        if deg == 0 then
            table.insert(queue, node)
        end
    end

    local order = {}
    while #queue > 0 do
        local curr = table.remove(queue, 1)
        table.insert(order, curr)

        for _, neighbor in ipairs(adjList[curr] or {}) do
            inDegree[neighbor] -= 1
            if inDegree[neighbor] == 0 then
                table.insert(queue, neighbor)
            end
        end
    end

    -- If order contains all nodes, no cycles exist; otherwise a cycle was detected
    local totalCount = 0
    for _ in pairs(allNodes) do totalCount += 1 end

    local hasCycle = (#order < totalCount)
    local cycleNode = nil
    if hasCycle then
        for node, deg in pairs(inDegree) do
            if deg > 0 then
                cycleNode = node
                break
            end
        end
    end

    return order, not hasCycle, cycleNode
end

function ServiceContainer:ResolveAllInOrder(): { string }
    local order, noCycles, cycleNode = self:TopologicalSort()
    if not noCycles then
        error(string.format("[ServiceContainer] Cannot initialize services due to circular dependency involving '%s'!", tostring(cycleNode)))
    end

    for _, sName in ipairs(order) do
        self:Get(sName)
    end
    return order
end

return ServiceContainer
