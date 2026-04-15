-- Minimal init for plenary test runner.
-- Run with:
--   nvim --headless --noplugin -u tests/minimal_init.lua \
--        -c "PlenaryBustedDirectory tests/unit/ {minimal_init='tests/minimal_init.lua'}"

-- Locate this file's directory to resolve plugin root.
local script_path = debug.getinfo(1, "S").source:sub(2) -- strip leading "@"
local plugin_root = vim.fn.fnamemodify(script_path, ":h:h")

-- Add plugin Lua modules to runtimepath.
vim.opt.runtimepath:prepend(plugin_root)

-- Expose server/ modules via Lua's package.path so specs can require("index") etc.
-- These modules have no vim.* dependencies and run cleanly inside Neovim's LuaJIT.
local server_dir = plugin_root .. "/server"
package.path = server_dir .. "/?.lua;" .. package.path

-- Add plenary (assumes installed alongside via lazy.nvim or provided by CI).
local plenary_path = vim.fn.stdpath("data") .. "/lazy/plenary.nvim"
if vim.fn.isdirectory(plenary_path) == 1 then
	vim.opt.runtimepath:prepend(plenary_path)
end

vim.cmd("runtime! plugin/plenary.vim")
