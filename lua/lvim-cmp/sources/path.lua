-- lvim-cmp.sources.path: filesystem path completion. Trigger characters "/" and "~"
-- open the context; get() then reads the contiguous path token ENDING AT THE KEYWORD
-- START (the typed keyword itself is the fuzzy query, so it is excluded from the token):
-- a token ending in "/" is a directory prefix, a bare "~" lists $HOME (inserting
-- "/name" so the accepted text composes to "~/name"). Relative prefixes resolve against
-- BOTH the current file's directory and the cwd (file dir first, deduplicated), so
-- "./x" works from wherever the file lives AND from the project root. Directories rank
-- before files (sort_text), carry the Folder kind and (config) a trailing slash;
-- file chips upgrade to their lvim-icons devicon when that plugin is present.
--
---@module "lvim-cmp.sources.path"

local config = require("lvim-cmp.config")

local api = vim.api
local uv = vim.uv

local M = {}

M.name = "path"

-- LSP CompletionItemKind numbers used for the two entry types.
local KIND_FILE = 17
local KIND_FOLDER = 19

-- Characters that TERMINATE a path token, scanning left from the keyword start.
-- Everything else (letters, digits, ., -, _, ~, /, @, +, #, $, %%) may be part of one.
local TOKEN_PATTERN = "([^%s%'%\"%`%(%)%[%]{}<>,;=:|*?]*)$"

--- The contiguous path token ending at the keyword start of `ctx` (may be "").
---@param ctx LvimCmpContext
---@return string
local function path_token(ctx)
    local before = ctx.line:sub(1, ctx.bounds.s)
    return before:match(TOKEN_PATTERN) or ""
end

--- Resolve a path prefix (everything up to and including its last "/") to the absolute
--- directories to list. Relative prefixes try the current file's directory first, then
--- the cwd (deduplicated).
---@param prefix string  ends with "/"
---@param bufnr integer
---@return string[] dirs
local function resolve_dirs(prefix, bufnr)
    if prefix:sub(1, 1) == "/" then
        return { prefix }
    end
    if prefix:sub(1, 2) == "~/" then
        local home = uv.os_homedir()
        if not home then
            return {}
        end
        return { home .. prefix:sub(2) }
    end
    local bases, dirs, seen = {}, {}, {}
    local name = api.nvim_buf_get_name(bufnr)
    if name ~= "" then
        bases[#bases + 1] = vim.fs.dirname(name)
    end
    bases[#bases + 1] = uv.cwd()
    for _, base in ipairs(bases) do
        if base and base ~= "" then
            local dir = vim.fs.normalize(base .. "/" .. prefix)
            if not seen[dir] then
                seen[dir] = true
                dirs[#dirs + 1] = dir
            end
        end
    end
    return dirs
end

--- One completion item for a directory entry. `insert_prefix` is prepended to the
--- INSERTED text only (the bare-"~" case composes "~" + "/name").
---@param name string
---@param is_dir boolean
---@param insert_prefix string
---@return LvimCmpItem
local function entry_item(name, is_dir, insert_prefix)
    local insert = insert_prefix .. name
    if is_dir and config.sources.path.trailing_slash then
        insert = insert .. "/"
    end
    local item = {
        -- no `detail`: the menu's right column already shows the kind name
        -- (Folder/File), and a detail would drag an empty docs float up for it
        raw = { label = name, insertText = insert },
        source_name = M.name,
        label = name,
        filter_text = name,
        -- directories list before files on the empty query
        sort_text = (is_dir and "0" or "1") .. name,
        kind = is_dir and KIND_FOLDER or KIND_FILE,
    }
    if not is_dir then
        -- cross-plugin optional: per-extension devicon chip (font glyphs only — the
        -- chip column is a fixed single cell)
        local ok, icons = pcall(require, "lvim-icons")
        if ok then
            local ic = icons.get(name)
            if ic and ic.width == 1 then
                item.icon = ic.glyph
                item.icon_hl = ic.hl
            end
        end
    end
    return item
end

--- List `dir` into `items`, deduplicating by entry name across multiple base dirs.
---@param dir string
---@param insert_prefix string
---@param items LvimCmpItem[]
---@param seen table<string, boolean>
local function list_dir(dir, insert_prefix, items, seen)
    local handle = uv.fs_scandir(dir)
    if not handle then
        return
    end
    while true do
        local name, entry_type = uv.fs_scandir_next(handle)
        if not name then
            break
        end
        if not seen[name] then
            seen[name] = true
            local is_dir = entry_type == "directory"
            if entry_type == "link" then
                local st = uv.fs_stat(dir .. "/" .. name)
                is_dir = st ~= nil and st.type == "directory"
            end
            items[#items + 1] = entry_item(name, is_dir, insert_prefix)
        end
    end
end

--- Whether this source can serve the context.
---@param ctx LvimCmpContext
---@return boolean
function M.enabled(ctx)
    local _ = ctx
    return config.sources.path.enabled
end

--- The characters that open a path context.
---@param bufnr integer
---@return table<string, boolean>
function M.trigger_chars(bufnr)
    local _ = bufnr
    if not config.sources.path.enabled then
        return {}
    end
    return { ["/"] = true, ["~"] = true }
end

--- Complete the directory the context's path token points into. Emits empty (still
--- exactly once) when the text before the keyword is not a path.
---@param ctx LvimCmpContext
---@param cb fun(items: LvimCmpItem[], incomplete: boolean)
---@return fun()? cancel
function M.get(ctx, cb)
    local token = path_token(ctx)
    local items, seen = {}, {}
    if token == "~" then
        -- bare "~": list $HOME, inserting "/name" so the buffer composes to "~/name"
        local home = uv.os_homedir()
        if home then
            list_dir(home, "/", items, seen)
        end
    elseif token:sub(-1) == "/" then
        for _, dir in ipairs(resolve_dirs(token, ctx.bufnr)) do
            list_dir(dir, "", items, seen)
        end
    end
    vim.schedule(function()
        cb(items, false)
    end)
    return nil
end

return M
