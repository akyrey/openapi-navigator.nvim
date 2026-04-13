-- Tests for config.lua — defaults, merging, and option access.

local config = require("openapi-navigator.config")

describe("config.build", function()
  after_each(function()
    config.build({})
  end)

  it("populates options with defaults when called with no args", function()
    config.build()
    assert.is_not_nil(config.options)
    assert.is_not_nil(config.options.patterns)
    assert.is_not_nil(config.options.root_markers)
    assert.is_not_nil(config.options.keymaps)
    assert.is_not_nil(config.options.hover)
  end)

  it("default patterns include openapi*.yaml", function()
    config.build()
    local found = false
    for _, p in ipairs(config.options.patterns) do
      if p == "openapi*.yaml" then
        found = true
        break
      end
    end
    assert.is_true(found, "expected openapi*.yaml in default patterns")
  end)

  it("default root_markers include openapi.yaml", function()
    config.build()
    local found = false
    for _, m in ipairs(config.options.root_markers) do
      if m == "openapi.yaml" then
        found = true
        break
      end
    end
    assert.is_true(found, "expected openapi.yaml in default root_markers")
  end)

  it("default keymaps are set", function()
    config.build()
    assert.are.equal("gd", config.options.keymaps.goto_definition)
    assert.are.equal("K", config.options.keymaps.hover)
    assert.are.equal("gr", config.options.keymaps.find_references)
  end)

  it("default hover options are set", function()
    config.build()
    assert.are.equal(80, config.options.hover.max_width)
    assert.are.equal(30, config.options.hover.max_height)
    assert.are.equal(2, config.options.hover.max_depth)
  end)

  it("user options override defaults", function()
    config.build({ hover = { max_width = 120, max_depth = 3, max_height = 30 } })
    assert.are.equal(120, config.options.hover.max_width)
    assert.are.equal(3, config.options.hover.max_depth)
  end)

  it("partial user options preserve unspecified defaults", function()
    config.build({ hover = { max_width = 100, max_height = 30, max_depth = 2 } })
    assert.are.equal("gd", config.options.keymaps.goto_definition)
  end)

  it("keymap can be disabled by setting to false", function()
    config.build({ keymaps = { goto_definition = false, hover = "K", find_references = "gr" } })
    assert.is_false(config.options.keymaps.goto_definition)
    assert.are.equal("K", config.options.keymaps.hover)
  end)

  it("custom patterns are merged with defaults", function()
    config.build({ patterns = { "my-api.yaml" } })
    assert.are.equal("my-api.yaml", config.options.patterns[1])
  end)

  it("calling build() twice replaces options", function()
    config.build({ hover = { max_depth = 5, max_width = 80, max_height = 30 } })
    config.build({ hover = { max_depth = 1, max_width = 80, max_height = 30 } })
    assert.are.equal(1, config.options.hover.max_depth)
  end)

  it("build() returns the merged options table", function()
    local opts = config.build({ hover = { max_width = 60, max_height = 30, max_depth = 2 } })
    assert.are.equal(60, opts.hover.max_width)
  end)
end)
