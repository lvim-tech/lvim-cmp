-- lvim-cmp.config: the LIVE config — setup() merges user options into this table in
-- place (lvim-utils.utils.merge), so every module `require("lvim-cmp.config")` and sees
-- the effective values. Only IMPLEMENTED options live here; deferred features (the
-- <Tab> chain, per-filetype source overrides, cmdline completion) gain their options
-- when they gain their code, so the README's full-default block never advertises a
-- dead knob.
--
---@module "lvim-cmp.config"

---@class LvimCmpTriggerConfig
---@field show_on_trigger_chars boolean  open a fresh context when a server trigger character is typed
---@field show_on_insert boolean         probe on InsertEnter when a keyword already precedes the cursor
---@field show_on_backspace boolean      open (not just keep) the menu on a deletion inside a keyword
---@field min_keyword_length integer     keyword chars required before the menu auto-opens

---@class LvimCmpFuzzyConfig
---@field max_results integer            ranked items materialised per keystroke (the menu scrolls past the view)
---@field prefix_boost integer           score added to a candidate whose filter text is a case-insensitive PREFIX of the query — promotes literal-prefix matches above scattered fuzzy hits (0 disables)

---@class LvimCmpLspSourceConfig
---@field enabled boolean
---@field priority integer               merge rank: higher-priority sources list first among equal scores
---@field min_keyword_length integer     per-source floor (this source's trigger character bypasses it)
---@field max_items integer?             cap the items taken from this source (nil = all)
---@field timeout_ms integer             emit what has arrived after this long; a late client is dropped

---@class LvimCmpPathSourceConfig
---@field enabled boolean
---@field priority integer
---@field trailing_slash boolean         accepting a directory inserts "name/" (else "name")

---@class LvimCmpBufferSourceConfig
---@field enabled boolean
---@field priority integer
---@field min_keyword_length integer
---@field fallback_for string[]          run only when every listed source returned 0 items (flat list)
---@field buffers string                 which buffers feed the word index: "current" | "visible" | "all"
---@field min_word_length integer        words shorter than this never enter the index
---@field max_buffer_size integer        buffers larger than this (bytes) are skipped
---@field index_debounce_ms integer      a changed buffer serves its cached words and re-indexes after this pause

---@class LvimCmpMenuSelectionConfig
---@field preselect boolean              first ranked item starts selected (shown, not inserted)

---@class LvimCmpMenuIconPaddingConfig
---@field left integer                   spaces before the kind icon (the chip box is padding+icon+padding)
---@field right integer

---@class LvimCmpMenuLabelPaddingConfig
---@field left integer                   spaces before the label text (the window shifts left by the chip
---@field right integer                  width + this, so the label TEXT stays on the keyword)

---@class LvimCmpMenuTintConfig            blend factors (0..1) toward the panel for the per-kind accent tints
---@field row number                      the row background at REST
---@field row_selected number             the row background while the cursor is on it (the selection)
---@field chip number                     the icon chip background at REST
---@field chip_selected number            the icon chip background on the selected row

---@class LvimCmpMenuConfig
---@field max_height integer
---@field max_width integer
---@field direction_priority string[]    "s" below / "n" above, tried in order
---@field selection LvimCmpMenuSelectionConfig
---@field icon_padding LvimCmpMenuIconPaddingConfig
---@field label_padding LvimCmpMenuLabelPaddingConfig
---@field tint LvimCmpMenuTintConfig
---@field detail string|false            dim right column: "kind" (the kind name as text) | "lsp" (the LSP
---                                      detail's first line, else the kind name — widens the menu and
---                                      duplicates the docs float beside it) | false (no column)
---@field scrollbar boolean

---@class LvimCmpDocsConfig
---@field auto boolean                   show the docs float for the selected item automatically
---@field delay integer                  ms from selection to a CLOSED docs float opening
---@field update_delay integer           ms from selection to an OPEN docs float updating
---@field max_width integer
---@field max_height integer

---@class LvimCmpGhostConfig
---@field enabled boolean                inline preview of the selected item's remainder

---@class LvimCmpKeysConfig               each entry is a LIST of insert-mode lhs strings
---@field select_next string[]
---@field select_prev string[]
---@field accept string[]
---@field abort string[]
---@field trigger string[]
---@field docs_toggle string[]
---@field tab string[]                     snippet jump forward → select next → fall back to the raw key
---@field s_tab string[]                   snippet jump backward → select previous → fall back to the raw key
---@field docs_scroll_down string[]        scroll the docs float down (no-op → fall back) while it is open
---@field docs_scroll_up string[]          scroll the docs float up (no-op → fall back) while it is open

---@class LvimCmpSourcesConfig                the three built-in sources; an EXTERNAL source
--- registered via `require("lvim-cmp").register_source(src, opts)` stores its own config
--- under `sources.<src.name>` (opts merged over `{ enabled = true, priority = 50 }`) —
--- snippets, for example, come from the lvim-snippets plugin this way.
---@field lsp LvimCmpLspSourceConfig
---@field path LvimCmpPathSourceConfig
---@field buffer LvimCmpBufferSourceConfig

---@class LvimCmpConfig
---@field enabled boolean|fun(bufnr: integer): boolean  master switch (also per-buffer via a function)
---@field debounce_ms integer            keystroke → rank delay; 0 = per keystroke (the matcher is the budget)
---@field keyword_pattern string         Lua pattern for the keyword under the cursor (context bounds)
---@field trigger LvimCmpTriggerConfig
---@field fuzzy LvimCmpFuzzyConfig
---@field sources LvimCmpSourcesConfig
---@field menu LvimCmpMenuConfig
---@field docs LvimCmpDocsConfig
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
        prefix_boost = 16,
    },
    sources = {
        lsp = {
            enabled = true,
            priority = 100,
            min_keyword_length = 1,
            max_items = nil,
            timeout_ms = 400,
        },
        path = {
            enabled = true,
            priority = 60,
            trailing_slash = true,
        },
        buffer = {
            enabled = true,
            priority = 20,
            min_keyword_length = 1,
            fallback_for = { "lsp" },
            buffers = "visible",
            min_word_length = 3,
            max_buffer_size = 200000,
            index_debounce_ms = 100,
        },
    },
    menu = {
        max_height = 12,
        max_width = 60,
        direction_priority = { "s", "n" },
        selection = {
            preselect = true,
        },
        icon_padding = {
            left = 2,
            right = 2,
        },
        label_padding = {
            left = 1,
            right = 1,
        },
        tint = {
            row = 0.1,
            row_selected = 0.2,
            chip = 0.15,
            chip_selected = 0.2,
        },
        detail = "kind",
        scrollbar = true,
    },
    docs = {
        auto = true,
        delay = 150,
        update_delay = 50,
        max_width = 60,
        max_height = 20,
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
        docs_toggle = { "<C-d>" },
        tab = { "<Tab>" },
        s_tab = { "<S-Tab>" },
        docs_scroll_down = { "<C-f>" },
        docs_scroll_up = { "<C-b>" },
    },
}

return M
