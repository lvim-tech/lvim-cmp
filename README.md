# lvim-cmp

The completion engine of the **lvim-tech** set. Async LSP completion rendered in the canonical lvim-ui
cursor-anchored menu (non-focusable — focus never leaves your buffer), fuzzy-ranked on every keystroke
through the shared **lvim-fuzzy** engine (deterministic: identical ranking on the native and pure-Lua
backends), with matched-char highlighting on the visible rows, kind chips in the outline's glyph family,
ghost text, and `textEdit` / snippet / `additionalTextEdits`-correct acceptance.

Current sources: **LSP** (buffer, path and snippet sources are planned follow-ups on the same source
contract).

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

## Requirements

Requires **Neovim >= 0.11**, [lvim-utils](https://github.com/lvim-tech/lvim-utils),
[lvim-ui](https://github.com/lvim-tech/lvim-ui) (the `menu` primitive) and
[lvim-fuzzy](https://github.com/lvim-tech/lvim-fuzzy) (ranking + match positions).
[lvim-pairs](https://github.com/lvim-tech/lvim-pairs) is optional (the `<CR>` fallback handshake).

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
| `<C-Space>` | trigger manually (regardless of keyword length) |

Public API: `setup(opts)`, `enable()` / `disable()`, `show()`, `hide()`, `accept()`, `select(delta)`,
`visible()`, `capabilities()`.

## Configuration

`setup()` merges your options into the live config in place — every reader
(`require("lvim-cmp.config")`) sees the effective values. The full default config:

```lua
require("lvim-cmp").setup({
    enabled = true, -- master switch; also fun(bufnr): boolean
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
    },
    sources = {
        lsp = {
            enabled = true,
            min_keyword_length = 1, -- per-source floor (a trigger character bypasses it)
            max_items = nil, -- cap items taken from this source (nil = all)
            timeout_ms = 400, -- emit what has arrived after this long
        },
    },
    menu = {
        max_height = 12, -- visible rows (longer lists scroll)
        max_width = 60,
        direction_priority = { "s", "n" }, -- below / above, tried in order
        selection = {
            preselect = true, -- first ranked item starts selected (shown, not inserted)
        },
        detail = true, -- dim right column (LSP detail, else the kind name)
        scrollbar = true,
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
    },
})
```

## Health

`:checkhealth lvim-cmp` reports the runtime requirement, the shared dependencies (including WHICH
lvim-fuzzy backend loaded), whether the trigger autocmds / keymaps are wired, the current buffer's
completion-capable clients, and validates the live config.

## License

BSD 3-Clause — see [LICENSE](LICENSE).
