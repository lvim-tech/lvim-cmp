-- lvim-cmp.kinds: CompletionItemKind → Nerd glyph + accent — the SAME glyph family and
-- palette spread as the lvim-lsp outline/breadcrumbs, so a symbol looks identical in the
-- completion menu and in the outline. The accent map keys are live-palette colour names
-- consumed by highlights.lua (which derives one LvimCmpKind<Name> chip group per kind).
--
---@module "lvim-cmp.kinds"

local M = {}

-- LSP CompletionItemKind numbers → names (the protocol table is bi-directional).
local KIND_NAME = vim.lsp.protocol.CompletionItemKind

-- Kind name → glyph (Nerd Font, single width — verified via strdisplaywidth).
---@type table<string, string>
M.icons = {
    Text = "󰉿",
    Method = "󰆧",
    Function = "󰊕",
    Constructor = "󰙴",
    Field = "󰜢",
    Variable = "󰀫",
    Class = "󰠱",
    Interface = "󰜰",
    Module = "󰏗",
    Property = "󰜢",
    Unit = "󰑭",
    Value = "󰎠",
    Enum = "󰕘",
    Keyword = "󰌋",
    Snippet = "󰩫",
    Color = "󰏘",
    File = "󰈙",
    Reference = "󰈇",
    Folder = "󰉋",
    EnumMember = "󰦨",
    Constant = "󰏿",
    Struct = "󰙅",
    Event = "󰉁",
    Operator = "󰆕",
    TypeParameter = "󰫣",
}

-- Kind name → palette accent key (the outline's spread: functions blue, types yellow,
-- interfaces/enums orange, variables cyan, fields teal, constants red, modules purple,
-- values green, container-ish kinds magenta).
---@type table<string, string>
M.accents = {
    Text = "fg",
    Method = "blue",
    Function = "blue",
    Constructor = "blue",
    Field = "teal",
    Variable = "cyan",
    Class = "yellow",
    Interface = "orange",
    Module = "purple",
    Property = "teal",
    Unit = "green",
    Value = "green",
    Enum = "orange",
    Keyword = "purple",
    Snippet = "green",
    Color = "magenta",
    File = "purple",
    Reference = "magenta",
    Folder = "purple",
    EnumMember = "orange",
    Constant = "red",
    Struct = "yellow",
    Event = "magenta",
    Operator = "magenta",
    TypeParameter = "orange",
}

--- Resolve a CompletionItemKind number to its display triple.
---@param kind integer?  the LSP kind number (nil/unknown → Text)
---@return string icon, string hl_group, string name
function M.get(kind)
    local name = (kind and KIND_NAME[kind]) or "Text"
    if type(name) ~= "string" then
        name = "Text"
    end
    return M.icons[name] or M.icons.Text, "LvimCmpKind" .. name, name
end

return M
