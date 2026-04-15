-- Tests for server/index.lua — ref index building, pointer-at-position, and invalidation.

local index     = require("index")
local workspace = require("workspace")
local store     = require("document_store")
local fs        = require("fs")

local fixture_dir = vim.fn.resolve(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h") .. "/fixtures")
local spec30      = vim.fn.resolve(fixture_dir .. "/openapi30.yaml")
local spec31      = vim.fn.resolve(fixture_dir .. "/openapi31.yaml")
local spec_json   = vim.fn.resolve(fixture_dir .. "/openapi30.json")
local user_yaml   = vim.fn.resolve(fixture_dir .. "/schemas/User.yaml")
local addr_yaml   = vim.fn.resolve(fixture_dir .. "/schemas/Address.yaml")

local spec30_uri  = fs.path_to_uri(spec30)

-- Root-markers from default config
local root_markers = {
	"openapi.yaml", "openapi.yml", "openapi.json",
	"swagger.yaml", "swagger.json",
}

-- Shim workspace.get_root so the index uses the fixture directory as root.
local _orig_get_root = workspace.get_root

local function use_fixture_root()
	workspace.get_root = function(_dir, _markers)
		return fixture_dir
	end
end

local function restore_get_root()
	workspace.get_root = _orig_get_root
end

local function reset_index()
	index._definitions   = {}
	index._references    = {}
	index._indexed_files = {}
end

-- ── canonical_key ─────────────────────────────────────────────────────────────

describe("canonical_key", function()
	it("produces file::pointer format", function()
		local k = index.canonical_key("/abs/path/file.yaml", "/components/schemas/User")
		assert.are.equal("/abs/path/file.yaml::/components/schemas/User", k)
	end)

	it("produces file:: format when pointer is nil", function()
		local k = index.canonical_key("/abs/path/file.yaml", nil)
		assert.are.equal("/abs/path/file.yaml::", k)
	end)

	it("produces file:: format when pointer is empty string", function()
		local k = index.canonical_key("/abs/path/file.yaml", "")
		assert.are.equal("/abs/path/file.yaml::", k)
	end)
end)

-- ── ensure_indexed + get_definition — OpenAPI 3.0 YAML ───────────────────────

describe("ensure_indexed — OpenAPI 3.0 YAML", function()
	before_each(function()
		use_fixture_root()
		reset_index()
		index.ensure_indexed(spec30_uri, root_markers)
	end)

	after_each(function()
		restore_get_root()
	end)

	it("indexes all fixture files", function()
		assert.is_true(index._indexed_files[spec30] ~= nil, "openapi30.yaml should be indexed")
		assert.is_true(index._indexed_files[user_yaml] ~= nil, "schemas/User.yaml should be indexed")
		assert.is_true(index._indexed_files[addr_yaml] ~= nil, "schemas/Address.yaml should be indexed")
	end)

	it("has a non-trivial number of definitions", function()
		local count = 0
		for _ in pairs(index._definitions) do
			count = count + 1
		end
		assert.is_true(count >= 10, "expected >= 10 definitions, got " .. count)
	end)

	it("definition for UserId has correct file", function()
		local k   = index.canonical_key(spec30, "/components/schemas/UserId")
		local def = index.get_definition(k)
		assert.is_not_nil(def, "UserId should be in definitions")
		assert.are.equal(spec30, def.file)
		assert.is_true(def.line > 0)
	end)

	it("definition for UserList has correct file", function()
		local k   = index.canonical_key(spec30, "/components/schemas/UserList")
		local def = index.get_definition(k)
		assert.is_not_nil(def, "UserList should be in definitions")
		assert.are.equal(spec30, def.file)
	end)

	it("definition for Error is indexed", function()
		local k   = index.canonical_key(spec30, "/components/schemas/Error")
		local def = index.get_definition(k)
		assert.is_not_nil(def, "Error should be in definitions")
	end)

	it("definitions from cross-file schemas are indexed", function()
		local k   = index.canonical_key(user_yaml, "/properties/email")
		local def = index.get_definition(k)
		assert.is_not_nil(def, "User.yaml /properties/email should be indexed")
		assert.are.equal(user_yaml, def.file)
	end)

	it("definitions from Address.yaml are indexed", function()
		local k   = index.canonical_key(addr_yaml, "/components/schemas/Address")
		local def = index.get_definition(k)
		assert.is_not_nil(def, "Address should be indexed from Address.yaml")
	end)
end)

-- ── ensure_indexed + get_references — OpenAPI 3.0 YAML ───────────────────────

describe("ensure_indexed — references", function()
	before_each(function()
		use_fixture_root()
		reset_index()
		index.ensure_indexed(spec30_uri, root_markers)
	end)

	after_each(function()
		restore_get_root()
	end)

	it("UserId has multiple references", function()
		local k    = index.canonical_key(spec30, "/components/schemas/UserId")
		local refs = index.get_references(k)
		assert.is_true(#refs >= 2, "expected >= 2 refs to UserId, got " .. #refs)
	end)

	it("UserSummary has at least one reference", function()
		local k    = index.canonical_key(spec30, "/components/schemas/UserSummary")
		local refs = index.get_references(k)
		assert.is_true(#refs >= 1, "expected >= 1 ref to UserSummary, got " .. #refs)
	end)

	it("cross-file User.yaml has at least one reference", function()
		local k    = index.canonical_key(user_yaml, nil)
		local refs = index.get_references(k)
		assert.is_true(#refs >= 1, "expected >= 1 ref to User.yaml, got " .. #refs)
	end)

	it("reference entries have required fields", function()
		local k    = index.canonical_key(spec30, "/components/schemas/UserId")
		local refs = index.get_references(k)
		assert.is_true(#refs > 0)
		local ref = refs[1]
		assert.is_not_nil(ref.file)
		assert.is_not_nil(ref.line)
		assert.is_not_nil(ref.col)
		assert.is_not_nil(ref.text)
	end)

	it("reference text contains $ref", function()
		local k    = index.canonical_key(spec30, "/components/schemas/UserId")
		local refs = index.get_references(k)
		assert.is_true(#refs > 0)
		for _, r in ipairs(refs) do
			assert.is_not_nil(r.text:find("%$ref"), "reference text should contain $ref: " .. r.text)
		end
	end)

	it("returns empty table for a key with no references", function()
		local k    = index.canonical_key(spec30, "/no/such/key")
		local refs = index.get_references(k)
		assert.are.same({}, refs)
	end)
end)

-- ── ensure_indexed — OpenAPI 3.1 YAML ────────────────────────────────────────

describe("ensure_indexed — OpenAPI 3.1 YAML", function()
	before_each(function()
		use_fixture_root()
		reset_index()
		index.ensure_indexed(fs.path_to_uri(spec31), root_markers)
	end)

	after_each(function()
		restore_get_root()
	end)

	it("indexes openapi31.yaml", function()
		assert.is_true(index._indexed_files[spec31] ~= nil, "openapi31.yaml should be indexed")
	end)

	it("3.1 UserId definition is found", function()
		local k   = index.canonical_key(spec31, "/components/schemas/UserId")
		local def = index.get_definition(k)
		assert.is_not_nil(def, "3.1 UserId should be indexed")
	end)

	it("3.1 Metadata (nullable type array) definition is found", function()
		local k   = index.canonical_key(spec31, "/components/schemas/Metadata")
		local def = index.get_definition(k)
		assert.is_not_nil(def, "3.1 Metadata should be indexed")
	end)

	it("3.1 UserEvent definition is found", function()
		local k   = index.canonical_key(spec31, "/components/schemas/UserEvent")
		local def = index.get_definition(k)
		assert.is_not_nil(def, "3.1 UserEvent should be indexed")
	end)

	it("3.1 webhook $ref to UserSummary is captured as a reference", function()
		local k    = index.canonical_key(spec31, "/components/schemas/UserSummary")
		local refs = index.get_references(k)
		assert.is_true(#refs >= 1, "UserSummary should be referenced from 3.1 spec")
	end)
end)

-- ── ensure_indexed — JSON format ──────────────────────────────────────────────

describe("ensure_indexed — JSON format", function()
	before_each(function()
		use_fixture_root()
		reset_index()
		index.ensure_indexed(fs.path_to_uri(spec_json), root_markers)
	end)

	after_each(function()
		restore_get_root()
	end)

	it("indexes openapi30.json", function()
		assert.is_true(index._indexed_files[spec_json] ~= nil, "openapi30.json should be indexed")
	end)

	it("Widget definition from JSON is found", function()
		local k   = index.canonical_key(spec_json, "/components/schemas/Widget")
		local def = index.get_definition(k)
		assert.is_not_nil(def, "Widget should be indexed from JSON spec")
	end)

	it("WidgetId has references in JSON spec", function()
		local k    = index.canonical_key(spec_json, "/components/schemas/WidgetId")
		local refs = index.get_references(k)
		assert.is_true(#refs >= 1, "WidgetId should have references in JSON spec")
	end)
end)

-- ── mtime caching ─────────────────────────────────────────────────────────────

describe("mtime caching", function()
	before_each(function()
		use_fixture_root()
		reset_index()
	end)

	after_each(function()
		restore_get_root()
	end)

	it("records mtime for each indexed file", function()
		index.ensure_indexed(spec30_uri, root_markers)
		for f in pairs(index._indexed_files) do
			assert.is_not_nil(index._indexed_files[f])
			assert.is_true(index._indexed_files[f] >= 0)
		end
	end)

	it("calling ensure_indexed twice does not duplicate references", function()
		index.ensure_indexed(spec30_uri, root_markers)
		local k      = index.canonical_key(spec30, "/components/schemas/UserId")
		local count1 = #index.get_references(k)

		index.ensure_indexed(spec30_uri, root_markers)  -- second call — mtime unchanged
		local count2 = #index.get_references(k)

		assert.are.equal(count1, count2, "double index should not duplicate refs")
	end)
end)

-- ── invalidate ────────────────────────────────────────────────────────────────

describe("invalidate", function()
	before_each(function()
		use_fixture_root()
		reset_index()
		index.ensure_indexed(spec30_uri, root_markers)
	end)

	after_each(function()
		restore_get_root()
	end)

	it("does not crash", function()
		assert.has_no.errors(function()
			index.invalidate(spec30)
		end)
	end)

	it("re-indexes the file immediately after invalidation", function()
		index.invalidate(spec30)
		assert.is_not_nil(index._indexed_files[spec30], "file should be re-indexed immediately after invalidate")
		assert.is_true(index._indexed_files[spec30] >= 0)
	end)

	it("removes stale definitions then restores them via re-index", function()
		local k = index.canonical_key(spec30, "/components/schemas/UserId")
		assert.is_not_nil(index.get_definition(k), "definition should exist before invalidate")
		index.invalidate(spec30)
		-- File still exists on disk, so it's re-indexed immediately
		local def_after = index.get_definition(k)
		assert.is_not_nil(def_after, "definition should be re-indexed after invalidate")
	end)
end)

-- ── get_pointer_at ────────────────────────────────────────────────────────────

describe("get_pointer_at", function()
	local test_uri = "file:///tmp/openapi-test-pointer.yaml"

	after_each(function()
		store.close(test_uri)
	end)

	it("returns nil for an empty document", function()
		store.open(test_uri, "", 1)
		local pointer = index.get_pointer_at(test_uri, { line = 0, character = 0 })
		assert.has_no.errors(function()
			index.get_pointer_at(test_uri, { line = 0, character = 0 })
		end)
		-- May be nil or any value — just must not crash
		_ = pointer
	end)

	it("returns pointer for cursor on a top-level key", function()
		local lines = {
			"openapi: '3.0.3'",
			"info:",
			"  title: Test",
			"components:",
			"  schemas:",
			"    User:",
			"      type: object",
		}
		store.open(test_uri, table.concat(lines, "\n"), 1)
		-- Cursor on line index 5 (0-indexed) = "    User:"
		local pointer = index.get_pointer_at(test_uri, { line = 5, character = 4 })
		assert.is_not_nil(pointer)
		assert.is_not_nil(pointer:find("User"), "pointer should include User, got: " .. tostring(pointer))
	end)

	it("pointer reflects nesting depth", function()
		local lines = {
			"components:",
			"  schemas:",
			"    UserId:",
			"      type: integer",
		}
		store.open(test_uri, table.concat(lines, "\n"), 1)
		-- Cursor on line index 2 (0-indexed) = "    UserId:"
		local pointer = index.get_pointer_at(test_uri, { line = 2, character = 4 })
		assert.is_not_nil(pointer)
		assert.are.equal("/components/schemas/UserId", pointer)
	end)

	it("pointer updates correctly when cursor moves to a sibling", function()
		local lines = {
			"components:",
			"  schemas:",
			"    UserId:",
			"      type: integer",
			"    UserName:",
			"      type: string",
		}
		store.open(test_uri, table.concat(lines, "\n"), 1)
		-- Cursor on line index 4 (0-indexed) = "    UserName:"
		local pointer = index.get_pointer_at(test_uri, { line = 4, character = 4 })
		assert.are.equal("/components/schemas/UserName", pointer)
	end)

	it("pointer on a deeply nested property", function()
		local lines = {
			"components:",
			"  schemas:",
			"    User:",
			"      properties:",
			"        email:",
			"          type: string",
		}
		store.open(test_uri, table.concat(lines, "\n"), 1)
		-- Cursor on line index 4 (0-indexed) = "        email:"
		local pointer = index.get_pointer_at(test_uri, { line = 4, character = 8 })
		assert.are.equal("/components/schemas/User/properties/email", pointer)
	end)
end)
