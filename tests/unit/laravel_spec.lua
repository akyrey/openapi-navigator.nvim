-- Tests for server/laravel.lua

local laravel = require("laravel")
local json = require("json")
local fs = require("fs")

-- Resolve fixture paths (handles /tmp→/private/tmp on macOS)
local fixture_dir =
	vim.fn.resolve(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h") .. "/fixtures/laravel")

-- Load the sample route list once
local route_list_path = fixture_dir .. "/artisan-route-list.json"
local routes_json = fs.read_file(route_list_path)
local ALL_ROUTES = json.decode(routes_json)

-- ── _normalize_uri ────────────────────────────────────────────────────────────

describe("_normalize_uri", function()
	it("strips leading slash and lowercases", function()
		assert.are.equal("api/users", laravel._normalize_uri("/api/users"))
		assert.are.equal("api/users", laravel._normalize_uri("api/USERS"))
	end)

	it("replaces {param} names with {}", function()
		assert.are.equal("api/users/{}", laravel._normalize_uri("api/users/{id}"))
		assert.are.equal("api/users/{}", laravel._normalize_uri("api/users/{userId}"))
	end)

	it("handles multiple params", function()
		assert.are.equal(
			"api/users/{}/addresses/{}",
			laravel._normalize_uri("/api/users/{userId}/addresses/{addressId}")
		)
	end)
end)

-- ── _get_route_methods ────────────────────────────────────────────────────────

describe("_get_route_methods", function()
	it("parses pipe-delimited method string (Laravel ≤10)", function()
		local route = { method = "GET|HEAD" }
		local methods = laravel._get_route_methods(route)
		assert.are.same({ "GET", "HEAD" }, methods)
	end)

	it("parses methods array (Laravel 11+)", function()
		local route = { methods = { "GET", "HEAD" } }
		local methods = laravel._get_route_methods(route)
		assert.are.same({ "GET", "HEAD" }, methods)
	end)

	it("returns empty table when neither field is present", function()
		local methods = laravel._get_route_methods({})
		assert.are.same({}, methods)
	end)
end)

-- ── _parse_paths_pointer ──────────────────────────────────────────────────────

describe("_parse_paths_pointer", function()
	it("detects method-level pointer", function()
		local path, method = laravel._parse_paths_pointer("/paths//users/{id}/get")
		assert.are.equal("/users/{id}", path)
		assert.are.equal("get", method)
	end)

	it("detects path-level pointer (no method)", function()
		local path, method = laravel._parse_paths_pointer("/paths//users/{id}")
		assert.are.equal("/users/{id}", path)
		assert.is_nil(method)
	end)

	it("returns nil for non-paths pointers", function()
		local path, method = laravel._parse_paths_pointer("/components/schemas/User")
		assert.is_nil(path)
		assert.is_nil(method)
	end)

	it("returns nil for root pointer", function()
		local path, method = laravel._parse_paths_pointer("/info/title")
		assert.is_nil(path)
		assert.is_nil(method)
	end)

	it("handles nested path with HTTP method", function()
		local path, method = laravel._parse_paths_pointer("/paths//api/v2/users/{userId}/addresses/{addressId}/get")
		assert.are.equal("/api/v2/users/{userId}/addresses/{addressId}", path)
		assert.are.equal("get", method)
	end)

	it("handles path ending in a non-method segment", function()
		-- e.g. cursor is on the path key whose last segment looks like a word
		local path, method = laravel._parse_paths_pointer("/paths//users/{id}/profile")
		assert.are.equal("/users/{id}/profile", path)
		assert.is_nil(method)
	end)
end)

-- ── match_route ───────────────────────────────────────────────────────────────

describe("match_route", function()
	it("matches GET /users/{id} with path_prefix 'api'", function()
		local matches = laravel.match_route("/users/{id}", "get", ALL_ROUTES, "api")
		assert.are.equal(1, #matches)
		assert.are.equal("App\\Http\\Controllers\\UserController@show", matches[1].action)
	end)

	it("matches POST /users with path_prefix 'api'", function()
		local matches = laravel.match_route("/users", "post", ALL_ROUTES, "api")
		assert.are.equal(1, #matches)
		assert.are.equal("App\\Http\\Controllers\\UserController@store", matches[1].action)
	end)

	it("ignores {param} name differences", function()
		-- spec says {id}, Laravel route uses {user} — should still match
		local matches = laravel.match_route("/users/{id}", "delete", ALL_ROUTES, "api")
		assert.are.equal(1, #matches)
		assert.are.equal("App\\Http\\Controllers\\UserController@destroy", matches[1].action)
	end)

	it("returns all non-HEAD methods when method is nil (path-level)", function()
		local matches = laravel.match_route("/users", nil, ALL_ROUTES, "api")
		-- Should find GET (index) and POST (store) but not HEAD-only entries
		assert.is_true(#matches >= 2)
		-- No pure-HEAD-only route should appear
		for _, m in ipairs(matches) do
			local methods = laravel._get_route_methods(m)
			local has_non_head = false
			for _, verb in ipairs(methods) do
				if verb ~= "HEAD" then
					has_non_head = true
				end
			end
			assert.is_true(has_non_head)
		end
	end)

	it("matches using the 'methods' array format (Laravel 11+)", function()
		local matches = laravel.match_route("/v2/users/{userId}/addresses/{addressId}", "get", ALL_ROUTES, "api")
		assert.are.equal(1, #matches)
		assert.are.equal("App\\Http\\Controllers\\V2\\AddressController@show", matches[1].action)
	end)

	it("returns empty table when no route matches", function()
		local matches = laravel.match_route("/nonexistent", "get", ALL_ROUTES, "api")
		assert.are.same({}, matches)
	end)

	it("returns empty table when method does not match", function()
		local matches = laravel.match_route("/users/{id}", "post", ALL_ROUTES, "api")
		assert.are.same({}, matches)
	end)

	it("matches without prefix when path_prefix is empty", function()
		-- Routes with "api/" prefix won't match when prefix is ""
		local matches = laravel.match_route("/api/users/{id}", "get", ALL_ROUTES, "")
		assert.are.equal(1, #matches)
	end)
end)

-- ── resolve_action ────────────────────────────────────────────────────────────

describe("resolve_action", function()
	it("resolves UserController@show to file:line", function()
		local loc = laravel.resolve_action(fixture_dir, "App\\Http\\Controllers\\UserController@show")
		assert.is_not_nil(loc)
		assert.is_not_nil(loc.file)
		assert.is_not_nil(loc.line)
		assert.is_true(loc.file:match("UserController%.php$") ~= nil)
		-- The function is declared somewhere in the file
		local lines = fs.read_lines(loc.file)
		assert.is_true(lines[loc.line]:match("function%s+show") ~= nil)
	end)

	it("resolves UserController@index correctly", function()
		local loc = laravel.resolve_action(fixture_dir, "App\\Http\\Controllers\\UserController@index")
		assert.is_not_nil(loc)
		local lines = fs.read_lines(loc.file)
		assert.is_true(lines[loc.line]:match("function%s+index") ~= nil)
	end)

	it("resolves a nested namespace (V2\\AddressController@show)", function()
		local loc = laravel.resolve_action(fixture_dir, "App\\Http\\Controllers\\V2\\AddressController@show")
		assert.is_not_nil(loc)
		assert.is_true(loc.file:match("AddressController%.php$") ~= nil)
	end)

	it("returns nil for Closure", function()
		local loc = laravel.resolve_action(fixture_dir, "Closure")
		assert.is_nil(loc)
	end)

	it("returns nil for nil action", function()
		local loc = laravel.resolve_action(fixture_dir, nil)
		assert.is_nil(loc)
	end)

	it("returns nil when class file does not exist", function()
		local loc = laravel.resolve_action(fixture_dir, "App\\Http\\Controllers\\Ghost\\MissingController@show")
		assert.is_nil(loc)
	end)

	it("returns nil when method not found in file", function()
		local loc = laravel.resolve_action(fixture_dir, "App\\Http\\Controllers\\UserController@nonExistentMethod")
		assert.is_nil(loc)
	end)
end)
