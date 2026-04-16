local M = {}

M.defaults = {
	-- File patterns to treat as OpenAPI specs (glob format)
	patterns = {
		"openapi*.yaml",
		"openapi*.yml",
		"openapi*.json",
		"swagger*.yaml",
		"swagger*.json",
		"**/api-docs/**/*.yaml",
		"**/api-docs/**/*.yml",
	},

	-- Root markers used to find the spec root directory
	root_markers = {
		"openapi.yaml",
		"openapi.yml",
		"openapi.json",
		"swagger.yaml",
		"swagger.json",
	},

	-- Hover preview options (passed to the LSP server as initializationOptions)
	hover = {
		max_width = 80,
		max_height = 30,
		max_depth = 2,
	},

	-- Browser preview options
	preview = {
		-- TCP port for the local HTTP server. 0 = let the OS pick a free port.
		port = 0,
		-- RapiDoc color theme: "dark" or "light"
		theme = "dark",
		-- Automatically open the browser when :OpenAPIPreview is run
		open_browser = true,
	},

	-- Laravel framework adapter (passed to the LSP server as initializationOptions)
	laravel = {
		-- Set to false to disable Laravel route navigation entirely
		enabled = true,
		-- Command used to list routes. Override for Docker or custom wrappers, e.g.:
		--   cmd = { "./xenv", "artisan", "route:list", "--json" }
		cmd = { "php", "artisan", "route:list", "--json" },
		-- Prefix to prepend to OpenAPI paths before matching Laravel URIs.
		-- Use "api" when your spec paths are "/users/{id}" but Laravel registers "api/users/{id}".
		path_prefix = "",
	},
}

-- Active resolved options (populated after setup())
M.options = {}

--- Merge user options over defaults.
--- @param user_opts table|nil
--- @return table
function M.build(user_opts)
	M.options = vim.tbl_deep_extend("force", {}, M.defaults, user_opts or {})
	return M.options
end

return M
