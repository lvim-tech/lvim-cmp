-- lvim-cmp.engine: the orchestration core — contexts → multi-source fan-out → fuzzy
-- rank → menu/ghost/docs. The correctness backbone is the context GENERATION: every
-- source response carries the id it was requested under and is dropped unless it still
-- matches; no stale menu ever renders. The performance backbone is the two-path split:
--   • a keystroke INSIDE the current keyword bounds only RE-RANKS the cached candidate
--     set (one lvim-fuzzy call — no source round-trip), unless a response was
--     isIncomplete (then it refetches, per the protocol);
--   • leaving the bounds / a trigger character cancels in-flight requests and opens a
--     fresh context (fan-out again).
-- Sources respond independently: each arrival re-merges the per-source buckets (in
-- source-priority order, each bucket pre-sorted by its own sortText — so the fuzzy
-- index tiebreak encodes priority then server order) and re-prepares the matcher set.
-- There is no input debounce by default (`debounce_ms = 0`): the matcher IS the budget;
-- source responses are emitted vim.schedule'd off the keystroke by the sources.
--
---@module "lvim-cmp.engine"

local config = require("lvim-cmp.config")
local context = require("lvim-cmp.context")
local sources = require("lvim-cmp.sources")
local fuzzy = require("lvim-cmp.fuzzy")
local menu = require("lvim-cmp.menu")
local ghost = require("lvim-cmp.ghost")
local docs = require("lvim-cmp.docs")
local accept = require("lvim-cmp.accept")

local api = vim.api

local M = {}

---@class LvimCmpActive           the live completion session (one at a time)
---@field ctx LvimCmpContext      the context the sources were queried under
---@field responses table<string, { items: LvimCmpItem[], incomplete: boolean }>  per-source buckets (items pre-sorted by sort_text)
---@field items LvimCmpItem[]     the merged candidate list (buckets in source-priority order)
---@field set LvimCmpFuzzySet?    the prepared lvim-fuzzy candidate set (nil until a response lands)
---@field incomplete boolean      any response was isIncomplete → refetch per keystroke
---@field ranked LvimCmpItem[]    the current ranked view (what the menu shows)
---@field query string            the query the view was ranked under
---@field cancel fun()?           aborts in-flight source requests
---@field last { row: integer, col: integer, tick: integer }?  last processed cursor state (dedup)
---@field merge_scheduled boolean a coalesced merge is already queued for this tick (dedup the merge)

---@type LvimCmpActive?
local active = nil

---@type integer  debounce generation (a newer keystroke invalidates a pending deferred rank)
local rank_gen = 0

--- Whether completion is enabled for `bufnr` (the master switch, possibly a predicate).
---@param bufnr integer
---@return boolean
local function enabled(bufnr)
    local e = config.enabled
    if type(e) == "function" then
        return e(bufnr) == true
    end
    return e == true
end

--- Tear the session down: cancel in-flight requests, hide the menu + ghost + docs.
function M.hide()
    if active and active.cancel then
        active.cancel()
    end
    active = nil
    docs.reset() -- before menu.hide(): the primitive closes the docs slot with the menu
    menu.hide()
    ghost.clear()
end

--- Whether the completion menu is on screen.
---@return boolean
function M.visible()
    return menu.visible()
end

--- The item behind the current selection (nil when nothing is shown/selected).
---@return LvimCmpItem?
local function selected_item()
    if not active then
        return nil
    end
    local i = menu.selected()
    return i and active.ranked[i] or nil
end

--- Refresh the ghost preview for the current selection (or clear it).
---@param query string
local function update_ghost(query)
    if not config.ghost_text.enabled then
        return
    end
    local item = selected_item()
    if item and menu.visible() then
        ghost.show(item, query)
    else
        ghost.clear()
    end
end

--- Hand the current selection to the docs float (debounced there).
local function update_docs()
    if not active then
        return
    end
    docs.on_select(menu.visible() and selected_item() or nil, active.ctx.bufnr)
end

--- Per-candidate score offsets for the fuzzy rank (folded in natively before the top-K
--- cap): a candidate whose filter text is a case-insensitive PREFIX of the query gets
--- `config.fuzzy.prefix_boost`, so a literal-prefix completion outranks a scattered fuzzy
--- hit. Returns nil (no boosts) for an empty query or when the boost is disabled.
---@param items LvimCmpItem[]
---@param query string
---@return integer[]?
local function compute_boosts(items, query)
    local pb = config.fuzzy.prefix_boost or 0
    if query == "" or pb <= 0 then
        return nil
    end
    local q = query:lower()
    local nq = #q
    local boosts = {}
    for i, it in ipairs(items) do
        local ft = it.filter_text
        boosts[i] = (ft ~= "" and ft:sub(1, nq):lower() == q) and pb or 0
    end
    return boosts
end

--- Rank the cached candidate set against the LIVE query and render. The fast path —
--- one lvim-fuzzy call, no source round-trip. Hides (keeping the session) when nothing
--- matches; tears down when the cursor left the context.
local function rerank()
    if not active or not active.set then
        return
    end
    local ctx = active.ctx
    if api.nvim_get_current_buf() ~= ctx.bufnr then
        M.hide()
        return
    end
    local cursor = api.nvim_win_get_cursor(0)
    if cursor[1] ~= ctx.cursor[1] or cursor[2] < ctx.bounds.s then
        M.hide()
        return
    end
    local line = api.nvim_get_current_line()
    local query = line:sub(ctx.bounds.s + 1, cursor[2])
    active.query = query
    active.last = { row = cursor[1], col = cursor[2], tick = vim.b[ctx.bufnr].changedtick }

    local results = fuzzy.match(active.set, query, compute_boosts(active.items, query))
    local ranked = {}
    for k, r in ipairs(results) do
        ranked[k] = active.items[r.index]
    end
    active.ranked = ranked
    if #ranked == 0 then
        -- nothing matches RIGHT NOW; keep the session — a corrected keystroke re-matches
        docs.reset()
        menu.hide()
        ghost.clear()
        return
    end
    menu.show(ranked, query, ctx, config.menu.selection.preselect and 1 or nil)
    update_ghost(query)
    update_docs()
end

--- Run `rerank` now, or defer it by `debounce_ms` (a newer keystroke supersedes).
local function schedule_rank()
    rank_gen = rank_gen + 1
    local ms = config.debounce_ms
    if not ms or ms <= 0 then
        rerank()
        return
    end
    local gen = rank_gen
    vim.defer_fn(function()
        if gen == rank_gen then
            rerank()
        end
    end, ms)
end

--- Sort a response's items by sort_text (stable via original index), so the fuzzy
--- index tiebreak follows the server's intended empty-query order within its bucket.
---@param items LvimCmpItem[]
---@return LvimCmpItem[]
local function sort_bucket(items)
    local order = {}
    for i, it in ipairs(items) do
        order[i] = { it = it, i = i }
    end
    table.sort(order, function(a, b)
        if a.it.sort_text ~= b.it.sort_text then
            return a.it.sort_text < b.it.sort_text
        end
        return a.i < b.i
    end)
    local sorted = {}
    for k, e in ipairs(order) do
        sorted[k] = e.it
    end
    return sorted
end

--- Merge the arrived buckets — sources in priority order, each pre-sorted — re-prepare the matcher
--- set (the haystack crosses the Lua↔native boundary ONCE per merge, never per keystroke) and rerank.
--- Coalesced by `on_response`: one merge per event-loop tick, not one per response.
---@param ctx_id integer
local function merge_responses(ctx_id)
    if not active or active.ctx.id ~= ctx_id then
        return -- stale: a newer context superseded this request
    end
    active.merge_scheduled = false
    local merged, texts, any_incomplete = {}, {}, false
    for _, src in ipairs(sources.list()) do
        local bucket = active.responses[src.name]
        if bucket then
            any_incomplete = any_incomplete or bucket.incomplete
            for _, it in ipairs(bucket.items) do
                merged[#merged + 1] = it
                texts[#texts + 1] = it.filter_text
            end
        end
    end
    active.items = merged
    active.incomplete = any_incomplete
    active.set = fuzzy.prepare(texts)
    rerank()
end

--- A source response for context `ctx_id` landed (already vim.schedule'd by the source). Store the
--- bucket and coalesce the merge: every source emits via vim.schedule, so a burst of responses lands
--- in ONE event-loop tick — the first schedules a single `merge_responses`, the rest (guarded by
--- `merge_scheduled`) just drop their bucket in. Result is one merge + prepare + rerank per burst
--- instead of one per source. A later async straggler (an LSP reply) is its own tick → its own merge.
---@param ctx_id integer
---@param source_name string
---@param items LvimCmpItem[]
---@param incomplete boolean
local function on_response(ctx_id, source_name, items, incomplete)
    if not active or active.ctx.id ~= ctx_id then
        return -- stale: a newer context superseded this request
    end
    active.responses[source_name] = { items = sort_bucket(items), incomplete = incomplete }
    if not active.merge_scheduled then
        active.merge_scheduled = true
        vim.schedule(function()
            merge_responses(ctx_id)
        end)
    end
end

--- Open a fresh context (cancels the previous session's requests) and fan out.
---@param trigger_char string?
---@param manual boolean?
---@param for_incomplete boolean?  the re-request is because the prior response was isIncomplete (TriggerKind 3)
local function start_context(trigger_char, manual, for_incomplete)
    if active and active.cancel then
        active.cancel()
    end
    local ctx = context.new(trigger_char, manual, for_incomplete)
    active = {
        ctx = ctx,
        responses = {},
        items = {},
        set = nil,
        incomplete = false,
        ranked = {},
        query = ctx.keyword,
        cancel = nil,
        last = { row = ctx.cursor[1], col = ctx.cursor[2], tick = vim.b[ctx.bufnr].changedtick },
        merge_scheduled = false,
    }
    active.cancel = sources.fanout(ctx, function(source_name, items, incomplete)
        on_response(ctx.id, source_name, items, incomplete)
    end)
end

--- The main driver — a text change in insert mode. `char` is the character recorded by
--- InsertCharPre (nil for a deletion or a non-typed change).
---@param char string?
function M.on_text_changed(char)
    local bufnr = api.nvim_get_current_buf()
    -- Scratch buffers (non-empty buftype) never complete — UI panels, prompts, previews — UNLESS
    -- the plugin that owns one opts it in with `b:lvim_cmp_enable = true`: an editable scratch
    -- that is a genuine editor (e.g. lvim-db's query editor) completes like a real file buffer.
    if not enabled(bufnr) or (vim.bo[bufnr].buftype ~= "" and not vim.b[bufnr].lvim_cmp_enable) then
        M.hide()
        return
    end
    -- a server trigger character opens a fresh context (bounds start AT the cursor)
    if char and config.trigger.show_on_trigger_chars and sources.trigger_chars(bufnr)[char] then
        start_context(char)
        return
    end
    local cursor = api.nvim_win_get_cursor(0)
    local line = api.nvim_get_current_line()
    local s = context.keyword_bounds(line, cursor[2])

    if active and active.ctx.bufnr == bufnr and active.ctx.cursor[1] == cursor[1] and active.ctx.bounds.s == s then
        -- INSIDE the current bounds: re-rank the cached set. Refetch instead when the
        -- response was isIncomplete (its item set depends on the query) OR the cache is
        -- EMPTY (reuse exists to avoid refetching a non-empty list; an empty one has
        -- nothing to re-rank — e.g. the server answered before its workspace loaded).
        if char and (active.incomplete or (active.set and #active.items == 0)) then
            -- an isIncomplete refetch re-triggers as TriggerKind 3; an empty-cache refetch is
            -- a plain Invoked (kind 1), so only pass the flag when it was actually incomplete
            start_context(active.ctx.trigger_char, active.ctx.manual, active.incomplete)
        else
            schedule_rank()
        end
        return
    end

    -- outside any context: open one when the keyword qualifies
    local keyword = line:sub(s + 1, cursor[2])
    local opening_ok = char ~= nil or config.trigger.show_on_backspace or menu.visible()
    if opening_ok and #keyword >= config.trigger.min_keyword_length then
        start_context(nil)
    else
        M.hide()
    end
end

--- A cursor move in insert mode (arrows, mouse). Re-ranks while the cursor stays inside
--- the live context; tears down when it leaves. Movement caused by the keystroke just
--- handled is deduplicated via the recorded (row, col, tick).
function M.on_cursor_moved()
    if not active then
        return
    end
    local bufnr = api.nvim_get_current_buf()
    if bufnr ~= active.ctx.bufnr then
        M.hide()
        return
    end
    local cursor = api.nvim_win_get_cursor(0)
    local last = active.last
    if last and last.row == cursor[1] and last.col == cursor[2] and last.tick == vim.b[bufnr].changedtick then
        return -- already processed by on_text_changed
    end
    local line = api.nvim_get_current_line()
    local s = context.keyword_bounds(line, cursor[2])
    if cursor[1] == active.ctx.cursor[1] and s == active.ctx.bounds.s then
        schedule_rank()
    else
        M.hide()
    end
end

--- InsertEnter — optionally open on an already-present keyword.
function M.on_insert_enter()
    if config.trigger.show_on_insert then
        M.on_text_changed(nil)
    end
end

--- Leaving insert mode always tears the session down.
function M.on_insert_leave()
    M.hide()
end

--- Manual trigger (<C-Space>): open a context at the cursor regardless of keyword
--- length — the `manual` flag bypasses every per-source keyword floor.
function M.trigger()
    local bufnr = api.nvim_get_current_buf()
    if not enabled(bufnr) then
        return
    end
    start_context(nil, true)
end

--- Move the menu selection and refresh the ghost + docs.
---@param delta integer
---@return boolean handled  false when no menu is visible (caller falls back)
function M.select(delta)
    if not menu.visible() then
        return false
    end
    menu.select_move(delta)
    update_ghost(active and active.query or "")
    update_docs()
    return true
end

--- Toggle the docs float for the current selection (mutes/unmutes auto-docs).
---@return boolean handled  false when no menu is visible (caller falls back)
function M.docs_toggle()
    if not menu.visible() or not active then
        return false
    end
    docs.toggle(selected_item(), active.ctx.bufnr)
    return true
end

--- Scroll the open docs float by half its height (<C-f>/<C-b>). Handled only when the
--- menu is up AND a docs float is actually shown — otherwise the caller falls back so
--- the raw key keeps its native meaning.
---@param dir integer  1 = down, -1 = up
---@return boolean handled
function M.docs_scroll(dir)
    if not menu.visible() then
        return false
    end
    local step = math.max(1, math.floor((config.docs.max_height or 20) / 2))
    return docs.scroll(dir * step)
end

--- Accept the selected item: resolve it (docs/additionalTextEdits/command may arrive
--- only on resolve), apply the edit, run its command.
---@return boolean handled  false when nothing is selected (caller falls back)
function M.accept()
    local item = selected_item()
    if not item or not active then
        return false
    end
    local ctx = active.ctx
    -- close the UI before mutating the buffer (the mutation retriggers TextChangedI)
    M.hide()
    -- Snapshot the buffer's changedtick: `sources.resolve` is an async LSP round-trip with no timeout, and
    -- `accept.apply` replaces from the edit start to the CURRENT cursor. That "typed tail is part of the query"
    -- rationale only holds for text typed BEFORE this keypress — so if anything is typed/deleted while the
    -- resolve is in flight (tick changes), bail rather than swallow it. Unchanged tick = the common case.
    local tick = vim.b[ctx.bufnr].changedtick
    sources.resolve(item, function(resolved)
        if api.nvim_get_current_buf() ~= ctx.bufnr or vim.b[ctx.bufnr].changedtick ~= tick then
            return
        end
        accept.apply(resolved, ctx)
        sources.execute(resolved, ctx.bufnr)
    end)
    return true
end

--- Full teardown (disable): session + the menu handle itself.
function M.teardown()
    M.hide()
    menu.close()
end

return M
