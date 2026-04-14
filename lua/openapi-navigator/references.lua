--- Find all usages of a $ref target and populate the quickfix list.
--- Works in two modes:
---   • Cursor is ON a $ref value → find all other refs pointing to the same target.
---   • Cursor is ON a definition key → find all refs that point here.

local M = {}

local resolver = require("openapi-navigator.resolver")
local index = require("openapi-navigator.index")

-- ============================================================
-- Helpers
-- ============================================================

--- Build a human-readable title for the quickfix list.
--- @param canonical_key string
--- @return string
local function qf_title(canonical_key)
	-- Strip the leading absolute path portion for brevity
	local sep = canonical_key:find("::", 1, true)
	if sep then
		local file_part = vim.fn.fnamemodify(canonical_key:sub(1, sep - 1), ":~:.")
		local ptr_part = canonical_key:sub(sep + 2)
		return "OpenAPI refs → " .. file_part .. (ptr_part ~= "" and "#" .. ptr_part or "")
	end
	return "OpenAPI refs → " .. canonical_key
end

--- Build a canonical key for the $ref under the cursor (ref mode).
--- The key is the resolved absolute target file + pointer.
--- @param bufnr integer
--- @return string|nil
local function canonical_key_from_ref(bufnr)
	local ref = resolver.parse_ref_at_cursor()
	if not ref then
		return nil
	end

	local source_file = vim.api.nvim_buf_get_name(bufnr)
	local target_file

	if ref.file then
		local dir = vim.fn.fnamemodify(source_file, ":h")
		target_file = vim.fn.resolve(dir .. "/" .. ref.file)
	else
		target_file = vim.fn.resolve(source_file)
	end

	return index.canonical_key(target_file, ref.pointer)
end

-- ============================================================
-- Public API
-- ============================================================

--- Find all $ref usages of the definition under cursor and open quickfix.
function M.find()
	local bufnr = vim.api.nvim_get_current_buf()

	-- Ensure the index is up-to-date before querying
	index.ensure_indexed(bufnr)

	-- Determine the canonical key to look up
	local ckey

	local ref = resolver.parse_ref_at_cursor()
	if ref then
		-- Cursor is on a $ref line — search for all refs to the same target
		ckey = canonical_key_from_ref(bufnr)
	else
		-- Cursor is on a definition — use the pointer at the cursor position
		ckey = index.get_canonical_key_at_cursor(bufnr)
	end

	if not ckey then
		vim.notify("openapi-navigator: could not determine target under cursor", vim.log.levels.WARN)
		return
	end

	local locations = index.get_references(ckey)

	if #locations == 0 then
		vim.notify("openapi-navigator: no references found", vim.log.levels.INFO)
		return
	end

	-- Build quickfix list items
	local items = {}
	for _, loc in ipairs(locations) do
		table.insert(items, {
			filename = loc.file,
			lnum = loc.line,
			col = loc.col + 1, -- quickfix uses 1-indexed columns
			text = loc.text,
		})
	end

	-- Replace the current quickfix list
	vim.fn.setqflist({}, "r", {
		title = qf_title(ckey),
		items = items,
	})

	vim.cmd("copen")

	vim.notify(string.format("openapi-navigator: found %d reference(s)", #items), vim.log.levels.INFO)
end

return M
