# openapi-navigator.nvim — Claude Code Guide

## Project overview

A pure-Lua Neovim plugin for navigating OpenAPI/Swagger specification files.
Complements yaml-language-server (validation/completion) with navigation features:
`$ref` go-to-definition, hover preview, and find-all-references.

No external binary dependencies. Neovim >= 0.9 required.

## Directory layout

```
lua/openapi-navigator/
  init.lua        Entry point: setup(), OpenAPI detection, autocommands, keymaps
  config.lua      Defaults + setup() merge
  resolver.lua    $ref parsing, file resolution, JSON pointer walking
  index.lua       Bidirectional ref index (definitions ↔ references tables)
  hover.lua       Floating schema preview with recursive $ref expansion
  references.lua  Find all usages → quickfix list
plugin/
  openapi-navigator.vim  Double-load guard
tests/
  minimal_init.lua       Plenary test harness initialiser
  unit/
    resolver_spec.lua    $ref parsing + JSON pointer resolution tests
    index_spec.lua       Index building, invalidation, pointer-at-cursor tests
  fixtures/
    openapi.yaml         Main spec (same-file and cross-file $refs)
    schemas/
      User.yaml          Cross-file target schema
      nested.yaml        Nested $ref target (for hover depth testing)
```

## Key modules

### resolver.lua — the core engine

Everything else depends on this. Three main functions:

- `parse_ref_at_cursor()` → `{raw, file, pointer} | nil` — extracts the `$ref`
  string from the current line using Lua pattern matching (no YAML parser).
- `resolve_file(ref, bufnr)` → absolute path — resolves relative paths via
  `vim.fn.resolve(dir .. "/" .. ref.file)`.
- `resolve_pointer(filepath, pointer)` → `{line, col} | nil` — walks file lines
  tracking `parent_indent` to match JSON pointer segments without a YAML parser.

### index.lua — bidirectional ref index

Two hash tables built by scanning spec files:

- `_definitions[canonical_key]` = `{file, line, col}` — definition path → location
- `_references[canonical_key]`  = `[{file, line, col, text}]` — ref target → all usages

`canonical_key` format: `<abs_file_path>::<pointer_or_empty>`

`ensure_indexed(bufnr)` is lazy and mtime-cached — only re-scans changed files.
`invalidate(bufnr)` is called on `BufWritePost` and re-indexes the saved file immediately.

### init.lua — detection + wiring

`is_openapi_buffer(bufnr)` detects OpenAPI files in three steps:
1. Filename pattern match (against `config.options.patterns`).
2. Scan first 20 lines for `openapi:` / `swagger:` top-level key.
3. Walk parent directories for a root_marker (catches files in split specs).

Results are cached per-buffer and cleared on `BufDelete`.

## Design decisions

- **No YAML parser** — `$ref` extraction and JSON pointer resolution use Lua
  pattern matching on raw lines with indentation tracking. This handles 99% of
  real specs and avoids a dependency on lyaml or similar.
- **`string.gsub` returns two values** (`result, count`). Always capture into a
  local before passing to `table.insert` or other single-value contexts — the
  multi-value expansion turns a 2-arg call into a 3-arg call and triggers
  "bad argument #2 to 'insert' (number expected, got string)".
- **Canonical keys use absolute (resolved) paths** — `vim.fn.resolve()` is
  applied consistently so `/tmp/...` and `/private/tmp/...` (macOS symlink) are
  the same key.
- **LSP hover fallback** — `hover.show()` calls `vim.lsp.buf.hover()` when the
  cursor is not on a `$ref`, so yaml-language-server hover still works.
- **Synchronous indexing** — `vim.fn.readfile()` is a fast C call; typical specs
  (<50 files) index in <50ms. Async upgrade path: wrap `index_file()` calls in
  `vim.schedule()` batches without changing the public API.

## Running tests

```bash
nvim --headless --noplugin \
  -u tests/minimal_init.lua \
  -c "set rtp+=~/.local/share/nvim/lazy/plenary.nvim" \
  -c "PlenaryBustedDirectory tests/unit/ {minimal_init='tests/minimal_init.lua'}" \
  -c "qa!"
```

CI runs on Neovim v0.9.5, v0.10.3, and nightly (see `.github/workflows/ci.yml`).

## Framework adapter system (deferred — Phase 6)

Route ↔ spec linking (Laravel, Express, Django, …) is intentionally deferred.
When implemented it will live in `lua/openapi-navigator/frameworks.lua` as a
generic adapter interface:

```lua
-- Each adapter registers:
{
  name         = "laravel",
  detect       = function(root) ... end,          -- returns true if this adapter applies
  list_routes  = function(opts) ... end,           -- returns [{method, uri, handler}]
  match_route  = function(path, method, routes) ... end,
  find_spec    = function(handler, spec_root) ... end,
}
```

Built-in adapters (Laravel, Express, …) ship with the plugin; users can register
custom adapters via `require("openapi-navigator").register_framework(adapter)`.
