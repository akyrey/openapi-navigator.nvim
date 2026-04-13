--- Floating hover preview for $ref targets.
--- Shows the YAML block of the referenced schema in a floating window.
--- Recursively expands nested $refs up to config.hover.max_depth levels.

local M = {}

local config = require("openapi-navigator.config")
local resolver = require("openapi-navigator.resolver")

-- ============================================================
-- Block extraction
-- ============================================================

--- Extract the YAML block starting at `start_line` (1-indexed) from `lines`.
--- Collects the start line plus all subsequent lines indented deeper than
--- `start_col`, stopping when the indent returns to `start_col` or less.
--- @param lines string[]
--- @param start_line integer  1-indexed
--- @param start_col integer   0-indexed column of the target key
--- @return string[]
local function extract_block(lines, start_line, start_col)
  local result = {}
  if start_line < 1 or start_line > #lines then return result end

  table.insert(result, lines[start_line])

  for i = start_line + 1, #lines do
    local line = lines[i]
    if line:match("^%s*$") then
      -- Keep blank lines that are within the block
      table.insert(result, line)
    else
      local indent = #(line:match("^( *)") or "")
      if indent <= start_col then
        -- Dedented back to parent level or beyond — end of block
        break
      end
      table.insert(result, line)
    end
  end

  -- Trim trailing blank lines
  while #result > 0 and result[#result]:match("^%s*$") do
    table.remove(result)
  end

  return result
end

--- Read lines from a file (prefers open buffer, falls back to readfile).
--- @param filepath string
--- @return string[]
local function read_file_lines(filepath)
  local bufnr = vim.fn.bufnr(filepath)
  if bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr) then
    return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  end
  return vim.fn.readfile(filepath)
end

-- ============================================================
-- Recursive $ref expansion
-- ============================================================

--- Expand $ref occurrences inside `block_lines` up to `max_depth` levels.
--- Returns a new list of lines with $ref lines replaced by the referenced content.
--- @param block_lines string[]
--- @param source_file string  the file the block came from (for relative refs)
--- @param depth integer       current recursion depth
--- @param max_depth integer
--- @return string[]
local function expand_refs(block_lines, source_file, depth, max_depth)
  if depth >= max_depth then return block_lines end

  local is_json = source_file:match("%.json$") ~= nil
  local expanded = {}

  for _, line in ipairs(block_lines) do
    local ref = resolver.parse_ref_from_line(line, is_json)
    if ref then
      -- Replace this $ref line with the referenced block
      local fake_buf = 0
      -- Build a temporary buf name context for resolve_file
      local target_file = ref.file
        and vim.fn.resolve(vim.fn.fnamemodify(source_file, ":h") .. "/" .. ref.file)
        or source_file

      if vim.fn.filereadable(target_file) == 1 then
        local target_lines = read_file_lines(target_file)
        local pos = resolver.resolve_pointer(target_file, ref.pointer)
        if pos then
          local sub_block = extract_block(target_lines, pos.line, pos.col)
          -- Compute the indent of the $ref line to match indentation
          local ref_indent = #(line:match("^( *)") or "")
          local block_base_indent = pos.col
          local indent_diff = ref_indent - block_base_indent

          -- Re-indent the sub-block to match the calling context
          local reindented = {}
          for _, bl in ipairs(sub_block) do
            if bl:match("^%s*$") then
              table.insert(reindented, bl)
            else
              local current_indent = #(bl:match("^( *)") or "")
              local new_indent = math.max(0, current_indent + indent_diff)
              table.insert(reindented, string.rep(" ", new_indent) .. vim.trim(bl))
            end
          end

          -- Recursively expand nested $refs
          local further = expand_refs(reindented, target_file, depth + 1, max_depth)
          vim.list_extend(expanded, further)
        else
          -- Could not resolve — keep original $ref line
          table.insert(expanded, line)
        end
      else
        table.insert(expanded, line)
      end
    else
      table.insert(expanded, line)
    end
  end

  return expanded
end

-- ============================================================
-- Public API
-- ============================================================

--- Show a floating preview of the $ref under the cursor.
--- Falls back to vim.lsp.buf.hover() when cursor is not on a $ref.
function M.show()
  local ref = resolver.parse_ref_at_cursor()

  if not ref then
    -- Fall back to LSP hover
    vim.lsp.buf.hover()
    return
  end

  local source_file = vim.api.nvim_buf_get_name(0)
  local target_file = M._resolve_target_file(ref, source_file)

  if not target_file then
    vim.notify(
      "openapi-navigator: hover: file not found: " .. (ref.file or "<current>"),
      vim.log.levels.WARN
    )
    return
  end

  local target_lines = read_file_lines(target_file)
  local pos = resolver.resolve_pointer(target_file, ref.pointer)

  if not pos then
    vim.notify(
      "openapi-navigator: hover: could not resolve pointer: " .. (ref.pointer or "(none)"),
      vim.log.levels.WARN
    )
    return
  end

  local block = extract_block(target_lines, pos.line, pos.col)
  if #block == 0 then
    vim.notify("openapi-navigator: hover: empty block at target", vim.log.levels.WARN)
    return
  end

  local opts = config.options.hover
  local expanded = expand_refs(block, target_file, 0, opts.max_depth)

  -- Trim lines to max_width
  local display = {}
  for _, line in ipairs(expanded) do
    if #line > opts.max_width then
      table.insert(display, line:sub(1, opts.max_width - 1) .. "…")
    else
      table.insert(display, line)
    end
  end

  -- Limit total lines shown
  if #display > opts.max_height then
    display = vim.list_slice(display, 1, opts.max_height)
    table.insert(display, "  … (truncated)")
  end

  vim.lsp.util.open_floating_preview(display, "yaml", {
    border = "rounded",
    max_width = opts.max_width,
    max_height = opts.max_height,
    focusable = true,
  })
end

--- Internal helper: resolve target file from a parsed ref.
--- @param ref {file: string|nil}
--- @param source_file string
--- @return string|nil
function M._resolve_target_file(ref, source_file)
  if not ref.file then return source_file end
  local dir = vim.fn.fnamemodify(source_file, ":h")
  local abs = vim.fn.resolve(dir .. "/" .. ref.file)
  if vim.fn.filereadable(abs) == 0 then return nil end
  return abs
end

return M
