---@mod dap-python Python extension for nvim-dap

local api = vim.api
local M = {}

local root_session
local sessions = {}


--- Test runner to use by default. Default is "unittest". See |dap-python.test_runners|
--- Override this to set a different runner:
--- ```
--- require('dap-python').test_runner = "pytest"
--- ```
---@type string name of the test runner
M.test_runner = 'unittest'

--- Table to register test runners.
--- Built-in are test runners for unittest, pytest and django.
--- The key is the test runner name, the value a function to generate the
--- module name to run and its arguments. See |TestRunner|
---@type table<string, TestRunner>
M.test_runners = {}

local function prune_nil(items)
  return vim.tbl_filter(function(x) return x end, items)
end

M.widgets = {}
M.widgets.sessions = {
  refresh_listener = {'event_initialized', 'event_stopped', 'event_terminated'},
  new_buf = function()
    local buf = api.nvim_create_buf(false, true)
    api.nvim_buf_set_option(buf, 'buftype', 'nofile')
    api.nvim_buf_set_keymap(
      buf, "n", "<CR>", "<Cmd>lua require('dap.ui').trigger_actions()<CR>", {})
    api.nvim_buf_set_keymap(
      buf, "n", "<2-LeftMouse>", "<Cmd>lua require('dap.ui').trigger_actions()<CR>", {})
    return buf
  end,
  render = function(view)
    local layer = view.layer()
    local render_session = function(session)
      local dap = require('dap')
      local suffix
      if session.current_frame then
        suffix = 'Stopped at line ' .. session.current_frame.line
      elseif session.stopped_thread_id then
        suffix = 'Stopped'
      else
        suffix = 'Running'
      end
      local config_name = (session.config or {}).name or 'No name'
      local prefix = session == dap.session() and '→ ' or '  '
      return prefix .. config_name .. ' (' .. suffix .. ')'
    end
    local context = {}
    context.actions = {
      {
        label = 'Activate session',
        fn = function(_, session)
          if session then
            require('dap').set_session(session)
            if vim.bo.bufhidden == 'wipe' then
              view.close()
            else
              view.refresh()
            end
          end
        end
      }
    }
    layer.render(vim.tbl_keys(sessions), render_session, context)
  end
}

local is_windows = function()
    return vim.loop.os_uname().sysname:find("Windows", 1, true) and true
end


local get_python_path = function()
  local venv_path = os.getenv('VIRTUAL_ENV') or os.getenv('CONDA_PREFIX')
  if venv_path then
    if is_windows() then
        return venv_path .. '\\Scripts\\python.exe'
    end
    return venv_path .. '/bin/python'
  end
  return nil
end


local enrich_config = function(config, on_config)
  if not config.pythonPath and not config.python then
    config.pythonPath = get_python_path()
  end
  on_config(config)
end


local default_setup_opts = {
  include_configs = true,
  console = 'integratedTerminal',
  pythonPath = nil,
}

local default_test_opts = {
  console = 'integratedTerminal'
}


local function load_dap()
  local ok, dap = pcall(require, 'dap')
  assert(ok, 'nvim-dap is required to use dap-python')
  return dap
end


---@private
function M.test_runners.unittest(classname, methodname)
  local path = vim.fn.expand('%:.:r:gs?/?.?')
  local test_path = table.concat(prune_nil({path, classname, methodname}), '.')
  local args = {'-v', test_path}
  return 'unittest', args
end


---@private
function M.test_runners.pytest(classname, methodname)
  local path = vim.fn.expand('%:p')
  local test_path = table.concat(prune_nil({path, classname, methodname}), '::')
  -- -s "allow output to stdout of test"
  local args = {'-s', test_path}
  return 'pytest', args
end


---@private
function M.test_runners.django(classname, methodname)
  local path = vim.fn.expand('%:r:gs?/?.?')
  local test_path = table.concat(prune_nil({path, classname, methodname}), '.')
  local args = {'test', test_path}
  return 'django', args
end


--- Register the python debug adapter
---@param adapter_python_path string|nil Path to the python interpreter. Path must be absolute or in $PATH and needs to have the debugpy package installed. Default is `python3`
---@param opts SetupOpts|nil See |SetupOpts|
function M.setup(adapter_python_path, opts)
  local dap = load_dap()
  adapter_python_path = adapter_python_path and vim.fn.expand(vim.fn.trim(adapter_python_path)) or 'python3'
  opts = vim.tbl_extend('keep', opts or {}, default_setup_opts)
  dap.adapters.python = function(cb, config)
    if config.request == 'attach' then
      local port = (config.connect or config).port
      cb({
        type = 'server';
        port = assert(port, '`connect.port` is required for a python `attach` configuration');
        host = (config.connect or config).host or '127.0.0.1';
        enrich_config = enrich_config;
        options = {
          source_filetype = 'python',
        }
      })
    else
      cb({
        type = 'executable';
        command = adapter_python_path;
        args = { '-m', 'debugpy.adapter' };
        enrich_config = enrich_config;
        options = {
          source_filetype = 'python',
        }
      })
    end
  end

  dap.listeners.after['event_debugpyAttach']['dap-python'] = function(_, config)
    local adapter = {
      host = config.connect.host,
      port = config.connect.port,
    }
    local session
    local connect_opts = {}
    session = require('dap.session'):connect(adapter, connect_opts, function(err)
      if err then
        vim.notify('Error connecting to subprocess session: ' .. vim.inspect(err), vim.log.levels.WARN)
      elseif session then
        session:initialize(config)
        dap.set_session(session)
      end
    end)
  end

  dap.listeners.after.event_initialized['dap-python'] = function(session)
    sessions[session] = true
    if not root_session then
      root_session = session
    end
  end
  local remove_session = function(session)
    sessions[session] = nil
    if session == root_session then
      root_session = nil
    elseif dap.session() == session or dap.session() == nil then
      dap.set_session(root_session)
    end
  end
  dap.listeners.after.event_exited['dap-python'] = remove_session
  dap.listeners.after.event_terminated['dap-python'] = remove_session
  dap.listeners.after.disconnected['dap-python'] = remove_session

  if opts.include_configs then
    dap.configurations.python = dap.configurations.python or {}
    table.insert(dap.configurations.python, {
      type = 'python';
      request = 'launch';
      name = 'Launch file';
      program = '${file}';
      console = opts.console;
      pythonPath = opts.pythonPath,
    })
    table.insert(dap.configurations.python, {
      type = 'python';
      request = 'launch';
      name = 'Launch file with arguments';
      program = '${file}';
      args = function()
        local args_string = vim.fn.input('Arguments: ')
        return vim.split(args_string, " +")
      end;
      console = opts.console;
      pythonPath = opts.pythonPath,
    })
    table.insert(dap.configurations.python, {
      type = 'python';
      request = 'attach';
      name = 'Attach remote';
      connect = function()
        local host = vim.fn.input('Host [127.0.0.1]: ')
        host = host ~= '' and host or '127.0.0.1'
        local port = tonumber(vim.fn.input('Port [5678]: ')) or 5678
        return { host = host, port = port }
      end;
    })
  end
end


local function get_nodes(query_text, predicate)
  local end_row = api.nvim_win_get_cursor(0)[1]
  local ft = api.nvim_buf_get_option(0, 'filetype')
  assert(ft == 'python', 'test_method of dap-python only works for python files, not ' .. ft)
  local query = vim.treesitter.parse_query(ft, query_text)
  assert(query, 'Could not parse treesitter query. Cannot find test')
  local parser = vim.treesitter.get_parser(0)
  local root = (parser:parse()[1]):root()
  local nodes = {}
  for _, node in query:iter_captures(root, 0, 0, end_row) do
    if predicate(node) then
      table.insert(nodes, node)
    end
  end
  return nodes
end


local function get_function_nodes()
  local query_text = [[
    (function_definition
      name: (identifier) @name) @definition.function
  ]]
  return get_nodes(query_text, function(node)
    return node:type() == 'identifier'
  end)
end


local function get_class_nodes()
  local query_text = [[
    (class_definition
      name: (identifier) @name) @definition.class
  ]]
  return get_nodes(query_text, function(node)
    return node:type() == 'identifier'
  end)
end


local function get_node_text(node)
  local row1, col1, row2, col2 = node:range()
  if row1 == row2 then
    row2 = row2 + 1
  end
  local lines = api.nvim_buf_get_lines(0, row1, row2, true)
  if #lines == 1 then
    return (lines[1]):sub(col1 + 1, col2)
  end
  return table.concat(lines, '\n')
end


local function get_parent_classname(node)
  local parent = node:parent()
  while parent do
    local type = parent:type()
    if type == 'class_definition' then
      for child in parent:iter_children() do
        if child:type() == 'identifier' then
          return get_node_text(child)
        end
      end
    end
    parent = parent:parent()
  end
end


---@param opts DebugOpts
local function trigger_test(classname, methodname, opts)
  local test_runner = opts.test_runner or M.test_runner
  local runner = M.test_runners[test_runner]
  if not runner then
    vim.notify('Test runner `' .. test_runner .. '` not supported', vim.log.levels.WARN)
    return
  end
  assert(type(runner) == "function", "Test runner must be a function")
  local module, args = runner(classname, methodname)
  local config = {
    name = table.concat(prune_nil({classname, methodname}), '.'),
    type = 'python',
    request = 'launch',
    module = module,
    args = args,
    console = opts.console
  }
  load_dap().run(vim.tbl_extend('force', config, opts.config or {}))
end


local function closest_above_cursor(nodes)
  local result
  for _, node in pairs(nodes) do
    if not result then
      result = node
    else
      local node_row1, _, _, _ = node:range()
      local result_row1, _, _, _ = result:range()
      if node_row1 > result_row1 then
        result = node
      end
    end
  end
  return result
end


--- Run test class above cursor
---@param opts DebugOpts See |DebugOpts|
function M.test_class(opts)
  opts = vim.tbl_extend('keep', opts or {}, default_test_opts)
  local class_node = closest_above_cursor(get_class_nodes())
  if not class_node then
    print('No suitable test class found')
    return
  end
  local class = get_node_text(class_node)
  trigger_test(class, nil, opts)
end


--- Run the test method above cursor
---@param opts DebugOpts See |DebugOpts|
function M.test_method(opts)
  opts = vim.tbl_extend('keep', opts or {}, default_test_opts)
  local function_node = closest_above_cursor(get_function_nodes())
  if not function_node then
    print('No suitable test method found')
    return
  end
  local class = get_parent_classname(function_node)
  local function_name = get_node_text(function_node)
  trigger_test(class, function_name, opts)
end


--- Strips extra whitespace at the start of the lines
--
-- >>> remove_indent({'    print(10)', '    if True:', '        print(20)'})
-- {'print(10)', 'if True:', '    print(20)'}
local function remove_indent(lines)
  local offset = nil
  for _, line in ipairs(lines) do
    local first_non_ws = line:find('[^%s]') or 0
    if first_non_ws >= 1 and (not offset or first_non_ws < offset) then
      offset = first_non_ws
    end
  end
  if offset > 1 then
    return vim.tbl_map(function(x) return string.sub(x, offset) end, lines)
  else
    return lines
  end
end


--- Debug the selected code
---@param opts DebugOpts
function M.debug_selection(opts)
  opts = vim.tbl_extend('keep', opts or {}, default_test_opts)
  local start_row, _ = unpack(api.nvim_buf_get_mark(0, '<'))
  local end_row, _ = unpack(api.nvim_buf_get_mark(0, '>'))
  local lines = api.nvim_buf_get_lines(0, start_row - 1, end_row, false)
  local code = table.concat(remove_indent(lines), '\n')
  local config = {
    type = 'python',
    request = 'launch',
    code = code,
    console = opts.console
  }
  load_dap().run(vim.tbl_extend('force', config, opts.config or {}))
end



---@class PathMapping
---@field localRoot string
---@field remoteRoot string


---@class DebugpyConfig
---@field django boolean|nil Enable django templates. Default is `false`
---@field gevent boolean|nil Enable debugging of gevent monkey-patched code. Default is `false`
---@field jinja boolean|nil Enable jinja2 template debugging. Default is `false`
---@field justMyCode boolean|nil Debug only user-written code. Default is `true`
---@field pathMappings PathMapping[]|nil Map of local and remote paths.
---@field pyramid boolean|nil Enable debugging of pyramid applications
---@field redirectOutput boolean|nil Redirect output to debug console. Default is `false`
---@field showReturnValue boolean|nil Shows return value of function when stepping
---@field sudo boolean|nil Run program under elevated permissions. Default is `false`

---@class DebugpyLaunchConfig : DebugpyConfig
---@field module string|nil Name of the module to debug
---@field program string|nil Absolute path to the program
---@field code string|nil Code to execute in string form
---@field python string[]|nil Path to python executable and interpreter arguments
---@field args string[]|nil Command line arguments passed to the program
---@field console DebugpyConsole See |DebugpyConsole|
---@field cwd string|nil Absolute path to the working directory of the program being debugged.
---@field env table|nil Environment variables defined as key value pair
---@field stopOnEntry boolean|nil Stop at first line of user code.


---@class DebugOpts
---@field console DebugpyConsole See |DebugpyConsole|
---@field test_runner "unittest"|"pytest"|"django"|string name of the test runner. Default is |dap-python.test_runner|
---@field config DebugpyConfig Overrides for the configuration

---@class SetupOpts
---@field include_configs boolean Add default configurations
---@field console DebugpyConsole See |DebugpyConsole|
---@field pythonPath string|nil Path to python interpreter. Uses interpreter from `VIRTUAL_ENV` environment variable or `adapter_python_path` by default


---@alias TestRunner fun(classname: string, methodname: string): string module, string[] args

---@alias DebugpyConsole "internalConsole"|"integratedTerminal"|"externalTerminal"|nil

return M
