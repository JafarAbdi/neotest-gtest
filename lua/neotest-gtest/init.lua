local async = require("neotest.async")
local lib = require("neotest.lib")
local ProjectConfig = require("cmake.project_config")
local config = require("neotest-gtest.config")

---@class Failure
---@field failure string
---@field type string

---@class Testsuite
---@field name string
---@field status string
---@field result string
---@field timestamp string
---@field time string
---@field classname string
---@field failures Failure[]?

---@class Testsuites
---@field name string
---@field tests integer
---@field failures integer
---@field disabled integer
---@field errors integer
---@field timestamp string
---@field time string
---@field testsuite Testsuite[]

---@class Result
---@field name string
---@field tests integer
---@field failures integer
---@field disabled integer
---@field errors integer
---@field timestamp string
---@field time string
---@field testsuites Testsuites[]

local test_name_to_position_id = function(test_name)
  return test_name:match("%((.+)%)"):gsub(" ", ""):gsub(",", ".")
end
---@class neotest.Adapter
---@field name string
local adapter = { name = "neotest-gtest" }

function adapter.setup(values)
  setmetatable(config, { __index = vim.tbl_deep_extend("force", config.defaults, values) })
end

---Find the project root directory given a current directory to work from.
---Should no root be found, the adapter can still be used in a non-project context if a test file matches.
---@async
---@param dir string @Directory to treat as cwd
---@return string | nil @Absolute root dir of test suite
adapter.root = lib.files.match_root_pattern(
  ".neovim.json",
  "compile_commands.json",
  ".clangd",
  ".git"
)

---@async
---@param file_path string
---@return boolean
function adapter.is_test_file(file_path)
  for _, pattern in pairs(config.test_path_pattern) do
    if file_path:match(pattern) then
      return true
    end
  end
  return false
end

local query = [[
(function_definition
  declarator: (function_declarator
    parameters: (parameter_list
                  (parameter_declaration
                      type: (type_identifier))
                  .
                  (parameter_declaration
                      type: (type_identifier)))) @test.name
  (#match? @test.name "TEST|TEST_F|TEST_P")) @test.definition
]]

query = vim.treesitter.query.parse_query("cpp", query)
---Given a file path, parse all the tests within it.
---@async
---@param file_path string Absolute file path
---@return neotest.Tree | nil
function adapter.discover_positions(file_path)
  local position_id = function(position, _)
    return position.path .. "::" .. test_name_to_position_id(position.name)
  end
  return lib.treesitter.parse_positions(
    file_path,
    query,
    { nested_namespaces = true, position_id = position_id }
  )
end

---@param args neotest.RunArgs
---@return neotest.RunSpec
function adapter.build_spec(args)
  local data = args.tree:data()
  if not require("cmake").auto_select_target(data.path) then
    return
  end
  local project_config = ProjectConfig.new()
  local target_dir, target, _ = project_config:get_current_target()
  local results_path = async.fn.tempname()
  local command = target.filename .. " --gtest_output=json:" .. results_path .. " --gtest_color=yes"
  if data.type == "test" then
    command = command .. " --gtest_filter=" .. "'*" .. test_name_to_position_id(data.name) .. "*'"
  end
  return {
    command = command,
    cwd = target_dir.filename,
    context = {
      results_path = results_path,
    },
  }
end

-- The following functions are copied from
---@param test Testsuite
---@return string
local function get_status(test)
  if test.result == "SKIPPED" or test.status == "NOTRUN" then
    return "skipped"
  end
  assert(test.result == "COMPLETED", "unknown result")
  return #(test.failures or {}) == 0 and "passed" or "failed"
end

local function range_contains(range, line)
  -- range is linstart, colstart, lineend, colend
  -- we ignore cols because Google Test doesn't report them. If someone writes
  -- multiple tests on the same line that's on them.
  return range[1] <= line and range[3] >= line
end

---@param tree neotest.Tree
---@param error Failure
---@return neotest.Error
local function error_info(tree, error)
  local message = error.failure
  local test_data = tree:data()
  if message == nil then
    return { message = "Unknown error" }
  end
  -- split first line: it represents location, the rest is an arbitrary message
  local linebreak = message:find("\n")
  local location = message:sub(1, linebreak - 1)
  message = message:sub(linebreak + 1)
  local filename, linenum = location:match("(.*)%:(%d+)$")
  -- 3 cases:
  -- First line is "unknown file": exception thrown somewhere
  -- First line is "/path/to/file:linenum", the failure is inside the test
  -- First line is "/path/to/file:linenum", the failure is outside the test
  local header
  if linenum ~= nil then
    linenum = tonumber(linenum)
    assert(filename ~= nil, "error format not understood")
    if filename == test_data.path then
      header = string.format("Assertion failure at line %d:", linenum)
      -- Do not show diagnostics outside of test: multiple tests can show
      -- the same line, which will likely lead to confusion
      -- TODO: Investigate alternatives, such as showing all errors with
      -- test names
      if not range_contains(test_data.range, linenum) then
        linenum = nil
      end
    else
      header = string.format("Assertion failure in %s at line %d:", filename, linenum)
      linenum = nil
    end
  else
    assert(filename == nil, "error format not understood")
    -- file is unknown: do not repeat ourselves. GTest will say everything
    header = ""
  end
  return {
    message = header and (header .. "\n" .. message) or message,
    -- google test lines are 1-indexed, neovim expects 0-indexed
    line = linenum and linenum - 1,
  }
end

---@param tree neotest.Tree
---@param testsuite Testsuite
---@return neotest.Error[]
local function make_errors_list(tree, testsuite)
  return vim.tbl_map(function(e)
    return error_info(tree, e)
  end, testsuite.failures or {})
end

---@param tree neotest.Tree
---@param test Testsuite
---@return string
local function make_summary(tree, test)
  local lines = {}
  local status = get_status(test)
  local errors = make_errors_list(tree, test)
  lines[#lines + 1] = string.format("%s.%s", test.classname, test.name)

  if status == "skipped" then
    lines[#lines + 1] = "Test skipped."
  elseif status == "passed" then
    lines[#lines + 1] = string.format("Passed, Time: %s, Timestamp: %s", test.time, test.timestamp)
  else
    lines[#lines + 1] = string.format(
      "Errors: %d, Time: %s, Timestamp: %s",
      #errors,
      test.time,
      test.timestamp
    )
  end

  return table.concat(lines, "\n")
end

---@async
---@param spec neotest.RunSpec
---@param result neotest.StrategyResult
---@param tree neotest.Tree
---@return table<string, neotest.Result>
function adapter.results(spec, result, tree)
  local success, data = pcall(lib.files.read, spec.context.results_path)
  if not success then
    return {}
  end
  ---@type Result
  local gtest_output = vim.json.decode(data) or { testsuites = {} }
  local reports = {}
  local position_id = tree:data().path
  reports[position_id] = {
    status = gtest_output.failures == 0 and "passed" or "failed",
    output = result.output,
    short = gtest_output.name
      .. "\n"
      .. "tests: "
      .. gtest_output.tests
      .. " failures: "
      .. gtest_output.failures
      .. " disabled: "
      .. gtest_output.disabled
      .. " errors: "
      .. gtest_output.errors,
    errors = {},
  }
  for _, testsuite in ipairs(gtest_output.testsuites) do
    -- Hacky way to detect if we're running TEST_P
    local is_test_p = #vim.split(testsuite.name, "/") == 2
    for _, test in ipairs(testsuite.testsuite) do
      -- TEST_P's classname consists of two parts `XXXX/test_suite_name` -- name consists of two parts `test_name/XXX`
      -- TEST/TEST_F's classname is just one part `test_suite_name` -- name consists of one part `test_name`
      local classname_splitted = vim.split(test.classname, "/")
      local name_splitted = vim.split(test.name, "/")
      position_id = tree:data().path .. "::" .. classname_splitted[#classname_splitted] .. "." .. name_splitted[1]
      local test_data = tree:get_key(position_id)
      reports[position_id] = {
        status = get_status(test),
        output = result.output,
        short = make_summary(test_data, test),
        errors = make_errors_list(test_data, test),
      }
    end
  end
  return reports
end

return adapter
