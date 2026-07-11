-- lvim-cmp.ghost: the inline ghost-text preview — the SELECTED item's remaining text as
-- a dim italic inline extmark at the cursor (plus virt_lines for a multi-line body).
-- Shown only when the item's insert text literally starts with the typed keyword: a
-- fuzzy (non-prefix) match has no truthful "remainder" to overlay, so it shows nothing
-- instead of something wrong. ONE extmark id is reused across keystrokes.
--
---@module "lvim-cmp.ghost"

local api = vim.api

local M = {}

local ns = api.nvim_create_namespace("lvim_cmp_ghost")

-- The reused extmark id (one ghost at a time) and the buffer it lives in.
---@type integer
local MARK_ID = 1
---@type integer?
local marked_buf = nil

--- Show the ghost for `item` at the current cursor, given the typed `keyword`.
--- Clears instead when the item is not a literal prefix extension.
---@param item LvimCmpItem
---@param keyword string
function M.show(item, keyword)
    local text = (item.raw.textEdit and item.raw.textEdit.newText) or item.raw.insertText or item.label or ""
    -- snippet placeholders would render literally — strip the preview down to the label
    if item.raw.insertTextFormat == 2 then
        text = item.label or ""
    end
    if keyword == "" or text == keyword or text:sub(1, #keyword) ~= keyword then
        M.clear()
        return
    end
    local remainder = text:sub(#keyword + 1)
    local lines = vim.split(remainder, "\n", { plain = true })
    local virt_lines = nil
    if #lines > 1 then
        virt_lines = {}
        for i = 2, #lines do
            virt_lines[i - 1] = { { lines[i], "LvimCmpGhost" } }
        end
    end
    local bufnr = api.nvim_get_current_buf()
    local cursor = api.nvim_win_get_cursor(0)
    pcall(api.nvim_buf_set_extmark, bufnr, ns, cursor[1] - 1, cursor[2], {
        id = MARK_ID,
        virt_text = { { lines[1], "LvimCmpGhost" } },
        virt_text_pos = "inline",
        hl_mode = "combine",
        virt_lines = virt_lines,
        ephemeral = false,
    })
    marked_buf = bufnr
end

--- Remove the ghost (no-op when none is shown).
function M.clear()
    if marked_buf and api.nvim_buf_is_valid(marked_buf) then
        api.nvim_buf_del_extmark(marked_buf, ns, MARK_ID)
    end
    marked_buf = nil
end

return M
