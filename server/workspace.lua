--- Workspace helpers: spec root detection and file globbing.
--- Pure Lua + POSIX shell (no vim.* dependencies).

local fs  = require("fs")
local log = require("log")

local M = {}

--- Walk up directories from `dir` looking for a root-marker file.
--- Returns the directory containing the marker, or nil.
--- @param dir string  starting directory (absolute)
--- @param markers string[]
--- @return string|nil
function M.find_root(dir, markers)
	local current = fs.resolve(dir)
	while true do
		for _, marker in ipairs(markers) do
			if fs.file_readable(current .. "/" .. marker) then
				return current
			end
		end
		local parent = fs.dirname(current)
		if parent == current then
			break
		end
		current = parent
	end
	return nil
end

--- Recursively collect all YAML / JSON files under `root`.
--- Uses `find` via io.popen on POSIX systems.
--- @param root string
--- @return string[]
function M.glob_spec_files(root)
	local files = {}

	-- Build the find command: look for *.yaml, *.yml, *.json
	-- Exclude hidden directories (.git, node_modules, etc.)
	local cmd = string.format(
		"find %q -type f \\( -name '*.yaml' -o -name '*.yml' -o -name '*.json' \\) "
			.. "! -path '*/.git/*' ! -path '*/node_modules/*' 2>/dev/null",
		root
	)

	local f = io.popen(cmd)
	if not f then
		log.warn("glob_spec_files: io.popen failed for root %s", root)
		return files
	end

	for line in f:lines() do
		if line ~= "" then
			local resolved = fs.resolve(line)
			table.insert(files, resolved)
		end
	end
	f:close()

	return files
end

--- Per-directory cache of resolved spec roots.
--- @type table<string, string|false>
M._roots = {}

--- Find and cache the spec root for a given source directory.
--- Returns the root path, or nil if none found.
--- Falls back to `dir` itself so single-file specs work too.
--- @param dir string
--- @param markers string[]
--- @return string
function M.get_root(dir, markers)
	if M._roots[dir] ~= nil then
		-- false means we already looked and found nothing special
		return M._roots[dir] or dir
	end
	local root = M.find_root(dir, markers) or dir
	M._roots[dir] = root
	return root
end

return M
