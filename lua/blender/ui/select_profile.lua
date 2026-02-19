local config = require 'blender.config'
local Profile = require 'blender.profile'

---@param on_select fun(profile: Profile): nil
local function SelectProfile(on_select)
  -- Process profiles (handle functions and lists)
  local profiles = vim
    .iter(config.profiles)
    :map(function(profile)
      if type(profile) == 'function' then
        profile = profile()
        return vim.islist(profile) and profile or { profile }
      end
      return { profile }
    end)
    :flatten()
    :totable()

  -- Handle no profiles case
  if #profiles == 0 then
    vim.notify('[Blender.nvim] No profiles found. Please ensure Blender is installed or add a custom profile.', vim.log.levels.WARN)
    return
  end

  -- Create profile objects
  local profile_objects = {}
  for i, profile_config in ipairs(profiles) do
    local profile = Profile.create(profile_config)
    profile_objects[i] = profile
  end

  -- Use vim.ui.select for now (works with dressing.nvim or snacks input if configured)
  vim.ui.select(profile_objects, {
    prompt = '󰂫 Select Blender Profile',
    format_item = function(profile)
      return '󰂫 ' .. profile.name
    end,
  }, function(selected)
    if selected then
      on_select(selected)
    end
  end)
end

return SelectProfile
