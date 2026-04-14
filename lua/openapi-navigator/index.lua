--- Ref index builder.
--- Scans all spec files in the detected root directory and builds two
--- bidirectional lookup tables:
---
---   _definitions[canonical_pointer] = { file, line, col }
---   _references[canonical_ref]      = { { file, line, col, text }, ... }
---
--- "canonical" means that cross-file refs are normalized to absolute paths,
--- so `./schemas/User.yaml#/properties/name` and
--- `../schemas/User.yaml#/properties/name` from different files both resolve
--- to the same key.

local M = {}

local config = require("openapi-navigator.config")
local resolver = require("openapi-navigator.resolver")

-- ============================================================
-- Internal state
-- ============================================================

--- definition path → location
--- key:   "/components/schemas/User"  (pointer, no leading file)
---        "/abs/path/to/file.yaml::/components/schemas/User"  (cross-file, sep "::")
--- value: { file = "/abs/path.yaml", line = 42, col = 4 }
--- @type table<string, {file: string, line: integer, col: integer}>
M._definitions = {}

--- canonical ref string → list of source locations
--- key:   "#/components/schemas/User"          (same-file ref, normalised per-file)
---        "/abs/path/schemas/User.yaml#/..."   (cross-file ref, absolute)
--- Actually we store by GLOBAL canonical = "<abs_target_file>::<pointer_or_empty>"
--- @type table<string, {file: string, line: integer, col: integer, text: string}[]>
M._references = {}

--- filepath → mtime at last index time (for change detection)
--- @type table<string, integer>
M._indexed_files = {}

--- Per-directory cache of resolved spec roots.
--- Keyed by the directory of the buffer file so that opening files from
--- different projects in the same session each get their own root.
--- @type table<string, string>
M._roots = {}

-- ============================================================
-- Helpers
-- ============================================================

--- Count leading spaces.
--- @param line string
--- @return integer
local function leading_spaces(line)
  local s = line:match("^( *)")
  return s and #s or 0
end

--- Extract key from a YAML/JSON line.
--- @param line string
--- @return string|nil
local function extract_key(line)
  return line:match("^%s*'([^']+)'%s*:")
    or line:match('^%s*"([^"]+)"%s*:')
    or line:match("^%s*([%w_%.%-%/{@}]+)%s*:")
end

--- Build the canonical key for the index from a resolved absolute file path
--- and an optional pointer string.
--- @param abs_file string
--- @param pointer string|nil
--- @return string
local function canonical_key(abs_file, pointer)
  return abs_file .. "::" .. (pointer or "")
end

-- ============================================================
-- Root discovery
-- ============================================================

--- Find the spec root for a given buffer, cached per source directory.
--- @param bufnr integer
--- @return string|nil
local function get_root(bufnr)
  local filepath = vim.fn.resolve(vim.api.nvim_buf_get_name(bufnr))
  local dir = vim.fn.fnamemodify(filepath, ":h")
  if M._roots[dir] ~= nil then return M._roots[dir] end
  local init = require("openapi-navigator.init")
  M._roots[dir] = init.get_spec_root(bufnr)
  return M._roots[dir]
end

-- ============================================================
-- Pointer path building (reverse of resolve_pointer)
-- ============================================================

--- Given all lines of a file up to `target_lnum`, compute the JSON pointer
--- path of the key at `target_lnum` by walking the indentation stack.
--- @param lines string[]
--- @param target_lnum integer  1-indexed
--- @return string  e.g. "/components/schemas/User"
local function compute_pointer_for_line(lines, target_lnum)
  --- Stack entries: { indent = N, key = "..." }
  local stack = {}

  for i = 1, target_lnum do
    local line = lines[i]
    if not line:match("^%s*$") and not line:match("^%s*#") then
      local indent = leading_spaces(line)
      local key = extract_key(line)
      if key then
        -- Pop all stack entries at the same or deeper indent (siblings/children)
        while #stack > 0 and stack[#stack].indent >= indent do
          table.remove(stack)
        end
        table.insert(stack, { indent = indent, key = key })
      end
    end
  end

  local parts = {}
  for _, entry in ipairs(stack) do
    table.insert(parts, entry.key)
  end
  return "/" .. table.concat(parts, "/")
end

-- ============================================================
-- File scanning
-- ============================================================

--- Scan a single file and populate the definition + reference tables.
--- @param filepath string  absolute path
local function index_file(filepath)
  local is_json = filepath:match("%.json$") ~= nil
  local lines = vim.fn.readfile(filepath)
  if not lines or #lines == 0 then return end

  local file_dir = vim.fn.fnamemodify(filepath, ":h")

  -- ---- Pass 1: build definitions (JSON pointer path for every key) ----
  -- We walk line by line and maintain an indentation stack.
  -- Every line that has a key at indent > 0 (not the root document) gets
  -- a pointer computed and stored.
  -- (We only need key lines, not value-only lines.)
  local def_stack = {} -- { indent, key }

  for lnum, line in ipairs(lines) do
    if not line:match("^%s*$") and not (not is_json and line:match("^%s*#")) then
      local indent = leading_spaces(line)
      local key = extract_key(line)
      if key then
        while #def_stack > 0 and def_stack[#def_stack].indent >= indent do
          table.remove(def_stack)
        end
        table.insert(def_stack, { indent = indent, key = key })

        local parts = {}
        for _, entry in ipairs(def_stack) do
          table.insert(parts, entry.key)
        end
        local pointer = "/" .. table.concat(parts, "/")
        local ckey = canonical_key(filepath, pointer)
        M._definitions[ckey] = { file = filepath, line = lnum, col = indent }
      end
    end
  end

  -- ---- Pass 2: find all $ref values ----
  for lnum, line in ipairs(lines) do
    local ref = resolver.parse_ref_from_line(line, is_json)
    if ref then
      -- Resolve the absolute target file
      local target_file
      if ref.file then
        target_file = vim.fn.resolve(file_dir .. "/" .. ref.file)
      else
        target_file = filepath
      end

      local ckey = canonical_key(target_file, ref.pointer)
      if not M._references[ckey] then
        M._references[ckey] = {}
      end
      table.insert(M._references[ckey], {
        file = filepath,
        line = lnum,
        col = leading_spaces(line),
        text = vim.trim(line),
      })
    end
  end

  M._indexed_files[filepath] = vim.fn.getftime(filepath)
end

-- ============================================================
-- Public API
-- ============================================================

--- Ensure all spec files in the root are indexed.
--- Skips files whose mtime hasn't changed since last index.
--- @param bufnr integer
function M.ensure_indexed(bufnr)
  local root = get_root(bufnr)
  if not root then return end

  -- Collect spec files under the root
  local files = {}
  for _, ext in ipairs({ "yaml", "yml", "json" }) do
    local glob_result = vim.fn.globpath(root, "**/*." .. ext, false, true)
    vim.list_extend(files, glob_result)
  end

  for _, filepath in ipairs(files) do
    filepath = vim.fn.resolve(filepath)
    local mtime = vim.fn.getftime(filepath)
    if M._indexed_files[filepath] ~= mtime then
      index_file(filepath)
    end
  end
end

--- Invalidate index entries for a specific buffer's file (called on BufWritePost).
--- @param bufnr integer
function M.invalidate(bufnr)
  local filepath = vim.fn.resolve(vim.api.nvim_buf_get_name(bufnr))
  if filepath == "" then return end

  -- Remove from indexed-files so it will be re-scanned
  M._indexed_files[filepath] = nil

  -- Remove stale definition entries that came from this file
  for ckey, loc in pairs(M._definitions) do
    if loc.file == filepath then
      M._definitions[ckey] = nil
    end
  end

  -- Remove stale reference entries that came from this file
  for ckey, locs in pairs(M._references) do
    local filtered = {}
    for _, loc in ipairs(locs) do
      if loc.file ~= filepath then
        table.insert(filtered, loc)
      end
    end
    if #filtered > 0 then
      M._references[ckey] = filtered
    else
      M._references[ckey] = nil
    end
  end

  -- Re-index the saved file immediately
  local mtime = vim.fn.getftime(filepath)
  if mtime >= 0 then
    index_file(filepath)
  end
end

--- Get the JSON pointer path of the definition the cursor is currently inside.
--- Works by walking all lines up to the cursor and computing the indentation stack.
--- @param bufnr integer|nil  defaults to current buffer
--- @return string|nil  e.g. "/components/schemas/User"
function M.get_pointer_at_cursor(bufnr)
  bufnr = bufnr or 0
  local row = vim.api.nvim_win_get_cursor(0)[1] -- 1-indexed
  local all_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  if #all_lines == 0 then return nil end

  row = math.min(row, #all_lines)
  return compute_pointer_for_line(all_lines, row)
end

--- Get the canonical index key for the definition under the cursor.
--- @param bufnr integer|nil
--- @return string|nil
function M.get_canonical_key_at_cursor(bufnr)
  bufnr = bufnr or 0
  local pointer = M.get_pointer_at_cursor(bufnr)
  if not pointer then return nil end
  local filepath = vim.fn.resolve(vim.api.nvim_buf_get_name(bufnr))
  return canonical_key(filepath, pointer)
end

--- Look up all locations that reference a canonical key.
--- @param ckey string
--- @return {file: string, line: integer, col: integer, text: string}[]
function M.get_references(ckey)
  return M._references[ckey] or {}
end

--- Look up the definition location for a canonical key.
--- @param ckey string
--- @return {file: string, line: integer, col: integer}|nil
function M.get_definition(ckey)
  return M._definitions[ckey]
end

--- Build a canonical key from a resolved absolute file + optional pointer.
--- Exported so other modules can construct keys without duplicating logic.
--- @param abs_file string
--- @param pointer string|nil
--- @return string
function M.canonical_key(abs_file, pointer)
  return canonical_key(abs_file, pointer)
end

return M
