--- Structured logger — all output goes to stderr so stdout stays clean for LSP frames.
--- Neovim pipes the server's stderr into :LspLog automatically.

local M = {}

local LOG_LEVELS = { DEBUG = 0, INFO = 1, WARN = 2, ERROR = 3 }
local current_level = LOG_LEVELS.INFO

--- Set the minimum log level. Messages below this level are suppressed.
--- @param level string  "DEBUG"|"INFO"|"WARN"|"ERROR"
function M.set_level(level)
	current_level = LOG_LEVELS[level] or LOG_LEVELS.INFO
end

local function write(level_name, msg, ...)
	if (LOG_LEVELS[level_name] or 0) < current_level then
		return
	end
	local text = type(msg) == "string" and msg or tostring(msg)
	if select("#", ...) > 0 then
		-- Format remaining args into the message
		local ok, formatted = pcall(string.format, text, ...)
		text = ok and formatted or (text .. " " .. table.concat({ ... }, " "))
	end
	io.stderr:write(string.format("[openapi-lsp] [%s] %s\n", level_name, text))
	io.stderr:flush()
end

function M.debug(msg, ...) write("DEBUG", msg, ...) end
function M.info(msg, ...)  write("INFO",  msg, ...) end
function M.warn(msg, ...)  write("WARN",  msg, ...) end
function M.error(msg, ...) write("ERROR", msg, ...) end

return M
