local function get_version_from_path(path)
  local name = vim.fn.fnamemodify(path, ':t')
  local version = name:match '^blender[%d%.]*%-(%d+%.%d+)'
  if version then
    return 'Blender ' .. version
  end
  if name == 'Blender' or name == 'blender' then
    return 'Blender'
  end
  return nil
end

local function find_blender_versions(search_paths, execs)
  local found = {}
  local checked = {}

  for name, exec in pairs(execs) do
    for _, path in ipairs(search_paths) do
      local full_path
      local is_windows = vim.fn.has 'win32' == 1
      if is_windows then
        full_path = path .. '/' .. name .. '/blender'
      else
        full_path = path == '' and exec or path .. '/' .. exec
      end
      if not checked[full_path] then
        checked[full_path] = true
        local exec_path = vim.fn.exepath(full_path)
        if exec_path ~= '' then
          local version_name = get_version_from_path(exec_path)
          if version_name and not found[version_name] then
            found[version_name] = exec_path
          end
        end
      end
    end
  end

  return found
end

local function scan_directory_for_blender(dir)
  local versions = {}
  if vim.fn.isdirectory(dir) ~= 1 then
    return versions
  end
  for _, name in ipairs(vim.fn.readdir(dir)) do
    local blender_path = dir .. '/' .. name .. '/blender'
    if vim.fn.executable(blender_path) == 1 then
      local version = name:match '^Blender%s+(%d+%.%d+)'
      if version then
        versions['Blender ' .. version] = blender_path
      end
    end
  end
  return versions
end

return function()
  local execs = {
    ['Blender'] = 'blender',
    ['Blender 3.6'] = 'blender-3.6',
    ['Blender 4.0'] = 'blender-4.0',
    ['Blender 4.1'] = 'blender-4.1',
    ['Blender 4.2'] = 'blender-4.2',
    ['Blender 4.3'] = 'blender-4.3',
    ['Blender 4.4'] = 'blender-4.4',
    ['Blender 4.5'] = 'blender-4.5',
    ['Blender 5.0'] = 'blender-5.0',
  }

  local search_paths = {}
  if vim.fn.has 'unix' == 1 then
    table.insert(search_paths, '/bin')
    table.insert(search_paths, '/usr/bin')
    table.insert(search_paths, '/usr/local/bin')
  end
  if vim.fn.has 'mac' == 1 then
    execs['Blender.app'] = '/Applications/Blender.app/Contents/MacOS/Blender'
    table.insert(search_paths, '/opt/homebrew/bin')
  end
  local is_windows = vim.fn.has 'win32' == 1
  if is_windows then
    local program_files = vim.env.ProgramFiles or 'C:/Program Files'
    local program_files_x86 = vim.env['ProgramFiles(x86)'] or 'C:/Program Files (x86)'
    table.insert(search_paths, program_files .. '/Blender Foundation')
    table.insert(search_paths, program_files_x86 .. '/Blender Foundation')
  end

  local profiles = {}
  local found_versions = find_blender_versions(search_paths, execs)

  if is_windows then
    local program_files = vim.env.ProgramFiles or 'C:/Program Files'
    local program_files_x86 = vim.env['ProgramFiles(x86)'] or 'C:/Program Files (x86)'
    for _, pf in ipairs { program_files, program_files_x86 } do
      local auto_versions = scan_directory_for_blender(pf .. '/Blender Foundation')
      for version, path in pairs(auto_versions) do
        if not found_versions[version] then
          found_versions[version] = path
        end
      end
    end
  end

  for name, exec_path in pairs(found_versions) do
    local profile = {
      name = name,
      cmd = exec_path,
    }
    table.insert(profiles, profile)
  end

  return profiles
end
