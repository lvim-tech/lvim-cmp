# lvim-cmp

The completion engine of the **lvim-tech** set. Async multi-source completion rendered in the canonical
lvim-ui cursor-anchored menu (non-focusable — focus never leaves your buffer), fuzzy-ranked on every
keystroke through the shared **lvim-fuzzy** engine (deterministic: identical ranking on the native and
pure-Lua backends), with matched-char highlighting on the visible rows, kind chips in the outline's glyph
family, a documentation float beside the menu, ghost text, and `textEdit` / snippet /
`additionalTextEdits`-correct acceptance.

Sources: **LSP**, **path** (filesystem completion on `/` and `~`) and **buffer** (words from open
buffers) built-in — all on one source contract, merged by source priority, and extensible with your own
[custom sources](#custom-sources). **Snippet** completion comes from
[lvim-snippets](https://github.com/lvim-tech/lvim-snippets), which registers its `snippets` source
through that same public API.

## Highlights

- **Per-keystroke ranking, no debounce by default** — the matcher is the budget, not a timer. Candidate
  sets cross into lvim-fuzzy ONCE per server response; each keystroke is a single match call, and a
  keystroke inside the current keyword re-ranks the cached set with **no server round-trip**
  (`isIncomplete` responses refetch, per the protocol).
- **A generation counter is the correctness backbone** — every async response is stamped with the
  context id it was requested under and dropped unless still current: no stale menu ever renders.
- **The canonical menu** — the lvim-ui `menu` primitive: one long-lived non-focusable window glued to
  the keyword start (no shift while typing), direction flip at the screen edge, ephemeral
  decoration-provider highlights on visible rows only, bg-only selection bar, scrollbar.
- **Honest ghost text** — the selected item's remainder inline, shown only when its insert text
  literally extends what you typed.
- **Native acceptance** — `textEdit` ranges in the client's offset encoding, `vim.snippet` expansion
  for snippet-format items, `additionalTextEdits` (auto-imports) after `completionItem/resolve`, and
  the item's command.
- **The `<CR>` handshake** — accept when an item is selected, else `require("lvim-pairs").cr()` (the
  split-an-empty-pair newline) when lvim-pairs is present, else a plain newline.
- **A documentation float** — the selected item resolves (`completionItem/resolve`, cached on the item
  so accepting reuses it) and its detail + documentation render as markdown in the menu's sibling slot,
  debounced (`docs.delay` closed / `docs.update_delay` open), hidden when there is nothing to show;
  `<C-d>` toggles it.
- **Source fallbacks + floors** — a source with `fallback_for` runs only when the listed sources
  returned nothing (default: buffer words appear only where the LSP has nothing to say); each source has
  its own `min_keyword_length` floor, bypassed by `<C-Space>` and by that source's own trigger
  characters.
- **Buffer words with a debounced index** — each buffer keeps a keyword index keyed by its changedtick;
  while you type it serves the cached words and re-scans only after a pause, so big buffers never pay a
  full scan per keystroke. Configurable scope (current / visible / all buffers), minimum word length,
  size cap; deduplicated across buffers.
- **Path completion** — `/` and `~` open it; relative prefixes resolve against the current file's
  directory AND the cwd; directories rank first, carry the Folder kind and a trailing slash on accept;
  file chips upgrade to their lvim-icons devicon when that plugin is present.
- **Snippet-correct acceptance for any source** — an item with `insertTextFormat = 2` expands through
  native `vim.snippet` (tabstops jump on `<Tab>`), and an item carrying its own `expand` function (the
  lvim-snippets LuaSnip records) runs it instead — the accept path is the seam snippet sources plug
  into, no snippet code lives here.

## Requirements

Requires **Neovim >= 0.11**, [lvim-utils](https://github.com/lvim-tech/lvim-utils),
[lvim-ui](https://github.com/lvim-tech/lvim-ui) (the `menu` primitive) and
[lvim-fuzzy](https://github.com/lvim-tech/lvim-fuzzy) (ranking + match positions).
[lvim-pairs](https://github.com/lvim-tech/lvim-pairs) is optional (the `<CR>` fallback handshake), so is
[lvim-icons](https://github.com/lvim-tech/lvim-icons) (devicon chips in path completion), and so is
[lvim-snippets](https://github.com/lvim-tech/lvim-snippets) (snippet completion — it registers itself).

## Installation

### lvim-installer (recommended)

Open the **Plugins** tab and install / update / pin it:

```vim
:LvimInstaller plugins
```

### Native (vim.pack)

```lua
vim.pack.add({
    { src = "https://github.com/lvim-tech/lvim-utils" },
    { src = "https://github.com/lvim-tech/lvim-ui" },
    { src = "https://github.com/lvim-tech/lvim-fuzzy" },
    { src = "https://github.com/lvim-tech/lvim-cmp" },
})
require("lvim-cmp").setup({})
```

## LSP capabilities

Start your servers with the lvim-cmp capabilities fragment so they send everything it consumes
(snippet items, resolve-lazy fields, `itemDefaults`, insert/replace edits, trigger context):

```lua
local capabilities =
    vim.tbl_deep_extend("force", vim.lsp.protocol.make_client_capabilities(), require("lvim-cmp").capabilities())
vim.lsp.config("*", { capabilities = capabilities })
```

## Usage

Completion opens as you type (see `trigger` below). Insert-mode keys (all configurable):

| key | action |
|---|---|
| `<C-n>` / `<Down>` | select next (wraps) |
| `<C-p>` / `<Up>` | select previous (wraps) |
| `<CR>` | accept the selected item (else the lvim-pairs / newline fallback) |
| `<C-e>` | abort (hide the menu) |
| `<C-Space>` | trigger manually (regardless of keyword length and per-source floors) |
| `<C-d>` | toggle the documentation float (mutes/unmutes auto-docs for the session) |
| `<Tab>` / `<S-Tab>` | snippet jump forward/backward → select next/previous → the raw key |
| `<C-f>` / `<C-b>` | scroll the open documentation float down/up (else the raw key) |

Public API: `setup(opts)`, `enable()` / `disable()`, `show()`, `hide()`, `accept()`, `select(delta)`,
`visible()`, `capabilities()`.

## Configuration

`setup()` merges your options into the live config in place — every reader
(`require("lvim-cmp.config")`) sees the effective values. The full default config:

```lua
require("lvim-cmp").setup({
    -- Master switch; also fun(bufnr): boolean. Scratch buffers (non-empty 'buftype')
    -- never complete regardless — UI panels, prompts, previews — unless the plugin
    -- that owns one opts it in with `vim.b.lvim_cmp_enable = true` (an editable
    -- scratch that is a genuine editor, e.g. lvim-db's query editor).
    enabled = true,
    debounce_ms = 0, -- keystroke → rank delay; 0 = per keystroke (the matcher is the budget)
    keyword_pattern = "[%a_][%w_%-]*", -- context bounds (Lua pattern)
    trigger = {
        show_on_trigger_chars = true, -- a server trigger character opens a fresh context
        show_on_insert = false, -- probe on InsertEnter when a keyword precedes the cursor
        show_on_backspace = false, -- open (not just keep) the menu on a deletion
        min_keyword_length = 1, -- keyword chars before the menu auto-opens
    },
    fuzzy = {
        max_results = 200, -- ranked items materialised per keystroke
        prefix_boost = 16, -- score added to literal case-insensitive PREFIX matches (0 disables)
    },
    sources = {
        lsp = {
            enabled = true,
            priority = 100, -- merge rank: higher-priority sources list first among equal scores
            min_keyword_length = 1, -- per-source floor (this source's trigger characters bypass it)
            max_items = nil, -- cap items taken from this source (nil = all)
            timeout_ms = 400, -- emit what has arrived after this long
        },
        path = {
            enabled = true,
            priority = 60,
            trailing_slash = true, -- accepting a directory inserts "name/"
        },
        buffer = {
            enabled = true,
            priority = 20,
            min_keyword_length = 1,
            fallback_for = { "lsp" }, -- run only when these sources returned 0 items
            buffers = "visible", -- which buffers feed the index: "current" | "visible" | "all"
            min_word_length = 3, -- shorter words never enter the index
            max_buffer_size = 200000, -- buffers larger than this (bytes) are skipped
            index_debounce_ms = 100, -- a changed buffer re-indexes after this typing pause
        },
    },
    menu = {
        max_height = 12, -- visible rows (longer lists scroll)
        max_width = 60,
        direction_priority = { "s", "n" }, -- below / above, tried in order
        selection = {
            preselect = true, -- first ranked item starts selected (shown, not inserted)
        },
        icon_padding = {
            left = 2, -- spaces before the kind icon
            right = 2, -- spaces after the icon (before the label)
        },
        label_padding = {
            left = 1, -- spaces before the label text (the window shifts by chip + this,
            right = 1, -- so the label TEXT stays on the keyword)
        },
        -- Per-kind accent tints (blend factors toward the panel). Every row is coloured by its
        -- kind: the row background, the label text, the icon chip and the right column all share
        -- the one accent; the cursor row is a STRONGER tint of its own colour (not a blue bar).
        tint = {
            row = 0.1, -- row background at rest
            row_selected = 0.2, -- row background under the cursor (the selection)
            chip = 0.15, -- icon chip background at rest
            chip_selected = 0.2, -- icon chip background on the selected row
        },
        -- dim right column: "kind" (the kind name in the accent, bold) | "lsp" (LSP detail's first
        -- line, else the kind name — widens the menu and duplicates the docs float) | false (none)
        detail = "kind",
        scrollbar = true,
    },
    docs = {
        auto = true, -- show the docs float for the selected item automatically
        delay = 150, -- ms from selection to a CLOSED docs float opening
        update_delay = 50, -- ms from selection to an OPEN docs float updating
        max_width = 60,
        max_height = 20,
    },
    ghost_text = {
        enabled = true, -- inline preview of the selected item's remainder
    },
    keys = {
        select_next = { "<C-n>", "<Down>" },
        select_prev = { "<C-p>", "<Up>" },
        accept = { "<CR>" },
        abort = { "<C-e>" },
        trigger = { "<C-Space>" },
        docs_toggle = { "<C-d>" },
        tab = { "<Tab>" }, -- snippet jump forward → select next → the raw key
        s_tab = { "<S-Tab>" }, -- snippet jump backward → select previous → the raw key
        docs_scroll_down = { "<C-f>" }, -- scroll the open docs float (no-op → the raw key)
        docs_scroll_up = { "<C-b>" },
    },
})
```

## Snippets

Snippet completion lives in its own plugin,
[lvim-snippets](https://github.com/lvim-tech/lvim-snippets) — the VS Code / SnipMate / LuaSnip
collection engine plus the `:LvimSnippets` picker. On its `setup()` it registers a `snippets` source
into lvim-cmp through the public [`register_source`](#custom-sources) API (nothing to wire here), the
items expand through the standard accept path (`vim.snippet`, or the item's own `expand` for LuaSnip
records), and its format-priority rank rides in each item's `sort_text` as the equal-fuzzy tiebreak.
Collections, folders, formats and their priority are configured in **lvim-snippets**' own `setup()`;
`:checkhealth lvim-snippets` reports the discovered files.

## Custom sources

The three built-in sources (LSP, path, buffer) are not the whole story — you can register your own
EXTERNAL source (git, cmdline, a database-schema source, emoji, calc, …) at runtime; snippets via
lvim-snippets arrive through exactly this seam. A source is any table implementing the source contract:
required `name` (string), `enabled(ctx)` and `get(ctx, cb)`; optional `trigger_chars(bufnr)`,
`resolve(item, cb)`, `execute(item, bufnr)`. Register it after `setup()`:

```lua
require("lvim-cmp").register_source({
    name = "emoji",
    enabled = function()
        return true
    end,
    -- cb(items, incomplete): items are LvimCmpItem tables (label, filter_text, kind, …)
    get = function(ctx, cb)
        cb({}, false)
    end,
}, { priority = 40, min_keyword_length = 2 })
```

`opts` is the source's per-source config — `priority` (merge rank among equal fuzzy scores),
`enabled`, `min_keyword_length`, `fallback_for`, … — stored under `sources.<name>` and honoured by the
same fan-out as the built-ins. Registering an existing name (built-in or external) **replaces** it, so a
source can be swapped or hot-reloaded. Registered external sources appear in `:checkhealth lvim-cmp`.

## Health

`:checkhealth lvim-cmp` reports the runtime requirement, the shared dependencies (including WHICH
lvim-fuzzy backend loaded), whether the trigger autocmds / keymaps are wired, every source's live status
(the current buffer's completion-capable clients, the buffer word-index statistics, the registered
external sources — the lvim-snippets `snippets` source shows up there), and validates the live config.

## License

BSD 3-Clause — see [LICENSE](LICENSE).
