---Wrapper to provide signal-like API using EventEmitter
---This allows Task to work without nui-components Signal
local EventEmitter = require 'blender.event_emitter'

local M = {}

---@class EventWrapper
---@field private _emitter EventEmitter
---@field private _event string
---@field private _transforms function[]
---@field private _filters function[]
---@field private _handler_id? string
local EventWrapper = {}
EventWrapper.__index = EventWrapper

function EventWrapper.new(emitter, event)
  return setmetatable({
    _emitter = emitter,
    _event = event,
    _transforms = {},
    _filters = {},
  }, EventWrapper)
end

---Observe the event
---@param handler function
---@return EventWrapper
function EventWrapper:observe(handler)
  -- Create a wrapper that applies all transformations and filters
  local wrapped_handler = function(value)
    -- Apply all transformations
    for _, transform in ipairs(self._transforms) do
      value = transform(value)
    end
    
    -- Apply all filters
    for _, filter in ipairs(self._filters) do
      if not filter(value) then
        return -- Skip this event
      end
    end
    
    -- Call the actual handler
    handler(value)
  end
  
  self._handler_id = self._emitter:on(self._event, wrapped_handler)
  return self
end

---Unsubscribe from the event
function EventWrapper:unsubscribe()
  if self._handler_id then
    self._emitter:off(self._event, self._handler_id)
    self._handler_id = nil
  end
end

---Map function (transforms values)
---@param fn function
---@return EventWrapper
function EventWrapper:map(fn)
  -- Create a new wrapper that inherits all transforms and filters
  local wrapper = EventWrapper.new(self._emitter, self._event)
  wrapper._transforms = vim.list_extend({}, self._transforms)
  wrapper._filters = vim.list_extend({}, self._filters)
  
  -- Add the new transform
  table.insert(wrapper._transforms, fn)
  
  return wrapper
end

---Filter function (filters values)
---@param fn function
---@return EventWrapper
function EventWrapper:filter(fn)
  -- Create a new wrapper that inherits all transforms and filters
  local wrapper = EventWrapper.new(self._emitter, self._event)
  wrapper._transforms = vim.list_extend({}, self._transforms)
  wrapper._filters = vim.list_extend({}, self._filters)
  
  -- Add the new filter
  table.insert(wrapper._filters, fn)
  
  return wrapper
end

---@class SignalTable
---@field _emitter EventEmitter
---@field _events table<string, EventWrapper>
local SignalTable = {}

function SignalTable:__index(key)
  -- This is called when accessing signal[event]
  if key == '_emitter' or key == '_events' then
    return rawget(self, key)
  end
  local events = rawget(self, '_events')
  return events and events[key] or nil
end

function SignalTable:__newindex(key, value)
  -- This is called when setting signal[event] = value
  -- Emit the event with the value
  if key ~= '_emitter' and key ~= '_events' and self._emitter then
    self._emitter:emit(key, value)
  end
end

---Create signal-like event system
---Can accept either a table with event names as keys (values can be nil or anything)
---or an array of event names
---@param events table<string, any> | string[]
---@return table
function M.create(events)
  local emitter = EventEmitter.new()
  local event_wrappers = {}
  
  -- Handle both array-style and table-style event lists
  -- For array style: { 'change', 'start', 'exit' }
  -- For table style with keys: { change = true, start = true } (can't use nil values in table literals)
  local event_list = {}
  
  -- Check if it's an array or a keyed table
  if vim.tbl_islist(events) then
    event_list = events
  else
    event_list = vim.tbl_keys(events)
  end
  
  for _, event in ipairs(event_list) do
    event_wrappers[event] = EventWrapper.new(emitter, event)
  end
  
  local signal = setmetatable({
    _emitter = emitter,
    _events = event_wrappers,
  }, SignalTable)
  
  return signal
end

return M
