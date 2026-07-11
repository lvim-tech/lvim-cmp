-- lvim-cmp.menu: the presenter — ranked items → lvim-ui `menu` rows. Owns the ONE
-- long-lived lvim-ui menu handle (the canonical cursor-anchored non-focusable popup;
-- never a raw float) and the row shape: a KIND chip box (accent per kind, the outline's
-- glyph family) + the label with matched-char highlighting (computed lazily by the
-- preset for VISIBLE rows only, via lvim-fuzzy positions) + a dim right detail column.
-- The window is anchored at the keyword START and offset by the chip width, so the
-- LABEL column sits exactly over the text being completed.
--
---@module "lvim-cmp.menu"

local config = require("lvim-cmp.config")
local fuzzy = require("lvim-cmp.fuzzy")
local kinds = require("lvim-cmp.kinds")
local ui = require("lvim-ui")

local M = {}

-- The kind chip is " <icon> " = 3 cells; the window shifts left by that much so the
-- label lands on the keyword.
local CHIP_CELLS = 3

---@type table? the lazily-created lvim-ui menu handle
local handle = nil

--- The (lazily created) shared menu handle, configured from the live config.
---@return table
local function ensure_handle()
    if handle then
        return handle
    end
    handle = ui.menu({
        max_height = config.menu.max_height,
        max_width = config.menu.max_width,
        col_offset = -CHIP_CELLS,
        direction_priority = config.menu.direction_priority,
        scrollbar = config.menu.scrollbar,
        hl = { match = "LvimCmpMatch" },
    })
    return handle
end

--- One dim right-column string for an item: its LSP detail (first line), else the kind name.
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
    local want_detail = config.menu.detail
    for i, item in ipairs(items) do
        local icon, khl, kname = kinds.get(item.kind)
        local boxes = {
            { text = " " .. icon .. " ", hl = khl },
            {
                text = item.label,
                positions = function()
                    return fuzzy.positions(item.label, query)
                end,
            },
        }
        if want_detail then
            boxes[#boxes + 1] = {
                text = " " .. detail_text(item, kname) .. " ",
                hl = "LvimCmpDetail",
                right = true,
            }
        end
        rows[i] = { boxes = boxes }
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
