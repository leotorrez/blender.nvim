local config = require 'blender.config'

---@param msg string
---@param level 'TRACE' | 'DEBUG' | 'INFO' | 'WARN' | 'ERROR' | 'OFF' | 0 | 1 | 2 | 3 | 4 | 5
return function(msg, level)
  local lvl = type(level) == 'string' and vim.log.levels[level] or level
  ---@cast lvl integer
  if config.notify.enabled and config.notify.verbosity <= lvl then
    local ok, snacks = pcall(require, 'snacks')
    if ok and snacks.notifier then
      -- Map vim.log.levels to snacks notification levels
      local level_map = {
        [vim.log.levels.TRACE] = 'trace',
        [vim.log.levels.DEBUG] = 'debug',
        [vim.log.levels.INFO] = 'info',
        [vim.log.levels.WARN] = 'warn',
        [vim.log.levels.ERROR] = 'error',
      }
      snacks.notifier.notify(msg, { title = 'Blender.nvim', level = level_map[lvl] or 'info' })
    else
      -- Fallback to vim.notify if snacks is not available
      vim.notify('[Blender.nvim] ' .. msg, lvl)
    end
  end
end
