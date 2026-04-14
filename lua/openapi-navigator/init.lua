local M = {}

local config = require("openapi-navigator.config")

-- Cache: bufnr → boolean (is this an OpenAPI buffer?)
local _detection_cache = {}

-- ---------------------------------------------------------------------------
-- OpenAPI buffer detection
-- ---------------------------------------------------------------------------

--- Check whether a filename matches any of the configured glob patterns.
--- Uses vim.fn.glob2regpat to convert each glob to a Vim regex, then
--- vim.fn.match to test. Checks both the full path and the basename.
--- @param filename string  basename or full path
--- @param patterns string[]
--- @return boolean
local function matches_pattern(filename, patterns)
  local base = vim.fn.fnamemodify(filename, ":t")
  for _, pat in ipairs(patterns) do
    local re = vim.fn.glob2regpat(pat)
    if vim.fn.match(filename, re) >= 0 then
      return true
    end
    if vim.fn.match(base, re) >= 0 then
      return true
    end
  end
  return false
end

--- Walk up directories from `dir` looking for any root marker file.
--- Returns the directory containing the marker or nil.
--- @param dir string  starting directory (absolute)
--- @param markers string[]
--- @return string|nil
local function find_root(dir, markers)
  local current = dir
  while true do
    for _, marker in ipairs(markers) do
      if vim.fn.filereadable(current .. "/" .. marker) == 1 then
        return current
      end
    end
    local parent = vim.fn.fnamemodify(current, ":h")
    if parent == current then
      break
    end
    current = parent
  end
  return nil
end

--- Check if a buffer contains an OpenAPI/Swagger document.
--- Detection strategy (in order):
---   1. Check the detection cache.
---   2. Match the filename against configured patterns.
---   3. Scan the first 20 lines for top-level openapi:/swagger: key.
---   4. Walk parent directories for a root_marker file (split specs).
--- @param bufnr integer
--- @return boolean
local function is_openapi_buffer(bufnr)
  if _detection_cache[bufnr] ~= nil then
    return _detection_cache[bufnr]
  end

  local filepath = vim.api.nvim_buf_get_name(bufnr)
  if filepath == "" then
    _detection_cache[bufnr] = false
    return false
  end

  -- Only care about yaml/yml/json files
  if not filepath:match("%.[yY][aA]?[mM][lL]$") and not filepath:match("%.json$") then
    _detection_cache[bufnr] = false
    return false
  end

  local opts = config.options

  -- 1. Filename pattern match
  local name_matches = matches_pattern(filepath, opts.patterns)

  -- 2. Content check: first 20 lines for top-level openapi: or swagger:
  local content_match = false
  if vim.api.nvim_buf_is_loaded(bufnr) then
    local first_lines = vim.api.nvim_buf_get_lines(bufnr, 0, 20, false)
    for _, line in ipairs(first_lines) do
      if line:match("^openapi%s*:") or line:match("^swagger%s*:") then
        content_match = true
        break
      end
      -- JSON format
      if line:match('"openapi"%s*:') or line:match('"swagger"%s*:') then
        content_match = true
        break
      end
    end
  else
    local raw = vim.fn.readfile(filepath, "", 20)
    for _, line in ipairs(raw) do
      if line:match("^openapi%s*:") or line:match("^swagger%s*:") then
        content_match = true
        break
      end
      if line:match('"openapi"%s*:') or line:match('"swagger"%s*:') then
        content_match = true
        break
      end
    end
  end

  if content_match then
    _detection_cache[bufnr] = true
    return true
  end

  -- 3. Part of a multi-file spec: check for root markers in parent dirs
  if name_matches then
    local dir = vim.fn.fnamemodify(filepath, ":h")
    local root = find_root(dir, opts.root_markers)
    if root then
      _detection_cache[bufnr] = true
      return true
    end
  end

  _detection_cache[bufnr] = false
  return false
end

-- Expose for use by other modules
M.is_openapi_buffer = is_openapi_buffer
M.find_root = find_root

--- Find the spec root directory for the given buffer.
--- Walks parent directories looking for a root_marker file.
--- Falls back to the buffer file's own directory so that specs that aren't
--- named openapi.yaml (e.g. petstore.yaml, api-docs.yaml) still get indexed.
--- @param bufnr integer
--- @return string|nil
function M.get_spec_root(bufnr)
  local filepath = vim.api.nvim_buf_get_name(bufnr or 0)
  if filepath == "" then return nil end
  local dir = vim.fn.fnamemodify(vim.fn.resolve(filepath), ":h")
  return find_root(dir, config.options.root_markers) or dir
end

-- ---------------------------------------------------------------------------
-- Keymap attachment
-- ---------------------------------------------------------------------------

--- Attach buffer-local keymaps for OpenAPI navigation.
--- @param bufnr integer
local function attach_keymaps(bufnr)
  local km = config.options.keymaps
  local function map(lhs, rhs, desc)
    if lhs ~= false then
      vim.keymap.set("n", lhs, rhs, { buffer = bufnr, desc = desc, silent = true })
    end
  end

  map(km.goto_definition, function()
    require("openapi-navigator.resolver").goto_definition()
  end, "OpenAPI: go to $ref definition")

  map(km.hover, function()
    require("openapi-navigator.hover").show()
  end, "OpenAPI: hover preview of $ref")

  map(km.find_references, function()
    require("openapi-navigator.references").find()
  end, "OpenAPI: find all $ref usages")
end

-- Track which buffers already have keymaps so we don't double-attach
local _keymaps_attached = {}

-- ---------------------------------------------------------------------------
-- Setup
-- ---------------------------------------------------------------------------

--- Main entry point. Call this from your config:
---   require("openapi-navigator").setup(opts)
--- @param opts table|nil
function M.setup(opts)
  config.build(opts)

  local group = vim.api.nvim_create_augroup("OpenAPINavigator", { clear = true })

  -- Attach keymaps and start lazy indexing when entering an OpenAPI buffer
  vim.api.nvim_create_autocmd("BufEnter", {
    group = group,
    pattern = { "*.yaml", "*.yml", "*.json" },
    callback = function(ev)
      if is_openapi_buffer(ev.buf) and not _keymaps_attached[ev.buf] then
        attach_keymaps(ev.buf)
        _keymaps_attached[ev.buf] = true
        -- Trigger lazy index build (non-blocking: index does its own scheduling)
        vim.schedule(function()
          if vim.api.nvim_buf_is_valid(ev.buf) then
            require("openapi-navigator.index").ensure_indexed(ev.buf)
          end
        end)
      end
    end,
  })

  -- Invalidate index entries and re-detect on save
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    pattern = { "*.yaml", "*.yml", "*.json" },
    callback = function(ev)
      -- Clear detection cache so the file is re-evaluated after edits
      _detection_cache[ev.buf] = nil
      if is_openapi_buffer(ev.buf) then
        require("openapi-navigator.index").invalidate(ev.buf)
      end
    end,
  })

  -- Clean up caches when a buffer is deleted
  vim.api.nvim_create_autocmd("BufDelete", {
    group = group,
    callback = function(ev)
      _detection_cache[ev.buf] = nil
      _keymaps_attached[ev.buf] = nil
    end,
  })

  -- User commands
  vim.api.nvim_create_user_command("OpenAPIReferences", function()
    require("openapi-navigator.references").find()
  end, { desc = "Find all $ref usages of the definition under cursor" })

  vim.api.nvim_create_user_command("OpenAPIDebug", function()
    local idx   = require("openapi-navigator.index")
    local res   = require("openapi-navigator.resolver")
    local bufnr = vim.api.nvim_get_current_buf()
    local file  = vim.api.nvim_buf_get_name(bufnr)
    local lines = {}

    local function add(label, value)
      table.insert(lines, string.format("  %-22s %s", label .. ":", tostring(value)))
    end

    table.insert(lines, "openapi-navigator debug")
    table.insert(lines, string.rep("─", 50))
    add("buffer", vim.fn.fnamemodify(file, ":~:."))
    add("detected as OpenAPI", tostring(is_openapi_buffer(bufnr)))
    add("spec root", tostring(M.get_spec_root(bufnr)))

    local n_def, n_ref, n_files = 0, 0, 0
    for _ in pairs(idx._definitions)   do n_def   = n_def   + 1 end
    for _ in pairs(idx._references)    do n_ref   = n_ref   + 1 end
    for _ in pairs(idx._indexed_files) do n_files  = n_files + 1 end
    add("indexed files", n_files)
    add("definitions", n_def)
    add("reference keys", n_ref)

    local ref = res.parse_ref_at_cursor()
    if ref then
      add("$ref on cursor", ref.raw)
      local target = res.resolve_file(ref, bufnr)
      add("resolves to file", tostring(target and vim.fn.fnamemodify(target, ":~:.") or "NOT FOUND"))
      if target then
        local pos = res.resolve_pointer(target, ref.pointer)
        add("pointer line", tostring(pos and pos.line or "NOT FOUND"))
      end
      if target then
        local ckey = idx.canonical_key(
          vim.fn.resolve(target),
          ref.pointer
        )
        local refs = idx.get_references(ckey)
        add("canonical key", ckey)
        add("references found", #refs)
      end
    else
      local pointer = idx.get_pointer_at_cursor(bufnr)
      add("$ref on cursor", "none")
      add("pointer at cursor", tostring(pointer))
      if pointer then
        local ckey = idx.canonical_key(vim.fn.resolve(file), pointer)
        local refs = idx.get_references(ckey)
        add("canonical key", ckey)
        add("references found", #refs)
      end
    end

    vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO, { title = "OpenAPI Navigator" })
  end, { desc = "Show openapi-navigator diagnostics for the current buffer" })
end

return M
