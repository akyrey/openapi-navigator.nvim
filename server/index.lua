--- Bidirectional ref index.
--- Ported from lua/openapi-navigator/index.lua — vim.* replaced with
--- document_store, workspace, and fs equivalents.
---
--- Two hash tables:
---   _definitions[canonical_key] = { file, line, col }
---   _references[canonical_key]  = { { file, line, col, text }, ... }
---
--- canonical_key format: "<abs_file_path>::<pointer_or_empty>"

local store     = require("document_store")
local workspace = require("workspace")
local fs        = require("fs")
local resolver  = require("resolver")

local M = {}

-- ── Internal state ────────────────────────────────────────────────────────────

M._definitions    = {}  -- canonical_key → { file, line, col }
M._references     = {}  -- canonical_key → [{ file, line, col, text }]
M._indexed_files  = {}  -- filepath → mtime at last index
M._roots          = {}  -- per-directory cache (mirrors workspace._roots for init_options)

-- ── Helpers ───────────────────────────────────────────────────────────────────

local leading_spaces = resolver.leading_spaces
local extract_key    = resolver.extract_key

--- Build the canonical key from an absolute file path and optional pointer.
--- @param abs_file string
--- @param pointer string|nil
--- @return string
local function canonical_key(abs_file, pointer)
	return abs_file .. "::" .. (pointer or "")
end

M.canonical_key = canonical_key

-- ── File scanning ─────────────────────────────────────────────────────────────

--- Scan a single file and populate the definition + reference tables.
--- @param filepath string  absolute path
local function index_file(filepath)
	local is_json = filepath:match("%.json$") ~= nil
	local uri     = fs.path_to_uri(filepath)

	-- Prefer the open document; fall back to disk
	local lines = store.get_lines(uri) or fs.read_lines(filepath)
	if not lines or #lines == 0 then
		return
	end

	local file_dir = fs.dirname(filepath)

	-- ---- Pass 1: definitions ------------------------------------------------
	local def_stack = {}  -- { indent, key }

	for lnum, line in ipairs(lines) do
		if not line:match("^%s*$") and not (not is_json and line:match("^%s*#")) then
			local indent = leading_spaces(line)
			local key    = extract_key(line)
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
				local ckey    = canonical_key(filepath, pointer)
				M._definitions[ckey] = { file = filepath, line = lnum, col = indent }
			end
		end
	end

	-- ---- Pass 2: references -------------------------------------------------
	for lnum, line in ipairs(lines) do
		local ref = resolver.parse_ref_from_line(line, is_json)
		if ref then
			local target_file
			if ref.file then
				target_file = fs.resolve(fs.join(file_dir, ref.file))
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
				col  = leading_spaces(line),
				text = line:match("^%s*(.-)%s*$") or line,  -- trimmed
			})
		end
	end

	M._indexed_files[filepath] = fs.mtime(filepath)
end

-- ── Public API ────────────────────────────────────────────────────────────────

--- Ensure all spec files under the root for `uri` are indexed.
--- Skips files whose mtime hasn't changed since last index.
--- @param uri string  URI of any file in the workspace
--- @param root_markers string[]
function M.ensure_indexed(uri, root_markers)
	local path = fs.uri_to_path(uri)
	local dir  = fs.dirname(fs.resolve(path))
	local root = workspace.get_root(dir, root_markers)

	local files = workspace.glob_spec_files(root)
	for _, filepath in ipairs(files) do
		filepath = fs.resolve(filepath)
		local mtime = fs.mtime(filepath)
		if M._indexed_files[filepath] ~= mtime then
			index_file(filepath)
		end
	end
end

--- Invalidate and re-index a single file.
--- Called on didSave / workspace/didChangeWatchedFiles.
--- @param filepath string  absolute path
function M.invalidate(filepath)
	filepath = fs.resolve(filepath)

	-- Remove stale entries from this file
	for ckey, loc in pairs(M._definitions) do
		if loc.file == filepath then
			M._definitions[ckey] = nil
		end
	end

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

	M._indexed_files[filepath] = nil

	-- Re-index immediately if the file exists
	if fs.file_readable(filepath) then
		index_file(filepath)
	end
end

--- Compute the JSON pointer of the key at `position` in `uri`.
--- Position is a 0-indexed LSP Position {line, character}.
--- @param uri string
--- @param position {line: integer, character: integer}
--- @return string|nil  e.g. "/components/schemas/User"
function M.get_pointer_at(uri, position)
	local target_lnum = position.line + 1  -- convert to 1-indexed

	local path  = fs.uri_to_path(uri)
	local lines = store.get_lines(uri) or fs.read_lines(path)
	if not lines or #lines == 0 then
		return nil
	end

	target_lnum = math.min(target_lnum, #lines)

	local stack = {}  -- { indent, key }
	for i = 1, target_lnum do
		local line = lines[i]
		if not line:match("^%s*$") and not line:match("^%s*#") then
			local indent = leading_spaces(line)
			local key    = extract_key(line)
			if key then
				while #stack > 0 and stack[#stack].indent >= indent do
					table.remove(stack)
				end
				table.insert(stack, { indent = indent, key = key })
			end
		end
	end

	if #stack == 0 then
		return nil
	end

	local parts = {}
	for _, entry in ipairs(stack) do
		table.insert(parts, entry.key)
	end
	return "/" .. table.concat(parts, "/")
end

--- Get all reference locations for a canonical key.
--- @param ckey string
--- @return {file: string, line: integer, col: integer, text: string}[]
function M.get_references(ckey)
	return M._references[ckey] or {}
end

--- Get the definition location for a canonical key.
--- @param ckey string
--- @return {file: string, line: integer, col: integer}|nil
function M.get_definition(ckey)
	return M._definitions[ckey]
end

return M
