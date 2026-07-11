-- lvim-cmp.config: the LIVE config — setup() merges user options into this table in
-- place (lvim-utils.utils.merge), so every module `require("lvim-cmp.config")` and sees
-- the effective values. Only IMPLEMENTED options live here; deferred features (buffer/
-- path/snippet sources, the docs float, the <Tab> chain) gain their options when they
-- gain their code, so the README's full-default block never advertises a dead knob.
--
---@module "lvim-cmp.config"

---@class LvimCmpTriggerConfig
---@field show_on_trigger_chars boolean  open a fresh context when a server trigger character is typed
---@field show_on_insert boolean         probe on InsertEnter when a keyword already precedes the cursor
---@field show_on_backspace boolean      open (not just keep) the menu on a deletion inside a keyword
---@field min_keyword_length integer     keyword chars required before the menu auto-opens

---@class LvimCmpFuzzyConfig
---@field max_results integer            ranked items materialised per keystroke (the menu scrolls past the view)

---@class LvimCmpLspSourceConfig
---@field enabled boolean
---@field min_keyword_length integer     per-source floor (a trigger character bypasses it)
---@field max_items integer?             cap the items taken from this source (nil = all)
---@field timeout_ms integer             emit what has arrived after this long; a late client is dropped

---@class LvimCmpMenuSelectionConfig
---@field preselect boolean              first ranked item starts selected (shown, not inserted)

---@class LvimCmpMenuConfig
---@field max_height integer
---@field max_width integer
---@field direction_priority string[]    "s" below / "n" above, tried in order
---@field selection LvimCmpMenuSelectionConfig
---@field detail boolean                 dim right column (LSP detail, else the kind name)
---@field scrollbar boolean

---@class LvimCmpGhostConfig
---@field enabled boolean                inline preview of the selected item's remainder

---@class LvimCmpKeysConfig               each entry is a LIST of insert-mode lhs strings
---@field select_next string[]
---@field select_prev string[]
---@field accept string[]
---@field abort string[]
---@field trigger string[]

---@class LvimCmpConfig
---@field enabled boolean|fun(bufnr: integer): boolean  master switch (also per-buffer via a function)
---@field debounce_ms integer            keystroke → rank delay; 0 = per keystroke (the matcher is the budget)
---@field keyword_pattern string         Lua pattern for the keyword under the cursor (context bounds)
---@field trigger LvimCmpTriggerConfig
---@field fuzzy LvimCmpFuzzyConfig
---@field sources { lsp: LvimCmpLspSourceConfig }
---@field menu LvimCmpMenuConfig
---@field ghost_text LvimCmpGhostConfig
---@field keys LvimCmpKeysConfig
local M = {
    enabled = true,
    debounce_ms = 0,
    keyword_pattern = "[%a_][%w_%-]*",
    trigger = {
        show_on_trigger_chars = true,
        show_on_insert = false,
        show_on_backspace = false,
        min_keyword_length = 1,
    },
    fuzzy = {
        max_results = 200,
    },
    sources = {
        lsp = {
            enabled = true,
            min_keyword_length = 1,
            max_items = nil,
            timeout_ms = 400,
        },
    },
    menu = {
        max_height = 12,
        max_width = 60,
        direction_priority = { "s", "n" },
        selection = {
            preselect = true,
        },
        detail = true,
        scrollbar = true,
    },
    ghost_text = {
        enabled = true,
    },
    keys = {
        select_next = { "<C-n>", "<Down>" },
        select_prev = { "<C-p>", "<Up>" },
        accept = { "<CR>" },
        abort = { "<C-e>" },
        trigger = { "<C-Space>" },
    },
}

return M
