-- lvim-cmp.sources.snippets: completion items from VS Code-format snippet collections,
-- expanded natively through vim.snippet on accept (the same path LSP snippet items take
-- — no snippet engine of our own). Discovery scans each configured root (plus
-- stdpath("config")/snippets, always) and its immediate subdirectories: a directory
-- with a package.json manifest maps files per its `contributes.snippets` (language →
-- path); loose `<filetype>.json` files map by basename. The language "all" applies to
-- every filetype. Files parse LAZILY, once per filetype per session, into ready items
-- whose documentation (description + fenced body) feeds the docs float.
--
---@module "lvim-cmp.sources.snippets"

local config = require("lvim-cmp.config")

local uv = vim.uv

local M = {}

M.name = "snippets"

-- LSP CompletionItemKind.Snippet / InsertTextFormat.Snippet
local KIND_SNIPPET = 15
local FORMAT_SNIPPET = 2

---@type table<string, string[]>?  language → snippet-file paths (nil until discovery ran)
local files_by_lang = nil

---@type table<string, LvimCmpItem[]>  filetype → built items (parsed lazily, kept per session)
local items_by_ft = {}

---@type string[]  files that failed to parse (reported by :checkhealth)
local broken_files = {}

--- Read + JSON-decode a file; nil (and a health note) on failure.
---@param path string
---@return table?
local function read_json(path)
    local fd = io.open(path, "r")
    if not fd then
        return nil
    end
    local text = fd:read("*a")
    fd:close()
    local ok, decoded = pcall(vim.json.decode, text)
    if not ok or type(decoded) ~= "table" then
        broken_files[#broken_files + 1] = path
        return nil
    end
    return decoded
end

--- Register `path` for one language (or a list of languages) in `map`.
---@param map table<string, string[]>
---@param lang string|string[]
---@param path string
local function register(map, lang, path)
    local langs = type(lang) == "table" and lang or { lang }
    for _, l in ipairs(langs) do
        if type(l) == "string" and l ~= "" then
            map[l] = map[l] or {}
            map[l][#map[l] + 1] = path
        end
    end
end

--- Register one collection directory: by its package.json manifest when present, else
--- by loose `<lang>.json` basenames. Returns whether the dir contributed anything.
---@param map table<string, string[]>
---@param dir string
---@return boolean
local function register_dir(map, dir)
    local found = false
    local manifest = read_json(dir .. "/package.json")
    local contributes = manifest and manifest.contributes and manifest.contributes.snippets
    if type(contributes) == "table" then
        for _, entry in ipairs(contributes) do
            if type(entry) == "table" and type(entry.path) == "string" and entry.language then
                local path = vim.fs.normalize(dir .. "/" .. entry.path)
                if uv.fs_stat(path) then
                    register(map, entry.language, path)
                    found = true
                end
            end
        end
        return found
    end
    local handle = uv.fs_scandir(dir)
    while handle do
        local name, entry_type = uv.fs_scandir_next(handle)
        if not name then
            break
        end
        if entry_type == "file" and name:sub(-5) == ".json" and name ~= "package.json" then
            register(map, name:sub(1, -6), dir .. "/" .. name)
            found = true
        end
    end
    return found
end

--- Discover every collection once: each root in config (plus the implicit
--- stdpath("config")/snippets) and its immediate subdirectories.
---@return table<string, string[]>
local function discover()
    if files_by_lang then
        return files_by_lang
    end
    local map = {}
    local roots = { vim.fn.stdpath("config") .. "/snippets" }
    for _, p in ipairs(config.sources.snippets.paths) do
        roots[#roots + 1] = vim.fs.normalize(p)
    end
    for _, root in ipairs(roots) do
        if uv.fs_stat(root) then
            register_dir(map, root)
            local handle = uv.fs_scandir(root)
            while handle do
                local name, entry_type = uv.fs_scandir_next(handle)
                if not name then
                    break
                end
                if entry_type == "directory" then
                    register_dir(map, root .. "/" .. name)
                end
            end
        end
    end
    files_by_lang = map
    return map
end

--- Build the items of ONE parsed snippet file for `ft`. A snippet may declare several
--- prefixes — each becomes its own item (same body).
---@param snippets table   the decoded file: name → { prefix, body, description }
---@param ft string        fence language for the documentation preview
---@param out LvimCmpItem[]
local function build_items(snippets, ft, out)
    for name, snip in pairs(snippets) do
        if type(snip) == "table" and snip.prefix and snip.body then
            local body = type(snip.body) == "table" and table.concat(snip.body, "\n") or tostring(snip.body)
            local desc = snip.description
            if type(desc) == "table" then
                desc = table.concat(desc, "\n")
            end
            local doc = (type(desc) == "string" and desc ~= "" and (desc .. "\n\n") or "")
                .. "```"
                .. ft
                .. "\n"
                .. body
                .. "\n```"
            local prefixes = type(snip.prefix) == "table" and snip.prefix or { snip.prefix }
            for _, prefix in ipairs(prefixes) do
                if type(prefix) == "string" and prefix ~= "" then
                    out[#out + 1] = {
                        raw = {
                            label = prefix,
                            insertText = body,
                            insertTextFormat = FORMAT_SNIPPET,
                            detail = type(name) == "string" and name or nil,
                            documentation = { kind = "markdown", value = doc },
                        },
                        source_name = M.name,
                        label = prefix,
                        filter_text = prefix,
                        sort_text = prefix,
                        kind = KIND_SNIPPET,
                    }
                end
            end
        end
    end
end

--- The (lazily built, session-cached) items for a filetype: its own files + "all".
---@param ft string
---@return LvimCmpItem[]
local function items_for(ft)
    if ft == "" then
        ft = "all"
    end
    local cached = items_by_ft[ft]
    if cached then
        return cached
    end
    local map = discover()
    local out = {}
    local paths = {}
    vim.list_extend(paths, map[ft] or {})
    if ft ~= "all" then
        vim.list_extend(paths, map.all or {})
    end
    for _, path in ipairs(paths) do
        local decoded = read_json(path)
        if decoded then
            build_items(decoded, ft, out)
        end
    end
    items_by_ft[ft] = out
    return out
end

--- Whether this source can serve the context.
---@param ctx LvimCmpContext
---@return boolean
function M.enabled(ctx)
    local _ = ctx
    return config.sources.snippets.enabled
end

--- Emit the context filetype's snippet items.
---@param ctx LvimCmpContext
---@param cb fun(items: LvimCmpItem[], incomplete: boolean)
---@return fun()? cancel
function M.get(ctx, cb)
    local items = items_for(vim.bo[ctx.bufnr].filetype)
    vim.schedule(function()
        cb(items, false)
    end)
    return nil
end

--- Registry statistics for :checkhealth.
---@return { languages: integer, files: integer, broken: string[] }
function M.stats()
    local map = discover()
    local languages, files = 0, 0
    for _, paths in pairs(map) do
        languages = languages + 1
        files = files + #paths
    end
    return { languages = languages, files = files, broken = broken_files }
end

--- Drop the discovery + item caches (config `paths` changed / new files on disk).
function M.reset()
    files_by_lang = nil
    items_by_ft = {}
    broken_files = {}
end

return M
