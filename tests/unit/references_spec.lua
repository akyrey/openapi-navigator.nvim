-- Tests for references.lua — canonical key building and index lookup.
-- These tests exercise the logic that maps cursor position → canonical key,
-- which drives the find-references feature.

local index     = require("index")
local workspace = require("workspace")
local store     = require("document_store")
local resolver  = require("resolver")
local fs        = require("fs")

local fixture_dir = vim.fn.resolve(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h") .. "/fixtures")
local spec30    = vim.fn.resolve(fixture_dir .. "/openapi30.yaml")
local spec31    = vim.fn.resolve(fixture_dir .. "/openapi31.yaml")
local user_yaml = vim.fn.resolve(fixture_dir .. "/schemas/User.yaml")

local spec30_uri = fs.path_to_uri(spec30)
local spec31_uri = fs.path_to_uri(spec31)

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
	index._roots         = {}
end

-- ── canonical key building from a $ref line ───────────────────────────────────

describe("canonical key from $ref cursor position", function()
	local test_uri = "file:///tmp/openapi-test-refs-ckey.yaml"

	before_each(function()
		use_fixture_root()
		reset_index()
		index.ensure_indexed(spec30_uri, root_markers)
	end)

	after_each(function()
		store.close(test_uri)
		restore_get_root()
	end)

	it("same-file $ref resolves to the correct canonical key", function()
		store.open(test_uri, "  $ref: '#/components/schemas/UserId'", 1)
		local ref = resolver.parse_ref_at(test_uri, { line = 0, character = 5 })
		assert.is_not_nil(ref)
		assert.is_nil(ref.file)
		assert.are.equal("/components/schemas/UserId", ref.pointer)

		-- Build the canonical key as references.lua does: same-file ref → use source file
		local target_file = resolver.resolve_file(ref, spec30_uri)
		local ckey = index.canonical_key(target_file, ref.pointer)
		assert.are.equal(spec30 .. "::/components/schemas/UserId", ckey)
	end)

	it("cross-file $ref resolves to the absolute target file canonical key", function()
		store.open(test_uri, "  $ref: './schemas/User.yaml'", 1)
		local ref = resolver.parse_ref_at(test_uri, { line = 0, character = 5 })
		assert.is_not_nil(ref)
		assert.are.equal("./schemas/User.yaml", ref.file)

		-- resolve_file needs a URI whose dirname matches spec30's parent
		local target_file = resolver.resolve_file(ref, spec30_uri)
		local ckey = index.canonical_key(target_file, ref.pointer)
		assert.are.equal(user_yaml .. "::", ckey)
	end)

	it("cross-file $ref with pointer resolves to correct canonical key", function()
		store.open(test_uri, "  $ref: './schemas/User.yaml#/properties/email'", 1)
		local ref = resolver.parse_ref_at(test_uri, { line = 0, character = 5 })
		assert.is_not_nil(ref)
		assert.are.equal("./schemas/User.yaml", ref.file)
		assert.are.equal("/properties/email", ref.pointer)

		local target_file = resolver.resolve_file(ref, spec30_uri)
		local ckey = index.canonical_key(target_file, ref.pointer)
		assert.are.equal(user_yaml .. "::/properties/email", ckey)
	end)
end)

-- ── references found via the index ───────────────────────────────────────────

describe("reference lookup — OpenAPI 3.0", function()
	before_each(function()
		use_fixture_root()
		reset_index()
		index.ensure_indexed(spec30_uri, root_markers)
	end)

	after_each(function()
		restore_get_root()
	end)

	it("UserId has references in multiple locations", function()
		local k = index.canonical_key(spec30, "/components/schemas/UserId")
		local refs = index.get_references(k)
		assert.is_true(#refs >= 2)
		-- All refs should point back to files within the fixture dir
		for _, r in ipairs(refs) do
			assert.is_not_nil(
				r.file:find(fixture_dir, 1, true),
				"reference file should be inside fixture dir: " .. r.file
			)
		end
	end)

	it("Error schema has at least one reference", function()
		local k = index.canonical_key(spec30, "/components/schemas/Error")
		local refs = index.get_references(k)
		assert.is_true(#refs >= 1, "Error should have >= 1 reference")
	end)

	it("cross-file User.yaml target has a reference from openapi30.yaml", function()
		local k = index.canonical_key(user_yaml, nil)
		local refs = index.get_references(k)
		local from_spec = false
		for _, r in ipairs(refs) do
			if r.file == spec30 then
				from_spec = true
			end
		end
		assert.is_true(from_spec, "User.yaml should be referenced from openapi30.yaml")
	end)

	it("cross-file ref with pointer is captured", function()
		local k = index.canonical_key(user_yaml, "/properties/address")
		local refs = index.get_references(k)
		assert.is_true(#refs >= 1, "User.yaml#/properties/address should have at least one reference")
	end)
end)

describe("reference lookup — OpenAPI 3.1", function()
	before_each(function()
		use_fixture_root()
		reset_index()
		index.ensure_indexed(spec31_uri, root_markers)
	end)

	after_each(function()
		restore_get_root()
	end)

	it("3.1 UserSummary has references (including from webhook)", function()
		local k = index.canonical_key(spec31, "/components/schemas/UserSummary")
		local refs = index.get_references(k)
		assert.is_true(#refs >= 1, "3.1 UserSummary should be referenced")
		local found_in_spec31 = false
		for _, r in ipairs(refs) do
			if r.file == spec31 then
				found_in_spec31 = true
			end
		end
		assert.is_true(found_in_spec31, "UserSummary should be referenced within openapi31.yaml")
	end)

	it("3.1 Metadata has at least one reference", function()
		local k = index.canonical_key(spec31, "/components/schemas/Metadata")
		local refs = index.get_references(k)
		assert.is_true(#refs >= 1, "3.1 Metadata should be referenced from Item schema")
	end)

	it("3.1 path-item $ref to PathItem.yaml is captured", function()
		local path_item_yaml = vim.fn.resolve(fixture_dir .. "/schemas/PathItem.yaml")
		local k = index.canonical_key(path_item_yaml, nil)
		local refs = index.get_references(k)
		assert.is_true(#refs >= 1, "PathItem.yaml should be referenced from openapi31.yaml paths")
	end)
end)

-- ── get_pointer_at for definition-side references ─────────────────────────────

describe("pointer-at for definition lookup", function()
	local test_uri = "file:///tmp/openapi-test-refs-pointer.yaml"

	after_each(function()
		store.close(test_uri)
	end)

	it("cursor on a definition key produces a pointer matching expected refs", function()
		use_fixture_root()
		reset_index()
		index.ensure_indexed(spec30_uri, root_markers)

		-- Load spec30 contents into the document store
		local lines = vim.fn.readfile(spec30)
		store.open(test_uri, table.concat(lines, "\n"), 1)

		-- Find the line number for "    UserId:" in the loaded lines (1-indexed)
		local userid_line = nil
		for i, l in ipairs(lines) do
			if l:match("^    UserId:") then
				userid_line = i
				break
			end
		end
		assert.is_not_nil(userid_line, "should find UserId line in spec30")

		-- LSP position is 0-indexed
		local pointer = index.get_pointer_at(test_uri, { line = userid_line - 1, character = 4 })
		assert.is_not_nil(pointer)
		assert.is_not_nil(pointer:find("UserId"), "pointer should include UserId")

		-- Use this pointer to look up references (key is relative to spec30, not test_uri)
		local ckey = index.canonical_key(spec30, pointer)
		local refs = index.get_references(ckey)
		assert.is_true(#refs >= 2, "UserId should have multiple references when looked up by pointer")

		restore_get_root()
	end)
end)
