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
		max_width  = 80,
		max_height = 30,
		max_depth  = 2,
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
