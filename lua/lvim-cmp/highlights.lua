-- lvim-cmp.highlights: the plugin's highlight groups, self-themed from the shared
-- lvim-utils palette via a bound build() factory (re-applied on ColorScheme / palette
-- sync — the standard pipeline; never an inline colour in render logic). The menu
-- chrome groups (LvimUiMenu*) come from the lvim-ui menu preset; here live only the
-- lvim-cmp-specific ones: the per-kind roles (chip / chip-selected / row background /
-- label text) and the match/detail/ghost text roles.
--
---@module "lvim-cmp.highlights"

local hl = require("lvim-utils.highlight")
local kinds = require("lvim-cmp.kinds")
local config = require("lvim-cmp.config")

local M = {}

---@type boolean the factory is bound (setup may be called more than once)
local bound = false

--- Bind the palette factory. Idempotent.
function M.setup()
    if bound then
        return
    end
    bound = true
    hl.bind(function(c)
        c = c or require("lvim-utils.colors")
        -- Concrete shade of the menu PANEL the chips sit on (the lvim-ui menu chrome rule:
        -- the theme's float shade, else bg_dark — never "NONE", a blend needs a hex). The
        -- tint canon: a coloured cell blends its accent toward the surface it SITS ON — a
        -- chip tinted over the EDITOR bg reads as a foreign dark patch on the float.
        local panel = c.bg_float or c.bg_dark
        local groups = {
            -- matched query chars inside a label (painted on visible rows only)
            LvimCmpMatch = { fg = c.red, bold = true },
            -- inline ghost-text preview of the selected item's remainder
            LvimCmpGhost = { fg = c.comment, italic = true },
        }
        -- Six groups per CompletionItemKind, all derived from the ONE kind accent, so every row
        -- reads as a self-coloured legend that tracks the live palette (the tint canon: every
        -- coloured cell is the accent tinted toward the PANEL it sits on). The four tint strengths
        -- are live-configurable via `menu.tint`:
        --   • <Name>       — the icon chip at REST: accent fg over `tint.chip`.
        --   • <Name>Sel    — the chip on the SELECTED row: accent fg over `tint.chip_selected`.
        --   • <Name>Row    — the WHOLE-row background at REST: `tint.row` (via the menu row `hl`).
        --   • <Name>RowSel — the WHOLE-row background while selected: `tint.row_selected` (the row
        --                    `sel_hl`, used instead of the blue bar — the cursor line is a stronger
        --                    tint of the row's OWN colour).
        --   • <Name>Text   — the label text: the accent as fg only, so the row tint shows through.
        --   • <Name>Detail — the right column (the kind name): the accent fg, BOLD.
        local t = config.menu.tint
        for name, accent in pairs(kinds.accents) do
            local color = c[accent] or c.fg
            groups["LvimCmpKind" .. name] = { fg = color, bg = hl.blend(color, panel, t.chip) }
            groups["LvimCmpKind" .. name .. "Sel"] = { fg = color, bg = hl.blend(color, panel, t.chip_selected) }
            groups["LvimCmpKind" .. name .. "Row"] = { bg = hl.blend(color, panel, t.row) }
            groups["LvimCmpKind" .. name .. "RowSel"] = { bg = hl.blend(color, panel, t.row_selected) }
            groups["LvimCmpKind" .. name .. "Text"] = { fg = color }
            groups["LvimCmpKind" .. name .. "Detail"] = { fg = color, bold = true }
        end
        return groups
    end)
end

return M
