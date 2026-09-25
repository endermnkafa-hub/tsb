--!strict
local Signal = require("Core.Signal")

export type StateDefinition = {
    Priority: number?,
    Timeout: number?, -- Max duration in seconds before auto-recovering to fallback
    FallbackState: string?,
    OnEnter: ((self: any, prevState: string, ctx: any, reason: string?) -> ())?,
    OnUpdate: ((self: any, dt: number, ctx: any) -> ())?,
    OnExit: ((self: any, nextState: string, ctx: any) -> ())?,
    CanEnter: ((self: any, ctx: any) -> boolean)?,
    CanExit: ((self: any, ctx: any) -> boolean)?,
}

export type TransitionTelemetry = {
    From: string,
    To: string,
    Reason: string,
    Source: string,
    Timestamp: number,
    DurationInPrev: number,
}

local StateMachine = {}
StateMachine.__index = StateMachine

function StateMachine.new(initialState: string?, logger: any?)
    local self = setmetatable({
        CurrentState = initialState or "IDLE",
        PreviousState = "NONE",
        StateStartTime = os.clock(),
        TransitionsCount = 0,
        History = {},
        TelemetryLogs = {}, -- Structured Transition Telemetry
        MaxTelemetryLogs = 50,
        StateChanged = Signal.new(),
        _logger = logger,
        _states = {},
        _transitions = {},
        _priorities = {
            EMERGENCY_STOP = 100,
            SKY_ESCAPE     = 90,
            SKY_DODGE      = 80,
            VOID_KILL      = 70,
            MASS_BRING     = 60,
            BEHIND_TP      = 50,
            COMBAT         = 30,
            IDLE           = 0,
        },
    }, StateMachine)

    self:RegisterDefaultTransitions()
    return self
end

function StateMachine:RegisterState(name: string, def: StateDefinition)
    self._states[name] = def
    if def.Priority then
        self._priorities[name] = def.Priority
    end
end

function StateMachine:RegisterTransition(fromState: string | { string }, toState: string, condition: ((ctx: any) -> boolean)?)
    local fromList = type(fromState) == "table" and fromState or { fromState }
    for _, f in ipairs(fromList) do
        local key = f .. "->" .. toState
        self._transitions[key] = {
            From = f,
            To = toState,
            Condition = condition,
        }
    end
end

function StateMachine:RegisterDefaultTransitions()
    -- Explicit Strict Whitelist Transitions Graph
    self:RegisterTransition("IDLE", "COMBAT")
    self:RegisterTransition("IDLE", "BEHIND_TP")
    self:RegisterTransition("IDLE", "MASS_BRING")
    self:RegisterTransition("IDLE", "VOID_KILL")
    self:RegisterTransition("IDLE", "SKY_DODGE")
    self:RegisterTransition("IDLE", "SKY_ESCAPE")
    self:RegisterTransition("IDLE", "EMERGENCY_STOP")

    self:RegisterTransition("COMBAT", "IDLE")
    self:RegisterTransition("COMBAT", "BEHIND_TP")
    self:RegisterTransition("COMBAT", "MASS_BRING")
    self:RegisterTransition("COMBAT", "VOID_KILL")
    self:RegisterTransition("COMBAT", "SKY_DODGE")
    self:RegisterTransition("COMBAT", "SKY_ESCAPE")
    self:RegisterTransition("COMBAT", "EMERGENCY_STOP")

    self:RegisterTransition("BEHIND_TP", "IDLE")
    self:RegisterTransition("BEHIND_TP", "COMBAT")
    self:RegisterTransition("BEHIND_TP", "SKY_DODGE")
    self:RegisterTransition("BEHIND_TP", "SKY_ESCAPE")
    self:RegisterTransition("BEHIND_TP", "EMERGENCY_STOP")

    self:RegisterTransition("MASS_BRING", "IDLE")
    self:RegisterTransition("MASS_BRING", "COMBAT")
    self:RegisterTransition("MASS_BRING", "EMERGENCY_STOP")

    self:RegisterTransition("VOID_KILL", "IDLE")
    self:RegisterTransition("VOID_KILL", "EMERGENCY_STOP")

    self:RegisterTransition("SKY_DODGE", "IDLE")
    self:RegisterTransition("SKY_DODGE", "COMBAT")
    self:RegisterTransition("SKY_DODGE", "EMERGENCY_STOP")

    self:RegisterTransition("SKY_ESCAPE", "IDLE")
    self:RegisterTransition("SKY_ESCAPE", "EMERGENCY_STOP")

    self:RegisterTransition("EMERGENCY_STOP", "IDLE")
end

function StateMachine:CanTransitionTo(targetState: string, ctx: any): boolean
    if self.CurrentState == targetState then return false end

    if targetState == "EMERGENCY_STOP" then return true end
    if self.CurrentState == "EMERGENCY_STOP" and targetState ~= "IDLE" then return false end

    local transKey = self.CurrentState .. "->" .. targetState
    local transRule = self._transitions[transKey]
    if not transRule then
        return false -- Whitelist guard
    end

    if transRule.Condition and not transRule.Condition(ctx) then
        return false
    end

    local currentDef = self._states[self.CurrentState]
    if currentDef and currentDef.CanExit and not currentDef:CanExit(ctx) then
        return false
    end

    local currentPri = self._priorities[self.CurrentState] or 0
    local targetPri = self._priorities[targetState] or 0

    if targetPri < currentPri and currentPri >= 70 then
        return false
    end

    local targetDef = self._states[targetState]
    if targetDef and targetDef.CanEnter and not targetDef:CanEnter(ctx) then
        return false
    end

    return true
end

function StateMachine:TransitionTo(newState: string, ctx: any, reason: string?, source: string?, force: boolean?): boolean
    if not force and not self:CanTransitionTo(newState, ctx) then
        return false
    end

    local now = os.clock()
    local oldState = self.CurrentState
    local durationInPrev = now - self.StateStartTime

    local oldDef = self._states[oldState]
    if oldDef and oldDef.OnExit then
        if self._logger then
            self._logger:SafeCall("FSM.OnExit", oldDef.OnExit, oldDef, newState, ctx)
        else
            pcall(oldDef.OnExit, oldDef, newState, ctx)
        end
    end

    table.insert(self.History, 1, oldState)
    if #self.History > 20 then table.remove(self.History) end

    -- Record Structured Telemetry Entry
    local telemetry: TransitionTelemetry = {
        From = oldState,
        To = newState,
        Reason = reason or "Standard Transition",
        Source = source or "Engine",
        Timestamp = now,
        DurationInPrev = durationInPrev,
    }
    table.insert(self.TelemetryLogs, 1, telemetry)
    if #self.TelemetryLogs > self.MaxTelemetryLogs then
        table.remove(self.TelemetryLogs)
    end

    self.PreviousState = oldState
    self.CurrentState = newState
    self.StateStartTime = now
    self.TransitionsCount += 1

    local newDef = self._states[newState]
    if newDef and newDef.OnEnter then
        if self._logger then
            self._logger:SafeCall("FSM.OnEnter", newDef.OnEnter, newDef, oldState, ctx, reason)
        else
            pcall(newDef.OnEnter, newDef, oldState, ctx, reason)
        end
    end

    self.StateChanged:Fire(newState, oldState, telemetry)
    return true
end

function StateMachine:Rollback(ctx: any): boolean
    if #self.History > 0 then
        local prev = table.remove(self.History, 1)
        return self:TransitionTo(prev, ctx, "FSM Rollback", "FSM", true)
    end
    return false
end

function StateMachine:Update(dt: number, ctx: any)
    local def = self._states[self.CurrentState]
    if def then
        -- Timeout Auto-Recovery Guard (Prevents getting permanently stuck in transient special states)
        if def.Timeout and (os.clock() - self.StateStartTime) > def.Timeout then
            local fallback = def.FallbackState or "IDLE"
            if self._logger then
                self._logger:Warn("FSM", string.format("State '%s' timed out (> %.1fs), auto-recovering to '%s'", self.CurrentState, def.Timeout, fallback))
            end
            self:TransitionTo(fallback, ctx, "State Timeout Recovery", "FSM", true)
            return
        end

        if def.OnUpdate then
            if self._logger then
                self._logger:SafeCall("FSM.OnUpdate", def.OnUpdate, def, dt, ctx)
            else
                pcall(def.OnUpdate, def, dt, ctx)
            end
        end
    end
end

return StateMachine
