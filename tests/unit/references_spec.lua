-- Tests for references.lua — canonical key building and quickfix integration.
-- These tests exercise the logic that maps cursor position → canonical key,
-- which drives the find-references feature.

local config     = require("openapi-navigator.config")
local index      = require("openapi-navigator.index")
local init       = require("openapi-navigator.init")
local resolver   = require("openapi-navigator.resolver")

config.build({})

local fixture_dir = vim.fn.resolve(
  vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h") .. "/fixtures"
)
local spec30    = vim.fn.resolve(fixture_dir .. "/openapi30.yaml")
local spec31    = vim.fn.resolve(fixture_dir .. "/openapi31.yaml")
local user_yaml = vim.fn.resolve(fixture_dir .. "/schemas/User.yaml")

local _original_get_spec_root = init.get_spec_root
local function use_fixture_root()
  init.get_spec_root = function(_bufnr)
    return fixture_dir
  end
end
local function restore_get_spec_root()
  init.get_spec_root = _original_get_spec_root
end

local function reset_index()
  index._definitions   = {}
  index._references    = {}
  index._indexed_files = {}
  index._roots         = {}
end

-- ── canonical key building from a $ref line ───────────────────────────────────

describe("canonical key from $ref cursor position", function()
  local bufnr

  before_each(function()
    use_fixture_root()
    reset_index()
    index.ensure_indexed(0)
  end)

  after_each(function()
    restore_get_spec_root()
    if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end
  end)

  local function buf_with_line(filepath, line_text)
    bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(bufnr, filepath)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { line_text })
    local win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, bufnr)
    vim.api.nvim_win_set_cursor(win, { 1, 0 })
    return bufnr
  end

  it("same-file $ref resolves to the correct canonical key", function()
    buf_with_line(spec30, "  $ref: '#/components/schemas/UserId'")
    local ref = resolver.parse_ref_at_cursor()
    assert.is_not_nil(ref)
    assert.is_nil(ref.file)
    assert.are.equal("/components/schemas/UserId", ref.pointer)

    -- Build the canonical key as references.lua does
    local target_file = vim.fn.resolve(vim.api.nvim_buf_get_name(0))
    local ckey = index.canonical_key(target_file, ref.pointer)
    assert.are.equal(spec30 .. "::/components/schemas/UserId", ckey)
  end)

  it("cross-file $ref resolves to the absolute target file canonical key", function()
    buf_with_line(spec30, "  $ref: './schemas/User.yaml'")
    local ref = resolver.parse_ref_at_cursor()
    assert.is_not_nil(ref)

    local source_dir = vim.fn.fnamemodify(spec30, ":h")
    local target_file = vim.fn.resolve(source_dir .. "/" .. ref.file)
    local ckey = index.canonical_key(target_file, ref.pointer)
    assert.are.equal(user_yaml .. "::", ckey)
  end)

  it("cross-file $ref with pointer resolves to correct canonical key", function()
    buf_with_line(spec30, "  $ref: './schemas/User.yaml#/properties/email'")
    local ref = resolver.parse_ref_at_cursor()
    assert.is_not_nil(ref)

    local source_dir = vim.fn.fnamemodify(spec30, ":h")
    local target_file = vim.fn.resolve(source_dir .. "/" .. ref.file)
    local ckey = index.canonical_key(target_file, ref.pointer)
    assert.are.equal(user_yaml .. "::/properties/email", ckey)
  end)
end)

-- ── references found via the index ───────────────────────────────────────────

describe("reference lookup — OpenAPI 3.0", function()
  before_each(function()
    use_fixture_root()
    reset_index()
    index.ensure_indexed(0)
  end)

  after_each(function()
    restore_get_spec_root()
  end)

  it("UserId has references in multiple locations", function()
    local k = index.canonical_key(spec30, "/components/schemas/UserId")
    local refs = index.get_references(k)
    assert.is_true(#refs >= 2)
    -- All refs should point back to files within the fixture dir
    for _, r in ipairs(refs) do
      assert.is_not_nil(r.file:find(fixture_dir, 1, true),
        "reference file should be inside fixture dir: " .. r.file)
    end
  end)

  it("Error schema has at least one reference", function()
    local k = index.canonical_key(spec30, "/components/schemas/Error")
    local refs = index.get_references(k)
    assert.is_true(#refs >= 1, "Error should have >= 1 reference")
  end)

  it("cross-file User.yaml target has a reference from openapi30.yaml", function()
    local k = index.canonical_key(user_yaml, nil)
    local refs = index.get_references(k)
    local from_spec = false
    for _, r in ipairs(refs) do
      if r.file == spec30 then from_spec = true end
    end
    assert.is_true(from_spec, "User.yaml should be referenced from openapi30.yaml")
  end)

  it("cross-file ref with pointer is captured", function()
    -- openapi30.yaml has $ref: './schemas/User.yaml#/properties/address'
    local addr_key = vim.fn.resolve(fixture_dir .. "/schemas/Address.yaml")
    local k = index.canonical_key(user_yaml, "/properties/address")
    local refs = index.get_references(k)
    -- The cross-file+pointer ref from openapi30.yaml to User.yaml#/properties/address
    assert.is_true(#refs >= 1,
      "User.yaml#/properties/address should have at least one reference")
  end)
end)

describe("reference lookup — OpenAPI 3.1", function()
  before_each(function()
    use_fixture_root()
    reset_index()
    index.ensure_indexed(0)
  end)

  after_each(function()
    restore_get_spec_root()
  end)

  it("3.1 UserSummary has references (including from webhook)", function()
    local k = index.canonical_key(spec31, "/components/schemas/UserSummary")
    local refs = index.get_references(k)
    assert.is_true(#refs >= 1, "3.1 UserSummary should be referenced")
    -- At least one reference should be the webhook or paths section
    local found_in_spec31 = false
    for _, r in ipairs(refs) do
      if r.file == spec31 then found_in_spec31 = true end
    end
    assert.is_true(found_in_spec31, "UserSummary should be referenced within openapi31.yaml")
  end)

  it("3.1 Metadata has at least one reference", function()
    local k = index.canonical_key(spec31, "/components/schemas/Metadata")
    local refs = index.get_references(k)
    assert.is_true(#refs >= 1, "3.1 Metadata should be referenced from Item schema")
  end)

  it("3.1 path-item $ref to PathItem.yaml is captured", function()
    local path_item_yaml = vim.fn.resolve(fixture_dir .. "/schemas/PathItem.yaml")
    local k = index.canonical_key(path_item_yaml, nil)
    local refs = index.get_references(k)
    assert.is_true(#refs >= 1,
      "PathItem.yaml should be referenced from openapi31.yaml paths")
  end)
end)

-- ── get_pointer_at_cursor used for definition-side references ─────────────────

describe("pointer-at-cursor for definition lookup", function()
  local bufnr

  after_each(function()
    if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end
  end)

  it("cursor on a definition key produces a pointer matching expected refs", function()
    use_fixture_root()
    reset_index()
    index.ensure_indexed(0)

    -- Set up a buffer as if we were editing openapi30.yaml, cursor on UserId line
    bufnr = vim.api.nvim_create_buf(false, true)
    local lines = vim.fn.readfile(spec30)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    vim.api.nvim_buf_set_name(bufnr, spec30)

    -- Find the line number for "    UserId:" in the loaded lines
    local userid_line = nil
    for i, l in ipairs(lines) do
      if l:match("^    UserId:") then
        userid_line = i
        break
      end
    end
    assert.is_not_nil(userid_line, "should find UserId line in spec30")

    local win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, bufnr)
    vim.api.nvim_win_set_cursor(win, { userid_line, 4 })

    local pointer = index.get_pointer_at_cursor(bufnr)
    assert.is_not_nil(pointer)
    assert.is_not_nil(pointer:find("UserId"), "pointer should include UserId")

    -- Now use this pointer to look up references
    local ckey = index.canonical_key(spec30, pointer)
    local refs = index.get_references(ckey)
    assert.is_true(#refs >= 2, "UserId should have multiple references when looked up by pointer")

    restore_get_spec_root()
  end)
end)
