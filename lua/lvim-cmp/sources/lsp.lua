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
    ---@type boolean the FINAL response (every client answered) has been emitted — no more work
    local settled = false
    ---@type boolean the request was cancelled (a newer context superseded it) — suppress emits
    local cancelled = false
    ---@type boolean at least one (possibly partial) emit has gone out — a later arrival is a LIVE update
    local emitted = false
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

    local function cancel_inflight()
        for _, req in ipairs(inflight) do
            req.client:cancel_request(req.id)
        end
    end

    --- Deliver the CURRENT accumulation (schedule'd off the keystroke). Fires on each
    --- meaningful change: the timeout's partial set, every straggler that lands after it
    --- (a live menu update instead of a dropped result), and the final all-answered set.
    local function emit()
        emitted = true
        vim.schedule(function()
            if not cancelled then
                cb(items, incomplete)
            end
        end)
    end

    local function cancel_fn()
        if cancelled then
            return
        end
        cancelled = true
        stop_timer()
        cancel_inflight()
    end

    for _, client in ipairs(clients) do
        local params = lsp.util.make_position_params(ctx.win, client.offset_encoding)
        -- Trigger kind: an isIncomplete re-request is kind 3 (TriggerForIncompleteCompletions);
        -- otherwise kind 2 with the character, but ONLY when THIS client declared it (a
        -- context opened by another source's trigger — path's "/" — is a plain Invoked
        -- request for a server that never asked for the char); else kind 1 (Invoked).
        local trigger_kind, trigger_character = 1, nil
        if ctx.for_incomplete then
            trigger_kind = 3
        elseif ctx.trigger_char then
            local provider = client.server_capabilities.completionProvider
            for _, ch in ipairs((type(provider) == "table" and provider.triggerCharacters) or {}) do
                if ch == ctx.trigger_char then
                    trigger_kind, trigger_character = 2, ctx.trigger_char
                    break
                end
            end
        end
        ---@diagnostic disable-next-line: inject-field  -- CompletionParams = PositionParams + context
        params.context = { triggerKind = trigger_kind, triggerCharacter = trigger_character }
        local ok, request_id = client:request("textDocument/completion", params, function(err, result)
            if settled or cancelled then
                return
            end
            pending = pending - 1
            local before = #items
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
                -- everyone answered → the final, complete set
                settled = true
                stop_timer()
                emit()
            elseif emitted and #items > before then
                -- a straggler that missed the timeout but beat the cancel: fold its items in
                -- as a LIVE menu update instead of dropping them
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
        -- every request failed to send (client stopping mid-keystroke): the request is already settled, so
        -- release the created-but-never-started timer here instead of leaking it until a later cancel runs.
        stop_timer()
        if not settled then
            settled = true
            emit()
        end
        return cancel_fn
    end

    if timer then
        timer:start(
            config.sources.lsp.timeout_ms,
            0,
            vim.schedule_wrap(function()
                stop_timer()
                if settled or cancelled then
                    return
                end
                -- timeout: emit what has arrived and KEEP the slow clients in flight, so a
                -- later answer becomes a live update (see the request callback), not a drop
                emit()
            end)
        )
    end

    return cancel_fn
end

--- Resolve an item (documentation / detail / additionalTextEdits / command) via
--- completionItem/resolve when the server offers it; otherwise pass it through.
--- `cb(item)` always fires (schedule'd), with the resolved fields merged into `raw`.
--- Cached per item (`item.resolved`), so the docs float's resolve doubles as the
--- accept-time one.
---@param item LvimCmpItem
---@param cb fun(item: LvimCmpItem)
function M.resolve(item, cb)
    local client = item.client_id and lsp.get_client_by_id(item.client_id) or nil
    local provider = client and client.server_capabilities.completionProvider
    local can = type(provider) == "table" and provider.resolveProvider
    if item.resolved or not (client and can) then
        vim.schedule(function()
            cb(item)
        end)
        return
    end
    local ok = client:request("completionItem/resolve", item.raw, function(err, result)
        if not err and type(result) == "table" then
            -- The spec says a resolve response is the COMPLETE item, but real servers ship partial results
            -- (omitting textEdit/sortText they sent originally). Fold instead of replace so a partial resolve
            -- cannot drop the original's fields (which `item.resolved` would then cache for the session).
            item.raw = vim.tbl_extend("force", item.raw, result)
            item.resolved = true
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
