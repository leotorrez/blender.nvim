---Simple event emitter to replace nui-components signals
---@class EventEmitter
---@field private _handlers table<string, table<integer, function>>
---@field private _next_id integer
local EventEmitter = {}
EventEmitter.__index = EventEmitter

---Create a new event emitter
---@return EventEmitter
function EventEmitter.new()
  return setmetatable({
    _handlers = {},
    _next_id = 1,
  }, EventEmitter)
end

---Register an event handler
---@param event string Event name
---@param handler function Handler function
---@return integer handler_id ID to use for unsubscribing
function EventEmitter:on(event, handler)
  if not self._handlers[event] then
    self._handlers[event] = {}
  end
  
  local id = self._next_id
  self._next_id = self._next_id + 1
  
  self._handlers[event][id] = handler
  
  return id
end

---Register a one-time event handler
---@param event string Event name
---@param handler function Handler function
---@return integer handler_id ID for cleanup
function EventEmitter:once(event, handler)
  local id
  id = self:on(event, function(...)
    self:off(event, id)
    handler(...)
  end)
  return id
end

---Unregister an event handler
---@param event string Event name
---@param handler_id integer Handler ID from on()
function EventEmitter:off(event, handler_id)
  if self._handlers[event] then
    self._handlers[event][handler_id] = nil
  end
end

---Emit an event
---@param event string Event name
---@param ... any Arguments to pass to handlers
function EventEmitter:emit(event, ...)
  if not self._handlers[event] then
    return
  end
  
  for _, handler in pairs(self._handlers[event]) do
    pcall(handler, ...)
  end
end

---Clear all handlers for an event
---@param event string Event name
function EventEmitter:clear(event)
  self._handlers[event] = nil
end

---Clear all event handlers
function EventEmitter:clear_all()
  self._handlers = {}
end

return EventEmitter
