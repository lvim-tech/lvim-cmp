-- lvim-cmp.menu: the presenter — ranked items → lvim-ui `menu` rows. Owns the ONE
-- long-lived lvim-ui menu handle (the canonical cursor-anchored non-focusable popup;
-- never a raw float). Every row is coloured by its KIND accent (a self-tinting legend):
-- a KIND chip box (accent fg over a tint, strong `…Sel` variant on the selected row; an
-- item may override the glyph — path devicons) + the label in the accent fg (padded by
-- `menu.label_padding`) with matched-char highlighting (computed lazily by the preset for
-- VISIBLE rows only, via lvim-fuzzy positions) + an optional dim right column
-- (`menu.detail`: "kind" shows the kind name, "lsp" the LSP detail's first line, false
-- drops it). The whole row carries a faint accent-tinted background (row `hl`), overridden
-- by the blue selection bar on the active row. The window is anchored at the keyword START
-- and offset by the chip + label-padding width, so the label TEXT sits over the text being
-- completed. The docs float renders in the handle's sibling docs slot (docked beside the
-- menu by the primitive), passed through here so docs.lua never touches a window itself.
--
---@module "lvim-cmp.menu"

local config = require("lvim-cmp.config")
local fuzzy = require("lvim-cmp.fuzzy")
local kinds = require("lvim-cmp.kinds")
local ui = require("lvim-ui")

local M = {}

---@type table? the lazily-created lvim-ui menu handle
local handle = nil

--- The kind-chip padding: `menu.icon_padding` spaces on each side of the (single-width
--- Nerd) glyph. The chip is left+1+right cells wide.
---@return string left, string right, integer cells
local function chip_padding()
    local pad = config.menu.icon_padding
    local l = math.max(0, pad.left or 0)
    local r = math.max(0, pad.right or 0)
    return string.rep(" ", l), string.rep(" ", r), l + 1 + r
end

--- The label padding: `menu.label_padding` spaces on each side of the label text.
---@return string left, string right, integer left_cells
local function label_padding()
    local pad = config.menu.label_padding
    local l = math.max(0, pad.left or 0)
    local r = math.max(0, pad.right or 0)
    return string.rep(" ", l), string.rep(" ", r), l
end

--- The (lazily created) shared menu handle, configured from the live config.
---@return table
local function ensure_handle()
    if handle then
        return handle
    end
    local _, _, chip_cells = chip_padding()
    local _, _, label_left = label_padding()
    handle = ui.menu({
        max_height = config.menu.max_height,
        max_width = config.menu.max_width,
        -- shift left by the chip AND the label's left padding, so the label TEXT (not its
        -- leading spaces) lands on the keyword being completed
        col_offset = -(chip_cells + label_left),
        direction_priority = config.menu.direction_priority,
        scrollbar = config.menu.scrollbar,
        docs = { max_width = config.docs.max_width, max_height = config.docs.max_height },
        hl = { match = "LvimCmpMatch" },
    })
    return handle
end

--- The dim right-column string for an item under `menu.detail = "lsp"`: its LSP detail
--- (first line), else the kind name.
---@param item LvimCmpItem
---@param kind_name string
---@return string
local function detail_text(item, kind_name)
    local d = item.raw.detail
    if type(d) == "string" and d ~= "" then
        d = d:match("^[^\n]*") or d
        return d
    end
    return kind_name
end

--- Build the lvim-ui menu rows for `items` under `query`.
---@param items LvimCmpItem[]
---@param query string
---@return table[] rows  LvimUiMenuRow[]
local function build_rows(items, query)
    local rows = {}
    local detail_mode = config.menu.detail
    local pad_l, pad_r = chip_padding()
    local lpad_l, lpad_r, lpad_left_n = label_padding()
    for i, item in ipairs(items) do
        local icon, khl, kname = kinds.get(item.kind)
        -- The chip's selected-row variant raises it to the strong/active tint so it composes
        -- with the selection bar (see highlights.lua).
        ---@type string?
        local sel_khl = khl .. "Sel"
        -- a source may override the chip glyph (path devicons); the group follows it —
        -- devicon groups are fg-only, so the selection bar shows through (no Sel variant)
        if item.icon then
            icon = item.icon
            if item.icon_hl then
                khl, sel_khl = item.icon_hl, nil
            end
        end
        local boxes = {
            { text = pad_l .. icon .. pad_r, hl = khl, sel_hl = sel_khl },
            {
                -- the label in the kind's accent (fg only; the row tint shows through), padded
                text = lpad_l .. item.label .. lpad_r,
                hl = "LvimCmpKind" .. kname .. "Text",
                positions = function()
                    -- fuzzy positions are byte offsets in item.label; the box text prepends
                    -- `lpad_left_n` spaces, so shift them to land on the padded label
                    local ps = fuzzy.positions(item.label, query)
                    if ps and lpad_left_n > 0 then
                        for k = 1, #ps do
                            ps[k] = ps[k] + lpad_left_n
                        end
                    end
                    return ps
                end,
            },
        }
        if detail_mode then
            boxes[#boxes + 1] = {
                text = " " .. (detail_mode == "lsp" and detail_text(item, kname) or kname) .. " ",
                hl = "LvimCmpKind" .. kname .. "Detail", -- the kind name in the accent, bold
                right = true,
            }
        end
        -- the whole row gets a faint accent-tinted background at rest (`hl`); while selected it
        -- becomes a STRONGER tint of the SAME accent (`sel_hl`) — the cursor line, not a blue bar
        rows[i] = {
            boxes = boxes,
            hl = "LvimCmpKind" .. kname .. "Row",
            sel_hl = "LvimCmpKind" .. kname .. "RowSel",
        }
    end
    return rows
end

--- Show/refresh the menu for a ranked item list.
---@param items LvimCmpItem[]
---@param query string
---@param ctx LvimCmpContext  the anchor comes from its keyword bounds
---@param selected integer?   preselected row (nil = none)
function M.show(items, query, ctx, selected)
    local h = ensure_handle()
    h.show({
        items = build_rows(items, query),
        anchor = { lnum = ctx.cursor[1], col = ctx.bounds.s, win = ctx.win },
        selected = selected,
    })
end

--- Whether the menu is on screen.
---@return boolean
function M.visible()
    return handle ~= nil and handle.visible()
end

--- Move the selection by `delta` (wraps).
---@param delta integer
function M.select_move(delta)
    if handle then
        handle.select_move(delta)
    end
end

--- The selected row index, or nil.
---@return integer?
function M.selected()
    return handle and handle.selected() or nil
end

--- Show markdown `lines` in the sibling docs slot (glued beside the menu by the
--- primitive; treesitter-highlighted as markdown).
---@param lines string[]
function M.docs_show(lines)
    if handle and handle.visible() then
        handle.docs_show(lines, { filetype = "markdown" })
    end
end

--- Hide the docs slot (the menu stays).
function M.docs_hide()
    if handle then
        handle.docs_hide()
    end
end

--- Scroll the docs slot by `delta` screen lines (sign = direction). Returns whether a
--- docs window was present to scroll.
---@param delta integer
---@return boolean
function M.docs_scroll(delta)
    if handle and handle.docs_scroll then
        return handle.docs_scroll(delta)
    end
    return false
end

--- Hide the menu (keeps the long-lived window buffer for the next show).
function M.hide()
    if handle then
        handle.hide()
    end
end

--- Destroy the handle (teardown / disable).
function M.close()
    if handle then
        handle.close()
        handle = nil
    end
end

return M
