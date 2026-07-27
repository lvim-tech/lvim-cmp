-- lvim-cmp.kinds: CompletionItemKind → display triple (glyph, highlight group, name). The
-- glyph and the accent are NOT owned here — they live in the LIVE config (`config.kinds`),
-- so a user `setup({ kinds = { accents = { Text = "cyan" } } })` recolours a kind without a
-- fork. This module only resolves the protocol NUMBER to a name and reads the live tables;
-- highlights.lua derives one `LvimCmpKind<Name>*` group family per accent.
--
---@module "lvim-cmp.kinds"

local config = require("lvim-cmp.config")

local M = {}

-- LSP CompletionItemKind numbers → names (the protocol table is bi-directional).
local KIND_NAME = vim.lsp.protocol.CompletionItemKind

--- Resolve a CompletionItemKind number to its display triple.
---@param kind integer?  the LSP kind number (nil/unknown → Text)
---@return string icon, string hl_group, string name
function M.get(kind)
    local name = (kind and KIND_NAME[kind]) or "Text"
    if type(name) ~= "string" then
        name = "Text"
    end
    local icons = config.kinds.icons
    return icons[name] or icons.Text, "LvimCmpKind" .. name, name
end

return M
