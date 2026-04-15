--- $ref completion provider.
--- Returns LSP CompletionItem[] for the $ref value being typed at the cursor.
--- Offers two categories:
---   • Local pointer completions (#/...) from the current file's index
---   • File path completions (./...) from the workspace spec files

local store = require("document_store")
local index = require("index")
local workspace = require("workspace")
local fs = require("fs")

local M = {}

-- ── Helpers ───────────────────────────────────────────────────────────────────

--- Compute a relative path from `from_dir` to `to_path`.
--- Returns e.g. "./schemas/User.yaml" or "../shared/Base.yaml", or nil.
local function make_relative(from_dir, to_path)
	local function split_path(p)
		local parts = {}
		for part in p:gmatch("[^/]+") do
			parts[#parts + 1] = part
		end
		return parts
	end

	local fp = split_path(from_dir)
	local tp = split_path(to_path)

	local common = 0
	for i = 1, math.min(#fp, #tp) do
		if fp[i] == tp[i] then
			common = i
		else
			break
		end
	end

	local rel = {}
	for _ = common + 1, #fp do
		rel[#rel + 1] = ".."
	end
	for i = common + 1, #tp do
		rel[#rel + 1] = tp[i]
	end

	if #rel == 0 then
		return nil
	end
	local s = table.concat(rel, "/")
	return (s:sub(1, 2) == "..") and s or "./" .. s
end

--- Parse the $ref value start column and the already-typed prefix at `position`.
--- Returns { prefix = string, start_col = integer } or nil if not on a $ref line.
--- `start_col` is the 0-indexed LSP character offset where the ref value begins
--- (i.e. right after the opening quote or after the colon+space for unquoted).
local function parse_ref_context(uri, position)
	local lnum = position.line + 1
	local line = store.get_line(uri, lnum)
	if not line then
		local lines = fs.read_lines(fs.uri_to_path(uri))
		line = lines and lines[lnum]
	end
	if not line then
		return nil
	end

	local is_json = uri:match("%.json$") ~= nil
	local s, e -- 1-indexed start/end of the opening delimiter match

	if is_json then
		-- Match: "$ref": "
		s, e = line:find('"$ref"%s*:%s*"')
	else
		-- Try quoted first: $ref: ' or $ref: "
		s, e = line:find("%$ref%s*:%s*[\"']")
		if not s then
			-- Unquoted: $ref: (followed by anything)
			s, e = line:find("%$ref%s*:%s*")
		end
	end

	if not s then
		return nil
	end

	-- e is the 1-indexed last char of the opening delimiter.
	-- The ref value starts at e+1 (1-indexed) = e (0-indexed LSP).
	-- position.character is 0-indexed; line:sub uses 1-indexed.
	local start_col = e -- 0-indexed LSP column of ref value start
	local prefix = line:sub(e + 1, position.character) -- already-typed part of the ref value

	return { prefix = prefix, start_col = start_col }
end

-- ── Completion item builders ──────────────────────────────────────────────────

--- Build CompletionItems for local JSON pointer definitions (#/...).
local function local_completions(uri, ctx, position)
	local path = fs.resolve(fs.uri_to_path(uri))
	local items = {}

	for ckey, _ in pairs(index._definitions) do
		local ckey_file, pointer = ckey:match("^(.-)::(/.+)$")
		if ckey_file and ckey_file == path and pointer then
			local label = "#" .. pointer
			if label:sub(1, #ctx.prefix) == ctx.prefix then
				items[#items + 1] = {
					label = label,
					kind = 18, -- CompletionItemKind.Reference
					filterText = label,
					detail = "local $ref",
					sortText = "1" .. label,
					textEdit = {
						range = {
							start = { line = position.line, character = ctx.start_col },
							["end"] = { line = position.line, character = position.character },
						},
						newText = label,
					},
				}
			end
		end
	end

	return items
end

--- Build CompletionItems for cross-file spec paths (./... or ../...).
local function file_completions(uri, ctx, position, root_markers)
	local source_path = fs.resolve(fs.uri_to_path(uri))
	local source_dir = fs.dirname(source_path)
	local root = workspace.get_root(source_dir, root_markers)
	local files = workspace.glob_spec_files(root)
	local items = {}

	for _, filepath in ipairs(files) do
		filepath = fs.resolve(filepath)
		if filepath == source_path then
			goto continue
		end

		local rel = make_relative(source_dir, filepath)
		if rel and rel:sub(1, #ctx.prefix) == ctx.prefix then
			items[#items + 1] = {
				label = rel,
				kind = 17, -- CompletionItemKind.File
				filterText = rel,
				detail = "file $ref",
				sortText = "2" .. rel,
				textEdit = {
					range = {
						start = { line = position.line, character = ctx.start_col },
						["end"] = { line = position.line, character = position.character },
					},
					newText = rel,
				},
			}
		end

		::continue::
	end

	return items
end

-- ── Public API ────────────────────────────────────────────────────────────────

--- Return LSP CompletionItem[] for the $ref value at `position` in `uri`.
--- Returns an empty table when the cursor is not on a $ref line.
--- @param uri string
--- @param position {line: integer, character: integer}
--- @param root_markers string[]
--- @return table[]
function M.complete(uri, position, root_markers)
	index.ensure_indexed(uri, root_markers)

	local ctx = parse_ref_context(uri, position)
	if not ctx then
		return {}
	end

	local items = {}
	local prefix = ctx.prefix

	-- Local pointer completions when prefix is empty or starts with '#'
	if prefix == "" or prefix:sub(1, 1) == "#" then
		for _, item in ipairs(local_completions(uri, ctx, position)) do
			items[#items + 1] = item
		end
	end

	-- File path completions when prefix is empty or doesn't start with '#'
	if prefix == "" or prefix:sub(1, 1) ~= "#" then
		for _, item in ipairs(file_completions(uri, ctx, position, root_markers)) do
			items[#items + 1] = item
		end
	end

	return items
end

return M
