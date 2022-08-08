local config = {
  defaults = {
    test_path_pattern = { ".*_test%.cpp", ".*_test%.cc" },
  },
}

setmetatable(config, { __index = config.defaults })

return config
