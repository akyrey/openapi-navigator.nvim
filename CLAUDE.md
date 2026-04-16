# openapi-navigator.nvim — Claude Code Guide

## Project overview

A pure-Lua Neovim plugin for navigating OpenAPI/Swagger specification files.
Implemented as a standalone LSP server (JSON-RPC 2.0 over stdio) so it
works with any LSP client keymap setup — `gd`, `K`, `gr` route through the
server automatically without keymap conflicts.

Complements yaml-language-server (validation/completion) with navigation
features: `$ref` go-to-definition, hover preview, and find-all-references.

No external binary dependencies. Neovim >= 0.9 required. The server is
launched via `nvim --headless -l server/main.lua` (uses Neovim's built-in
LuaJIT — no separate runtime needed).

## Directory layout

```
lua/openapi-navigator/
  init.lua        Thin Neovim client: OpenAPI detection, vim.lsp.start(), :OpenAPIPreview commands
  config.lua      Defaults + setup() merge (no keymaps — those come from user LSP config)
  preview/
    init.lua      Preview orchestrator: server lifecycle, browser open, BufWritePost hook
    http.lua      vim.loop TCP HTTP server (routes /, /events, /spec, /*)
    sse.lua       SSE subscriber manager: add_client, broadcast, heartbeat timers
    html.lua      RapiDoc HTML page template (pure function, no deps)
plugin/
  openapi-navigator.vim  Double-load guard
server/                  Standalone LSP server (no vim.* dependencies)
  main.lua        Entry point: stdio loop → dispatcher
  rpc.lua         JSON-RPC 2.0 framing (Content-Length headers)
  json.lua        Vendored pure-Lua JSON codec (rxi/json.lua, MIT)
  dispatcher.lua  Route LSP method → handler; owns capabilities table
  document_store.lua  In-memory store of open file contents (didOpen/didChange)
  workspace.lua   Root detection, file globbing via find(1), mtime cache
  resolver.lua    $ref parsing, file resolution, JSON pointer walking
  index.lua       Bidirectional ref index (definitions ↔ references tables)
  hover.lua       LSP Hover response builder with recursive $ref expansion
  references.lua  LSP Location[] response builder for find-all-references
  fs.lua          Pure-Lua file ops (read, resolve, URI↔path, mtime)
  log.lua         Stderr-only logger (stdout reserved for LSP frames)
bin/
  openapi-navigator-lsp  Shell shim (resolves server/main.lua relative to bin/)
tests/
  minimal_init.lua       Plenary harness: adds server/ to package.path
  unit/
    resolver_spec.lua    $ref parsing + JSON pointer resolution tests
    index_spec.lua       Index building, invalidation, get_pointer_at tests
    hover_spec.lua       Target-file resolution + block extraction tests
    references_spec.lua  Canonical key building + reference lookup tests
    config_spec.lua      Config defaults and merging tests
    preview_html_spec.lua  html.render output structure tests
    preview_sse_spec.lua   SSE subscriber list tests (mock TCP handles)
  fixtures/
    openapi30.yaml       Main 3.0 spec (same-file and cross-file $refs)
    openapi31.yaml       OpenAPI 3.1 spec (webhooks, nullable arrays, prefixItems)
    openapi30.json       JSON-format spec
    schemas/
      User.yaml          Cross-file target schema
      Address.yaml       Nested cross-file schema
      PathItem.yaml      3.1 path-item $ref target
```

## Key modules

### server/resolver.lua — the core engine

Everything else depends on this. Key functions:

- `parse_ref_from_line(line, is_json)` → `{raw, file, pointer} | nil` — extracts
  the `$ref` string using Lua pattern matching (no YAML parser).
- `parse_ref_at(uri, position)` → `{raw, file, pointer} | nil` — reads the line
  from `document_store` (falling back to disk) and calls `parse_ref_from_line`.
- `resolve_file(ref, source_uri)` → absolute path — resolves relative paths via
  `fs.resolve(fs.join(dirname, ref.file))`.
- `resolve_pointer(filepath, pointer, uri)` → `{line, col} | nil` — walks file
  lines tracking `parent_indent` to match JSON pointer segments without a YAML
  parser. Reads from store if available, else disk.

### server/index.lua — bidirectional ref index

Two hash tables built by scanning spec files:

- `_definitions[canonical_key]` = `{file, line, col}` — definition path → location
- `_references[canonical_key]`  = `[{file, line, col, text}]` — ref target → all usages

`canonical_key` format: `<abs_file_path>::<pointer_or_empty>`

`ensure_indexed(uri, root_markers)` is lazy and mtime-cached — only re-scans
changed files. Calls `workspace.get_root` to discover the spec root, then globs
all YAML/JSON files within it.

`get_pointer_at(uri, position)` — returns the JSON pointer for the key at the
given (0-indexed) LSP position, reading lines from `document_store`.

`invalidate(filepath)` — removes stale entries and immediately re-indexes the
file. Called by the dispatcher on `textDocument/didSave` and
`workspace/didChangeWatchedFiles`.

### server/dispatcher.lua — LSP method router

Handles: `initialize`, `initialized`, `shutdown`, `exit`,
`textDocument/didOpen`, `textDocument/didChange`, `textDocument/didSave`,
`textDocument/didClose`, `textDocument/definition`, `textDocument/hover`,
`textDocument/references`, `workspace/didChangeWatchedFiles`.

Config comes from `initializationOptions.root_markers` and
`initializationOptions.hover`.

### lua/openapi-navigator/init.lua — Neovim client

`is_openapi_buffer(bufnr, opts)` detects OpenAPI files in three steps:
1. Extension check (`.yaml`, `.yml`, `.json`).
2. Scan first 20 lines for `openapi:` / `swagger:` top-level key.
3. Walk parent directories for a root_marker (catches files in split specs).

`setup(opts)` registers a `FileType yaml,json` autocmd that calls
`vim.lsp.start()` for OpenAPI buffers. No keymaps are attached — the user's
existing `gd` / `K` / `gr` LSP mappings route through the server automatically.

Also registers `:OpenAPIPreview` and `:OpenAPIPreviewStop` user commands, and
notifies the preview server (`preview.notify_change()`) in the `BufWritePost`
autocmd when the preview is running.

### lua/openapi-navigator/preview/ — Browser preview

Four modules that together implement the live preview feature. All use `vim.*`
APIs and must NOT be required from the `server/` side.

- **preview/html.lua** — `M.render(opts)` returns the complete HTML string with
  a `<rapi-doc>` element (loaded from unpkg CDN) and an `EventSource('/events')`
  script that updates `spec-url` on each `reload` event. Pure function, zero deps.

- **preview/sse.lua** — SSE subscriber list. `add_client(handle)` registers a
  TCP connection and starts a 30-second heartbeat timer. `broadcast(event_data)`
  writes `data: <event>\n\n` to all subscribers and removes dead ones.
  `close_all()` sends a `shutdown` event and closes every connection.

- **preview/http.lua** — `vim.loop.new_tcp()` server. Binds to `127.0.0.1:<port>`
  (port 0 = OS-assigned). Parses the HTTP request line from a per-connection
  accumulation buffer (waits for `\r\n\r\n`). Routes:
  - `GET /` → HTML page
  - `GET /events` → SSE (keeps connection open, hands to sse.lua)
  - `GET /spec` → reads main spec file from disk
  - `GET /*` → static file from spec root with path traversal guard
    (`vim.loop.fs_realpath` + `vim.startswith` against canonical root)

- **preview/init.lua** — orchestrator. `start(bufnr)` resolves the spec root
  via `require("openapi-navigator").get_spec_root()`, finds the first existing
  root_marker file as the main spec, starts the HTTP server, and opens the
  browser (`vim.ui.open` → `open`/`xdg-open` fallbacks). `stop()` tears
  everything down. `VimLeavePre` autocmd ensures clean shutdown on exit.

## Design decisions

- **No YAML parser** — `$ref` extraction and JSON pointer resolution use Lua
  pattern matching on raw lines with indentation tracking. This handles 99% of
  real specs and avoids a dependency on lyaml or similar.
- **`string.gsub` returns two values** (`result, count`). Always capture into a
  local before passing to `table.insert` or other single-value contexts — the
  multi-value expansion turns a 2-arg call into a 3-arg call and triggers
  "bad argument #2 to 'insert' (number expected, got string)".
- **Canonical keys use absolute (resolved) paths** — `fs.resolve()` (wraps
  `realpath -m`) is applied consistently so `/tmp/...` and `/private/tmp/...`
  (macOS symlink) produce the same key.
- **LSP hover fallback is free** — `hover.hover()` returns `nil` when the cursor
  is not on a `$ref`. The LSP client naturally falls through to other servers
  (e.g. yaml-language-server) for non-`$ref` positions.
- **Runtime is `nvim --headless -l`** — every Neovim install ships with LuaJIT;
  no separate `luajit` binary is needed on PATH.
- **LuaJIT is Lua 5.1** — `json.lua` must use arithmetic instead of bitwise
  operators (`math.floor(n/64)` not `n >> 6`, etc.).
- **Synchronous indexing** — `fs.read_lines()` is fast enough for typical specs
  (<50 files). Async upgrade path: wrap `index_file()` calls without changing
  the public API.
- **Preview HTTP server lives in `lua/`, not `server/`** — it needs `vim.loop`
  and `vim.notify`, which are unavailable in the headless server process. The
  preview modules are only ever loaded inside the interactive Neovim session.
- **SSE over WebSocket for live reload** — SSE is a plain HTTP keep-alive
  response; no upgrade handshake required. Sufficient for one-way
  server→browser notifications and ~60 lines of Lua to implement.
- **RapiDoc loaded from CDN** — avoids bundling ~500 KB of JS in the repo.
  The browser caches it after the first load. Requires internet on first use.
- **Static file serving for multi-file `$ref` resolution** — RapiDoc resolves
  `$ref`s relative to `spec-url`. Serving the entire spec root as static files
  means cross-file refs work without any bundling or dereferencing step.

## Running tests

```bash
nvim --headless --noplugin \
  -u tests/minimal_init.lua \
  -c "PlenaryBustedDirectory tests/unit/ {minimal_init='tests/minimal_init.lua'}" \
  -c "qa!"
```

CI runs on Neovim v0.9.5, v0.10.3, and nightly (see `.github/workflows/ci.yml`).

## Framework adapter system — Laravel

`server/laravel.lua` implements the first built-in route adapter. When the cursor
is on a `paths/<path>` or `paths/<path>/<method>` key and `gd` is pressed, the
adapter runs `php artisan route:list --json` (configurable via `laravel.cmd`),
matches the OpenAPI path to a Laravel route, resolves the controller action to a
file and line, and returns an LSP `Location` so the editor jumps to the method.

Key public functions in `server/laravel.lua`:
- `get_root(source_uri)` — walks up from spec dir looking for `artisan`; cached.
- `list_routes(root, cmd)` — runs the route-list command, parses JSON, caches by
  `mtime` of `<root>/routes/`.
- `match_route(spec_path, method, routes, prefix)` — normalises URIs (strip `/`,
  lowercase, replace `{name}` → `{}`), filters by method. Returns a list.
- `resolve_action(root, action_fqn)` — reads `composer.json` PSR-4 map, maps
  `App\Http\Controllers\UserController@show` → file + line.
- `find_definition(uri, position, config)` — orchestrates the above; called by the
  dispatcher when `resolver.parse_ref_at` returns nil.
- `invalidate_routes(filepath)` — clears the routes cache (called on
  `workspace/didChangeWatchedFiles` for `routes/*.php` files).

Config (forwarded via `initializationOptions.laravel`):
```lua
laravel = {
    enabled     = true,
    cmd         = { "php", "artisan", "route:list", "--json" },
    path_prefix = "",   -- e.g. "api" when spec paths omit the API prefix
}
```

Future adapters (Express, Django, …) can follow the same pattern as a new
`server/<framework>.lua` module wired into the dispatcher's definition fallback.
