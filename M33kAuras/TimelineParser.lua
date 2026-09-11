if not M33kAuras.IsLibsOK() then return end
---@type string
local AddonName = ...
---@class Private
local Private = select(2, ...)

local timer = M33kAuras.timer;
local L = M33kAuras.L

Private.ExecEnv.TimelineParser = {
  registeredEvents = {},
  bars = {},
  nextExpire = nil,
  recheckTimer = nil,
  currentStage = 0,

  CopyBarToState = function(self, bar, states, cloneID, extendTimer)
    extendTimer = extendTimer or 0
    states[cloneID] = states[cloneID] or {}
    local state = states[cloneID]
    state.show = true
    state.changed = true
    state.eventID = bar.eventID
    state.spellID = bar.spellID
    state.duration = bar.duration + extendTimer
    state.expirationTime = bar.expirationTime + extendTimer
    state.count = bar.count
    state.progressType = "timed"
    state.icon = bar.icon
    state.name = bar.name
    state.extend = extendTimer
    if extendTimer ~= 0 then
      state.autoHide = true
    end
    state.paused = bar.paused
    state.remaining = bar.remaining
  end,
  TimerMatches = function(self, eventID, spellID, counter)
    local bar = self.bars[eventID]
    if not bar then return false end
    if spellID and spellID ~= "" and tostring(bar.spellID) ~= spellID then
      return false
    end
    if counter then
      counter:SetCount(bar.count)
      if not counter:Match() then
        return false
      end
    end
    return true
  end,
  GetAllTimers = function(self)
    return self.bars
  end,
  GetTimerByID = function(self, eventID)
    return self.bars[eventID]
  end,
  GetTimer = function(self, spellID, counter, extendTimer)
    local bestMatch
    for id, bar in pairs(self.bars) do
      if self:TimerMatches(id, spellID, counter)
      and (bestMatch == nil or bar.expirationTime < bestMatch.expirationTime)
      and bar.expirationTime + extendTimer > GetTime() then
        bestMatch = bar
      end
    end
    return bestMatch
  end,

  GetStage = function(self)
    return self.currentStage
  end,

  RecheckTimers = function(self)
    local now = GetTime()
    self.nextExpire = nil
    for eventID, bar in pairs(self.bars) do
      if not bar.paused then
        if bar.expirationTime < now then
          if bar.scheduledScanExpireAt == nil or bar.scheduledScanExpireAt <= GetTime() then
            self.bars[eventID] = nil
          else
            if self.nextExpire == nil then
              self.nextExpire = bar.scheduledScanExpireAt
            elseif bar.scheduledScanExpireAt < self.nextExpire then
              self.nextExpire = bar.scheduledScanExpireAt
            end
          end
          if not bar.expired then
            bar.expired = true
            Private.ScanEvents("TimelineParser_EventCanceled", eventID)
          end
        elseif self.nextExpire == nil then
          self.nextExpire = bar.expirationTime
        elseif bar.expirationTime < self.nextExpire then
          self.nextExpire = bar.expirationTime
        end
      end
    end

    if self.nextExpire then
      self.recheckTimer = timer:ScheduleTimerFixed(self.RecheckTimers, self.nextExpire - now, self)
    end
  end,

  EventCallback = function(self, event, ...)
    if event == "TimelineParser_SpellIDDeclassified" then
      local eventID, spellID, timeLeft, count = ...

      local now = GetTime()
      local expirationTime = now + timeLeft
      self.bars[eventID] = {
        eventID = eventID,
        spellID = spellID,
        count = count,
        duration = timeLeft,
        expirationTime = expirationTime,
        icon = C_Spell.GetSpellTexture(spellID),
        name = C_Spell.GetSpellName(spellID),
      }

      Private.ScanEvents(event, eventID, spellID, timeLeft, count)

      if self.nextExpire == nil then
        self.recheckTimer = timer:ScheduleTimerFixed(self.RecheckTimers, expirationTime - now, self)
        self.nextExpire = expirationTime
      elseif expirationTime < self.nextExpire then
        timer:CancelTimer(self.recheckTimer)
        self.recheckTimer = timer:ScheduleTimerFixed(self.RecheckTimers, expirationTime - now, self)
        self.nextExpire = expirationTime
      end
    elseif event == "TimelineParser_EventPaused" then
      local eventID, spellID = ...

      local bar = self.bars[eventID]
      if not bar then return end
      bar.paused = true
      bar.remaining = bar.expirationTime - GetTime()

      Private.ScanEvents(event, eventID, spellID)
    elseif event == "TimelineParser_EventResumed" then
      local eventID, spellID, timeLeft = ...

      local bar = self.bars[eventID]
      if not bar then return end
      bar.paused = nil
      bar.expirationTime = GetTime() + timeLeft
      bar.remaining = nil

      if self.nextExpire == nil then
        self.recheckTimer = timer:ScheduleTimerFixed(self.RecheckTimers, bar.expirationTime - GetTime(), self)
      elseif bar.expirationTime < self.nextExpire then
        timer:CancelTimer(self.recheckTimer)
        self.recheckTimer = timer:ScheduleTimerFixed(self.RecheckTimers, bar.expirationTime - GetTime(), self)
        self.nextExpire = bar.expirationTime
      end

      Private.ScanEvents(event, eventID, spellID, timeLeft)
    elseif event == "TimelineParser_EventCanceled" then
      local eventID, spellID = ...

      local bar = self.bars[eventID]
      if bar then
        if bar.scheduledScanExpireAt == nil or bar.scheduledScanExpireAt <= GetTime() then
          self.bars[eventID] = nil
        end
        Private.ScanEvents(event, eventID, spellID)
      end
    elseif event == "TimelineParser_EventFinished" then
      -- The preceding cancellation may already have removed the cached timer.
      local eventID, spellID, count = ...
      Private.ScanEvents(event, eventID, spellID, count)
    elseif event == "TimelineParser_EncounterEnded" then
      for eventID, bar in pairs(self.bars) do
        self.bars[eventID] = nil
        Private.ScanEvents("TimelineParser_EventCanceled", eventID)
      end
    elseif event == "TimelineParser_StageChanged" then
      local newStage = ...
      self.currentStage = newStage
      Private.ScanEvents(event, newStage)
    end
  end,

  RegisterCallback = function(self, event)
    if not GREMINDER or not event or Private.ExecEnv.TimelineParser.registeredEvents[event] then
      return
    end
    self.registeredEvents[event] = true

    GREMINDER:RegisterCallback(event, function(...)
      self:EventCallback(event, ...)
    end)
    if event == "TimelineParser_StageChanged" then
      if GREMINDER.TimelineParser and GREMINDER.TimelineParser.bossMod then
        self.currentStage = GREMINDER.TimelineParser.bossMod:GetStage() or 0
      end
    end
  end,
  RegisterTimer = function(self)
    self:RegisterCallback("TimelineParser_SpellIDDeclassified")
    self:RegisterCallback("TimelineParser_EventPaused")
    self:RegisterCallback("TimelineParser_EventResumed")
    self:RegisterCallback("TimelineParser_EventCanceled")
    self:RegisterCallback("TimelineParser_EncounterEnded")
  end,

  RegisterStage = function(self)
    self:RegisterCallback("TimelineParser_StageChanged")
  end,

  RegisterTimerFinished = function(self)
    self:RegisterCallback("TimelineParser_EventFinished")
  end,

  scheduled_scans = {},

  DoScan = function(self, fireTime)
    self.scheduled_scans[fireTime] = nil
    Private.ScanEvents("TimelineParser_TimerUpdate")
  end,

  ScheduleCheck = function(self, fireTime)
    if not self.scheduled_scans[fireTime] then
      self.scheduled_scans[fireTime] = timer:ScheduleTimerFixed(self.DoScan, fireTime - GetTime(), self, fireTime)
    end
  end
}

 Private.event_prototypes["TimelineParser Stage"] = {
    type = "addons",
    events = {},
    internal_events = {
      "TimelineParser_StageChanged"
    },
    force_events = "TimelineParser_StageChanged",
    name = L["TimelineParser Stage"],
    init = function(trigger)
      Private.ExecEnv.TimelineParser:RegisterStage()
      return ""
    end,
    args = {
      {
        name = "stage",
        init = "Private.ExecEnv.TimelineParser:GetStage()",
        display = L["Stage"],
        type = "number",
        conditionType = "number",
        store = true,
      },
      {
      name = "note",
      type = "description",
      display = "",
      text = L["This trigger requires ExRT_Reminder of version 71 or higher to function."]
    },
    },
    automaticrequired = true,
    statesParameter = "one",
    progressType = "none"
  }
  Private.category_event_prototype.addons["TimelineParser Stage"] = L["TimelineParser Stage"]

Private.event_prototypes["TimelineParser Stage (Event)"] = {
  type = "event",
  events = {
    events = {
      "TimelineParser_StageChanged"
    }
  },
  name = M33kAuras.newFeatureString .. L["TimelineParser Stage (Event)"],
  init = function(trigger)
    Private.ExecEnv.TimelineParser:RegisterStage()
    return ""
  end,
  args = {
    {
      name = "stage",
      -- Keep the original stage when the event is delayed.
      init = "arg",
      display = L["Stage"],
      type = "number",
      conditionType = "number",
      store = true,
    },
    {
      name = "note",
      type = "description",
      display = "",
      text = L["This trigger requires ExRT_Reminder of version 71 or higher to function."]
    },
  },
  statesParameter = "one",
  progressType = "timed",
  delayEvents = true,
  timedrequired = true
}
Private.category_event_prototype.addons["TimelineParser Stage (Event)"] = L["TimelineParser Stage (Event)"]

Private.event_prototypes["TimelineParser Timer"] = {
  type = "addons",
  events = {},
  internal_events = {
    "TimelineParser_SpellIDDeclassified",
    "TimelineParser_EventPaused",
    "TimelineParser_EventResumed",
    "TimelineParser_EventCanceled",
    "TimelineParser_TimerUpdate",
    -- "TimelineParser_EncounterStarted",
    -- "TimelineParser_StageChanged" -- for another trigger?
  },
  force_events = "TimelineParser_ForceUpdate",
  name = L["TimelineParser Timer"],
  progressType = "timed",
  triggerFunction = function(trigger)
    Private.ExecEnv.TimelineParser:RegisterTimer()
    local ret = [[
    local triggerCounter = %q
    local counter
    if triggerCounter and triggerCounter ~= "" then
      counter = Private.ExecEnv.CreateTriggerCounter(triggerCounter)
    else
      counter = Private.ExecEnv.CreateTriggerCounter()
    end
    return function(states, event, eventID)
      local triggerSpellID = %q
      local useClone = %s
      local extendTimer = %s
      local triggerUseRemaining = %s
      local triggerRemaining = %s
      local cloneID = useClone and eventID or ""
      local state = states[cloneID]
      local counter = counter

      function copyOrSchedule(bar, cloneID)
        local remainingTime
        local changed
        if bar.paused then
          remainingTime = bar.remaining + extendTimer
        else
          remainingTime = bar.expirationTime - GetTime() + extendTimer
        end
        if triggerUseRemaining then
          if remainingTime > 0 and remainingTime %s triggerRemaining then
            Private.ExecEnv.TimelineParser:CopyBarToState(bar, states, cloneID, extendTimer)
            changed = true
          else
            local state = states[cloneID]
            if state and state.show then
              state.show = false
              state.changed = true
              changed = true
            end
          end
          if not bar.paused then
            if extendTimer > 0 then
              bar.scheduledScanExpireAt = math.max(bar.scheduledScanExpireAt or 0, bar.expirationTime + extendTimer)
            end
            if remainingTime >= triggerRemaining  then
              Private.ExecEnv.TimelineParser:ScheduleCheck(bar.expirationTime - triggerRemaining + extendTimer)
            end
          end
        else
          if not bar.paused and extendTimer > 0 then
            bar.scheduledScanExpireAt = math.max(bar.scheduledScanExpireAt or 0, bar.expirationTime + extendTimer)
          end
          if remainingTime > 0 then
            Private.ExecEnv.TimelineParser:CopyBarToState(bar, states, cloneID, extendTimer)
            changed = true
          end
        end
        return changed
      end

      if useClone then
        if event == "TimelineParser_SpellIDDeclassified"
        or event == "TimelineParser_EventPaused"
        or event == "TimelineParser_EventResumed"
        then
          if Private.ExecEnv.TimelineParser:TimerMatches(eventID, triggerSpellID, counter) then
            local bar = Private.ExecEnv.TimelineParser:GetTimerByID(eventID)
            if bar then
              return copyOrSchedule(bar, cloneID)
            end
          end
        elseif event == "TimelineParser_EventCanceled" and state then
          local bar = Private.ExecEnv.TimelineParser:GetTimerByID(eventID)
          if not bar then
            state.show = false
            state.changed = true
            return true
          end
          local bar_remainingTime = state.expirationTime - GetTime() + (state.extend or 0)
          if state.extend == 0 or bar_remainingTime <= 0 then
            state.show = false
            state.changed = true
            return true
          end
        elseif event == "TimelineParser_ForceUpdate" then
          local changed
          for _, state in pairs(states) do
            state.show = false
            state.changed = true
            changed = true
          end
          for eventID, bar in pairs(Private.ExecEnv.TimelineParser:GetAllTimers()) do
            if Private.ExecEnv.TimelineParser:TimerMatches(eventID, triggerSpellID, counter) then
              changed = copyOrSchedule(bar, eventID) or changed
            end
          end
          return changed
        elseif event == "TimelineParser_TimerUpdate" then
          local changed
          for eventID, bar in pairs(Private.ExecEnv.TimelineParser:GetAllTimers()) do
            if Private.ExecEnv.TimelineParser:TimerMatches(eventID, triggerSpellID, counter) then
              changed = copyOrSchedule(bar, eventID) or changed
            end
          end
          return changed
        end
      else
        if event == "TimelineParser_SpellIDDeclassified" then
          if extendTimer ~= 0 then
            if Private.ExecEnv.TimelineParser:TimerMatches(eventID, triggerSpellID, counter) then
              local bar = Private.ExecEnv.TimelineParser:GetTimerByID(eventID)
              Private.ExecEnv.TimelineParser:ScheduleCheck(bar.expirationTime + extendTimer)
            end
          end
        end
        local bar = Private.ExecEnv.TimelineParser:GetTimer(triggerSpellID, counter, extendTimer)
        if bar then
          if extendTimer == 0
            or not (state and state.show)
            or (state and state.show and state.expirationTime > (bar.expirationTime + extendTimer))
          then
            return copyOrSchedule(bar, cloneID)
          end
        else
          if state and state.show then
            local bar_remainingTime = state.expirationTime - GetTime() + (state.extend or 0)
            if state.extend == 0 or bar_remainingTime <= 0 then
              state.show = false
              state.changed = true
              return true
            end
          end
        end
      end
    end
    ]]

    return ret:format(
      trigger.use_count and trigger.count or "",
      trigger.use_spellId and tostring(trigger.spellId) or "",
      trigger.use_cloneId and "true" or "false",
      trigger.use_extend and tonumber(trigger.extend or 0) or 0,
      trigger.use_remaining and "true" or "false",
      trigger.remaining and tonumber(trigger.remaining or 0) or 0,
      trigger.remaining_operator or "<"
    )
  end,
  statesParameter = "full",
  args = {
    {
      name = "spellId",
      display = L["ID"],
      desc = L["The 'ID' value can be found in the TimelineParser source code"],
      type = "spell",
      conditionType = "string",
      noValidation = true,
      showExactOption = false,
      negativeIsEJ = true
    },
    {
      name = "remaining",
      display = L["Remaining Time"],
      type = "number",
    },
    {
      name = "extend",
      display = L["Offset Timer"],
      type = "string",
    },
    {
      name = "count",
      display = L["Count"],
      desc = L["Occurrence of the event, reset when aura is unloaded\nCan be a range of values\nCan have multiple values separated by a comma or a space\n\nExamples:\n2nd 5th and 6th events: 2, 5, 6\n2nd to 6th: 2-6\nevery 2 events: /2\nevery 3 events starting from 2nd: 2/3\nevery 3 events starting from 2nd and ending at 11th: 2-11/3"],
      type = "string",
      store = true,
      conditionType = "string",
      operator_types = "none",
      preamble = "local counter = Private.ExecEnv.CreateTriggerCounter(%q)",
      test = "counter:SetCount(tonumber(count) or 0) == nil and counter:Match()",
      conditionPreamble = function(input)
        return Private.ExecEnv.CreateTriggerCounter(input)
      end,
      conditionTest = function(state, needle, op, preamble)
        preamble:SetCount(tonumber(state.count) or 0)
        return preamble:Match()
      end,
    },
    {
      name = "cloneId",
      display = L["Clone per Event"],
      type = "toggle",
      test = "true",
      init = "false"
    },
    {
      name = "note",
      type = "description",
      display = "",
      text = L["This trigger requires ExRT_Reminder of version 71 or higher to function."]
    },
  },
  automaticrequired = true,
}
Private.category_event_prototype.addons["TimelineParser Timer"] = L["TimelineParser Timer"]

Private.event_prototypes["TimelineParser Timer Finished"] = {
  type = "addons",
  events = {},
  internal_events = {
    "TimelineParser_EventFinished"
  },
  name = M33kAuras.newFeatureString .. L["TimelineParser Timer Finished"],
  init = function(trigger)
    Private.ExecEnv.TimelineParser:RegisterTimerFinished()
    return ("local use_cloneId = %s\n"):format(trigger.use_cloneId and "true" or "false")
  end,
  statesParameter = "all",
  args = {
    {
      name = "eventID",
      init = "arg",
      hidden = true,
      test = "true",
      store = true,
    },
    {
      name = "spellId",
      init = "arg",
      display = L["ID"],
      desc = L["The 'ID' value can be found in the TimelineParser source code"],
      type = "spell",
      conditionType = "string",
      store = true,
      noValidation = true,
      showExactOption = false,
      negativeIsEJ = true
    },
    {
      name = "count",
      init = "arg",
      display = L["Count"],
      desc = L["Occurrence of the event reported by TimelineParser\nCan be a range of values\nCan have multiple values separated by a comma or a space\n\nExamples:\n2nd 5th and 6th events: 2, 5, 6\n2nd to 6th: 2-6\nevery 2 events: /2\nevery 3 events starting from 2nd: 2/3\nevery 3 events starting from 2nd and ending at 11th: 2-11/3"],
      type = "string",
      conditionType = "string",
      store = true,
      operator_types = "none",
      preamble = "local counter = Private.ExecEnv.CreateTriggerCounter(%q)",
      test = "counter:SetCount(tonumber(count) or 0) == nil and counter:Match()",
      conditionPreamble = function(input)
        return Private.ExecEnv.CreateTriggerCounter(input)
      end,
      conditionTest = function(state, needle, op, preamble)
        preamble:SetCount(tonumber(state.count) or 0)
        return preamble:Match()
      end,
    },
    {
      name = "message",
      init = "spellId and C_Spell.GetSpellName(spellId) or ''",
      display = L["Message"],
      desc = L["Spell name of the finished TimelineParser timer."],
      type = "longstring",
      conditionType = "string",
      store = true,
    },
    {
      name = "name",
      init = "message",
      hidden = true,
      test = "true",
      store = true,
    },
    {
      name = "icon",
      init = "spellId and C_Spell.GetSpellTexture(spellId)",
      hidden = true,
      test = "true",
      store = true,
    },
    {
      name = "cloneId",
      display = L["Clone per Event"],
      type = "toggle",
      test = "true",
      init = "use_cloneId and M33kAuras.GetUniqueCloneId() or ''"
    },
    {
      name = "note",
      type = "description",
      display = "",
      text = L["This trigger requires ExRT_Reminder of version 73.2 or higher to function."]
    },
  },
  timedrequired = true,
  progressType = "timed"
}
Private.category_event_prototype.addons["TimelineParser Timer Finished"] = L["TimelineParser Timer Finished"]
