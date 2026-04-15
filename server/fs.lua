--- Pure-Lua file-system helpers (no vim.* dependencies).
--- Replaces vim.fn.readfile, vim.fn.resolve, vim.fn.filereadable, etc.

local M = {}

--- Split a string by a delimiter.
--- @param s string
--- @param sep string  literal separator
--- @return string[]
local function split(s, sep)
	local parts = {}
	local pattern = "([^" .. sep .. "]*)" .. sep .. "?"
	for part in s:gmatch(pattern) do
		if part ~= "" then
			table.insert(parts, part)
		end
	end
	return parts
end

--- Return the directory component of a path (like dirname(1)).
--- @param path string
--- @return string
function M.dirname(path)
	-- Strip trailing slash(es) first, then remove last component
	local d = path:gsub("/+$", "")
	local result = d:match("^(.*)/[^/]+$")
	if not result then
		-- No slash found — relative filename with no directory
		return "."
	end
	return result == "" and "/" or result
end

--- Return the basename of a path.
--- @param path string
--- @return string
function M.basename(path)
	return path:match("([^/]+)$") or path
end

--- Resolve ".." and "." segments in an absolute path.
--- Handles paths that may start with "/" or not.
--- @param path string
--- @return string
function M.resolve(path)
	local is_abs = path:sub(1, 1) == "/"
	local parts = split(path, "/")
	local resolved = {}
	for _, part in ipairs(parts) do
		if part == "." then
			-- skip
		elseif part == ".." then
			if #resolved > 0 then
				table.remove(resolved)
			end
		else
			table.insert(resolved, part)
		end
	end
	local result = table.concat(resolved, "/")
	if is_abs then
		result = "/" .. result
	end
	-- Resolve macOS /tmp → /private/tmp symlink via shell
	-- Only attempt when the path exists and we can run realpath
	if result ~= "" then
		local f = io.popen("realpath -m " .. string.format("%q", result) .. " 2>/dev/null")
		if f then
			local real = f:read("*l")
			f:close()
			if real and real ~= "" then
				return real
			end
		end
	end
	return result
end

--- Join two path components.
--- @param a string
--- @param b string
--- @return string
function M.join(a, b)
	if b:sub(1, 1) == "/" then
		return b
	end
	return a:gsub("/+$", "") .. "/" .. b
end

--- Check whether a file is readable.
--- @param path string
--- @return boolean
function M.file_readable(path)
	local f = io.open(path, "r")
	if f then
		f:close()
		return true
	end
	return false
end

--- Read the entire contents of a file.
--- Returns the string content or nil on error.
--- @param path string
--- @return string|nil
function M.read_file(path)
	local f, err = io.open(path, "r")
	if not f then
		return nil, err
	end
	local content = f:read("*a")
	f:close()
	return content
end

--- Read a file into a list of lines (without trailing newlines).
--- @param path string
--- @return string[]
function M.read_lines(path)
	local content, err = M.read_file(path)
	if not content then
		return {}
	end
	local lines = {}
	-- Handle \r\n and \n line endings
	for line in (content .. "\n"):gmatch("([^\n]*)\n") do
		table.insert(lines, (line:gsub("\r$", "")))
	end
	-- Remove trailing empty line added by the sentinel \n above
	if lines[#lines] == "" then
		table.remove(lines)
	end
	return lines
end

--- Get mtime of a file. Returns -1 if not accessible.
--- @param path string
--- @return integer
function M.mtime(path)
	-- Use stat -f %m on macOS, stat -c %Y on Linux
	local cmd
	if package.config:sub(1, 1) == "\\" then
		-- Windows: best-effort via dir
		return -1
	end
	-- Try GNU stat first, then BSD stat
	local f = io.popen(
		string.format("stat -c %%Y %q 2>/dev/null || stat -f %%m %q 2>/dev/null", path, path)
	)
	if not f then return -1 end
	local s = f:read("*l")
	f:close()
	return tonumber(s) or -1
end

--- Convert a file:// URI to an absolute path.
--- @param uri string
--- @return string
function M.uri_to_path(uri)
	-- file:///abs/path → /abs/path
	-- file:///C:/path → C:/path  (Windows, best-effort)
	local path = uri:match("^file://(.+)$")
	if not path then
		return uri
	end
	-- URL-decode percent-encoding (common ones)
	path = path:gsub("%%(%x%x)", function(hex)
		return string.char(tonumber(hex, 16))
	end)
	-- On Unix: file:///abs/path → path = "/abs/path" — already absolute
	-- On Windows: file:///C:/path → path = "/C:/path" → strip leading /
	if path:match("^/[A-Za-z]:") then
		path = path:sub(2)
	end
	return path
end

--- Convert an absolute path to a file:// URI.
--- @param path string
--- @return string
function M.path_to_uri(path)
	-- Percent-encode characters that are not safe in a URI path
	local encoded = path:gsub("([^%w%-%.%_%~%/:])", function(c)
		return string.format("%%%02X", c:byte())
	end)
	if encoded:sub(1, 1) == "/" then
		return "file://" .. encoded
	end
	-- Windows: C:\path → file:///C:/path
	return "file:///" .. encoded
end

return M
