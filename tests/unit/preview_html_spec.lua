-- Tests for lua/openapi-navigator/preview/html.lua

local html = require("openapi-navigator.preview.html")

describe("html.render", function()
	it("returns a non-empty string", function()
		local result = html.render({})
		assert.is_string(result)
		assert.is_true(#result > 0)
	end)

	it("contains a rapi-doc element", function()
		local result = html.render({})
		assert.is_not_nil(result:find("<rapi%-doc", 1, false))
	end)

	it("sets spec-url to /spec", function()
		local result = html.render({})
		assert.is_not_nil(result:find('spec%-url="/spec"', 1, false))
	end)

	it("includes an EventSource for /events", function()
		local result = html.render({})
		assert.is_not_nil(result:find("EventSource", 1, true))
		assert.is_not_nil(result:find("/events", 1, true))
	end)

	it("sends reload when message data is 'reload'", function()
		local result = html.render({})
		assert.is_not_nil(result:find("reload", 1, true))
		assert.is_not_nil(result:find("spec%-url", 1, false))
	end)

	it("uses dark theme by default", function()
		local result = html.render({})
		assert.is_not_nil(result:find('theme="dark"', 1, true))
	end)

	it("uses light theme when specified", function()
		local result = html.render({ theme = "light" })
		assert.is_not_nil(result:find('theme="light"', 1, true))
		assert.is_nil(result:find('theme="dark"', 1, true))
	end)

	it("includes DOCTYPE and html tags", function()
		local result = html.render({})
		assert.is_not_nil(result:find("<!DOCTYPE html>", 1, true))
		assert.is_not_nil(result:find("<html", 1, true))
		assert.is_not_nil(result:find("</html>", 1, true))
	end)

	it("loads rapidoc from unpkg CDN", function()
		local result = html.render({})
		assert.is_not_nil(result:find("unpkg.com/rapidoc", 1, true))
	end)
end)
