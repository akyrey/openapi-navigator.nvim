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
  init.lua        Thin Neovim client: OpenAPI detection, vim.lsp.start()
  config.lua      Defaults + setup() merge (no keymaps — those come from user LSP config)
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

## Running tests

```bash
nvim --headless --noplugin \
  -u tests/minimal_init.lua \
  -c "PlenaryBustedDirectory tests/unit/ {minimal_init='tests/minimal_init.lua'}" \
  -c "qa!"
```

CI runs on Neovim v0.9.5, v0.10.3, and nightly (see `.github/workflows/ci.yml`).

## Framework adapter system (deferred)

Route ↔ spec linking (Laravel, Express, Django, …) is intentionally deferred.
When implemented it will live as a server-side module exposing a generic adapter
interface, callable via a custom LSP request method.
