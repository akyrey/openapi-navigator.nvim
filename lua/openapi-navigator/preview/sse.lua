--- openapi-navigator.nvim — Server-Sent Events subscriber manager.
--- Maintains a list of connected browser clients and broadcasts reload events.

local M = {}

-- List of active SSE clients: { handle: uv_tcp_t, timer: uv_timer_t }
local _clients = {}

-- Heartbeat interval in milliseconds (30 seconds)
local HEARTBEAT_MS = 30000

--- Write data to a TCP handle, returning false if the write fails.
--- @param handle userdata  uv_tcp_t
--- @param data string
--- @return boolean
local function safe_write(handle, data)
	if not handle or handle:is_closing() then
		return false
	end
	local ok = pcall(function()
		handle:write(data)
	end)
	return ok
end

--- Register a new SSE subscriber.
--- The HTTP server calls this after writing the SSE response headers.
--- @param handle userdata  uv_tcp_t — already connected, headers already sent
function M.add_client(handle)
	-- Send an initial comment to confirm the connection
	safe_write(handle, ": connected\n\n")

	-- Start a heartbeat timer to keep the connection alive
	local timer = vim.loop.new_timer()
	timer:start(HEARTBEAT_MS, HEARTBEAT_MS, function()
		if not safe_write(handle, ": heartbeat\n\n") then
			M.remove_client(handle)
		end
	end)

	table.insert(_clients, { handle = handle, timer = timer })
end

--- Unregister an SSE subscriber and stop its heartbeat timer.
--- @param handle userdata  uv_tcp_t
function M.remove_client(handle)
	for i, client in ipairs(_clients) do
		if client.handle == handle then
			-- Stop and close the timer
			if client.timer and not client.timer:is_closing() then
				client.timer:stop()
				client.timer:close()
			end
			table.remove(_clients, i)
			return
		end
	end
end

--- Broadcast an SSE event to all subscribers.
--- Dead clients (closed handles) are removed automatically.
--- @param event_data string  e.g. "reload" or "shutdown"
function M.broadcast(event_data)
	local frame = "data: " .. event_data .. "\n\n"
	local dead = {}

	for _, client in ipairs(_clients) do
		if not safe_write(client.handle, frame) then
			table.insert(dead, client.handle)
		end
	end

	for _, handle in ipairs(dead) do
		M.remove_client(handle)
	end
end

--- Close all SSE connections and stop all timers.
--- Called when the preview server is stopped.
function M.close_all()
	-- Attempt a graceful shutdown event before closing
	for _, client in ipairs(_clients) do
		safe_write(client.handle, "data: shutdown\n\n")
		if client.timer and not client.timer:is_closing() then
			client.timer:stop()
			client.timer:close()
		end
		if not client.handle:is_closing() then
			client.handle:close()
		end
	end
	_clients = {}
end

--- Return the number of currently connected SSE clients.
--- Useful for testing.
--- @return integer
function M.client_count()
	return #_clients
end

return M
