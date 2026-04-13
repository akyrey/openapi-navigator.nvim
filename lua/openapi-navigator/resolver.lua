local M = {}

-- ---------------------------------------------------------------------------
-- $ref parsing
-- ---------------------------------------------------------------------------

--- Parse a $ref value from the given line text.
--- Returns {raw, file, pointer} or nil if no $ref found.
--- @param line string
--- @param is_json boolean
--- @return {raw: string, file: string|nil, pointer: string|nil}|nil
local function parse_ref_from_line(line, is_json)
  local raw
  if is_json then
    raw = line:match('"$ref"%s*:%s*"([^"]+)"')
  else
    -- YAML: $ref: value  or  $ref: 'value'  or  $ref: "value"
    raw = line:match('%$ref%s*:%s*["\']([^"\']+)["\']')
      or line:match('%$ref%s*:%s*([^%s#\'"]+[^\'",%s]*)')
  end

  if not raw or raw == "" then
    return nil
  end

  -- Split on first '#' → file path + JSON pointer
  local hash_pos = raw:find("#", 1, true)
  local file_part, pointer_part

  if hash_pos then
    file_part = raw:sub(1, hash_pos - 1)
    pointer_part = raw:sub(hash_pos + 1) -- everything after '#'
  else
    file_part = raw
    pointer_part = nil
  end

  -- Empty string means same-file reference
  if file_part == "" then
    file_part = nil
  end

  -- Normalize pointer: ensure it starts with '/'
  if pointer_part and pointer_part ~= "" and not pointer_part:match("^/") then
    pointer_part = "/" .. pointer_part
  end

  return {
    raw = raw,
    file = file_part,
    pointer = (pointer_part ~= "") and pointer_part or nil,
  }
end

--- Extract the $ref from the current cursor line.
--- @return {raw: string, file: string|nil, pointer: string|nil}|nil
function M.parse_ref_at_cursor()
  local line = vim.api.nvim_get_current_line()
  local bufname = vim.api.nvim_buf_get_name(0)
  local is_json = bufname:match("%.json$") ~= nil
  return parse_ref_from_line(line, is_json)
end

--- Parse $ref from an arbitrary line + format.
--- @param line string
--- @param is_json boolean
--- @return {raw: string, file: string|nil, pointer: string|nil}|nil
function M.parse_ref_from_line(line, is_json)
  return parse_ref_from_line(line, is_json)
end

-- ---------------------------------------------------------------------------
-- File resolution
-- ---------------------------------------------------------------------------

--- Resolve the file path from a parsed ref table.
--- Returns the absolute path or nil if unresolvable.
--- @param ref {file: string|nil}
--- @param bufnr integer|nil  defaults to current buffer
--- @return string|nil
function M.resolve_file(ref, bufnr)
  bufnr = bufnr or 0

  if not ref.file then
    -- Same-file reference
    local name = vim.api.nvim_buf_get_name(bufnr)
    return (name ~= "") and name or nil
  end

  local current_file = vim.api.nvim_buf_get_name(bufnr)
  local current_dir = vim.fn.fnamemodify(current_file, ":h")
  local abs = vim.fn.resolve(current_dir .. "/" .. ref.file)

  if vim.fn.filereadable(abs) == 0 then
    return nil
  end

  return abs
end

-- ---------------------------------------------------------------------------
-- JSON pointer resolution (indentation-based, no full YAML parser)
-- ---------------------------------------------------------------------------

--- Decode JSON pointer escape sequences.
--- ~1 → /    ~0 → ~
--- @param s string
--- @return string
local function decode_pointer_segment(s)
  -- Explicitly discard the second return value of gsub (substitution count)
  -- to avoid multi-value expansion at call sites.
  local result = s:gsub("~1", "/"):gsub("~0", "~")
  return result
end

--- Count the number of leading spaces in a line.
--- @param line string
--- @return integer
local function leading_spaces(line)
  local spaces = line:match("^( *)")
  return spaces and #spaces or 0
end

--- Extract the YAML/JSON key from a line (at any indent level).
--- Returns the key string or nil if the line has no key pattern.
--- @param line string
--- @return string|nil
local function extract_key(line)
  -- Handle quoted keys first: '...' or "..."
  local key = line:match("^%s*'([^']+)'%s*:")
    or line:match('^%s*"([^"]+)"%s*:')
    -- Unquoted key (allows alphanumeric, underscore, hyphen, dot, slash, braces, @)
    or line:match("^%s*([%w_%.%-%/{@}]+)%s*:")
  return key
end

--- Resolve a JSON pointer within a file using line-by-line indentation walking.
--- Returns {line = N, col = C} (1-indexed line, 0-indexed col) or nil.
--- @param filepath string  absolute path to the file
--- @param pointer string|nil  e.g. "/components/schemas/User"
--- @return {line: integer, col: integer}|nil
function M.resolve_pointer(filepath, pointer)
  if not pointer or pointer == "" then
    return { line = 1, col = 0 }
  end

  -- Split pointer into segments and decode escapes.
  -- Use gmatch to split on "/" which naturally skips the leading slash.
  local segments = {}
  for seg in pointer:gmatch("[^/]+") do
    table.insert(segments, decode_pointer_segment(seg))
  end

  if #segments == 0 then
    return { line = 1, col = 0 }
  end

  local is_json = filepath:match("%.json$") ~= nil
  local lines

  -- Prefer reading from an open buffer if available
  local open_buf = vim.fn.bufnr(filepath)
  if open_buf ~= -1 and vim.api.nvim_buf_is_loaded(open_buf) then
    lines = vim.api.nvim_buf_get_lines(open_buf, 0, -1, false)
  else
    lines = vim.fn.readfile(filepath)
  end

  if not lines or #lines == 0 then
    return nil
  end

  local seg_idx = 1
  local parent_indent = -1 -- indent of the last matched segment (-1 = document root)

  for lnum, line in ipairs(lines) do
    -- Skip blank lines and YAML comment lines
    if line:match("^%s*$") or (not is_json and line:match("^%s*#")) then
      goto continue
    end

    local indent = leading_spaces(line)

    -- If we've already matched at least one segment, check we haven't
    -- dedented past the last matched segment (left its subtree)
    if seg_idx > 1 and indent <= parent_indent then
      return nil
    end

    local key = extract_key(line)

    if key and key == segments[seg_idx] and indent > parent_indent then
      if seg_idx == #segments then
        -- All segments matched — this is the target line
        return { line = lnum, col = indent }
      end
      parent_indent = indent
      seg_idx = seg_idx + 1
    end

    ::continue::
  end

  return nil
end

-- ---------------------------------------------------------------------------
-- Go-to-definition
-- ---------------------------------------------------------------------------

--- Jump to the target of the $ref under the cursor.
--- Shows a notification on failure.
--- @return boolean  true if jump succeeded
function M.goto_definition()
  local ref = M.parse_ref_at_cursor()
  if not ref then
    vim.notify("openapi-navigator: cursor is not on a $ref value", vim.log.levels.WARN)
    return false
  end

  local file = M.resolve_file(ref)
  if not file then
    vim.notify(
      "openapi-navigator: file not found: " .. (ref.file or "<current>"),
      vim.log.levels.ERROR
    )
    return false
  end

  -- Open the file if it's not the current buffer
  local current_file = vim.api.nvim_buf_get_name(0)
  if vim.fn.resolve(file) ~= vim.fn.resolve(current_file) then
    vim.cmd("edit " .. vim.fn.fnameescape(file))
  end

  if not ref.pointer then
    -- No pointer — jump to top of file
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    return true
  end

  local pos = M.resolve_pointer(file, ref.pointer)
  if not pos then
    vim.notify(
      "openapi-navigator: could not resolve pointer: " .. ref.pointer,
      vim.log.levels.ERROR
    )
    return false
  end

  vim.api.nvim_win_set_cursor(0, { pos.line, pos.col })
  -- Centre the view on the target
  vim.cmd("normal! zz")
  return true
end

return M
