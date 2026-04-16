--- openapi-navigator.nvim — Live browser preview orchestrator.
--- Manages the HTTP server lifecycle, browser opening, and BufWritePost
--- hooks that trigger SSE reload events.

local http = require("openapi-navigator.preview.http")
local sse = require("openapi-navigator.preview.sse")

local M = {}

-- ── State ─────────────────────────────────────────────────────────────────────

local _spec_root = nil     -- absolute path to the spec root being previewed
local _augroup_id = nil    -- augroup for BufWritePost / VimLeavePre autocmds

-- ── Helpers ───────────────────────────────────────────────────────────────────

--- Open a URL in the system browser.
--- @param url string
local function open_browser(url)
	if vim.ui.open then
		vim.ui.open(url)
	elseif vim.fn.has("mac") == 1 then
		vim.fn.system({ "open", url })
	elseif vim.fn.has("win32") == 1 then
		vim.fn.system({ "cmd", "/c", "start", url })
	else
		vim.fn.system({ "xdg-open", url })
	end
end

--- Find the main spec file within a spec root directory.
--- Checks each root_marker in config order, then falls back to `fallback_path`
--- (the current buffer's file) when no marker matches — handles specs whose
--- filename doesn't match the default markers (e.g. core_api.yaml).
--- @param spec_root string
--- @param root_markers string[]
--- @param fallback_path string  absolute path to the buffer being previewed
--- @return string|nil  absolute path to the main spec file
local function find_main_spec(spec_root, root_markers, fallback_path)
	for _, marker in ipairs(root_markers) do
		local candidate = spec_root .. "/" .. marker
		if vim.fn.filereadable(candidate) == 1 then
			return candidate
		end
	end
	-- No standard root marker found — use the current buffer if it lives
	-- inside the spec root and is readable (covers custom filenames).
	if fallback_path and vim.fn.filereadable(fallback_path) == 1 then
		return fallback_path
	end
	return nil
end

--- Register the BufWritePost autocmd that broadcasts SSE reload events.
--- @param augroup integer
local function register_write_hook(augroup)
	vim.api.nvim_create_autocmd("BufWritePost", {
		group = augroup,
		pattern = { "*.yaml", "*.yml", "*.json" },
		desc = "openapi-navigator: notify preview browser on save",
		callback = function()
			sse.broadcast("reload")
		end,
	})
end

-- ── Public API ────────────────────────────────────────────────────────────────

--- Start the preview server for the OpenAPI spec associated with `bufnr`.
--- If a server is already running for a different spec root, it is stopped first.
--- If a server is already running for the same spec root, just (re-)opens the browser.
--- @param bufnr integer|nil  defaults to current buffer (0)
function M.start(bufnr)
	local nav = require("openapi-navigator")
	local cfg = require("openapi-navigator.config").options

	bufnr = bufnr or vim.api.nvim_get_current_buf()

	local spec_root = nav.get_spec_root(bufnr)
	if not spec_root then
		vim.notify("openapi-navigator: current buffer is not part of an OpenAPI spec", vim.log.levels.WARN)
		return
	end

	local buf_path = vim.fn.resolve(vim.api.nvim_buf_get_name(bufnr))
	local main_spec = find_main_spec(spec_root, cfg.root_markers, buf_path)
	if not main_spec then
		vim.notify(
			"openapi-navigator: could not find a root spec file in " .. spec_root,
			vim.log.levels.WARN
		)
		return
	end

	-- If already running for the same root, just open the browser again
	if http.is_running() and _spec_root == spec_root then
		local port = http.get_port()
		if port and cfg.preview.open_browser then
			open_browser("http://127.0.0.1:" .. port .. "/")
		end
		return
	end

	-- Stop any previously running server (different spec root)
	if http.is_running() then
		M.stop()
	end

	_spec_root = spec_root

	-- Create a dedicated augroup for preview autocmds
	_augroup_id = vim.api.nvim_create_augroup("OpenAPINavigatorPreview", { clear = true })
	register_write_hook(_augroup_id)

	-- Register VimLeavePre for clean shutdown
	vim.api.nvim_create_autocmd("VimLeavePre", {
		group = _augroup_id,
		once = true,
		desc = "openapi-navigator: stop preview server on exit",
		callback = function()
			M.stop()
		end,
	})

	local preview_cfg = cfg.preview or {}
	http.start({
		port = preview_cfg.port or 0,
		spec_root = spec_root,
		main_spec = main_spec,
		theme = preview_cfg.theme or "dark",
	}, function(port)
		local url = "http://127.0.0.1:" .. port .. "/"
		vim.notify("openapi-navigator: preview at " .. url, vim.log.levels.INFO)
		if preview_cfg.open_browser ~= false then
			open_browser(url)
		end
	end)
end

--- Stop the preview server and clean up autocmds.
function M.stop()
	if not http.is_running() then
		return
	end

	http.stop()
	_spec_root = nil

	if _augroup_id then
		pcall(vim.api.nvim_del_augroup_by_id, _augroup_id)
		_augroup_id = nil
	end

	vim.notify("openapi-navigator: preview stopped", vim.log.levels.INFO)
end

--- Return true if the preview server is currently running.
--- @return boolean
function M.is_running()
	return http.is_running()
end

--- Broadcast a reload event to all connected browser clients.
--- Called from init.lua's BufWritePost hook when the preview is running.
function M.notify_change()
	sse.broadcast("reload")
end

return M
