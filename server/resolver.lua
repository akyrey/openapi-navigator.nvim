--- $ref parsing, file resolution, and JSON pointer walking.
--- Ported from lua/openapi-navigator/resolver.lua — all vim.* calls replaced
--- with document_store + fs equivalents.
---
--- Public API changes from the Neovim version:
---   parse_ref_at_cursor()    → parse_ref_at(uri, position)
---   resolve_file(ref, bufnr) → resolve_file(ref, source_uri)
---   goto_definition()        → removed (dispatcher returns a Location instead)

local store = require("document_store")
local fs    = require("fs")

local M = {}

-- ── $ref parsing ─────────────────────────────────────────────────────────────

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
		raw = line:match("%$ref%s*:%s*[\"']([^\"']+)[\"']")
			or line:match("%$ref%s*:%s*([^%s#'\"]+[^'\",%s]*)")
	end

	if not raw or raw == "" then
		return nil
	end

	-- Split on first '#' → file path + JSON pointer
	local hash_pos = raw:find("#", 1, true)
	local file_part, pointer_part

	if hash_pos then
		file_part    = raw:sub(1, hash_pos - 1)
		pointer_part = raw:sub(hash_pos + 1)
	else
		file_part    = raw
		pointer_part = nil
	end

	if file_part == "" then
		file_part = nil
	end

	if pointer_part and pointer_part ~= "" and not pointer_part:match("^/") then
		pointer_part = "/" .. pointer_part
	end

	return {
		raw     = raw,
		file    = file_part,
		pointer = (pointer_part ~= nil and pointer_part ~= "") and pointer_part or nil,
	}
end

-- Expose for use by index.lua
M.parse_ref_from_line = parse_ref_from_line

--- Extract the $ref from the line at `position` in `uri`.
--- Position is a 0-indexed LSP Position {line, character}.
--- @param uri string
--- @param position {line: integer, character: integer}
--- @return {raw: string, file: string|nil, pointer: string|nil}|nil
function M.parse_ref_at(uri, position)
	-- line is 0-indexed in LSP; store uses 1-indexed
	local lnum = position.line + 1
	local line = store.get_line(uri, lnum)
	if not line then
		-- Fall back to disk
		local path = fs.uri_to_path(uri)
		local lines = fs.read_lines(path)
		line = lines[lnum]
	end
	if not line then return nil end

	local is_json = uri:match("%.json$") ~= nil
	return parse_ref_from_line(line, is_json)
end

-- ── File resolution ───────────────────────────────────────────────────────────

--- Resolve the file path from a parsed ref table.
--- Returns the absolute path or nil if unresolvable.
--- @param ref {file: string|nil}
--- @param source_uri string  URI of the file containing the $ref
--- @return string|nil
function M.resolve_file(ref, source_uri)
	if not ref.file then
		-- Same-file reference
		return fs.uri_to_path(source_uri)
	end

	local source_path = fs.uri_to_path(source_uri)
	local source_dir  = fs.dirname(source_path)
	local abs         = fs.resolve(fs.join(source_dir, ref.file))

	if not fs.file_readable(abs) then
		return nil
	end
	return abs
end

-- ── JSON pointer resolution ───────────────────────────────────────────────────

--- Decode JSON pointer escape sequences.
--- ~1 → /    ~0 → ~
--- @param s string
--- @return string
local function decode_pointer_segment(s)
	-- Capture result to local — gsub returns (result, count) and we only want the string.
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
--- @param line string
--- @return string|nil
local function extract_key(line)
	return line:match("^%s*'([^']+)'%s*:")
		or line:match('^%s*"([^"]+)"%s*:')
		or line:match("^%s*([%w_%.%-%/{@}]+)%s*:")
end

--- Resolve a JSON pointer within a file using line-by-line indentation walking.
--- Returns {line = N, col = C} (1-indexed line, 0-indexed col) or nil.
--- @param path string   absolute path to the file
--- @param pointer string|nil  e.g. "/components/schemas/User"
--- @param uri string|nil      if given, check document_store first
--- @return {line: integer, col: integer}|nil
function M.resolve_pointer(path, pointer, uri)
	if not pointer or pointer == "" then
		return { line = 1, col = 0 }
	end

	local segments = {}
	for seg in pointer:gmatch("[^/]+") do
		table.insert(segments, decode_pointer_segment(seg))
	end

	if #segments == 0 then
		return { line = 1, col = 0 }
	end

	local is_json = path:match("%.json$") ~= nil

	-- Prefer open document over disk
	local lines
	if uri then
		lines = store.get_lines(uri)
	end
	if not lines then
		lines = fs.read_lines(path)
	end

	if not lines or #lines == 0 then
		return nil
	end

	local seg_idx     = 1
	local parent_indent = -1

	for lnum, line in ipairs(lines) do
		-- Skip blank lines and YAML comment lines
		if line:match("^%s*$") or (not is_json and line:match("^%s*#")) then
			goto continue
		end

		local indent = leading_spaces(line)

		if seg_idx > 1 and indent <= parent_indent then
			return nil
		end

		local key = extract_key(line)

		if key and key == segments[seg_idx] and indent > parent_indent then
			if seg_idx == #segments then
				return { line = lnum, col = indent }
			end
			parent_indent = indent
			seg_idx       = seg_idx + 1
		end

		::continue::
	end

	return nil
end

-- Expose helpers for index.lua
M.leading_spaces = leading_spaces
M.extract_key    = extract_key

return M
