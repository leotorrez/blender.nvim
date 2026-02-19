local n = require 'nui-components'

local config = require 'blender.config'
local dap = require 'blender.dap'
local signal_utils = require 'blender.signal.utils'
local hl = require('blender.highlights').groups
local notify = require 'blender.notify'
local ui = require 'blender.ui'

local instance

---@class ManageTaskProps
---@field task Task
---@field message? string

---@type {active_tab: SignalValue<'tab-output' | 'tab-debug'>}
local tab_signal = n.create_signal {
  active_tab = 'tab-output',
}

local is_tab_active = n.is_active_factory(tab_signal.active_tab)

---@param props ManageTaskProps
local function ManageTask(props)
  if instance then
    instance:close()
    ui._on_close(instance)
    instance = nil
  end

  local renderer = n.create_renderer {
    width = math.min(vim.o.columns, 100),
    height = math.min(vim.o.lines, 30),
  }

  renderer:on_mount(function()
    instance = renderer
    ui._on_open {
      close = function()
        if instance then
          instance:close()
          instance = nil
        end
      end,
    }
  end)

  renderer:on_unmount(function()
    instance = nil
    ui._on_close()
  end)

  local mappings = {}
  
  if config.keymaps.task_manager.stop_task then
    table.insert(mappings, {
      mode = { 'n', 'v' },
      key = config.keymaps.task_manager.stop_task,
      handler = function()
        props.task:stop()
      end,
    })
  end
  
  if config.keymaps.task_manager.restart_task then
    table.insert(mappings, {
      mode = { 'n', 'v' },
      key = config.keymaps.task_manager.restart_task,
      handler = function()
        notify('Restarting task', 'INFO')
        renderer:close()

        local function start_task()
          local new_task = props.task.profile:launch()
          if not new_task then
            notify('Failed to restart task', 'ERROR')
            return
          end
          ManageTask {
            task = new_task,
          }
        end

        if props.task.status == 'running' then
          signal_utils.observe_once(props.task:on 'exit', function()
            start_task()
          end)
          props.task:stop()
        else
          start_task()
        end
      end,
    })
  end
  
  renderer:add_mappings(mappings)

  renderer:render(n.rows(
    n.paragraph {
      is_focusable = false,
      lines = {
        props.message and n.line(n.text(' ', hl.BlenderAccent), n.text(props.message)) or nil,
      },
    },

    n.paragraph {
      is_focusable = false,
      border_label = {
        text = n.text('Blender Task Manager', hl.BlenderAccent),
        icon = '󰂫',
        align = 'center',
      },
      padding = { top = 0, right = 1, bottom = 0, left = 1 },
      truncate = true,
      lines = props.task:on('change'):map(function(e)
        local debugger_text
        if e.task.debugger_attached then
          debugger_text = 'Attached'
        elseif e.task.client then
          if e.task.profile:dap_enabled() then
            debugger_text = 'Not attached'
          elseif dap.is_available() then
            debugger_text = 'Disabled'
          else
            debugger_text = 'Disabled (missing nvim-dap)'
          end
        else
          debugger_text = 'N/a'
        end
        local watch_status = e.task.watch_status
            and table.concat(
              vim.tbl_map(function(p)
                return vim.fn.fnamemodify(p, ':~:.')
              end, e.task.watch_status.pattern),
              ', '
            )
          or 'N/a'
        return {
          n.line(n.text('Id:       ', hl.BlenderAccent), tostring(e.task.id)),
          n.line(n.text('Profile:  ', hl.BlenderAccent), e.task.profile.name),
          n.line(n.text('Command:  ', hl.BlenderAccent), table.concat(e.task.cmd, ' ')),
          n.line(
            n.text('Status:   ', hl.BlenderAccent),
            e.task.status .. (e.task.exit_code and ' (code ' .. e.task.exit_code .. ')' or '')
          ),
          n.line(
            n.text('PID:      ', hl.BlenderAccent),
            tostring(e.task.status == 'running' and e.task:get_pid() or 'N/a')
          ),
          n.line(n.text('Debugger: ', hl.BlenderAccent), debugger_text),
          n.line(n.text('Watch:    ', hl.BlenderAccent), watch_status),
        }
      end),
    },

    n.tabs(
      { active_tab = tab_signal.active_tab },
      n.columns(
        { flex = 0 },
        n.gap { flex = 1 },
        n.button {
          label = config.keymaps.task_manager.output_tab
              and ('  Output <' .. config.keymaps.task_manager.output_tab .. '> ')
            or '  Output ',
          global_press_key = config.keymaps.task_manager.output_tab or nil,
          is_active = is_tab_active 'tab-output',
          is_focusable = false,
          on_press = function()
            tab_signal.active_tab = signal_utils.signal_value 'tab-output'
          end,
          on_focus = function()
            tab_signal.active_tab = signal_utils.signal_value 'tab-output'
          end,
        },
        n.gap(1),
        n.button {
          label = config.keymaps.task_manager.debug_console_tab
              and ('  Debug Console <' .. config.keymaps.task_manager.debug_console_tab .. '> ')
            or '  Debug Console ',
          global_press_key = config.keymaps.task_manager.debug_console_tab or nil,
          is_active = is_tab_active 'tab-debug',
          is_focusable = false,
          on_press = function()
            tab_signal.active_tab = signal_utils.signal_value 'tab-debug'
          end,
          on_focus = function()
            tab_signal.active_tab = signal_utils.signal_value 'tab-debug'
          end,
        },
        n.gap { flex = 1 }
      ),
      n.tab(
        { id = 'tab-output' },
        n.buffer {
          buf = props.task:get_buf(),
          autoscroll = true,
          border_style = 'rounded',
          size = 16,
        }
      ),
      n.tab(
        { id = 'tab-debug' },
        n.buffer {
          buf = props.task:on('dap_repl_buf_set', { prime = true }):map(function(e)
            if e.prime then
              return dap.get_fallback_repl_buf()
            end
            return e.task:get_dap_repl_buf()
          end),
          autoscroll = true,
          filetype = 'dap-repl',
          border_style = 'rounded',
          size = 16,
        }
      )
    ),

    n.paragraph {
      is_focusable = false,
      align = 'right',
      lines = {
        n.line(n.text(
          (config.keymaps.task_manager.stop_task and ('<' .. config.keymaps.task_manager.stop_task .. '> Stop Task  ') or '')
            .. (config.keymaps.task_manager.restart_task and ('<' .. config.keymaps.task_manager.restart_task .. '> Restart Task') or ''),
          'Comment'
        )),
      },
    }
  ))
end

return ManageTask
