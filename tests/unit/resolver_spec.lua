-- Tests for resolver.lua — $ref parsing, file resolution, and JSON pointer walking.

local resolver = require("openapi-navigator.resolver")

-- Resolve fixture paths the way the plugin does (handles /tmp→/private/tmp on macOS).
local fixture_dir = vim.fn.resolve(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h") .. "/fixtures")
local spec30 = fixture_dir .. "/openapi30.yaml"
local spec31 = fixture_dir .. "/openapi31.yaml"
local spec_json = fixture_dir .. "/openapi30.json"
local user_yaml = fixture_dir .. "/schemas/User.yaml"
local addr_yaml = fixture_dir .. "/schemas/Address.yaml"

-- ── parse_ref_from_line ──────────────────────────────────────────────────────

describe("parse_ref_from_line — YAML", function()
	it("returns nil for a line without $ref", function()
		assert.is_nil(resolver.parse_ref_from_line("          schema:", false))
		assert.is_nil(resolver.parse_ref_from_line("  type: string", false))
		assert.is_nil(resolver.parse_ref_from_line("", false))
	end)

	it("parses a single-quoted same-file pointer", function()
		local ref = resolver.parse_ref_from_line("  $ref: '#/components/schemas/User'", false)
		assert.is_not_nil(ref)
		assert.is_nil(ref.file)
		assert.are.equal("/components/schemas/User", ref.pointer)
	end)

	it("parses a double-quoted same-file pointer", function()
		local ref = resolver.parse_ref_from_line('  $ref: "#/components/schemas/User"', false)
		assert.is_not_nil(ref)
		assert.is_nil(ref.file)
		assert.are.equal("/components/schemas/User", ref.pointer)
	end)

	-- Note: $ref: #/... (unquoted) is not tested because '#' starts a YAML comment,
	-- so such a line is not valid YAML and would never appear in a real spec file.

	it("parses a cross-file ref with no pointer", function()
		local ref = resolver.parse_ref_from_line("  $ref: './schemas/User.yaml'", false)
		assert.is_not_nil(ref)
		assert.are.equal("./schemas/User.yaml", ref.file)
		assert.is_nil(ref.pointer)
	end)

	it("parses a cross-file ref with a pointer", function()
		local ref = resolver.parse_ref_from_line("  $ref: './schemas/User.yaml#/properties/email'", false)
		assert.is_not_nil(ref)
		assert.are.equal("./schemas/User.yaml", ref.file)
		assert.are.equal("/properties/email", ref.pointer)
	end)

	it("parses a relative parent-directory ref", function()
		local ref = resolver.parse_ref_from_line("  $ref: '../openapi30.yaml#/components/schemas/UserId'", false)
		assert.is_not_nil(ref)
		assert.are.equal("../openapi30.yaml", ref.file)
		assert.are.equal("/components/schemas/UserId", ref.pointer)
	end)

	it("parses a deeply indented $ref", function()
		local ref = resolver.parse_ref_from_line("                  $ref: '#/components/schemas/Error'", false)
		assert.is_not_nil(ref)
		assert.is_nil(ref.file)
		assert.are.equal("/components/schemas/Error", ref.pointer)
	end)

	-- OpenAPI 3.1 allows path items to use $ref
	it("parses a path-item $ref (OpenAPI 3.1)", function()
		local ref = resolver.parse_ref_from_line("    $ref: './schemas/PathItem.yaml'", false)
		assert.is_not_nil(ref)
		assert.are.equal("./schemas/PathItem.yaml", ref.file)
		assert.is_nil(ref.pointer)
	end)

	it("raw field contains the original ref string", function()
		local ref = resolver.parse_ref_from_line("  $ref: '#/components/schemas/User'", false)
		assert.is_not_nil(ref)
		assert.are.equal("#/components/schemas/User", ref.raw)
	end)
end)

describe("parse_ref_from_line — JSON", function()
	it("returns nil for a line without $ref", function()
		assert.is_nil(resolver.parse_ref_from_line('  "type": "string"', true))
		assert.is_nil(resolver.parse_ref_from_line("", true))
	end)

	it("parses a same-file JSON pointer", function()
		local ref = resolver.parse_ref_from_line('  "$ref": "#/components/schemas/Widget"', true)
		assert.is_not_nil(ref)
		assert.is_nil(ref.file)
		assert.are.equal("/components/schemas/Widget", ref.pointer)
	end)

	it("parses a JSON $ref with leading whitespace", function()
		local ref = resolver.parse_ref_from_line('                  "$ref": "#/components/schemas/WidgetId"', true)
		assert.is_not_nil(ref)
		assert.are.equal("/components/schemas/WidgetId", ref.pointer)
	end)
end)

-- ── resolve_file ─────────────────────────────────────────────────────────────

describe("resolve_file", function()
	-- We need a buffer associated with the fixture file for resolve_file to work.
	local bufnr

	before_each(function()
		bufnr = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_buf_set_name(bufnr, spec30)
	end)

	after_each(function()
		if vim.api.nvim_buf_is_valid(bufnr) then
			vim.api.nvim_buf_delete(bufnr, { force = true })
		end
	end)

	it("returns the current file for a same-file ref", function()
		local ref = { file = nil }
		local result = resolver.resolve_file(ref, bufnr)
		assert.are.equal(vim.fn.resolve(spec30), result)
	end)

	it("resolves a relative cross-file ref", function()
		local ref = { file = "./schemas/User.yaml" }
		local result = resolver.resolve_file(ref, bufnr)
		assert.are.equal(vim.fn.resolve(user_yaml), result)
	end)

	it("resolves a relative parent-directory ref from a subdirectory file", function()
		local sub_bufnr = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_buf_set_name(sub_bufnr, user_yaml)
		local ref = { file = "../openapi30.yaml" }
		local result = resolver.resolve_file(ref, sub_bufnr)
		assert.are.equal(vim.fn.resolve(spec30), result)
		vim.api.nvim_buf_delete(sub_bufnr, { force = true })
	end)

	it("returns nil for a non-existent file", function()
		local ref = { file = "./does-not-exist.yaml" }
		local result = resolver.resolve_file(ref, bufnr)
		assert.is_nil(result)
	end)
end)

-- ── resolve_pointer — OpenAPI 3.0 YAML ───────────────────────────────────────

describe("resolve_pointer — OpenAPI 3.0 YAML", function()
	it("returns line 1 for a nil pointer", function()
		local pos = resolver.resolve_pointer(spec30, nil)
		assert.is_not_nil(pos)
		assert.are.equal(1, pos.line)
		assert.are.equal(0, pos.col)
	end)

	it("returns line 1 for an empty pointer", function()
		local pos = resolver.resolve_pointer(spec30, "")
		assert.are.equal(1, pos.line)
	end)

	it("resolves /components/schemas/UserId", function()
		local pos = resolver.resolve_pointer(spec30, "/components/schemas/UserId")
		assert.is_not_nil(pos)
		assert.is_true(pos.line > 0)
		-- Verify the resolved line actually contains the key
		local lines = vim.fn.readfile(spec30)
		assert.is_not_nil(lines[pos.line]:find("UserId"))
	end)

	it("resolves /components/schemas/UserList", function()
		local pos = resolver.resolve_pointer(spec30, "/components/schemas/UserList")
		assert.is_not_nil(pos)
		local lines = vim.fn.readfile(spec30)
		assert.is_not_nil(lines[pos.line]:find("UserList"))
	end)

	it("resolves /components/schemas/Error", function()
		local pos = resolver.resolve_pointer(spec30, "/components/schemas/Error")
		assert.is_not_nil(pos)
		local lines = vim.fn.readfile(spec30)
		assert.is_not_nil(lines[pos.line]:find("Error"))
	end)

	it("resolves /components/schemas/UserSummary/properties/id", function()
		local pos = resolver.resolve_pointer(spec30, "/components/schemas/UserSummary/properties/id")
		assert.is_not_nil(pos)
		local lines = vim.fn.readfile(spec30)
		-- The line should be indented more than the schema definition line
		assert.is_true(pos.col > 0)
		assert.is_not_nil(lines[pos.line]:find("id"))
	end)

	it("returns nil for a non-existent pointer", function()
		local pos = resolver.resolve_pointer(spec30, "/components/schemas/DoesNotExist")
		assert.is_nil(pos)
	end)

	it("returns nil for a partially-matching pointer", function()
		local pos = resolver.resolve_pointer(spec30, "/components/schemas/User/nonexistent")
		assert.is_nil(pos)
	end)

	it("resolves /components/responses/NotFound", function()
		local pos = resolver.resolve_pointer(spec30, "/components/responses/NotFound")
		assert.is_not_nil(pos)
		local lines = vim.fn.readfile(spec30)
		assert.is_not_nil(lines[pos.line]:find("NotFound"))
	end)
end)

-- ── resolve_pointer — cross-file YAML ────────────────────────────────────────

describe("resolve_pointer — cross-file YAML", function()
	it("resolves /properties/email in User.yaml", function()
		local pos = resolver.resolve_pointer(user_yaml, "/properties/email")
		assert.is_not_nil(pos)
		local lines = vim.fn.readfile(user_yaml)
		assert.is_not_nil(lines[pos.line]:find("email"))
	end)

	it("resolves /properties/address in User.yaml", function()
		local pos = resolver.resolve_pointer(user_yaml, "/properties/address")
		assert.is_not_nil(pos)
		local lines = vim.fn.readfile(user_yaml)
		assert.is_not_nil(lines[pos.line]:find("address"))
	end)

	it("resolves /components/schemas/Address in Address.yaml", function()
		local pos = resolver.resolve_pointer(addr_yaml, "/components/schemas/Address")
		assert.is_not_nil(pos)
		local lines = vim.fn.readfile(addr_yaml)
		assert.is_not_nil(lines[pos.line]:find("Address"))
	end)

	it("resolves /components/schemas/Address/properties/country in Address.yaml", function()
		local pos = resolver.resolve_pointer(addr_yaml, "/components/schemas/Address/properties/country")
		assert.is_not_nil(pos)
		local lines = vim.fn.readfile(addr_yaml)
		assert.is_not_nil(lines[pos.line]:find("country"))
	end)
end)

-- ── resolve_pointer — OpenAPI 3.1 YAML ───────────────────────────────────────

describe("resolve_pointer — OpenAPI 3.1 YAML", function()
	it("resolves /components/schemas/UserId", function()
		local pos = resolver.resolve_pointer(spec31, "/components/schemas/UserId")
		assert.is_not_nil(pos)
		local lines = vim.fn.readfile(spec31)
		assert.is_not_nil(lines[pos.line]:find("UserId"))
	end)

	it("resolves /components/schemas/Metadata (nullable type array)", function()
		local pos = resolver.resolve_pointer(spec31, "/components/schemas/Metadata")
		assert.is_not_nil(pos)
		local lines = vim.fn.readfile(spec31)
		assert.is_not_nil(lines[pos.line]:find("Metadata"))
	end)

	it("resolves /components/schemas/UserEvent", function()
		local pos = resolver.resolve_pointer(spec31, "/components/schemas/UserEvent")
		assert.is_not_nil(pos)
		local lines = vim.fn.readfile(spec31)
		assert.is_not_nil(lines[pos.line]:find("UserEvent"))
	end)

	it("resolves /components/schemas/Item", function()
		local pos = resolver.resolve_pointer(spec31, "/components/schemas/Item")
		assert.is_not_nil(pos)
		local lines = vim.fn.readfile(spec31)
		assert.is_not_nil(lines[pos.line]:find("Item"))
	end)

	it("resolves /webhooks/newUser", function()
		local pos = resolver.resolve_pointer(spec31, "/webhooks/newUser")
		assert.is_not_nil(pos)
		local lines = vim.fn.readfile(spec31)
		assert.is_not_nil(lines[pos.line]:find("newUser"))
	end)

	it("resolves deeply nested pointer /components/schemas/UserSummary/properties/nickname", function()
		local pos = resolver.resolve_pointer(spec31, "/components/schemas/UserSummary/properties/nickname")
		assert.is_not_nil(pos)
		local lines = vim.fn.readfile(spec31)
		assert.is_not_nil(lines[pos.line]:find("nickname"))
	end)
end)

-- ── resolve_pointer — JSON format ────────────────────────────────────────────

describe("resolve_pointer — JSON format", function()
	it("resolves /components/schemas/Widget", function()
		local pos = resolver.resolve_pointer(spec_json, "/components/schemas/Widget")
		assert.is_not_nil(pos)
		local lines = vim.fn.readfile(spec_json)
		assert.is_not_nil(lines[pos.line]:find("Widget"))
	end)

	it("resolves /components/schemas/WidgetId", function()
		local pos = resolver.resolve_pointer(spec_json, "/components/schemas/WidgetId")
		assert.is_not_nil(pos)
		local lines = vim.fn.readfile(spec_json)
		assert.is_not_nil(lines[pos.line]:find("WidgetId"))
	end)

	it("resolves /components/schemas/WidgetList", function()
		local pos = resolver.resolve_pointer(spec_json, "/components/schemas/WidgetList")
		assert.is_not_nil(pos)
		local lines = vim.fn.readfile(spec_json)
		assert.is_not_nil(lines[pos.line]:find("WidgetList"))
	end)

	it("returns nil for non-existent key in JSON", function()
		local pos = resolver.resolve_pointer(spec_json, "/components/schemas/NoSuchThing")
		assert.is_nil(pos)
	end)
end)

-- ── JSON pointer escape sequences ────────────────────────────────────────────

describe("resolve_pointer — JSON pointer escape sequences", function()
	-- ~0 decodes to ~, ~1 decodes to /
	-- We test the decoding indirectly: a pointer that encodes a key containing
	-- a slash would use ~1. For the test fixtures we use keys without slashes,
	-- so we test the decode helper is at least non-destructive on normal segments.
	it("resolves a pointer with no escape sequences unchanged", function()
		local pos = resolver.resolve_pointer(spec30, "/components/schemas/UserId")
		assert.is_not_nil(pos)
	end)
end)
