--- openapi-navigator.nvim — Minimal HTTP server for the OpenAPI preview.
--- Built on vim.loop (libuv TCP) — no external dependencies.
--- Serves the RapiDoc HTML page, the spec file, static spec files for $ref
--- resolution, and an SSE endpoint for live reload.

local html = require("openapi-navigator.preview.html")
local sse = require("openapi-navigator.preview.sse")

local M = {}

-- ── State ─────────────────────────────────────────────────────────────────────

local _server = nil   -- uv_tcp_t server handle
local _port = nil     -- bound port (integer)
local _opts = {}      -- { spec_root, main_spec, theme }
local _connections = {} -- list of active client handles

-- ── Helpers ───────────────────────────────────────────────────────────────────

--- Detect Content-Type from a file extension.
--- @param path string
--- @return string
local function content_type(path)
	if path:match("%.ya?ml$") then
		return "text/yaml; charset=utf-8"
	elseif path:match("%.json$") then
		return "application/json; charset=utf-8"
	else
		return "application/octet-stream"
	end
end

--- Build an HTTP response string.
--- @param status string  e.g. "200 OK"
--- @param headers table  list of "Name: Value" strings
--- @param body string
--- @return string
local function http_response(status, headers, body)
	local parts = { "HTTP/1.1 " .. status .. "\r\n" }
	for _, h in ipairs(headers) do
		parts[#parts + 1] = h .. "\r\n"
	end
	parts[#parts + 1] = "\r\n"
	parts[#parts + 1] = body
	return table.concat(parts)
end

--- Send a simple text/plain error response and close the connection.
--- @param client userdata
--- @param status string
--- @param message string
local function send_error(client, status, message)
	local body = status .. ": " .. message
	local resp = http_response(status, {
		"Content-Type: text/plain; charset=utf-8",
		"Content-Length: " .. #body,
		"Connection: close",
	}, body)
	pcall(function()
		client:write(resp, function()
			if not client:is_closing() then
				client:close()
			end
		end)
	end)
end

--- Percent-decode a URL path component.
--- @param s string
--- @return string
local function url_decode(s)
	return (s:gsub("%%(%x%x)", function(h)
		return string.char(tonumber(h, 16))
	end))
end

--- Resolve a URL path to an absolute filesystem path under spec_root.
--- Returns nil if the resolved path escapes spec_root (path traversal guard).
--- @param spec_root string  absolute path to spec root directory
--- @param url_path string   URL path starting with "/"
--- @return string|nil
local function safe_path(spec_root, url_path)
	-- Strip query string
	local path = url_path:match("^([^?]*)") or url_path
	path = url_decode(path)

	-- Normalise: collapse ".." and "." segments
	local segments = {}
	for seg in path:gmatch("[^/]+") do
		if seg == ".." then
			if #segments > 0 then
				table.remove(segments)
			end
		elseif seg ~= "." and seg ~= "" then
			table.insert(segments, seg)
		end
	end
	local rel = table.concat(segments, "/")
	local abs = spec_root .. "/" .. rel

	-- Canonicalise to catch symlinks (best-effort; realpath may fail)
	local real = vim.loop.fs_realpath(abs)
	if real then
		abs = real
	end
	local real_root = vim.loop.fs_realpath(spec_root) or spec_root

	-- Ensure the resolved path is inside spec_root
	if abs == real_root or vim.startswith(abs, real_root .. "/") then
		return abs
	end
	return nil
end

--- Read a file from disk and return its contents, or nil on error.
--- @param path string
--- @return string|nil
local function read_file(path)
	local fd, err = vim.loop.fs_open(path, "r", 438) -- 0666
	if not fd then
		return nil, err
	end
	local stat = vim.loop.fs_fstat(fd)
	if not stat then
		vim.loop.fs_close(fd)
		return nil, "fstat failed"
	end
	local data = vim.loop.fs_read(fd, stat.size, 0)
	vim.loop.fs_close(fd)
	return data
end

-- ── Request routing ───────────────────────────────────────────────────────────

--- Handle a single parsed HTTP request.
--- @param client userdata  uv_tcp_t
--- @param method string
--- @param raw_path string  URL path (may include query string)
local function route(client, method, raw_path)
	if method ~= "GET" then
		send_error(client, "405 Method Not Allowed", "only GET is supported")
		return
	end

	-- Strip query string for routing
	local path = raw_path:match("^([^?]*)") or raw_path

	-- ── GET / ─────────────────────────────────────────────────────────────────
	if path == "/" then
		local body = html.render({ theme = _opts.theme or "dark" })
		local resp = http_response("200 OK", {
			"Content-Type: text/html; charset=utf-8",
			"Content-Length: " .. #body,
			"Connection: keep-alive",
			"Cache-Control: no-store",
		}, body)
		pcall(function()
			client:write(resp, function()
				if not client:is_closing() then
					client:close()
				end
			end)
		end)
		return
	end

	-- ── GET /events (SSE) ─────────────────────────────────────────────────────
	if path == "/events" then
		local headers = table.concat({
			"HTTP/1.1 200 OK\r\n",
			"Content-Type: text/event-stream\r\n",
			"Cache-Control: no-cache\r\n",
			"Connection: keep-alive\r\n",
			"Access-Control-Allow-Origin: *\r\n",
			"\r\n",
		})
		pcall(function()
			client:write(headers)
		end)
		-- Hand the connection to the SSE manager — it now owns the handle
		sse.add_client(client)
		return
	end

	-- ── GET /spec (main spec file) ────────────────────────────────────────────
	if path == "/spec" then
		local data, err = read_file(_opts.main_spec)
		if not data then
			send_error(client, "500 Internal Server Error", "could not read spec: " .. (err or "unknown"))
			return
		end
		local ct = content_type(_opts.main_spec)
		local resp = http_response("200 OK", {
			"Content-Type: " .. ct,
			"Content-Length: " .. #data,
			"Connection: close",
			"Cache-Control: no-store",
			"Access-Control-Allow-Origin: *",
		}, data)
		pcall(function()
			client:write(resp, function()
				if not client:is_closing() then
					client:close()
				end
			end)
		end)
		return
	end

	-- ── GET /* (static files for $ref resolution) ─────────────────────────────
	local abs = safe_path(_opts.spec_root, path)
	if not abs then
		send_error(client, "403 Forbidden", "path outside spec root")
		return
	end

	local data, err = read_file(abs)
	if not data then
		send_error(client, "404 Not Found", "file not found: " .. (err or "unknown"))
		return
	end

	local ct = content_type(abs)
	local resp = http_response("200 OK", {
		"Content-Type: " .. ct,
		"Content-Length: " .. #data,
		"Connection: close",
		"Cache-Control: no-store",
		"Access-Control-Allow-Origin: *",
	}, data)
	pcall(function()
		client:write(resp, function()
			if not client:is_closing() then
				client:close()
			end
		end)
	end)
end

-- ── Connection handler ────────────────────────────────────────────────────────

--- Accept and process a single TCP connection.
--- @param client userdata  uv_tcp_t
local function handle_connection(client)
	table.insert(_connections, client)

	local buf = ""

	client:read_start(function(err, data)
		if err or not data then
			-- Client disconnected
			if not client:is_closing() then
				client:close()
			end
			-- Remove from _connections list
			for i, c in ipairs(_connections) do
				if c == client then
					table.remove(_connections, i)
					break
				end
			end
			return
		end

		buf = buf .. data

		-- Wait until we have the full HTTP headers (terminated by \r\n\r\n)
		if not buf:find("\r\n\r\n", 1, true) then
			return
		end

		-- Stop reading — we only care about the request line
		client:read_stop()

		local request_line = buf:match("^(.-)\r\n")
		if not request_line then
			send_error(client, "400 Bad Request", "malformed request")
			return
		end

		local method, path = request_line:match("^(%u+)%s+(%S+)")
		if not method or not path then
			send_error(client, "400 Bad Request", "malformed request line")
			return
		end

		route(client, method, path)
	end)
end

-- ── Public API ────────────────────────────────────────────────────────────────

--- Start the HTTP server.
--- @param opts table  { port: integer, spec_root: string, main_spec: string, theme: string }
--- @param on_ready fun(port: integer)|nil  called once the server is bound
function M.start(opts, on_ready)
	if _server then
		return -- already running
	end

	_opts = opts
	_connections = {}

	local server = vim.loop.new_tcp()
	server:bind("127.0.0.1", opts.port or 0)

	local _, bind_err = server:listen(128, function(err)
		if err then
			vim.notify("openapi-navigator preview: listen error: " .. err, vim.log.levels.ERROR)
			return
		end
		local client = vim.loop.new_tcp()
		server:accept(client)
		handle_connection(client)
	end)

	if bind_err then
		vim.notify("openapi-navigator preview: bind error: " .. bind_err, vim.log.levels.ERROR)
		server:close()
		return
	end

	local addr = server:getsockname()
	_port = addr and addr.port
	_server = server

	if on_ready then
		on_ready(_port)
	end
end

--- Stop the HTTP server and close all connections.
function M.stop()
	-- Send shutdown SSE event and close all SSE clients
	sse.close_all()

	-- Close all non-SSE connections
	for _, c in ipairs(_connections) do
		if not c:is_closing() then
			c:close()
		end
	end
	_connections = {}

	if _server and not _server:is_closing() then
		_server:close()
	end
	_server = nil
	_port = nil
	_opts = {}
end

--- Return the port the server is bound to, or nil if not running.
--- @return integer|nil
function M.get_port()
	return _port
end

--- Return true if the server is currently running.
--- @return boolean
function M.is_running()
	return _server ~= nil
end

return M
