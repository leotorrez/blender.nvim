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
  self.autocmds = {}
  self.main_buf = nil  -- Will be created in show()
  
  return self
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
  self:update_content_window()
end

---Update the content window to show the active tab's buffer
function TaskManager:update_content_window()
  if not self.content_win or not vim.api.nvim_win_is_valid(self.content_win) then
    return
  end
  
  local buf = self:get_active_buffer()
  if buf and vim.api.nvim_buf_is_valid(buf) then
    -- Update the buffer
    vim.api.nvim_win_set_buf(self.content_win, buf)
    
    -- Setup keymaps for the new buffer
    self:setup_keymaps_for_buffer(buf)
    
    -- Update the window title
    local title = self.active_tab == 'output' and ' Output ' or ' Debug Console '
    if self.content_win_config then
      self.content_win_config.title = title
      vim.api.nvim_win_set_config(self.content_win, self.content_win_config)
    end
    
    -- Scroll to bottom
    local line_count = vim.api.nvim_buf_line_count(buf)
    pcall(vim.api.nvim_win_set_cursor, self.content_win, { line_count, 0 })
  end
end

---Refresh the entire display
function TaskManager:refresh_display()
  if not self.win or not self.main_buf or not vim.api.nvim_buf_is_valid(self.main_buf) then
    return
  end
  
  local lines = {}
  local highlights = {}
  
  -- Get window width for separators
  local width = self.win.width or 100
  local separator = string.rep('━', width)
  
  -- Header section
  -- No separator needed - the content window border will serve as the separator
  table.insert(lines, '')
  
  -- Info section
  local task = self.task
  
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
  
  -- Add info lines
  local info_start = #lines + 1
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
  table.insert(lines, '')
  -- No separator needed - the content window border will serve as the separator
  
  -- Add highlights for info section labels
  for i = info_start, info_start + 6 do
    local line = lines[i]
    local colon_pos = line:find(':')
    if colon_pos then
      table.insert(highlights, { line = i - 1, col_start = 0, col_end = colon_pos, hl_group = hl.BlenderAccent })
    end
  end
  
  -- Tab section (footer)
  local tab_line_num = #lines
  if self.active_tab == 'output' then
    table.insert(lines, '[ Output ]  [ Debug Console ]')
    -- Highlight the active Output tab
    table.insert(highlights, { line = tab_line_num, col_start = 0, col_end = 10, hl_group = hl.BlenderAccent })
  else
    table.insert(lines, '[ Output ]  [ Debug Console ]')
    -- Highlight the active Debug Console tab
    table.insert(highlights, { line = tab_line_num, col_start = 12, col_end = 29, hl_group = hl.BlenderAccent })
  end
  
  -- Add keybind hints
  table.insert(lines, '')
  local hints = {}
  local km = config.keymaps.task_manager
  if km.stop_task then
    table.insert(hints, string.format('<%s> Stop', km.stop_task))
  end
  if km.restart_task then
    table.insert(hints, string.format('<%s> Restart', km.restart_task))
  end
  if km.output_tab then
    table.insert(hints, string.format('<%s> Output', km.output_tab))
  end
  if km.debug_console_tab then
    table.insert(hints, string.format('<%s> Debug', km.debug_console_tab))
  end
  if km.close then
    table.insert(hints, string.format('<%s> Close', km.close))
  end
  if #hints > 0 then
    local hints_line_num = #lines
    table.insert(lines, table.concat(hints, '  '))
    -- Highlight hints as comment
    table.insert(highlights, { line = hints_line_num, col_start = 0, col_end = -1, hl_group = 'Comment' })
  end
  
  -- Message if any
  if self.message then
    table.insert(lines, '')
    table.insert(lines, self.message)
  end
  
  -- Set buffer content
  vim.api.nvim_buf_set_option(self.main_buf, 'modifiable', true)
  vim.api.nvim_buf_set_lines(self.main_buf, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(self.main_buf, 'modifiable', false)
  
  -- Apply highlights
  local ns = vim.api.nvim_create_namespace('blender_task_manager')
  vim.api.nvim_buf_clear_namespace(self.main_buf, ns, 0, -1)
  
  for _, hl_info in ipairs(highlights) do
    vim.api.nvim_buf_add_highlight(
      self.main_buf,
      ns,
      hl_info.hl_group,
      hl_info.line,
      hl_info.col_start,
      hl_info.col_end
    )
  end
end

---Setup keymaps for a specific buffer
---@param buf number Buffer handle
function TaskManager:setup_keymaps_for_buffer(buf)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  
  local km = config.keymaps.task_manager
  local buftype = vim.api.nvim_buf_get_option(buf, 'buftype')
  local is_terminal = buftype == 'terminal'
  
  -- Set keymaps for both normal and terminal modes
  local modes = is_terminal and { 'n', 't' } or { 'n' }
  
  -- Stop task
  if km.stop_task then
    for _, mode in ipairs(modes) do
      vim.keymap.set(mode, km.stop_task, function()
        self.task:stop()
      end, { buffer = buf, desc = 'Stop Task' })
    end
  end
  
  -- Restart task
  if km.restart_task then
    for _, mode in ipairs(modes) do
      vim.keymap.set(mode, km.restart_task, function()
        self:restart_task()
      end, { buffer = buf, desc = 'Restart Task' })
    end
  end
  
  -- Switch to output tab
  if km.output_tab then
    for _, mode in ipairs(modes) do
      vim.keymap.set(mode, km.output_tab, function()
        self:switch_tab('output')
      end, { buffer = buf, desc = 'Output Tab' })
    end
  end
  
  -- Switch to debug tab
  if km.debug_console_tab then
    for _, mode in ipairs(modes) do
      vim.keymap.set(mode, km.debug_console_tab, function()
        self:switch_tab('debug')
      end, { buffer = buf, desc = 'Debug Console Tab' })
    end
  end
  
  -- Close window
  if km.close then
    for _, mode in ipairs(modes) do
      vim.keymap.set(mode, km.close, function()
        self:close()
      end, { buffer = buf, desc = 'Close Task Manager' })
    end
  end
end

---Setup keymaps for all windows
function TaskManager:setup_keymaps()
  -- Setup keymaps for info buffer
  if self.win and self.win.buf then
    self:setup_keymaps_for_buffer(self.win.buf)
  end
  
  -- Setup keymaps for content buffer
  local content_buf = self:get_active_buffer()
  if content_buf then
    self:setup_keymaps_for_buffer(content_buf)
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
        self:update_content_window()
      end
    end)
  end)
  
  table.insert(self.autocmds, function()
    -- Cleanup handled by task event system
  end)
end

---Show the task manager window
function TaskManager:show()
  -- Calculate window dimensions
  local width = math.min(vim.o.columns, 100)
  local total_height = math.min(vim.o.lines - 4, 30)
  local info_height = 16  -- Height for info panel
  local content_height = total_height - info_height
  
  -- Calculate center position for the top window
  local row = math.floor((vim.o.lines - total_height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)
  
  -- Create info buffer
  local info_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_option(info_buf, 'filetype', 'blender-task-manager')
  vim.api.nvim_buf_set_option(info_buf, 'modifiable', false)
  
  -- Create the info floating window (top)
  local info_win_opts = {
    relative = 'editor',
    width = width,
    height = info_height,
    row = row,
    col = col,
    style = 'minimal',
    border = { '╭', '─', '╮', '│', '', '', '', '│' },  -- Top and sides only, no bottom border
    title = ' Blender Task Manager ',
    title_pos = 'center',
  }
  
  local info_win = vim.api.nvim_open_win(info_buf, true, info_win_opts)
  
  if not info_win or not vim.api.nvim_win_is_valid(info_win) then
    vim.notify('[Blender.nvim] Failed to create task manager window', vim.log.levels.ERROR)
    return
  end
  
  -- Set window options for info window
  vim.api.nvim_win_set_option(info_win, 'winhighlight', 'Normal:Normal,FloatBorder:FloatBorder')
  vim.api.nvim_win_set_option(info_win, 'number', false)
  vim.api.nvim_win_set_option(info_win, 'relativenumber', false)
  vim.api.nvim_win_set_option(info_win, 'signcolumn', 'no')
  vim.api.nvim_win_set_option(info_win, 'wrap', false)
  
  -- Create content floating window (bottom) - initially with the active buffer
  local content_buf = self:get_active_buffer()
  local content_win_opts = {
    relative = 'editor',
    width = width,
    height = content_height,
    row = row + info_height,  -- Position directly below info window content
    col = col,
    style = 'minimal',
    border = { '├', '─', '┤', '│', '╯', '─', '╰', '│' },  -- Connects to info window sides
    title = self.active_tab == 'output' and ' Output ' or ' Debug Console ',
    title_pos = 'center',
  }
  
  local content_win = vim.api.nvim_open_win(content_buf, false, content_win_opts)
  
  if not content_win or not vim.api.nvim_win_is_valid(content_win) then
    vim.notify('[Blender.nvim] Failed to create content window', vim.log.levels.ERROR)
    -- Close info window and return
    pcall(vim.api.nvim_win_close, info_win, true)
    return
  end
  
  -- Set window options for content window
  vim.api.nvim_win_set_option(content_win, 'winhighlight', 'Normal:Normal,FloatBorder:FloatBorder')
  vim.api.nvim_win_set_option(content_win, 'number', false)
  vim.api.nvim_win_set_option(content_win, 'relativenumber', false)
  vim.api.nvim_win_set_option(content_win, 'signcolumn', 'no')
  
  -- Store window info
  self.win = {
    win = info_win,
    buf = info_buf,
    width = width,  -- Store width for separator generation
  }
  self.main_buf = info_buf
  self.content_win = content_win
  self.content_win_config = content_win_opts  -- Store for updates
  
  -- Scroll content to bottom
  local line_count = vim.api.nvim_buf_line_count(content_buf)
  pcall(vim.api.nvim_win_set_cursor, content_win, { line_count, 0 })
  
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
  
  -- Close info window
  if self.win and self.win.win and vim.api.nvim_win_is_valid(self.win.win) then
    pcall(vim.api.nvim_win_close, self.win.win, true)
  end
  self.win = nil
  
  -- Close content window
  if self.content_win and vim.api.nvim_win_is_valid(self.content_win) then
    pcall(vim.api.nvim_win_close, self.content_win, true)
  end
  self.content_win = nil
  
  -- Delete main buffer
  if self.main_buf and vim.api.nvim_buf_is_valid(self.main_buf) then
    pcall(vim.api.nvim_buf_delete, self.main_buf, { force = true })
  end
  self.main_buf = nil
  
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
