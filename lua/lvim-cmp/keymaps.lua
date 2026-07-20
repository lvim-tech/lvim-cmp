-- lvim-cmp.keymaps: the insert-mode keys (config.keys). Every mapping is a guard:
-- menu visible → drive the engine; else FALL BACK by feeding the key unmapped ("n"),
-- so native <C-n>/<Down>/… behaviour survives. <CR> is the documented lvim-pairs
-- handshake: confirm first, else `require("lvim-pairs").cr()` (the split-an-empty-pair
-- newline), else a plain <CR> — one compose order, no double mapping.
--
-- Termcode contract: every fallback string here is VIM NOTATION (e.g. "<CR>", "<C-n>"),
-- never pre-replaced termcodes. `feed()` is the SINGLE translation point — it runs
-- `vim.keycode` exactly once. `lvim-pairs.cr()` upholds the same contract (it returns
-- "<CR>" / "<CR><Esc>O" notation, and lvim-pairs' own expr map replaces those keycodes),
-- so composing it through `feed()` translates once and cannot double-translate.
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

--- Jump within an active snippet session if the tabstop in `dir` exists (dir 1 forward /
--- -1 back) — the first link of the <Tab> chain, above menu selection.
---@param dir integer
---@return boolean jumped
local function snippet_jump(dir)
    -- lvim-snippets owns a fuller snippet engine than `vim.snippet` (nested placeholders, mirrors,
    -- choices, transforms), so when it is installed its session is the one to drive; a session it
    -- started is invisible to `vim.snippet.active`. Falls back to the native one otherwise, which
    -- keeps lvim-cmp usable on its own.
    local ok, snip = pcall(require, "lvim-snippets")
    if ok and type(snip.jumpable) == "function" then
        if snip.jumpable(dir) then
            snip.jump(dir)
            return true
        end
        -- A native session can still exist (an LSP item expanded before lvim-snippets loaded).
    end
    if vim.snippet.active({ direction = dir }) then
        vim.snippet.jump(dir)
        return true
    end
    return false
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

    map_all(keys.docs_toggle, function(lhs)
        if not engine.docs_toggle() then
            feed(lhs)
        end
    end, "lvim-cmp: toggle documentation")

    -- <Tab> chain: an active snippet's next tabstop wins, then the menu selection, then
    -- the raw key (so <Tab> still indents when neither is live). <S-Tab> mirrors it back.
    map_all(keys.tab, function(lhs)
        if snippet_jump(1) or engine.select(1) then
            return
        end
        feed(lhs)
    end, "lvim-cmp: tab (snippet jump / select next)")

    map_all(keys.s_tab, function(lhs)
        if snippet_jump(-1) or engine.select(-1) then
            return
        end
        feed(lhs)
    end, "lvim-cmp: shift-tab (snippet jump / select previous)")

    map_all(keys.docs_scroll_down, function(lhs)
        if not engine.docs_scroll(1) then
            feed(lhs)
        end
    end, "lvim-cmp: scroll docs down")

    map_all(keys.docs_scroll_up, function(lhs)
        if not engine.docs_scroll(-1) then
            feed(lhs)
        end
    end, "lvim-cmp: scroll docs up")
end

--- Remove the mappings (disable).
function M.teardown()
    if not installed then
        return
    end
    installed = false
    local keys = config.keys
    for _, list in pairs({
        keys.select_next,
        keys.select_prev,
        keys.accept,
        keys.abort,
        keys.trigger,
        keys.docs_toggle,
        keys.tab,
        keys.s_tab,
        keys.docs_scroll_down,
        keys.docs_scroll_up,
    }) do
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
