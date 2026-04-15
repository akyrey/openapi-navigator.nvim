--- openapi-navigator.nvim — Neovim client.
--- Detects OpenAPI buffers and starts the LSP server via vim.lsp.start().
--- All navigation (gd, K, gr) is handled by the server; use your existing
--- LSP keymaps — no plugin-specific bindings are registered.

local M = {}

local config = require("openapi-navigator.config")

-- ── Detection cache ───────────────────────────────────────────────────────────

local _detection_cache = {}

--- Check whether a filename matches any of the configured glob patterns.
--- @param filename string
--- @param patterns string[]
--- @return boolean
local function matches_pattern(filename, patterns)
	local base = vim.fn.fnamemodify(filename, ":t")
	for _, pat in ipairs(patterns) do
		local re = vim.fn.glob2regpat(pat)
		if vim.fn.match(filename, re) >= 0 or vim.fn.match(base, re) >= 0 then
			return true
		end
	end
	return false
end

--- Walk up directories from `dir` looking for any root-marker file.
--- Returns the directory containing the marker, or nil.
--- @param dir string
--- @param markers string[]
--- @return string|nil
local function find_root(dir, markers)
	local current = dir
	while true do
		for _, marker in ipairs(markers) do
			if vim.fn.filereadable(current .. "/" .. marker) == 1 then
				return current
			end
		end
		local parent = vim.fn.fnamemodify(current, ":h")
		if parent == current then
			break
		end
		current = parent
	end
	return nil
end

--- Detect whether a buffer contains an OpenAPI/Swagger document.
--- Uses filename patterns, content scan, and root-marker walk.
--- @param bufnr integer
--- @param opts table  config options
--- @return boolean
local function is_openapi_buffer(bufnr, opts)
	if _detection_cache[bufnr] ~= nil then
		return _detection_cache[bufnr]
	end

	local filepath = vim.api.nvim_buf_get_name(bufnr)
	if filepath == "" then
		_detection_cache[bufnr] = false
		return false
	end

	if not filepath:match("%.[yY][aA]?[mM][lL]$") and not filepath:match("%.json$") then
		_detection_cache[bufnr] = false
		return false
	end

	-- 1. Content check: first 20 lines for top-level openapi:/swagger: key
	local lines
	if vim.api.nvim_buf_is_loaded(bufnr) then
		lines = vim.api.nvim_buf_get_lines(bufnr, 0, 20, false)
	else
		lines = vim.fn.readfile(filepath, "", 20)
	end

	for _, line in ipairs(lines) do
		if
			line:match("^openapi%s*:")
			or line:match("^swagger%s*:")
			or line:match('"openapi"%s*:')
			or line:match('"swagger"%s*:')
		then
			_detection_cache[bufnr] = true
			return true
		end
	end

	-- 2. Filename pattern + root-marker walk (catches split spec files)
	if matches_pattern(filepath, opts.patterns) then
		local dir = vim.fn.fnamemodify(filepath, ":h")
		if find_root(dir, opts.root_markers) then
			_detection_cache[bufnr] = true
			return true
		end
	end

	_detection_cache[bufnr] = false
	return false
end

M.is_openapi_buffer = is_openapi_buffer

-- ── Runtime detection ─────────────────────────────────────────────────────────

--- Locate the Lua runtime to use for the server.
--- Uses `nvim -l` (available in every Neovim install ≥ 0.9) which runs the
--- given script with Neovim's built-in LuaJIT — no external dependency.
--- Falls back to luajit or lua on PATH if nvim -l is somehow unavailable.
--- @return string[], string|nil  {cmd, args...}, or nil + error message
local function find_runtime_cmd(server_main)
	-- Primary: nvim --headless -l <script>
	-- nvim is always on PATH when this plugin is loaded.
	if vim.fn.executable("nvim") == 1 then
		return { "nvim", "--headless", "-l", server_main }
	end
	-- Fallbacks for unusual setups
	for _, exe in ipairs({ "luajit", "lua" }) do
		if vim.fn.executable(exe) == 1 then
			return { exe, server_main }
		end
	end
	return nil, "openapi-navigator: cannot find a Lua runtime. " .. "Ensure 'nvim', 'luajit', or 'lua' is on PATH."
end

--- Return the absolute path to the plugin root (the directory that contains
--- this file's parent: plugin_root/lua/openapi-navigator/init.lua).
--- @return string
local function plugin_root()
	-- debug.getinfo(1, "S").source is "@/abs/path/to/init.lua"
	local src = debug.getinfo(1, "S").source:sub(2) -- strip leading '@'
	-- Go up two levels: init.lua → openapi-navigator/ → lua/ → plugin root
	return vim.fn.fnamemodify(src, ":h:h:h")
end

-- ── Setup ─────────────────────────────────────────────────────────────────────

--- Get the spec root directory for a buffer.
--- Walks parent directories for a root marker, falls back to the file's own dir.
--- @param bufnr integer
--- @return string|nil
function M.get_spec_root(bufnr)
	local filepath = vim.api.nvim_buf_get_name(bufnr or 0)
	if filepath == "" then
		return nil
	end
	local dir = vim.fn.fnamemodify(vim.fn.resolve(filepath), ":h")
	local opts = config.options
	return find_root(dir, opts.root_markers) or dir
end

--- Main entry point.
---   require("openapi-navigator").setup(opts)
--- @param opts table|nil
function M.setup(opts)
	local cfg = config.build(opts)

	local root = plugin_root()
	local server_main = root .. "/server/main.lua"

	-- Verify the server script exists
	if vim.fn.filereadable(server_main) ~= 1 then
		vim.notify(
			"openapi-navigator: server not found at " .. server_main .. "\nDid the plugin install correctly?",
			vim.log.levels.ERROR
		)
		return
	end

	local group = vim.api.nvim_create_augroup("OpenAPINavigator", { clear = true })

	-- Start the LSP server whenever an OpenAPI buffer is opened
	vim.api.nvim_create_autocmd("FileType", {
		group = group,
		pattern = { "yaml", "json" },
		callback = function(ev)
			if not is_openapi_buffer(ev.buf, cfg) then
				return
			end

			local cmd, err = find_runtime_cmd(server_main)
			if not cmd then
				vim.notify(err, vim.log.levels.ERROR)
				return
			end

			local root_dir = M.get_spec_root(ev.buf)

			vim.lsp.start({
				name = "openapi-navigator",
				cmd = cmd,
				root_dir = root_dir,
				init_options = {
					root_markers = cfg.root_markers,
					hover = cfg.hover,
					laravel = cfg.laravel,
				},
				-- Only attach to YAML / JSON OpenAPI buffers
				filetypes = { "yaml", "json" },
			})
		end,
	})

	-- Clear detection cache on save so modified files are re-evaluated
	vim.api.nvim_create_autocmd("BufWritePost", {
		group = group,
		pattern = { "*.yaml", "*.yml", "*.json" },
		callback = function(ev)
			_detection_cache[ev.buf] = nil
		end,
	})

	-- Clean up cache when a buffer is deleted
	vim.api.nvim_create_autocmd("BufDelete", {
		group = group,
		callback = function(ev)
			_detection_cache[ev.buf] = nil
		end,
	})
end

return M
