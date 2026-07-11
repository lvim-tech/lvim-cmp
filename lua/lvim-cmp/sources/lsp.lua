-- lvim-cmp.sources.lsp: the LSP completion source — textDocument/completion fan-out
-- over every attached client that offers it, with cancellation, a timeout that turns a
-- slow server into a dropped straggler instead of a blocked menu, per-response
-- `isIncomplete` bookkeeping, `completionList.itemDefaults` folding, and
-- completionItem/resolve on accept. Responses are emitted through vim.schedule (off the
-- keystroke) and stamped with the requesting context id — the engine drops stale ones.
--
---@module "lvim-cmp.sources.lsp"

local config = require("lvim-cmp.config")

local lsp = vim.lsp
local uv = vim.uv

local M = {}

M.name = "lsp"

---@class LvimCmpItem                 one completion candidate (LSP-shaped + bookkeeping)
---@field raw table                   the raw LSP CompletionItem (resolve target)
---@field client_id integer           the client that produced it
---@field source_name string
---@field label string
---@field filter_text string          filterText or label — what fuzzy matching runs on
---@field sort_text string            sortText or label — the empty-query / tiebreak order
---@field kind integer?               CompletionItemKind

--- Clients attached to `bufnr` that provide completion.
---@param bufnr integer
---@return vim.lsp.Client[]
local function clients_for(bufnr)
    return lsp.get_clients({ bufnr = bufnr, method = "textDocument/completion" })
end

--- Whether this source can serve the context at all.
---@param ctx LvimCmpContext
---@return boolean
function M.enabled(ctx)
    return config.sources.lsp.enabled and #clients_for(ctx.bufnr) > 0
end

--- The union of every attached server's completion trigger characters.
---@param bufnr integer
---@return table<string, boolean>
function M.trigger_chars(bufnr)
    local set = {}
    for _, client in ipairs(clients_for(bufnr)) do
        local provider = client.server_capabilities.completionProvider
        for _, ch in ipairs((type(provider) == "table" and provider.triggerCharacters) or {}) do
            set[ch] = true
        end
    end
    return set
end

--- Fold `completionList.itemDefaults` into an item that omitted the field (the
--- capabilities() handshake declares support, so servers may rely on it).
---@param item table   raw LSP CompletionItem (mutated)
---@param defaults table?
local function apply_defaults(item, defaults)
    if not defaults then
        return
    end
    if item.insertTextFormat == nil then
        item.insertTextFormat = defaults.insertTextFormat
    end
    if item.insertTextMode == nil then
        item.insertTextMode = defaults.insertTextMode
    end
    if item.data == nil then
        item.data = defaults.data
    end
    if item.textEdit == nil and defaults.editRange and item.textEditText then
        -- editRange is either a Range or an { insert, replace } pair
        if defaults.editRange.insert then
            item.textEdit = {
                insert = defaults.editRange.insert,
                replace = defaults.editRange.replace,
                newText = item.textEditText,
            }
        else
            item.textEdit = { range = defaults.editRange, newText = item.textEditText }
        end
    end
end

--- Request completions for `ctx` from every capable client. `cb(items, incomplete)` is
--- called EXACTLY ONCE (vim.schedule'd): when every client answered, or when
--- `timeout_ms` fires with whatever has arrived (a straggler is then dropped). Returns
--- a cancel function that aborts the in-flight requests and suppresses the emit.
---@param ctx LvimCmpContext
---@param cb fun(items: LvimCmpItem[], incomplete: boolean)
---@return fun()? cancel
function M.get(ctx, cb)
    local clients = clients_for(ctx.bufnr)
    if #clients == 0 then
        vim.schedule(function()
            cb({}, false)
        end)
        return nil
    end

    local items = {} ---@type LvimCmpItem[]
    local incomplete = false
    local pending = #clients
    local finished = false
    ---@type { client: vim.lsp.Client, id: integer }[]
    local inflight = {}
    ---@type uv.uv_timer_t?
    local timer = uv.new_timer()

    local function stop_timer()
        if timer and not timer:is_closing() then
            timer:stop()
            timer:close()
        end
        timer = nil
    end

    --- Emit once (schedule'd off the keystroke), cancelling anything still in flight.
    local function emit()
        if finished then
            return
        end
        finished = true
        stop_timer()
        for _, req in ipairs(inflight) do
            req.client:cancel_request(req.id)
        end
        vim.schedule(function()
            cb(items, incomplete)
        end)
    end

    for _, client in ipairs(clients) do
        local params = lsp.util.make_position_params(ctx.win, client.offset_encoding)
        ---@diagnostic disable-next-line: inject-field  -- CompletionParams = PositionParams + context
        params.context = {
            triggerKind = ctx.trigger_char and 2 or 1,
            triggerCharacter = ctx.trigger_char,
        }
        local ok, request_id = client:request("textDocument/completion", params, function(err, result)
            if finished then
                return
            end
            pending = pending - 1
            if not err and result then
                -- CompletionList { isIncomplete, itemDefaults, items } or CompletionItem[]
                local list = result.items and result or { items = result, isIncomplete = false }
                if list.isIncomplete then
                    incomplete = true
                end
                local max = config.sources.lsp.max_items
                for _, raw in ipairs(list.items or {}) do
                    if max and #items >= max then
                        break
                    end
                    apply_defaults(raw, list.itemDefaults)
                    items[#items + 1] = {
                        raw = raw,
                        client_id = client.id,
                        source_name = M.name,
                        label = raw.label or "",
                        filter_text = raw.filterText or raw.label or "",
                        sort_text = raw.sortText or raw.label or "",
                        kind = raw.kind,
                    }
                end
            end
            if pending == 0 then
                emit()
            end
        end, ctx.bufnr)
        if ok and request_id then
            inflight[#inflight + 1] = { client = client, id = request_id }
        else
            pending = pending - 1
        end
    end
    if pending == 0 then
        emit()
        return nil
    end

    if timer then
        timer:start(config.sources.lsp.timeout_ms, 0, function()
            vim.schedule(emit)
        end)
    end

    return function()
        if finished then
            return
        end
        finished = true
        stop_timer()
        for _, req in ipairs(inflight) do
            req.client:cancel_request(req.id)
        end
    end
end

--- Resolve an item (documentation / detail / additionalTextEdits / command) via
--- completionItem/resolve when the server offers it; otherwise pass it through.
--- `cb(item)` always fires (schedule'd), with the resolved fields merged into `raw`.
---@param item LvimCmpItem
---@param cb fun(item: LvimCmpItem)
function M.resolve(item, cb)
    local client = lsp.get_client_by_id(item.client_id)
    local provider = client and client.server_capabilities.completionProvider
    local can = type(provider) == "table" and provider.resolveProvider
    if not (client and can) then
        vim.schedule(function()
            cb(item)
        end)
        return
    end
    local ok = client:request("completionItem/resolve", item.raw, function(err, result)
        if not err and type(result) == "table" then
            item.raw = result
        end
        vim.schedule(function()
            cb(item)
        end)
    end)
    if not ok then
        vim.schedule(function()
            cb(item)
        end)
    end
end

--- Execute an accepted item's attached workspace command, if any.
---@param item LvimCmpItem
---@param bufnr integer
function M.execute(item, bufnr)
    local command = item.raw.command
    if not command then
        return
    end
    local client = lsp.get_client_by_id(item.client_id)
    if client then
        client:exec_cmd(command, { bufnr = bufnr })
    end
end

return M
