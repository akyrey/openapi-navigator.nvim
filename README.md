# openapi-navigator.nvim

A pure-Lua Neovim plugin for navigating OpenAPI/Swagger specification files —
implemented as a standalone **LSP server** so navigation works seamlessly
alongside any other LSP client setup.

Uses your existing `gd` / `K` / `gr` mappings without fighting over them.
Complements **yaml-language-server** (validation, completion) with `$ref`
navigation that LSP alone doesn't provide. Supports OpenAPI 3.0 and 3.1,
YAML and JSON, single-file and multi-file specs.

No external binary dependencies. No Treesitter parsers required.

## Requirements

- Neovim >= 0.9
- yaml-language-server (optional, recommended for validation/completion)

## Installation

### lazy.nvim

```lua
{
  "akyrey/openapi-navigator.nvim",
  ft = { "yaml", "json" },
  opts = {},
}
```

### packer.nvim

```lua
use {
  "akyrey/openapi-navigator.nvim",
  config = function()
    require("openapi-navigator").setup()
  end,
}
```

## Features

### Go to Definition (`gd`)

When the cursor is on a `$ref` value, your existing `gd` mapping jumps to the
referenced definition. Works via the standard LSP `textDocument/definition`
request — FzfLua, Telescope, and `vim.lsp.buf.definition` all route through
the server automatically.

Supports all `$ref` formats:

| Format | Example |
|--------|---------|
| Same-file JSON pointer | `$ref: '#/components/schemas/User'` |
| Cross-file, no pointer | `$ref: './schemas/User.yaml'` |
| Cross-file with pointer | `$ref: './schemas/User.yaml#/properties/email'` |
| Relative from subdirectory | `$ref: '../openapi.yaml#/components/schemas/UserId'` |
| Path-item `$ref` (OpenAPI 3.1) | `$ref: './paths/users.yaml'` |

### Hover Preview (`K`)

Pressing `K` on a `$ref` value shows the target schema's content — type,
properties, required fields, description — formatted as YAML in a hover popup.

Nested `$ref` values inside the preview are recursively expanded up to
`hover.max_depth` levels (default: 2).

When the cursor is **not** on a `$ref`, the server returns nothing and Neovim
automatically falls through to yaml-language-server hover — no configuration
needed.

### Find All References (`gr`)

Find every `$ref` pointing to the definition under the cursor. Works in two
modes:

- **Cursor on a `$ref`** — finds all other refs pointing to the same target.
- **Cursor on a definition key** — finds all refs that point to that definition.

Results are returned as standard LSP locations, so your existing `gr` mapping
(whether it calls `vim.lsp.buf.references()`, opens a Telescope picker, or a
quickfix list) works unchanged.

Searches all `.yaml`, `.yml`, and `.json` files in the spec root directory.

## Usage

The plugin activates automatically for files it detects as OpenAPI specs:

- Files containing a top-level `openapi:` or `swagger:` key.
- Files matching the configured `patterns` (e.g. `openapi*.yaml`).
- YAML/JSON files inside a directory tree that contains a root marker file
  (e.g. `openapi.yaml`) — covers split multi-file specs.

No plugin-specific keymaps are registered. Navigation uses your existing LSP
keymaps — whatever you have bound to `gd`, `K`, and `gr` will just work.

### Debugging

Open an OpenAPI file, then:

- `:LspInfo` — confirm `openapi-navigator` is attached to the buffer.
- `:LspLog` — see the server's diagnostic output if something isn't working.

## Configuration

```lua
require("openapi-navigator").setup({
  -- File patterns to treat as OpenAPI specs
  patterns = {
    "openapi*.yaml",
    "openapi*.yml",
    "openapi*.json",
    "swagger*.yaml",
    "swagger*.json",
    "**/api-docs/**/*.yaml",
    "**/api-docs/**/*.yml",
  },

  -- Root markers used to find the spec root directory (for multi-file specs).
  -- When none of these are found, the current file's directory is used as root.
  root_markers = {
    "openapi.yaml",
    "openapi.yml",
    "openapi.json",
    "swagger.yaml",
    "swagger.json",
  },

  -- Hover preview options
  hover = {
    max_width  = 80,
    max_height = 30,
    max_depth  = 2,  -- max nested $ref expansion levels
  },
})
```

## Multi-file specs

The plugin resolves `$ref` paths relative to the file that contains them, so
deeply nested directory structures work correctly:

```
api/
├── openapi.yaml                   ← root (contains openapi: 3.0.3)
├── paths/
│   └── users.yaml                 ← $ref: '../schemas/User.yaml'
└── schemas/
    ├── User.yaml                  ← $ref: './Address.yaml#/properties/city'
    └── Address.yaml
```

The ref index is built lazily on first use and invalidated on file save.
When no root marker file is present, the current file's directory is scanned,
so single-file specs work without configuration.

## OpenAPI 3.1 support

The plugin handles OpenAPI 3.1-specific constructs transparently:

- **Path-item `$ref`** — `paths` entries that are `$ref` values are indexed and navigable.
- **Webhook `$ref`** — `webhooks` entries are scanned for `$ref` values.
- **Nullable type arrays** — `type: ["string", "null"]` does not confuse the schema block extractor.
- **`prefixItems`, `const`, `$schema`** — treated as regular keys; no special handling needed.

## Architecture

The plugin runs as a standalone Lua LSP server launched via
`nvim --headless -l server/main.lua` (Neovim's built-in LuaJIT — no extra
runtime needed on PATH).

```
openapi-navigator.nvim/
├── plugin/
│   └── openapi-navigator.vim      # Double-load guard
├── lua/openapi-navigator/
│   ├── init.lua                   # OpenAPI detection + vim.lsp.start()
│   └── config.lua                 # User options with defaults
└── server/                        # Standalone LSP server (no vim.* deps)
    ├── main.lua                   # Entry point: stdio → dispatcher loop
    ├── rpc.lua                    # JSON-RPC 2.0 framing
    ├── dispatcher.lua             # LSP method router
    ├── resolver.lua               # $ref parsing + JSON pointer resolution
    ├── index.lua                  # Bidirectional ref index
    ├── hover.lua                  # Hover response builder
    ├── references.lua             # Find-references response builder
    ├── document_store.lua         # In-memory open file contents
    ├── workspace.lua              # Root detection + file globbing
    └── fs.lua                     # Pure-Lua file ops (no vim.fn)
```

Data flow: **LSP request → dispatcher → resolver extracts `$ref` + walks
JSON pointer → index provides reverse lookups → Location / Hover / Location[]
returned to client**.
