# openapi-navigator.nvim

A pure-Lua Neovim plugin for navigating OpenAPI/Swagger specification files.

Designed to complement **yaml-language-server** (which handles validation and
completion) with navigation capabilities that LSP alone doesn't provide:
jump to `$ref` definitions, hover schema previews, and find-all-references.
Supports both OpenAPI 3.0 and 3.1 specs, in YAML and JSON, across single-file
and multi-file layouts using relative `$ref` paths.

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

When the cursor is on a `$ref` value, `gd` jumps to the referenced definition.

Supports all `$ref` formats:

| Format | Example |
|--------|---------|
| Same-file JSON pointer | `$ref: '#/components/schemas/User'` |
| Cross-file, no pointer | `$ref: './schemas/User.yaml'` |
| Cross-file with pointer | `$ref: './schemas/User.yaml#/properties/email'` |
| Relative from subdirectory | `$ref: '../openapi.yaml#/components/schemas/UserId'` |
| Path-item `$ref` (OpenAPI 3.1) | `$ref: './paths/users.yaml'` |

### Hover Preview (`K`)

Pressing `K` on a `$ref` value opens a floating window showing the target
schema's content — type, properties, required fields, description — formatted
as YAML.

Nested `$ref` values inside the preview are recursively expanded up to
`hover.max_depth` levels (default: 2).

When the cursor is **not** on a `$ref`, `K` falls back to `vim.lsp.buf.hover()`
so yaml-language-server hover still works normally.

### Find All References (`gr` / `:OpenAPIReferences`)

Find every `$ref` pointing to the definition under the cursor and populate the
quickfix list. Works in two modes:

- **Cursor on a `$ref`** — finds all other refs pointing to the same target.
- **Cursor on a definition key** — finds all refs that point to that definition.

Navigate results with `]q` / `[q` as usual.

Searches all `.yaml`, `.yml`, and `.json` files in the spec root directory.

## Usage

The plugin activates automatically for files it detects as OpenAPI specs:

- Files containing a top-level `openapi:` or `swagger:` key.
- Files matching the configured `patterns` (e.g. `openapi*.yaml`).
- YAML/JSON files inside a directory tree that contains a root marker file
  (e.g. `openapi.yaml`) — this covers split multi-file specs.
- Any YAML/JSON file in the same directory when no root marker is found —
  so specs named `petstore.yaml`, `api-docs.yaml`, etc. work without any
  extra configuration.

### Default keymaps (buffer-local, only on OpenAPI files)

| Key | Action |
|-----|--------|
| `gd` | Go to `$ref` definition |
| `K` | Hover preview (falls back to LSP hover when not on a `$ref`) |
| `gr` | Find all references → quickfix |

### Commands

| Command | Description |
|---------|-------------|
| `:OpenAPIReferences` | Find all usages of the definition under cursor |
| `:OpenAPIDebug` | Print plugin diagnostics for the current buffer |

### Debugging

If navigation isn't working, run `:OpenAPIDebug` on the file. It prints:

```
openapi-navigator debug
──────────────────────────────────────────────────
  buffer:                petstore.yaml
  detected as OpenAPI:   true
  spec root:             /project/api
  indexed files:         12
  definitions:           347
  reference keys:        89
  $ref on cursor:        #/components/schemas/Pet
  resolves to file:      petstore.yaml
  pointer line:          142
  canonical key:         /project/api/petstore.yaml::/components/schemas/Pet
  references found:      4
```

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

  -- Keymaps (set any to false to disable)
  keymaps = {
    goto_definition  = "gd",
    hover            = "K",
    find_references  = "gr",
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
so single-file specs and unconventionally named specs (e.g. `petstore.yaml`)
work without configuration.

## OpenAPI 3.1 support

The plugin handles OpenAPI 3.1-specific constructs transparently:

- **Path-item `$ref`** — `paths` entries that are themselves `$ref` values
  (e.g. `$ref: './paths/users.yaml'`) are indexed and navigable.
- **Webhook `$ref`** — `webhooks` entries are scanned for `$ref` values.
- **Nullable type arrays** — `type: ["string", "null"]` does not confuse
  the schema block extractor.
- **`prefixItems`, `const`, `$schema`** — treated as regular keys in the
  indentation walker; no special handling needed.

## Architecture

```
openapi-navigator.nvim/
├── plugin/
│   └── openapi-navigator.vim      # Double-load guard
└── lua/openapi-navigator/
    ├── init.lua                   # setup(), detection, autocommands, keymaps
    ├── config.lua                 # User options with defaults
    ├── resolver.lua               # $ref parsing + JSON pointer resolution
    ├── index.lua                  # Bidirectional ref index (definitions ↔ references)
    ├── hover.lua                  # Floating preview with $ref expansion
    └── references.lua             # Find all usages → quickfix
```

Data flow: **cursor line → resolver extracts `$ref` → file + pointer resolved →
index provides reverse lookups → results presented via Neovim APIs**.

## Extending — Framework Route Linking

Framework-specific route ↔ spec linking (e.g. Laravel, Express, Django) is
planned as a generic adapter system. Adapters will register themselves with:

```lua
require("openapi-navigator").register_framework({
  name        = "laravel",
  detect      = function(root) ... end,
  list_routes = function(opts) ... end,
  match_route = function(path, method, routes) ... end,
  find_spec   = function(handler, spec_root) ... end,
})
```

A built-in Laravel adapter is planned for a future release.
