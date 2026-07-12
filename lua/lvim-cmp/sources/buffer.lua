-- lvim-cmp.sources.buffer: words from open buffers. Each buffer owns a cached keyword
-- index keyed by its changedtick; a get() with a matching tick reuses it for free. A
-- STALE index is served as-is (the words of a keystroke ago are fine to complete from)
-- while a debounced timer re-scans after the typing pause — so continuous typing never
-- pays a full-buffer scan per context, and the index catches up the moment the user
-- stops. Which buffers feed the index is configurable (current / visible / all); words
-- are deduplicated across buffers (context buffer first) and the word currently being
-- typed never completes to itself.
--
---@module "lvim-cmp.sources.buffer"

local config = require("lvim-cmp.config")

local api = vim.api
local uv = vim.uv

local M = {}

M.name = "buffer"

---@class LvimCmpBufferIndex
---@field words string[]        the buffer's deduplicated keywords, in first-occurrence order
---@field tick integer          the changedtick the index was built at
---@field timer uv.uv_timer_t?  the pending debounced re-scan (nil when idle)

---@type table<integer, LvimCmpBufferIndex>  per-buffer index (dropped on wipeout)
local index = {}

---@type integer? the autocmd id of the wipeout janitor (installed on first use)
local wipe_autocmd = nil

--- Drop a wiped-out buffer's index (and its pending timer). Installed lazily so the
--- source stays inert until it is actually used.
local function ensure_janitor()
    if wipe_autocmd then
        return
    end
    wipe_autocmd = api.nvim_create_autocmd("BufWipeout", {
        group = api.nvim_create_augroup("LvimCmpBufferIndex", { clear = true }),
        callback = function(ev)
            local entry = index[ev.buf]
            if entry and entry.timer and not entry.timer:is_closing() then
                entry.timer:stop()
                entry.timer:close()
            end
            index[ev.buf] = nil
        end,
    })
end

--- Whether `bufnr` may feed the index at all: a real file-ish buffer under the size cap.
---@param bufnr integer
---@return boolean
local function indexable(bufnr)
    if not api.nvim_buf_is_loaded(bufnr) or vim.bo[bufnr].buftype ~= "" then
        return false
    end
    local last = api.nvim_buf_line_count(bufnr)
    local bytes = api.nvim_buf_get_offset(bufnr, last)
    return bytes >= 0 and bytes <= config.sources.buffer.max_buffer_size
end

--- Scan `bufnr` into a fresh word list: every `keyword_pattern` match of at least
--- `min_word_length` chars, deduplicated, in first-occurrence order.
---@param bufnr integer
---@return string[]
local function scan(bufnr)
    local pattern = config.keyword_pattern
    local min_len = config.sources.buffer.min_word_length
    local words, seen = {}, {}
    for _, line in ipairs(api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
        for word in line:gmatch(pattern) do
            if #word >= min_len and not seen[word] then
                seen[word] = true
                words[#words + 1] = word
            end
        end
    end
    return words
end

--- The word list for `bufnr`, through the cache discipline: fresh tick → cached; no
--- entry yet → scan NOW (first touch must produce words); stale tick → serve the stale
--- list and (re)arm the debounced re-scan.
---@param bufnr integer
---@return string[]
local function words_for(bufnr)
    if not indexable(bufnr) then
        return {}
    end
    ensure_janitor()
    local tick = vim.b[bufnr].changedtick
    local entry = index[bufnr]
    if entry and entry.tick == tick then
        return entry.words
    end
    if not entry then
        entry = { words = scan(bufnr), tick = tick, timer = nil }
        index[bufnr] = entry
        return entry.words
    end
    -- stale: serve what we have, refresh after the typing pause (a newer edit re-arms)
    if not entry.timer then
        entry.timer = uv.new_timer()
    end
    if entry.timer then
        entry.timer:stop()
        entry.timer:start(
            config.sources.buffer.index_debounce_ms,
            0,
            vim.schedule_wrap(function()
                local e = index[bufnr]
                if not e or not api.nvim_buf_is_valid(bufnr) then
                    return
                end
                e.words = scan(bufnr)
                e.tick = vim.b[bufnr].changedtick
            end)
        )
    end
    return entry.words
end

--- The buffers that feed this context, context buffer FIRST (its words win the dedupe),
--- per the configured `buffers` mode.
---@param ctx LvimCmpContext
---@return integer[]
local function target_bufs(ctx)
    local mode = config.sources.buffer.buffers
    local bufs, seen = { ctx.bufnr }, { [ctx.bufnr] = true }
    if mode == "visible" then
        for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
            local b = api.nvim_win_get_buf(win)
            if not seen[b] then
                seen[b] = true
                bufs[#bufs + 1] = b
            end
        end
    elseif mode == "all" then
        for _, b in ipairs(api.nvim_list_bufs()) do
            if not seen[b] and vim.bo[b].buflisted then
                seen[b] = true
                bufs[#bufs + 1] = b
            end
        end
    end
    return bufs
end

--- Whether this source can serve the context.
---@param ctx LvimCmpContext
---@return boolean
function M.enabled(ctx)
    local _ = ctx
    return config.sources.buffer.enabled
end

--- Collect the merged, deduplicated word items for `ctx`. Synchronous work, emitted
--- vim.schedule'd (the source contract) — the per-buffer cache keeps it off the
--- full-scan path on the keystroke.
---@param ctx LvimCmpContext
---@param cb fun(items: LvimCmpItem[], incomplete: boolean)
---@return fun()? cancel
function M.get(ctx, cb)
    local items, seen = {}, {}
    for _, bufnr in ipairs(target_bufs(ctx)) do
        for _, word in ipairs(words_for(bufnr)) do
            -- the keyword being typed must not complete to itself
            if not seen[word] and word ~= ctx.keyword then
                seen[word] = true
                items[#items + 1] = {
                    raw = { label = word },
                    source_name = M.name,
                    label = word,
                    filter_text = word,
                    sort_text = word,
                    kind = 1, -- Text
                }
            end
        end
    end
    vim.schedule(function()
        cb(items, false)
    end)
    return nil
end

--- Index statistics for :checkhealth — { buffers = indexed count, words = total }.
---@return { buffers: integer, words: integer }
function M.stats()
    local buffers, words = 0, 0
    for _, entry in pairs(index) do
        buffers = buffers + 1
        words = words + #entry.words
    end
    return { buffers = buffers, words = words }
end

return M
