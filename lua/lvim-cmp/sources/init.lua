-- lvim-cmp.sources: the source registry — lsp / snippets / path / buffer behind one
-- contract (enabled / trigger_chars / get / resolve / execute). Fan-out policy lives
-- here: sources run in config-priority order (the merge order among equal fuzzy
-- scores), a per-source `min_keyword_length` floor gates them (bypassed by a manual
-- trigger, or by a trigger character THE SOURCE ITSELF declares — a "/" context must
-- not fan out to a server that never asked for "/"), and a source with `fallback_for`
-- waits for the listed sources and runs only when they ALL returned 0 items (the flat
-- fallback list — not a DAG). Every source answers exactly once per context — an
-- ineligible or skipped-fallback source answers empty — so the engine's bookkeeping
-- never waits. Response staleness stays the ENGINE's job (context ids).
--
---@module "lvim-cmp.sources"

local config = require("lvim-cmp.config")
local lsp_source = require("lvim-cmp.sources.lsp")
local snippets_source = require("lvim-cmp.sources.snippets")
local path_source = require("lvim-cmp.sources.path")
local buffer_source = require("lvim-cmp.sources.buffer")

local M = {}

---@class LvimCmpItem                 one completion candidate (LSP-shaped + bookkeeping)
---@field raw table                   the raw LSP-shaped CompletionItem (insert/resolve target)
---@field source_name string
---@field label string
---@field filter_text string          filterText or label — what fuzzy matching runs on
---@field sort_text string            sortText or label — the empty-query / tiebreak order
---@field kind integer?               CompletionItemKind
---@field client_id integer?          the LSP client that produced it (lsp source only)
---@field icon string?                per-item chip glyph override (path devicons)
---@field icon_hl string?             highlight group for the chip override
---@field resolved boolean?           completionItem/resolve already ran (docs prefetch → accept reuse)

---@class LvimCmpSource               the source contract every sources/<name>.lua module implements
---@field name string
---@field enabled fun(ctx: LvimCmpContext): boolean
---@field trigger_chars? fun(bufnr: integer): table<string, boolean>
---@field get fun(ctx: LvimCmpContext, cb: fun(items: LvimCmpItem[], incomplete: boolean)): fun()?
---@field resolve? fun(item: LvimCmpItem, cb: fun(item: LvimCmpItem))
---@field execute? fun(item: LvimCmpItem, bufnr: integer)

--- The registered sources (order here is the stable tiebreak; fan-out re-sorts by the
--- LIVE config priority, so a setup()-time priority change takes effect immediately).
---@type LvimCmpSource[]
local providers = { lsp_source, snippets_source, path_source, buffer_source }

--- The per-source config table for `name` (empty for an unknown source).
---@param name string
---@return table
local function source_config(name)
    return config.sources[name] or {}
end

--- Every registered source, in effective priority order (highest first; registry order
--- breaks ties) — the merge order the engine builds the candidate list in.
---@return LvimCmpSource[]
function M.list()
    local order = {}
    for i, src in ipairs(providers) do
        order[i] = { src = src, i = i, p = source_config(src.name).priority or 0 }
    end
    table.sort(order, function(a, b)
        if a.p ~= b.p then
            return a.p > b.p
        end
        return a.i < b.i
    end)
    local out = {}
    for k, e in ipairs(order) do
        out[k] = e.src
    end
    return out
end

--- The union of trigger characters across the sources that serve `bufnr`.
---@param bufnr integer
---@return table<string, boolean>
function M.trigger_chars(bufnr)
    local set = {}
    for _, src in ipairs(providers) do
        if src.trigger_chars then
            for ch in pairs(src.trigger_chars(bufnr)) do
                set[ch] = true
            end
        end
    end
    return set
end

--- Whether `src` should actually run for `ctx`: enabled, and past its keyword floor.
--- The floor is bypassed by a manual trigger and by a trigger character the source
--- itself declares (another source's character does not open THIS source).
---@param src LvimCmpSource
---@param ctx LvimCmpContext
---@return boolean
local function eligible(src, ctx)
    if not src.enabled(ctx) then
        return false
    end
    if ctx.manual then
        return true
    end
    if ctx.trigger_char and src.trigger_chars and src.trigger_chars(ctx.bufnr)[ctx.trigger_char] then
        return true
    end
    return #ctx.keyword >= (source_config(src.name).min_keyword_length or 0)
end

--- Fan a context out to every eligible source. `on_response(source_name, items,
--- incomplete)` fires exactly once per REGISTERED source (schedule'd): eligible primaries
--- run immediately; a `fallback_for` source runs once the sources it falls back for have
--- all answered with 0 items, and answers empty otherwise. Returns a cancel function
--- that aborts everything still in flight (including a not-yet-started fallback).
---@param ctx LvimCmpContext
---@param on_response fun(source_name: string, items: LvimCmpItem[], incomplete: boolean)
---@return fun() cancel
function M.fanout(ctx, on_response)
    local cancels = {} ---@type fun()[]
    local cancelled = false
    ---@type table<string, integer>  responded source → its item count
    local counts = {}
    ---@type LvimCmpSource[]  fallback sources still waiting on their dependencies
    local waiting = {}

    --- Emit an EMPTY response for `src` (ineligible / skipped fallback), scheduled so
    --- the engine's bookkeeping stays uniform.
    ---@param src LvimCmpSource
    local function answer_empty(src)
        counts[src.name] = 0
        vim.schedule(function()
            if not cancelled then
                on_response(src.name, {}, false)
            end
        end)
    end

    --- Run `src` now, recording its count when it answers.
    ---@param src LvimCmpSource
    ---@param after fun()?  ran after the response lands (fallback re-check)
    local function run(src, after)
        local cancel = src.get(ctx, function(items, incomplete)
            counts[src.name] = #items
            if not cancelled then
                on_response(src.name, items, incomplete)
            end
            if after then
                after()
            end
        end)
        if cancel then
            cancels[#cancels + 1] = cancel
        end
    end

    --- Release every waiting fallback whose dependencies have all answered: run it when
    --- they produced nothing, answer empty when they produced items. An unknown name in
    --- `fallback_for` is ignored (it can never answer). Iterates to a fixed point so a
    --- fallback (mis)listed as another fallback's dependency still resolves.
    local function check_fallbacks()
        local progressed = true
        while progressed and #waiting > 0 do
            progressed = false
            local still = {}
            for _, src in ipairs(waiting) do
                local pending, total = false, 0
                for _, dep in ipairs(source_config(src.name).fallback_for) do
                    if counts[dep] == nil then
                        for _, p in ipairs(providers) do
                            if p.name == dep then
                                pending = true
                                break
                            end
                        end
                    else
                        total = total + counts[dep]
                    end
                end
                if pending then
                    still[#still + 1] = src
                elseif total == 0 then
                    progressed = true
                    run(src, check_fallbacks)
                else
                    progressed = true
                    answer_empty(src)
                end
            end
            waiting = still
        end
    end

    for _, src in ipairs(M.list()) do
        local fallback_for = source_config(src.name).fallback_for
        if not eligible(src, ctx) then
            answer_empty(src)
        elseif type(fallback_for) == "table" and #fallback_for > 0 then
            waiting[#waiting + 1] = src
        else
            run(src, check_fallbacks)
        end
    end
    check_fallbacks() -- dependencies may already all be answered (all ineligible)

    return function()
        cancelled = true
        waiting = {}
        for _, cancel in ipairs(cancels) do
            cancel()
        end
    end
end

--- Resolve an item through the source that produced it.
---@param item LvimCmpItem
---@param cb fun(item: LvimCmpItem)
function M.resolve(item, cb)
    for _, src in ipairs(providers) do
        if src.name == item.source_name and src.resolve then
            src.resolve(item, cb)
            return
        end
    end
    vim.schedule(function()
        cb(item)
    end)
end

--- Run an accepted item's post-accept command through its source.
---@param item LvimCmpItem
---@param bufnr integer
function M.execute(item, bufnr)
    for _, src in ipairs(providers) do
        if src.name == item.source_name and src.execute then
            src.execute(item, bufnr)
            return
        end
    end
end

return M
