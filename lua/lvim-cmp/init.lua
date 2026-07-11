-- lvim-cmp: the completion engine of the lvim-tech set. Async LSP completion rendered
-- in the canonical lvim-ui `menu` primitive (cursor-anchored, non-focusable), fuzzy-
-- ranked per keystroke through the shared lvim-fuzzy engine (deterministic across its
-- native/Lua backends), with matched-char highlighting on visible rows, ghost text, and
-- textEdit/snippet/additionalTextEdits-correct acceptance. This module owns setup() and
-- the small public API; the moving parts live in engine/trigger/sources/menu.
--
-- Public API:
--   M.setup(opts)        – merge options into the live config and wire everything
--   M.enable()/disable() – runtime switch (autocmds + keymaps + UI teardown)
--   M.show()             – manually open the menu at the cursor (<C-Space>)
--   M.hide()             – dismiss the menu
--   M.accept()           – accept the selected item
--   M.select(delta)      – move the selection
--   M.visible()          – whether the menu is on screen
--   M.capabilities()     – LSP client_capabilities fragment for lsp setup
--
---@module "lvim-cmp"

local config = require("lvim-cmp.config")
local engine = require("lvim-cmp.engine")
local trigger = require("lvim-cmp.trigger")
local keymaps = require("lvim-cmp.keymaps")
local highlights = require("lvim-cmp.highlights")
local merge = require("lvim-utils.utils").merge

local M = {}

--- Merge user options into the LIVE config (in place) and wire the plugin: highlight
--- factories, autocmds and insert-mode keys. Safe to call once at startup.
---@param opts? LvimCmpConfig  any subset of the defaults (see lvim-cmp.config)
function M.setup(opts)
    if opts then
        merge(config, opts)
    end
    highlights.setup()
    if config.enabled ~= false then
        trigger.setup()
        keymaps.setup()
    end
end

--- Enable at runtime (wires autocmds + keys; also flips `config.enabled` on).
function M.enable()
    if config.enabled == false then
        config.enabled = true
    end
    trigger.setup()
    keymaps.setup()
end

--- Disable at runtime: tear down autocmds, keymaps and the menu handle.
function M.disable()
    config.enabled = false
    trigger.teardown()
    keymaps.teardown()
    engine.teardown()
end

--- Manually open the completion menu at the cursor (regardless of keyword length).
function M.show()
    engine.trigger()
end

--- Dismiss the menu (and cancel in-flight requests).
function M.hide()
    engine.hide()
end

--- Accept the selected item.
---@return boolean handled
function M.accept()
    return engine.accept()
end

--- Move the selection by `delta` (wraps).
---@param delta integer
---@return boolean handled
function M.select(delta)
    return engine.select(delta)
end

--- Whether the completion menu is on screen.
---@return boolean
function M.visible()
    return engine.visible()
end

--- The client_capabilities fragment servers should be started with, so they send
--- everything lvim-cmp consumes: snippet items, resolve-lazy fields, itemDefaults,
--- insert/replace edits, trigger context. Merge it over
--- `vim.lsp.protocol.make_client_capabilities()` in the LSP setup.
---@return table
function M.capabilities()
    return {
        textDocument = {
            completion = {
                completionItem = {
                    snippetSupport = true,
                    insertReplaceSupport = true,
                    deprecatedSupport = true,
                    preselectSupport = true,
                    labelDetailsSupport = true,
                    documentationFormat = { "markdown", "plaintext" },
                    resolveSupport = {
                        properties = { "documentation", "detail", "additionalTextEdits", "command" },
                    },
                },
                completionList = {
                    itemDefaults = { "editRange", "insertTextFormat", "insertTextMode", "data" },
                },
                contextSupport = true,
            },
        },
    }
end

return M
