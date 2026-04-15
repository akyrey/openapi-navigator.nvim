--- JSON-RPC method dispatcher.
--- Routes incoming LSP requests and notifications to the appropriate handlers.

local json = require("json")
local store = require("document_store")
local index = require("index")
local resolver = require("resolver")
local hover_mod = require("hover")
local refs_mod = require("references")
local comp_mod = require("completion")
local laravel_mod = require("laravel")
local fs = require("fs")
local log = require("log")

local M = {}

-- ── Server state ──────────────────────────────────────────────────────────────

local _initialized = false
local _shutdown = false
local _init_options = {} -- passed from client via initialize params

--- Default configuration (overridden by initializationOptions).
local _config = {
	root_markers = {
		"openapi.yaml",
		"openapi.yml",
		"openapi.json",
		"swagger.yaml",
		"swagger.json",
	},
	hover = {
		max_width = 80,
		max_height = 30,
		max_depth = 2,
	},
	laravel = {
		enabled = true,
		cmd = { "php", "artisan", "route:list", "--json" },
		path_prefix = "",
	},
}

-- ── Response helpers ──────────────────────────────────────────────────────────

local function make_response(id, result)
	return {
		jsonrpc = "2.0",
		id = id,
		-- LSP requires "result" to be present (even as null) in every response.
		-- Lua nil table fields are omitted by pairs(), so we use json.null instead.
		result = (result == nil) and json.null or result,
	}
end

local function make_error(id, code, message)
	return {
		jsonrpc = "2.0",
		id = id,
		error = { code = code, message = message },
	}
end

-- Standard JSON-RPC / LSP error codes
local ERR_NOT_INITIALIZED = -32002
local ERR_INVALID_REQUEST = -32600
local ERR_METHOD_NOT_FOUND = -32601
local ERR_INTERNAL = -32603

-- ── Handler table ─────────────────────────────────────────────────────────────

local handlers = {}

-- initialize ──────────────────────────────────────────────────────────────────

handlers["initialize"] = function(id, params)
	_initialized = true

	-- Merge any options provided by the client
	if params and params.initializationOptions then
		local opts = params.initializationOptions
		if opts.root_markers then
			_config.root_markers = opts.root_markers
		end
		if opts.hover then
			for k, v in pairs(opts.hover) do
				_config.hover[k] = v
			end
		end
		if opts.laravel then
			for k, v in pairs(opts.laravel) do
				_config.laravel[k] = v
			end
		end
	end

	log.info("initialized (root_markers=%d)", #_config.root_markers)

	return make_response(id, {
		capabilities = {
			-- Full document sync: always receive full text on change
			textDocumentSync = {
				openClose = true,
				change = 1, -- TextDocumentSyncKind.Full
				save = { includeText = false },
			},
			definitionProvider = true,
			hoverProvider = true,
			referencesProvider = true,
			completionProvider = {
				-- Trigger on '#' (local ref) and '/' (deeper pointer path)
				triggerCharacters = { "#", "/" },
				resolveProvider = false,
			},
		},
		serverInfo = {
			name = "openapi-navigator",
			version = "2.0.0",
		},
	})
end

handlers["initialized"] = function(_id, _params)
	-- Notification — no response needed
	return nil
end

-- shutdown / exit ─────────────────────────────────────────────────────────────

handlers["shutdown"] = function(id, _params)
	_shutdown = true
	log.info("shutdown request received")
	return make_response(id, nil)
end

handlers["exit"] = function(_id, _params)
	log.info("exit notification received")
	os.exit(_shutdown and 0 or 1)
end

-- textDocument/didOpen ────────────────────────────────────────────────────────

handlers["textDocument/didOpen"] = function(_id, params)
	local doc = params.textDocument
	store.open(doc.uri, doc.text, doc.version)
	-- Kick off indexing for this file's workspace
	index.ensure_indexed(doc.uri, _config.root_markers)
	log.debug("didOpen %s", doc.uri)
	return nil
end

-- textDocument/didChange ──────────────────────────────────────────────────────

handlers["textDocument/didChange"] = function(_id, params)
	local doc = params.textDocument
	local changes = params.contentChanges
	if changes and #changes > 0 then
		-- We requested full sync (kind=1), so contentChanges[1].text is the full doc
		store.update(doc.uri, changes[1].text, doc.version)
		log.debug("didChange %s v%s", doc.uri, tostring(doc.version))
	end
	return nil
end

-- textDocument/didSave ────────────────────────────────────────────────────────

handlers["textDocument/didSave"] = function(_id, params)
	local uri = params.textDocument.uri
	local path = fs.resolve(fs.uri_to_path(uri))
	index.invalidate(path)
	log.debug("didSave %s", uri)
	return nil
end

-- textDocument/didClose ───────────────────────────────────────────────────────

handlers["textDocument/didClose"] = function(_id, params)
	store.close(params.textDocument.uri)
	log.debug("didClose %s", params.textDocument.uri)
	return nil
end

-- textDocument/definition ─────────────────────────────────────────────────────

handlers["textDocument/definition"] = function(id, params)
	local uri = params.textDocument.uri
	local position = params.position

	index.ensure_indexed(uri, _config.root_markers)

	local ref = resolver.parse_ref_at(uri, position)
	if not ref then
		-- No $ref at cursor — try Laravel route navigation
		if _config.laravel.enabled then
			local locs = laravel_mod.find_definition(uri, position, _config.laravel)
			if locs then
				-- Single location → scalar; multiple → array (Neovim shows picker)
				return make_response(id, #locs == 1 and locs[1] or locs)
			end
		end
		return make_response(id, nil)
	end

	local target_path = resolver.resolve_file(ref, uri)
	if not target_path then
		return make_response(id, nil)
	end

	local target_uri = fs.path_to_uri(target_path)

	if not ref.pointer then
		-- Cross-file ref with no pointer → jump to top of file
		return make_response(id, {
			uri = target_uri,
			range = { start = { line = 0, character = 0 }, ["end"] = { line = 0, character = 0 } },
		})
	end

	local pos = resolver.resolve_pointer(target_path, ref.pointer, target_uri)
	if not pos then
		return make_response(id, nil)
	end

	-- LSP positions are 0-indexed
	local lsp_line = pos.line - 1
	local lsp_col = pos.col

	return make_response(id, {
		uri = target_uri,
		range = {
			start = { line = lsp_line, character = lsp_col },
			["end"] = { line = lsp_line, character = lsp_col },
		},
	})
end

-- textDocument/hover ──────────────────────────────────────────────────────────

handlers["textDocument/hover"] = function(id, params)
	local uri = params.textDocument.uri
	local position = params.position

	local result = hover_mod.hover(uri, position, _config.hover)
	return make_response(id, result)
end

-- textDocument/references ─────────────────────────────────────────────────────

handlers["textDocument/references"] = function(id, params)
	local uri = params.textDocument.uri
	local position = params.position

	local locs = refs_mod.find(uri, position, _config.root_markers)
	return make_response(id, #locs > 0 and locs or nil)
end

-- textDocument/completion ────────────────────────────────────────────────────

handlers["textDocument/completion"] = function(id, params)
	local uri = params.textDocument.uri
	local position = params.position
	local items = comp_mod.complete(uri, position, _config.root_markers)
	return make_response(id, items)
end

-- workspace/didChangeWatchedFiles ─────────────────────────────────────────────

handlers["workspace/didChangeWatchedFiles"] = function(_id, params)
	for _, change in ipairs(params.changes or {}) do
		local path = fs.resolve(fs.uri_to_path(change.uri))
		index.invalidate(path)
		-- Invalidate Laravel routes cache when a routes/*.php file changes
		if path:match("/routes/[^/]+%.php$") then
			laravel_mod.invalidate_routes(path)
		end
		log.debug("watched file changed: %s", path)
	end
	return nil
end

-- $/cancelRequest — silently ignore ───────────────────────────────────────────

handlers["$/cancelRequest"] = function()
	return nil
end

-- ── Main dispatch ─────────────────────────────────────────────────────────────

--- Dispatch one decoded JSON-RPC message.
--- Returns a response table (to be sent) or nil (for notifications).
--- @param msg table  decoded JSON-RPC message
--- @return table|nil
function M.handle(msg)
	local method = msg.method
	local id = msg.id
	local params = msg.params

	if _shutdown and method ~= "exit" then
		if id then
			return make_error(id, ERR_INVALID_REQUEST, "server is shutting down")
		end
		return nil
	end

	if not _initialized and method ~= "initialize" and method ~= "exit" then
		if id then
			return make_error(id, ERR_NOT_INITIALIZED, "server not yet initialized")
		end
		return nil
	end

	local handler = handlers[method]
	if not handler then
		log.debug("unhandled method: %s", tostring(method))
		if id then
			return make_error(id, ERR_METHOD_NOT_FOUND, "method not found: " .. tostring(method))
		end
		return nil
	end

	local ok, result = pcall(handler, id, params)
	if not ok then
		log.error("handler error for %s: %s", tostring(method), tostring(result))
		if id then
			return make_error(id, ERR_INTERNAL, tostring(result))
		end
		return nil
	end

	return result
end

return M
