-- lvim-cmp.highlights: the plugin's highlight groups, self-themed from the shared
-- lvim-utils palette via a bound build() factory (re-applied on ColorScheme / palette
-- sync — the standard pipeline; never an inline colour in render logic). The menu
-- chrome groups (LvimUiMenu*) come from the lvim-ui menu preset; here live only the
-- lvim-cmp-specific ones: the kind chips, the match/detail/ghost text roles.
--
---@module "lvim-cmp.highlights"

local hl = require("lvim-utils.highlight")
local kinds = require("lvim-cmp.kinds")

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
        ---@param color string
        ---@param t number
        ---@return string
        local function mtint(color, t)
            return hl.blend(color, c.bg, t)
        end
        local groups = {
            -- matched query chars inside a label (painted on visible rows only)
            LvimCmpMatch = { fg = c.red, bold = true },
            -- the dim right detail column
            LvimCmpDetail = { fg = c.comment },
            -- inline ghost-text preview of the selected item's remainder
            LvimCmpGhost = { fg = c.comment, italic = true },
        }
        -- One chip group per CompletionItemKind: the kind's accent fg over a soft tint of
        -- the same accent (the ui.button lead-box canon), so the icon column reads as a
        -- colourful legend that tracks the live palette.
        for name, accent in pairs(kinds.accents) do
            local color = c[accent] or c.fg
            groups["LvimCmpKind" .. name] = { fg = color, bg = mtint(color, 0.15) }
        end
        return groups
    end)
end

return M
