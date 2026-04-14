-- Tests for hover.lua — target file resolution and block extraction.

local config = require("openapi-navigator.config")
local hover = require("openapi-navigator.hover")
local resolver = require("openapi-navigator.resolver")

config.build({})

local fixture_dir = vim.fn.resolve(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h") .. "/fixtures")
local spec30 = vim.fn.resolve(fixture_dir .. "/openapi30.yaml")
local spec31 = vim.fn.resolve(fixture_dir .. "/openapi31.yaml")
local user_yaml = vim.fn.resolve(fixture_dir .. "/schemas/User.yaml")
local addr_yaml = vim.fn.resolve(fixture_dir .. "/schemas/Address.yaml")

-- ── _resolve_target_file ─────────────────────────────────────────────────────

describe("hover._resolve_target_file", function()
	it("returns source file for a same-file ref", function()
		local result = hover._resolve_target_file({ file = nil }, spec30)
		assert.are.equal(spec30, result)
	end)

	it("resolves a relative cross-file ref", function()
		local result = hover._resolve_target_file({ file = "./schemas/User.yaml" }, spec30)
		assert.are.equal(user_yaml, result)
	end)

	it("resolves a ref from a subdirectory back to parent", function()
		local result = hover._resolve_target_file({ file = "../openapi30.yaml" }, user_yaml)
		assert.are.equal(spec30, result)
	end)

	it("returns nil for a non-existent file", function()
		local result = hover._resolve_target_file({ file = "./no-such-file.yaml" }, spec30)
		assert.is_nil(result)
	end)

	it("resolves cross-file schema inside schemas/", function()
		local result = hover._resolve_target_file({ file = "./Address.yaml" }, user_yaml)
		assert.are.equal(addr_yaml, result)
	end)
end)

-- ── block extraction via resolve_pointer (integration) ───────────────────────

describe("hover block extraction — OpenAPI 3.0", function()
	it("UserId definition block contains expected keys", function()
		local pos = resolver.resolve_pointer(spec30, "/components/schemas/UserId")
		assert.is_not_nil(pos)
		local lines = vim.fn.readfile(spec30)
		local block = {}
		-- Collect the block: start line + indented children
		local start_col = pos.col
		table.insert(block, lines[pos.line])
		for i = pos.line + 1, #lines do
			local line = lines[i]
			if line:match("^%s*$") then
				table.insert(block, line)
			else
				local indent = #(line:match("^( *)") or "")
				if indent <= start_col then
					break
				end
				table.insert(block, line)
			end
		end
		local text = table.concat(block, "\n")
		assert.is_not_nil(text:find("integer"), "block should contain 'integer'")
		assert.is_not_nil(text:find("int64"), "block should contain 'int64'")
	end)

	it("Error schema block contains code and message properties", function()
		local pos = resolver.resolve_pointer(spec30, "/components/schemas/Error")
		assert.is_not_nil(pos)
		local lines = vim.fn.readfile(spec30)
		local start_col = pos.col
		local block = { lines[pos.line] }
		for i = pos.line + 1, #lines do
			local line = lines[i]
			if line:match("^%s*$") then
				table.insert(block, line)
			else
				local indent = #(line:match("^( *)") or "")
				if indent <= start_col then
					break
				end
				table.insert(block, line)
			end
		end
		local text = table.concat(block, "\n")
		assert.is_not_nil(text:find("code"), "block should mention 'code'")
		assert.is_not_nil(text:find("message"), "block should mention 'message'")
	end)
end)

describe("hover block extraction — OpenAPI 3.1", function()
	it("Metadata block resolves despite nullable type array", function()
		local pos = resolver.resolve_pointer(spec31, "/components/schemas/Metadata")
		assert.is_not_nil(pos, "Metadata should be resolvable in 3.1 spec")
		local lines = vim.fn.readfile(spec31)
		assert.is_not_nil(lines[pos.line]:find("Metadata"))
	end)

	it("UserEvent block is extractable", function()
		local pos = resolver.resolve_pointer(spec31, "/components/schemas/UserEvent")
		assert.is_not_nil(pos)
		local lines = vim.fn.readfile(spec31)
		local start_col = pos.col
		local block = { lines[pos.line] }
		for i = pos.line + 1, #lines do
			local line = lines[i]
			if line:match("^%s*$") then
				table.insert(block, line)
			else
				local indent = #(line:match("^( *)") or "")
				if indent <= start_col then
					break
				end
				table.insert(block, line)
			end
		end
		local text = table.concat(block, "\n")
		assert.is_not_nil(text:find("user.created"), "block should mention 'user.created' const")
	end)

	it("Item block contains prefixItems (3.1-only keyword)", function()
		local pos = resolver.resolve_pointer(spec31, "/components/schemas/Item")
		assert.is_not_nil(pos)
		local lines = vim.fn.readfile(spec31)
		local start_col = pos.col
		local block = { lines[pos.line] }
		for i = pos.line + 1, #lines do
			local line = lines[i]
			if line:match("^%s*$") then
				table.insert(block, line)
			else
				local indent = #(line:match("^( *)") or "")
				if indent <= start_col then
					break
				end
				table.insert(block, line)
			end
		end
		local text = table.concat(block, "\n")
		assert.is_not_nil(text:find("prefixItems"), "block should contain 'prefixItems'")
	end)
end)
