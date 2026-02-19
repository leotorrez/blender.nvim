local config = require 'blender.config'
local dap = require 'blender.dap'
local hl = require('blender.highlights').groups
local notify = require 'blender.notify'
local ui = require 'blender.ui'

---@class TaskManager
---@field win? table Snacks.win instance
---@field task Task Current task
---@field active_tab 'output'|'debug' Active tab
---@field buffers table Buffer handles
---@field autocmds table Autocmd IDs for cleanup
local TaskManager = {}
TaskManager.__index = TaskManager

local instance

---@class ManageTaskProps
---@field task Task
---@field message? string

---Create a new TaskManager instance
---@param props ManageTaskProps
---@return TaskManager
function TaskManager.new(props)
  local self = setmetatable({}, TaskManager)
  self.task = props.task
  self.message = props.message
  self.active_tab = 'output'
  self.buffers = {
    info = vim.api.nvim_create_buf(false, true),
    header = vim.api.nvim_create_buf(false, true),
    footer = vim.api.nvim_create_buf(false, true),
  }
  self.autocmds = {}
  
  -- Set buffer options
  vim.api.nvim_buf_set_option(self.buffers.info, 'filetype', 'blender-task-info')
  vim.api.nvim_buf_set_option(self.buffers.header, 'filetype', 'blender-task-header')
  vim.api.nvim_buf_set_option(self.buffers.footer, 'filetype', 'blender-task-footer')
  
  return self
end

---Render task info into buffer
function TaskManager:render_info()
  local task = self.task
  local lines = {}
  
  -- Determine debugger status
  local debugger_text
  if task.debugger_attached then
    debugger_text = 'Attached'
  elseif task.client then
    if task.profile:dap_enabled() then
      debugger_text = 'Not attached'
    elseif dap.is_available() then
      debugger_text = 'Disabled'
    else
      debugger_text = 'Disabled (missing nvim-dap)'
    end
  else
    debugger_text = 'N/a'
  end
  
  -- Watch status
  local watch_status = task.watch_status
      and table.concat(
        vim.tbl_map(function(p)
          return vim.fn.fnamemodify(p, ':~:.')
        end, task.watch_status.pattern),
        ', '
      )
    or 'N/a'
  
  -- Build info lines
  table.insert(lines, string.format('Id:       %s', tostring(task.id)))
  table.insert(lines, string.format('Profile:  %s', task.profile.name))
  table.insert(lines, string.format('Command:  %s', table.concat(task.cmd, ' ')))
  table.insert(lines, string.format('Status:   %s%s', 
    task.status,
    task.exit_code and ' (code ' .. task.exit_code .. ')' or ''
  ))
  table.insert(lines, string.format('PID:      %s', 
    tostring(task.status == 'running' and task:get_pid() or 'N/a')
  ))
  table.insert(lines, string.format('Debugger: %s', debugger_text))
  table.insert(lines, string.format('Watch:    %s', watch_status))
  
  -- Set buffer lines
  vim.api.nvim_buf_set_option(self.buffers.info, 'modifiable', true)
  vim.api.nvim_buf_set_lines(self.buffers.info, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(self.buffers.info, 'modifiable', false)
  
  -- Add highlights
  local ns = vim.api.nvim_create_namespace('blender_task_info')
  vim.api.nvim_buf_clear_namespace(self.buffers.info, ns, 0, -1)
  
  for i, line in ipairs(lines) do
    local colon_pos = line:find(':')
    if colon_pos then
      vim.api.nvim_buf_add_highlight(self.buffers.info, ns, hl.BlenderAccent, i - 1, 0, colon_pos)
    end
  end
end

---Render header with message and title
function TaskManager:render_header()
  local lines = {}
  
  if self.message then
    table.insert(lines, ' ' .. self.message)
  end
  
  table.insert(lines, '󰂫 Blender Task Manager')
  
  vim.api.nvim_buf_set_option(self.buffers.header, 'modifiable', true)
  vim.api.nvim_buf_set_lines(self.buffers.header, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(self.buffers.header, 'modifiable', false)
end

---Render footer with keybind hints
function TaskManager:render_footer()
  local parts = {}
  
  local km = config.keymaps.task_manager
  if km.stop_task then
    table.insert(parts, '<' .. km.stop_task .. '> Stop Task')
  end
  if km.restart_task then
    table.insert(parts, '<' .. km.restart_task .. '> Restart Task')
  end
  if km.output_tab then
    table.insert(parts, '<' .. km.output_tab .. '> Output')
  end
  if km.debug_console_tab then
    table.insert(parts, '<' .. km.debug_console_tab .. '> Debug')
  end
  
  local line = table.concat(parts, '  ')
  
  vim.api.nvim_buf_set_option(self.buffers.footer, 'modifiable', true)
  vim.api.nvim_buf_set_lines(self.buffers.footer, 0, -1, false, { line })
  vim.api.nvim_buf_set_option(self.buffers.footer, 'modifiable', false)
  
  -- Highlight as comment
  local ns = vim.api.nvim_create_namespace('blender_task_footer')
  vim.api.nvim_buf_clear_namespace(self.buffers.footer, ns, 0, -1)
  vim.api.nvim_buf_add_highlight(self.buffers.footer, ns, 'Comment', 0, 0, -1)
end

---Get the buffer to display based on active tab
function TaskManager:get_active_buffer()
  if self.active_tab == 'output' then
    return self.task:get_buf()
  else
    local repl_buf = self.task:get_dap_repl_buf()
    if repl_buf and vim.api.nvim_buf_is_valid(repl_buf) then
      return repl_buf
    else
      return dap.get_fallback_repl_buf()
    end
  end
end

---Switch to a specific tab
---@param tab 'output'|'debug'
function TaskManager:switch_tab(tab)
  if self.active_tab == tab then
    return
  end
  
  self.active_tab = tab
  self:refresh_display()
end

---Refresh the entire display
function TaskManager:refresh_display()
  if not self.win then
    return
  end
  
  self:render_header()
  self:render_info()
  self:render_footer()
  
  -- The content buffer is managed separately in the layout
  self:update_content_buffer()
end

---Update the content buffer based on active tab
function TaskManager:update_content_buffer()
  if not self.win or not self.win.win or not vim.api.nvim_win_is_valid(self.win.win) then
    return
  end
  
  -- Find the content window in the layout
  -- We'll set this up when creating the window
  if self.content_win and vim.api.nvim_win_is_valid(self.content_win) then
    local buf = self:get_active_buffer()
    if buf and vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_win_set_buf(self.content_win, buf)
      
      -- Set buffer options for terminal/repl
      vim.api.nvim_win_set_option(self.content_win, 'number', false)
      vim.api.nvim_win_set_option(self.content_win, 'relativenumber', false)
      vim.api.nvim_win_set_option(self.content_win, 'signcolumn', 'no')
      
      -- Auto-scroll to bottom
      vim.api.nvim_buf_call(buf, function()
        vim.cmd('normal! G')
      end)
    end
  end
end

---Setup keymaps for the window
function TaskManager:setup_keymaps()
  if not self.win or not self.win.buf then
    return
  end
  
  local buf = self.win.buf
  local km = config.keymaps.task_manager
  
  -- Stop task
  if km.stop_task then
    vim.keymap.set('n', km.stop_task, function()
      self.task:stop()
    end, { buffer = buf, desc = 'Stop Task' })
  end
  
  -- Restart task
  if km.restart_task then
    vim.keymap.set('n', km.restart_task, function()
      self:restart_task()
    end, { buffer = buf, desc = 'Restart Task' })
  end
  
  -- Switch to output tab
  if km.output_tab then
    vim.keymap.set('n', km.output_tab, function()
      self:switch_tab('output')
    end, { buffer = buf, desc = 'Output Tab' })
  end
  
  -- Switch to debug tab
  if km.debug_console_tab then
    vim.keymap.set('n', km.debug_console_tab, function()
      self:switch_tab('debug')
    end, { buffer = buf, desc = 'Debug Console Tab' })
  end
end

---Restart the task
function TaskManager:restart_task()
  notify('Restarting task', 'INFO')
  self:close()
  
  local function start_task()
    local new_task = self.task.profile:launch()
    if not new_task then
      notify('Failed to restart task', 'ERROR')
      return
    end
    -- Create new task manager for the new task
    local ManageTask = require 'blender.ui.manage_task'
    ManageTask({ task = new_task })
  end
  
  if self.task.status == 'running' then
    -- Wait for task to exit, then start new one
    self.task:once('exit', function()
      start_task()
    end)
    self.task:stop()
  else
    start_task()
  end
end

---Setup autocmds to watch task changes
function TaskManager:setup_autocmds()
  -- Listen to task change events
  local handler_id = self.task:on('change', function()
    vim.schedule(function()
      if self.win then
        self:refresh_display()
      end
    end)
  end)
  
  table.insert(self.autocmds, function()
    -- Cleanup handled by task event system
  end)
  
  -- Listen to DAP REPL buffer changes
  handler_id = self.task:on('dap_repl_buf_set', function()
    vim.schedule(function()
      if self.active_tab == 'debug' then
        self:update_content_buffer()
      end
    end)
  end)
  
  table.insert(self.autocmds, function()
    -- Cleanup handled by task event system
  end)
end

---Show the task manager window
function TaskManager:show()
  -- Check if snacks is available
  local ok, snacks = pcall(require, 'snacks')
  if not ok or not snacks.win then
    vim.notify('[Blender.nvim] Snacks.nvim is required for task manager', vim.log.levels.ERROR)
    return
  end
  
  -- Create main window with layout
  local width = math.min(vim.o.columns, 100)
  local height = math.min(vim.o.lines, 30)
  
  self.win = snacks.win {
    buf = self.buffers.header,
    width = width,
    height = height,
    relative = 'editor',
    position = 'center',
    border = 'rounded',
    title = '',
    title_pos = 'center',
    wo = {
      winhighlight = 'Normal:Normal,FloatBorder:FloatBorder',
    },
  }
  
  if not self.win or not self.win.win or not vim.api.nvim_win_is_valid(self.win.win) then
    vim.notify('[Blender.nvim] Failed to create task manager window', vim.log.levels.ERROR)
    return
  end
  
  -- Create splits within the window for layout
  -- Header (already the main buffer)
  -- Info section
  -- Content section (output/debug)
  -- Footer
  
  vim.api.nvim_win_call(self.win.win, function()
    -- Split for info
    vim.cmd('split')
    local info_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(info_win, self.buffers.info)
    vim.api.nvim_win_set_height(info_win, 7)
    vim.api.nvim_win_set_option(info_win, 'number', false)
    vim.api.nvim_win_set_option(info_win, 'relativenumber', false)
    vim.api.nvim_win_set_option(info_win, 'signcolumn', 'no')
    vim.api.nvim_win_set_option(info_win, 'wrap', false)
    
    -- Go back to main window and split for content
    vim.api.nvim_set_current_win(self.win.win)
    vim.cmd('wincmd j')  -- Move down to info window
    vim.cmd('split')     -- Split below info
    self.content_win = vim.api.nvim_get_current_win()
    
    -- Set the active buffer (output or debug)
    local buf = self:get_active_buffer()
    if buf and vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_win_set_buf(self.content_win, buf)
    end
    
    -- Split for footer
    vim.cmd('split')
    local footer_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(footer_win, self.buffers.footer)
    vim.api.nvim_win_set_height(footer_win, 1)
    vim.api.nvim_win_set_option(footer_win, 'number', false)
    vim.api.nvim_win_set_option(footer_win, 'relativenumber', false)
    vim.api.nvim_win_set_option(footer_win, 'signcolumn', 'no')
  end)
  
  -- Render initial content
  self:refresh_display()
  
  -- Setup keymaps
  self:setup_keymaps()
  
  -- Setup autocmds
  self:setup_autocmds()
  
  -- Register with UI manager
  ui._on_open({
    close = function()
      self:close()
    end,
  })
end

---Close the task manager
function TaskManager:close()
  -- Cleanup autocmds
  for _, cleanup in ipairs(self.autocmds) do
    pcall(cleanup)
  end
  self.autocmds = {}
  
  -- Close window
  if self.win then
    pcall(function()
      self.win:close()
    end)
    self.win = nil
    self.content_win = nil
  end
  
  -- Delete buffers
  for name, buf in pairs(self.buffers) do
    if buf and vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end
  
  ui._on_close()
  
  if instance == self then
    instance = nil
  end
end

---Main entry point
---@param props ManageTaskProps
local function ManageTask(props)
  -- Close existing instance
  if instance then
    instance:close()
  end
  
  -- Create and show new instance
  instance = TaskManager.new(props)
  instance:show()
end

return ManageTask
