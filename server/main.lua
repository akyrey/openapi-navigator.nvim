#!/usr/bin/env luajit
--- openapi-navigator LSP server — entry point.
--- Reads JSON-RPC frames from stdin, dispatches to handlers, writes responses to stdout.

-- Add the server/ directory to the Lua module search path.
-- arg[0] is the path of this script (server/main.lua or the bin/ shim target).
local script_dir = arg[0]:match("^(.*/)") or "./"
-- Normalise: remove trailing slash duplication
script_dir = script_dir:gsub("//+", "/")
package.path = script_dir .. "?.lua;" .. package.path

local rpc        = require("rpc")
local dispatcher = require("dispatcher")
local log        = require("log")

-- Disable buffering on stdout so each frame is delivered immediately.
-- stderr is already line-buffered by default on most systems; keep it.
io.stdout:setvbuf("no")

log.info("openapi-navigator LSP server starting (PID %s)", tostring(
	(io.popen and io.popen("echo $$", "r") or {read = function() end}):read("*l") or "?"
))

while true do
	local msg = rpc.read_message(io.stdin)
	if not msg then
		-- EOF or fatal parse error — exit cleanly
		log.info("stdin closed, exiting")
		break
	end

	local ok, response = pcall(dispatcher.handle, msg)
	if not ok then
		log.error("unhandled dispatcher error: %s", tostring(response))
	elseif response then
		rpc.write_message(io.stdout, response)
	end
end
