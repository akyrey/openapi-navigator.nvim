--- Find all usages of a $ref target.
--- Ported from lua/openapi-navigator/references.lua.
--- Returns LSP Location[] instead of populating the quickfix list.

local store    = require("document_store")
local resolver = require("resolver")
local index    = require("index")
local fs       = require("fs")

local M = {}

--- Build the canonical key for the $ref at `position` in `uri`.
--- @param uri string
--- @param position {line: integer, character: integer}
--- @return string|nil
local function canonical_key_from_ref(uri, position)
	local ref = resolver.parse_ref_at(uri, position)
	if not ref then return nil end

	local target_path = resolver.resolve_file(ref, uri)
	if not target_path then return nil end

	return index.canonical_key(fs.resolve(target_path), ref.pointer)
end

--- Build LSP Location objects from index reference entries.
--- @param locs {file: string, line: integer, col: integer, text: string}[]
--- @return table[]  LSP Location[]
local function locations_from_locs(locs)
	local result = {}
	for _, loc in ipairs(locs) do
		table.insert(result, {
			uri   = fs.path_to_uri(loc.file),
			range = {
				start   = { line = loc.line - 1, character = loc.col },
				["end"] = { line = loc.line - 1, character = loc.col },
			},
		})
	end
	return result
end

--- Handle textDocument/references.
--- Implements both modes:
---   • Cursor on a $ref  → all refs pointing to the same target
---   • Cursor on a key   → all refs pointing to this definition
--- @param uri string
--- @param position {line: integer, character: integer}
--- @param root_markers string[]
--- @return table[]  LSP Location[]
function M.find(uri, position, root_markers)
	-- Ensure index is up-to-date
	index.ensure_indexed(uri, root_markers)

	-- Try ref mode first
	local ckey = canonical_key_from_ref(uri, position)

	if not ckey then
		-- Definition mode: compute pointer for the key the cursor is on
		local pointer = index.get_pointer_at(uri, position)
		if not pointer then return {} end

		local path = fs.resolve(fs.uri_to_path(uri))
		ckey = index.canonical_key(path, pointer)
	end

	local locs = index.get_references(ckey)
	return locations_from_locs(locs)
end

return M
