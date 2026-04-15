--- JSON-RPC 2.0 framing over stdio.
--- LSP uses: Content-Length: N\r\n\r\n<N bytes of JSON>

local json = require("json")
local log  = require("log")

local M = {}

--- Read one JSON-RPC message from the given file handle.
--- Returns the decoded Lua table, or nil on EOF / parse error.
--- @param input file*
--- @return table|nil
function M.read_message(input)
	-- Read headers until blank line
	local content_length = nil

	while true do
		local line = input:read("*l") -- reads one line, strips \n
		if line == nil then
			return nil -- EOF
		end

		-- Strip trailing \r if present (Content-Length: N\r\n → line = "Content-Length: N\r")
		line = line:gsub("\r$", "")

		if line == "" then
			-- Blank line: end of headers
			break
		end

		local name, value = line:match("^([%w%-]+):%s*(.+)$")
		if name and name:lower() == "content-length" then
			content_length = tonumber(value)
		end
	end

	if not content_length then
		log.warn("missing Content-Length header")
		return nil
	end

	local body = input:read(content_length)
	if not body or #body < content_length then
		log.warn("short read: expected %d bytes, got %d", content_length, body and #body or 0)
		return nil
	end

	local ok, msg = pcall(json.decode, body)
	if not ok then
		log.warn("JSON decode error: %s", msg)
		return nil
	end

	return msg
end

--- Write a JSON-RPC message to the given file handle.
--- @param output file*
--- @param msg table
function M.write_message(output, msg)
	local ok, body = pcall(json.encode, msg)
	if not ok then
		log.error("JSON encode error: %s", body)
		return
	end

	local frame = string.format("Content-Length: %d\r\n\r\n%s", #body, body)
	output:write(frame)
	output:flush()
end

return M
