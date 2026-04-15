--- Schema block extraction and recursive $ref expansion.
--- Ported from lua/openapi-navigator/hover.lua.
--- Returns an LSP Hover object instead of opening a float.

local store    = require("document_store")
local resolver = require("resolver")
local fs       = require("fs")

local M = {}

-- ── Block extraction ──────────────────────────────────────────────────────────

--- Extract the YAML block starting at `start_line` (1-indexed) from `lines`.
--- @param lines string[]
--- @param start_line integer  1-indexed
--- @param start_col integer   0-indexed column of the target key
--- @return string[]
local function extract_block(lines, start_line, start_col)
	local result = {}
	if start_line < 1 or start_line > #lines then
		return result
	end

	table.insert(result, lines[start_line])

	for i = start_line + 1, #lines do
		local line = lines[i]
		if line:match("^%s*$") then
			table.insert(result, line)
		else
			local indent = #(line:match("^( *)") or "")
			if indent <= start_col then
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

--- Get lines for a file: prefer open document store, fall back to disk.
--- @param path string
--- @return string[]
local function get_file_lines(path)
	local uri  = fs.path_to_uri(path)
	local from_store = store.get_lines(uri)
	if from_store then return from_store end
	return fs.read_lines(path)
end

-- ── Recursive $ref expansion ──────────────────────────────────────────────────

--- Expand $ref occurrences inside `block_lines` up to `max_depth` levels.
--- @param block_lines string[]
--- @param source_file string   absolute path the block came from
--- @param source_uri string    URI of the source (for resolve_file)
--- @param depth integer
--- @param max_depth integer
--- @return string[]
local function expand_refs(block_lines, source_file, source_uri, depth, max_depth)
	if depth >= max_depth then
		return block_lines
	end

	local is_json  = source_file:match("%.json$") ~= nil
	local expanded = {}

	for _, line in ipairs(block_lines) do
		local ref = resolver.parse_ref_from_line(line, is_json)
		if ref then
			local target_file
			if ref.file then
				local source_dir = fs.dirname(source_file)
				target_file = fs.resolve(fs.join(source_dir, ref.file))
			else
				target_file = source_file
			end

			if fs.file_readable(target_file) then
				local target_lines = get_file_lines(target_file)
				local target_uri   = fs.path_to_uri(target_file)
				local pos = resolver.resolve_pointer(target_file, ref.pointer, target_uri)
				if pos then
					local sub_block = extract_block(target_lines, pos.line, pos.col)

					-- Re-indent to match the calling context
					local ref_indent    = #(line:match("^( *)") or "")
					local block_base    = pos.col
					local indent_diff   = ref_indent - block_base
					local reindented    = {}
					for _, bl in ipairs(sub_block) do
						if bl:match("^%s*$") then
							table.insert(reindented, bl)
						else
							local cur = #(bl:match("^( *)") or "")
							local new = math.max(0, cur + indent_diff)
							table.insert(reindented, string.rep(" ", new) .. (bl:match("^%s*(.-)%s*$") or bl))
						end
					end

					local further = expand_refs(reindented, target_file, target_uri, depth + 1, max_depth)
					for _, fl in ipairs(further) do
						table.insert(expanded, fl)
					end
				else
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

-- ── Public API ────────────────────────────────────────────────────────────────

--- Build an LSP Hover response for the $ref at `position` in `uri`.
--- Returns an LSP Hover table or nil (editor falls through to other servers).
--- @param uri string
--- @param position {line: integer, character: integer}
--- @param opts {max_width: integer, max_height: integer, max_depth: integer}
--- @return table|nil  LSP Hover object
function M.hover(uri, position, opts)
	opts = opts or { max_width = 80, max_height = 30, max_depth = 2 }

	local ref = resolver.parse_ref_at(uri, position)
	if not ref then
		-- Not on a $ref — return nil so the editor tries other LSP clients
		return nil
	end

	local source_path = fs.uri_to_path(uri)
	local target_path = resolver.resolve_file(ref, uri)
	if not target_path then
		return nil
	end

	local target_uri   = fs.path_to_uri(target_path)
	local target_lines = get_file_lines(target_path)
	local pos          = resolver.resolve_pointer(target_path, ref.pointer, target_uri)
	if not pos then
		return nil
	end

	local block = extract_block(target_lines, pos.line, pos.col)
	if #block == 0 then
		return nil
	end

	local expanded = expand_refs(block, target_path, target_uri, 0, opts.max_depth)

	-- Trim lines to max_width and cap total height
	local display = {}
	for _, line in ipairs(expanded) do
		if #line > opts.max_width then
			table.insert(display, line:sub(1, opts.max_width - 1) .. "…")
		else
			table.insert(display, line)
		end
	end

	if #display > opts.max_height then
		local truncated = {}
		for i = 1, opts.max_height do
			table.insert(truncated, display[i])
		end
		table.insert(truncated, "  … (truncated)")
		display = truncated
	end

	-- Wrap in a fenced code block for markdown rendering
	local lang  = source_path:match("%.json$") and "json" or "yaml"
	local value = "```" .. lang .. "\n" .. table.concat(display, "\n") .. "\n```"

	return {
		contents = { kind = "markdown", value = value },
	}
end

return M
