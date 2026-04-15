--- In-memory store of open document contents.
--- Populated by textDocument/didOpen, updated by didChange, cleared by didClose.
--- Other modules read lines from here (preferred) or fall back to disk.

local M = {}

--- @type table<string, { text: string, version: integer, lines: string[] }>
local _store = {}

--- Split text into lines (handles \r\n and \n).
--- @param text string
--- @return string[]
local function split_lines(text)
	local lines = {}
	for line in (text .. "\n"):gmatch("([^\n]*)\n") do
		table.insert(lines, (line:gsub("\r$", "")))
	end
	if lines[#lines] == "" then
		table.remove(lines)
	end
	return lines
end

--- Store a new document (called on didOpen).
--- @param uri string
--- @param text string
--- @param version integer
function M.open(uri, text, version)
	_store[uri] = {
		text    = text,
		version = version or 0,
		lines   = split_lines(text),
	}
end

--- Replace the full text of a document (called on didChange with full sync).
--- @param uri string
--- @param text string
--- @param version integer
function M.update(uri, text, version)
	_store[uri] = {
		text    = text,
		version = version,
		lines   = split_lines(text),
	}
end

--- Remove a document from the store (called on didClose).
--- @param uri string
function M.close(uri)
	_store[uri] = nil
end

--- Check whether a document is currently open in the store.
--- @param uri string
--- @return boolean
function M.is_open(uri)
	return _store[uri] ~= nil
end

--- Get all lines of a document. Returns nil if not in store.
--- @param uri string
--- @return string[]|nil
function M.get_lines(uri)
	local doc = _store[uri]
	return doc and doc.lines or nil
end

--- Get a single line (1-indexed) from a document. Returns nil if not found.
--- @param uri string
--- @param lnum integer  1-indexed
--- @return string|nil
function M.get_line(uri, lnum)
	local doc = _store[uri]
	if not doc then return nil end
	return doc.lines[lnum]
end

--- Get the full text of a document. Returns nil if not in store.
--- @param uri string
--- @return string|nil
function M.get_text(uri)
	local doc = _store[uri]
	return doc and doc.text or nil
end

return M
