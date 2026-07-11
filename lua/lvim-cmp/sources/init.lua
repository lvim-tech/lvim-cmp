-- lvim-cmp.sources: the source registry. The foundation ships ONE source (lsp); the
-- registry exists so buffer/path/snippet sources plug in as `sources/<name>.lua` modules
-- with the same contract (enabled / trigger_chars / get / resolve / execute) without the
-- engine changing. Fan-out and per-source config gating live here; response staleness is
-- the ENGINE's job (it stamps and checks context ids).
--
---@module "lvim-cmp.sources"

local lsp_source = require("lvim-cmp.sources.lsp")

local M = {}

--- The registered sources, in priority order (highest first).
---@type table[]
local providers = { lsp_source }

--- Every registered source module (for health reporting).
---@return table[]
function M.list()
    return providers
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

--- Fan a context out to every enabled source. `on_response(source_name, items,
--- incomplete)` fires once per source (schedule'd by the source). Returns a cancel
--- function that aborts everything still in flight.
---@param ctx LvimCmpContext
---@param on_response fun(source_name: string, items: LvimCmpItem[], incomplete: boolean)
---@return fun() cancel
function M.fanout(ctx, on_response)
    local cancels = {} ---@type fun()[]
    for _, src in ipairs(providers) do
        if src.enabled(ctx) then
            local cancel = src.get(ctx, function(items, incomplete)
                on_response(src.name, items, incomplete)
            end)
            if cancel then
                cancels[#cancels + 1] = cancel
            end
        else
            -- an ineligible source still answers (empty), so the engine's bookkeeping
            -- never waits on it
            vim.schedule(function()
                on_response(src.name, {}, false)
            end)
        end
    end
    return function()
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
