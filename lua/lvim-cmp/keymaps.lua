-- lvim-cmp.keymaps: the insert-mode keys (config.keys). Every mapping is a guard:
-- menu visible → drive the engine; else FALL BACK by feeding the key unmapped ("n"),
-- so native <C-n>/<Down>/… behaviour survives. <CR> is the documented lvim-pairs
-- handshake: confirm first, else `require("lvim-pairs").cr()` (the split-an-empty-pair
-- newline), else a plain <CR> — one compose order, no double mapping.
--
---@module "lvim-cmp.keymaps"

local config = require("lvim-cmp.config")
local engine = require("lvim-cmp.engine")

local api = vim.api

local M = {}

---@type boolean the maps are installed
local installed = false

--- Feed `key` (vim notation) as if unmapped — the fallback path of every guard mapping.
---@param key string
local function feed(key)
    api.nvim_feedkeys(vim.keycode(key), "n", false)
end

--- The <CR> fallback keys: lvim-pairs' cr() when present (the handshake), else <CR>.
---@return string
local function cr_fallback()
    local ok, pairs_mod = pcall(require, "lvim-pairs")
    if ok and type(pairs_mod.cr) == "function" then
        return pairs_mod.cr()
    end
    return "<CR>"
end

--- Map every lhs in `keys` to `fn` in insert mode.
---@param keys string[]
---@param fn fun(lhs: string)
---@param desc string
local function map_all(keys, fn, desc)
    for _, lhs in ipairs(keys or {}) do
        vim.keymap.set("i", lhs, function()
            fn(lhs)
        end, { desc = desc, silent = true })
    end
end

--- Install the insert-mode mappings from the live config. Idempotent enough for a
--- single setup() call; re-running after a config change re-applies over the old maps.
function M.setup()
    installed = true
    local keys = config.keys

    map_all(keys.select_next, function(lhs)
        if not engine.select(1) then
            feed(lhs)
        end
    end, "lvim-cmp: select next")

    map_all(keys.select_prev, function(lhs)
        if not engine.select(-1) then
            feed(lhs)
        end
    end, "lvim-cmp: select previous")

    map_all(keys.accept, function(lhs)
        if engine.accept() then
            return
        end
        feed(lhs == "<CR>" and cr_fallback() or lhs)
    end, "lvim-cmp: accept")

    map_all(keys.abort, function(lhs)
        if engine.visible() then
            engine.hide()
        else
            feed(lhs)
        end
    end, "lvim-cmp: abort")

    map_all(keys.trigger, function()
        engine.trigger()
    end, "lvim-cmp: trigger completion")
end

--- Remove the mappings (disable).
function M.teardown()
    if not installed then
        return
    end
    installed = false
    local keys = config.keys
    for _, list in pairs({ keys.select_next, keys.select_prev, keys.accept, keys.abort, keys.trigger }) do
        for _, lhs in ipairs(list or {}) do
            pcall(vim.keymap.del, "i", lhs)
        end
    end
end

--- Whether the mappings are installed.
---@return boolean
function M.installed()
    return installed
end

return M
