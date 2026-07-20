-- lvim-cmp.accept: turn an accepted item into buffer text. The replaced range runs from
-- the item's textEdit START (the server computed it against the request-time document)
-- to the CURRENT cursor — the user typed since the edit was computed, and that typed
-- tail belongs to the query, so it is consumed by the replacement. Snippet-format items
-- expand through native vim.snippet; additionalTextEdits (imports etc.) apply through
-- the standard lsp.util path in the client's offset encoding.
--
---@module "lvim-cmp.accept"

local api = vim.api
local lsp = vim.lsp

local M = {}

--- Byte column of an LSP position character offset on `line`, honouring the client's
--- offset encoding (utf-16 by default). Clamped into the line.
---@param line string
---@param character integer
---@param encoding string
---@return integer
local function byte_col(line, character, encoding)
    if character <= 0 then
        return 0
    end
    local ok, col = pcall(vim.str_byteindex, line, encoding, character, false)
    if ok and col then
        return math.min(col, #line)
    end
    return math.min(character, #line)
end

--- The text an item inserts and whether it is snippet-format.
---@param raw table  the raw LSP CompletionItem
---@return string text, boolean is_snippet
local function insert_text(raw)
    local text = (raw.textEdit and raw.textEdit.newText) or raw.insertText or raw.label or ""
    return text, raw.insertTextFormat == 2
end

--- Apply `item` at the current cursor: replace [edit start .. cursor] with the item's
--- text (plain insert or vim.snippet expansion), then additionalTextEdits and the
--- item's command. Must run in insert mode in the target buffer.
---@param item LvimCmpItem
---@param ctx LvimCmpContext  the context the menu was built from (bounds fallback)
function M.apply(item, ctx)
    local bufnr = api.nvim_get_current_buf()
    if bufnr ~= ctx.bufnr then
        return
    end
    local cursor = api.nvim_win_get_cursor(0)
    local row = cursor[1] - 1
    local line = api.nvim_get_current_line()
    local client = item.client_id and lsp.get_client_by_id(item.client_id) or nil
    local encoding = (client and client.offset_encoding) or "utf-16"

    -- start column: the textEdit's (insert-mode range of an InsertReplaceEdit), else the
    -- keyword bounds the context was built from
    local scol
    local te = item.raw.textEdit
    local te_range = te and (te.range or te.insert)
    if te_range and te_range.start.line == row then
        scol = byte_col(line, te_range.start.character, encoding)
    else
        scol = math.min(ctx.bounds.s, #line)
    end
    local ecol = math.min(cursor[2], #line)
    if scol > ecol then
        scol = ecol
    end

    local text, is_snippet = insert_text(item.raw)
    if is_snippet then
        -- clear the typed range, land the cursor at its start, then expand. `item.expand` is a
        -- custom expander (a LuaSnip collection sets it — only LuaSnip can drive nodes it built);
        -- everything else goes through lvim-snippets' session engine, which implements the whole LSP
        -- grammar, and falls back to `vim.snippet` when that plugin is not installed.
        api.nvim_buf_set_text(bufnr, row, scol, row, ecol, { "" })
        api.nvim_win_set_cursor(0, { row + 1, scol })
        if type(item.expand) == "function" then
            item.expand()
        else
            local ok, session = pcall(require, "lvim-snippets.session")
            if ok and type(session.expand) == "function" then
                session.expand(text)
            else
                vim.snippet.expand(text)
            end
        end
    else
        local lines = vim.split(text, "\n", { plain = true })
        api.nvim_buf_set_text(bufnr, row, scol, row, ecol, lines)
        local last = lines[#lines]
        local end_row = row + #lines - 1
        local end_col = (#lines == 1) and (scol + #last) or #last
        api.nvim_win_set_cursor(0, { end_row + 1, end_col })
    end

    -- imports / auto-edits away from the cursor (filled in by resolve)
    local extra = item.raw.additionalTextEdits
    if type(extra) == "table" and #extra > 0 then
        lsp.util.apply_text_edits(extra, bufnr, encoding)
    end
end

return M
