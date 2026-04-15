--- Laravel framework adapter.
--- Resolves OpenAPI path+method positions to Laravel controller methods.
---
--- Public API consumed by dispatcher.lua:
---   M.find_definition(uri, position, config) → Location[] | nil
---   M.invalidate_routes(filepath)            → (clears the routes cache)
---
--- Pure Lua, no vim.* dependencies.

local fs = require("fs")
local index = require("index")
local json = require("json")
local log = require("log")
local workspace = require("workspace")

local M = {}

-- ── Constants ─────────────────────────────────────────────────────────────────

local HTTP_METHODS = {
	get = true,
	post = true,
	put = true,
	patch = true,
	delete = true,
	head = true,
	options = true,
	trace = true,
}

-- ── In-process caches ─────────────────────────────────────────────────────────

--- source_dir → laravel_root (string) or false (not found)
local _root_cache = {}

--- laravel_root → { routes = [...], mtime = N }
local _routes_cache = {}

--- laravel_root → { psr4 = { prefix → dir }, mtime = N }
local _composer_cache = {}

-- ── Internal helpers ──────────────────────────────────────────────────────────

--- Extract the HTTP method strings from a route entry.
--- Artisan ≤10 uses `method = "GET|HEAD"`, Artisan 11+ uses `methods = ["GET","HEAD"]`.
--- Always returns a list of uppercase strings (HEAD filtered out for matching purposes).
--- @param route table
--- @return string[]
local function get_route_methods(route)
	local methods = {}
	if type(route.methods) == "table" then
		for _, m in ipairs(route.methods) do
			if type(m) == "string" then
				methods[#methods + 1] = m:upper()
			end
		end
	elseif type(route.method) == "string" then
		for part in route.method:gmatch("[^|]+") do
			methods[#methods + 1] = part:upper()
		end
	end
	return methods
end

--- Normalise a URI for matching:
---   - strip leading slash(es)
---   - lowercase
---   - replace every {name} parameter with {}
--- @param path string
--- @return string
local function normalize_uri(path)
	local result = path:gsub("^/+", ""):lower():gsub("{[^}]+}", "{}")
	return result
end

--- Parse a JSON pointer that may represent a paths/<path>[/<method>] location.
--- Returns spec_path (with leading slash), method (lowercase) or nil.
--- @param pointer string  e.g. "/paths//users/{id}/get"
--- @return string|nil, string|nil
local function parse_paths_pointer(pointer)
	-- Pointer format: "/paths/<path_key>[/<method_key>]"
	-- Path keys start with "/" so the pointer looks like "/paths//users/{id}/get"
	if pointer:sub(1, 7) ~= "/paths/" then
		return nil, nil
	end

	local rest = pointer:sub(8) -- e.g. "/users/{id}/get"

	-- Check whether the final segment is a recognised HTTP method
	local last_seg = rest:match("/([^/]+)$")
	if last_seg and HTTP_METHODS[last_seg:lower()] then
		-- Strip the method segment to get the spec path
		local spec_path = rest:match("^(.+)/[^/]+$")
		return spec_path, last_seg:lower()
	end

	-- Path-level cursor (no method segment)
	return rest, nil
end

-- Expose for unit tests
M._parse_paths_pointer = parse_paths_pointer
M._normalize_uri = normalize_uri
M._get_route_methods = get_route_methods

-- ── Public API ────────────────────────────────────────────────────────────────

--- Find the Laravel project root by walking up from the spec's directory.
--- Looks for an `artisan` file.  Cached per source directory.
--- @param source_uri string  URI of the spec file
--- @return string|nil  absolute path to Laravel root, or nil
function M.get_root(source_uri)
	local path = fs.uri_to_path(source_uri)
	local dir = fs.dirname(fs.resolve(path))

	if _root_cache[dir] ~= nil then
		return _root_cache[dir] or nil
	end

	local root = workspace.find_root(dir, { "artisan" })
	_root_cache[dir] = root or false
	return root
end

--- Run the configured route:list command and return the parsed routes array.
--- Caches by the mtime of `<root>/routes/`; returns the cached value when fresh.
--- @param root string  absolute path to Laravel root
--- @param cmd string[] the command to execute (e.g. {"php","artisan","route:list","--json"})
--- @return table[]|nil  array of route entries, or nil on failure
function M.list_routes(root, cmd)
	local routes_dir = fs.join(root, "routes")
	local mtime = fs.mtime(routes_dir)
	local cached = _routes_cache[root]

	if cached and cached.mtime == mtime then
		return cached.routes
	end

	-- Build shell command: cd into root, then run each part properly quoted
	local parts = {}
	for _, part in ipairs(cmd) do
		parts[#parts + 1] = string.format("%q", part)
	end
	local cmd_str = "cd " .. string.format("%q", root) .. " && " .. table.concat(parts, " ") .. " 2>/dev/null"

	log.debug("laravel: running route:list: %s", cmd_str)

	local f = io.popen(cmd_str)
	if not f then
		log.warn("laravel: io.popen failed for cmd: %s", cmd_str)
		return nil
	end
	local output = f:read("*a")
	f:close()

	if not output or output == "" then
		log.warn("laravel: empty output from route:list")
		return nil
	end

	local ok, routes = pcall(json.decode, output)
	if not ok or type(routes) ~= "table" then
		log.warn("laravel: failed to parse route:list output: %s", tostring(routes))
		return nil
	end

	_routes_cache[root] = { routes = routes, mtime = mtime }
	log.info("laravel: loaded %d routes from %s", #routes, root)
	return routes
end

--- Find routes whose URI matches `spec_path` (and optionally `method`).
--- `spec_path` is the OpenAPI path key, e.g. "/users/{id}".
--- `method` is lowercase HTTP verb or nil (returns all methods for that path).
--- `prefix` is an optional string prepended to the normalised spec_path before matching
---   (e.g. "api" when the OpenAPI spec omits the API prefix).
--- Returns a list of matching route entries (may be empty).
--- @param spec_path string
--- @param method string|nil
--- @param routes table[]
--- @param prefix string
--- @return table[]
function M.match_route(spec_path, method, routes, prefix)
	prefix = prefix or ""

	local norm_spec = normalize_uri(spec_path)
	if prefix ~= "" then
		norm_spec = normalize_uri(prefix) .. "/" .. norm_spec
	end

	local matches = {}

	for _, route in ipairs(routes) do
		local norm_uri = normalize_uri(route.uri or "")

		if norm_uri == norm_spec then
			local route_methods = get_route_methods(route)

			if method == nil then
				-- Path-level: include any route for this URI (skip HEAD-only entries)
				local visible = false
				for _, m in ipairs(route_methods) do
					if m ~= "HEAD" then
						visible = true
						break
					end
				end
				if visible then
					matches[#matches + 1] = route
				end
			else
				-- Method-level: check for exact method match
				for _, m in ipairs(route_methods) do
					if m:lower() == method then
						matches[#matches + 1] = route
						break
					end
				end
			end
		end
	end

	return matches
end

--- Read and cache the PSR-4 autoload map from `<root>/composer.json`.
--- Returns a table `{ ["App\\"] = "app/", ... }` or nil on failure.
--- @param root string
--- @return table|nil
local function get_psr4(root)
	local composer_path = fs.join(root, "composer.json")
	local mtime = fs.mtime(composer_path)
	local cached = _composer_cache[root]

	if cached and cached.mtime == mtime then
		return cached.psr4
	end

	local content = fs.read_file(composer_path)
	if not content then
		log.warn("laravel: cannot read %s", composer_path)
		return nil
	end

	local ok, decoded = pcall(json.decode, content)
	if not ok or type(decoded) ~= "table" then
		log.warn("laravel: failed to parse composer.json: %s", tostring(decoded))
		return nil
	end

	-- Merge autoload and autoload-dev PSR-4 maps
	local psr4 = {}
	local function merge(section)
		if type(section) == "table" and type(section["psr-4"]) == "table" then
			for prefix, dir in pairs(section["psr-4"]) do
				psr4[prefix] = dir
			end
		end
	end
	merge(decoded.autoload)
	merge(decoded["autoload-dev"])

	_composer_cache[root] = { psr4 = psr4, mtime = mtime }
	return psr4
end

--- Resolve a Laravel action FQN to an absolute file + line number.
--- Accepts "App\\Http\\Controllers\\UserController@show" format.
--- Also handles Closure (returns nil) and invokable controllers (no @method).
--- @param root string   absolute Laravel project root
--- @param action string artisan route action string
--- @return {file: string, line: integer}|nil
function M.resolve_action(root, action)
	if not action or action == "Closure" then
		return nil
	end

	-- Split "ClassName@method" → class FQN + method name
	local class_fqn, method_name = action:match("^(.+)@(.+)$")
	if not class_fqn then
		-- No @ — assume invokable controller
		class_fqn = action
		method_name = "__invoke"
	end

	local psr4 = get_psr4(root)
	if not psr4 then
		return nil
	end

	-- Find the longest matching PSR-4 namespace prefix
	local best_prefix = ""
	local best_dir = ""
	for ns_prefix, ns_dir in pairs(psr4) do
		if class_fqn:sub(1, #ns_prefix) == ns_prefix and #ns_prefix > #best_prefix then
			best_prefix = ns_prefix
			best_dir = ns_dir
		end
	end

	if best_prefix == "" then
		log.debug("laravel: no PSR-4 prefix matches %s", class_fqn)
		return nil
	end

	-- Strip prefix, replace namespace separators with path separators
	local relative = class_fqn:sub(#best_prefix + 1)
	-- gsub returns (result, count) — capture only result
	local rel_path = relative:gsub("\\", "/")
	local filepath = fs.resolve(fs.join(root, best_dir .. rel_path .. ".php"))

	if not fs.file_readable(filepath) then
		log.debug("laravel: controller file not found: %s", filepath)
		return nil
	end

	-- Scan for the method declaration
	local pattern = "function%s+" .. method_name .. "%s*%("
	local lines = fs.read_lines(filepath)
	for lnum, line in ipairs(lines) do
		if line:match(pattern) then
			return { file = filepath, line = lnum }
		end
	end

	log.debug("laravel: method %s not found in %s", method_name, filepath)
	return nil
end

--- Invalidate the routes cache for the Laravel project that contains `filepath`.
--- Called from the dispatcher on workspace/didChangeWatchedFiles.
--- @param filepath string  absolute path of the changed file
function M.invalidate_routes(filepath)
	for root in pairs(_routes_cache) do
		if filepath:sub(1, #root) == root then
			_routes_cache[root] = nil
			log.debug("laravel: routes cache invalidated for %s", root)
			return
		end
	end
end

--- Main entry point for textDocument/definition.
--- Returns an LSP Location[] when the cursor is on a paths/<path>[/<method>]
--- position that maps to a Laravel route, or nil otherwise.
--- @param uri string
--- @param position {line: integer, character: integer}
--- @param config {enabled: boolean, cmd: string[], path_prefix: string}
--- @return table[]|nil  LSP Location array
function M.find_definition(uri, position, config)
	-- Determine what the cursor is on
	local pointer = index.get_pointer_at(uri, position)
	if not pointer then
		return nil
	end

	local spec_path, method = parse_paths_pointer(pointer)
	if not spec_path then
		return nil
	end

	-- Locate the Laravel project
	local root = M.get_root(uri)
	if not root then
		log.debug("laravel: no artisan found from %s", uri)
		return nil
	end

	-- Load (possibly cached) routes
	local routes = M.list_routes(root, config.cmd)
	if not routes then
		return nil
	end

	-- Match the spec path + method
	local matches = M.match_route(spec_path, method, routes, config.path_prefix)
	if #matches == 0 then
		log.debug("laravel: no route match for %s %s (prefix=%q)", method or "*", spec_path, config.path_prefix)
		return nil
	end

	-- Resolve each match to an LSP Location
	local locations = {}
	for _, route in ipairs(matches) do
		local loc = M.resolve_action(root, route.action)
		if loc then
			locations[#locations + 1] = {
				uri = fs.path_to_uri(loc.file),
				range = {
					start = { line = loc.line - 1, character = 0 },
					["end"] = { line = loc.line - 1, character = 0 },
				},
			}
		else
			log.debug("laravel: could not resolve action %s", tostring(route.action))
		end
	end

	return #locations > 0 and locations or nil
end

return M
