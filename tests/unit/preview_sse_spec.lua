-- Tests for lua/openapi-navigator/preview/sse.lua
-- Uses mock TCP handles to test the subscriber list without a real network.

local sse = require("openapi-navigator.preview.sse")

-- ── Mock TCP handle ────────────────────────────────────────────────────────────

--- Build a minimal mock that tracks written data and close state.
--- @return table
local function make_handle()
	local h = {
		_closed = false,
		_written = {},
		_should_fail = false,
	}

	function h:is_closing()
		return self._closed
	end

	function h:close()
		self._closed = true
	end

	function h:write(data)
		if self._should_fail then
			error("write failed")
		end
		table.insert(self._written, data)
	end

	function h:last_written()
		return self._written[#self._written]
	end

	function h:all_written()
		return table.concat(self._written)
	end

	return h
end

-- ── Tests ─────────────────────────────────────────────────────────────────────

describe("sse", function()
	-- Reset SSE state between tests by closing all clients
	before_each(function()
		sse.close_all()
	end)

	after_each(function()
		sse.close_all()
	end)

	describe("add_client", function()
		it("increments client count", function()
			local h = make_handle()
			assert.equals(0, sse.client_count())
			sse.add_client(h)
			assert.equals(1, sse.client_count())
		end)

		it("sends an initial connected comment", function()
			local h = make_handle()
			sse.add_client(h)
			assert.is_not_nil(h:all_written():find(": connected", 1, true))
		end)
	end)

	describe("remove_client", function()
		it("decrements client count", function()
			local h = make_handle()
			sse.add_client(h)
			assert.equals(1, sse.client_count())
			sse.remove_client(h)
			assert.equals(0, sse.client_count())
		end)

		it("is a no-op for an unknown handle", function()
			local h = make_handle()
			-- Should not error
			sse.remove_client(h)
			assert.equals(0, sse.client_count())
		end)
	end)

	describe("broadcast", function()
		it("writes the SSE data frame to all clients", function()
			local h1 = make_handle()
			local h2 = make_handle()
			sse.add_client(h1)
			sse.add_client(h2)

			sse.broadcast("reload")

			assert.is_not_nil(h1:all_written():find("data: reload\n\n", 1, true))
			assert.is_not_nil(h2:all_written():find("data: reload\n\n", 1, true))
		end)

		it("removes dead clients that fail on write", function()
			local good = make_handle()
			local dead = make_handle()
			dead._should_fail = true

			sse.add_client(good)
			sse.add_client(dead)
			assert.equals(2, sse.client_count())

			sse.broadcast("reload")

			-- Dead client should have been removed
			assert.equals(1, sse.client_count())
		end)

		it("removes clients whose handles are already closing", function()
			local h = make_handle()
			sse.add_client(h)
			h._closed = true -- simulate closed handle

			sse.broadcast("test")

			assert.equals(0, sse.client_count())
		end)
	end)

	describe("close_all", function()
		it("closes all client handles", function()
			local h1 = make_handle()
			local h2 = make_handle()
			sse.add_client(h1)
			sse.add_client(h2)

			sse.close_all()

			assert.equals(0, sse.client_count())
			assert.is_true(h1._closed)
			assert.is_true(h2._closed)
		end)

		it("sends shutdown event before closing", function()
			local h = make_handle()
			sse.add_client(h)

			sse.close_all()

			assert.is_not_nil(h:all_written():find("data: shutdown", 1, true))
		end)

		it("is a no-op when there are no clients", function()
			-- Should not error
			sse.close_all()
			assert.equals(0, sse.client_count())
		end)
	end)
end)
