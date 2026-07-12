-- lvim-cmp.context: the completion Context — a snapshot of "where completion is
-- happening": buffer, window, cursor, line, and the KEYWORD BOUNDS the query is read
-- from. Each context carries a monotonic `id` (the generation counter): every async
-- source response is stamped with the id it was requested under and DROPPED unless it
-- still matches the engine's current context — the correctness backbone that guarantees
-- no stale menu ever renders.
--
---@module "lvim-cmp.context"

local config = require("lvim-cmp.config")

local api = vim.api

local M = {}

---@type integer the monotonic context generation
local generation = 0

---@class LvimCmpContext
---@field id integer            generation stamp (stale responses are dropped by it)
---@field bufnr integer
---@field win integer
---@field cursor integer[]      { lnum (1-based), col (0-based byte) }
---@field line string           the cursor line at snapshot time
---@field bounds { s: integer, e: integer }  keyword byte bounds: 0-based start, exclusive end (= cursor col)
---@field keyword string        the text inside the bounds (the query)
---@field trigger_char string?  set when this context was opened by a source trigger character
---@field manual boolean        opened by an explicit user trigger (<C-Space>) — bypasses per-source keyword floors
---@field for_incomplete boolean  a re-request because the prior response was isIncomplete → LSP TriggerKind 3

--- Keyword bounds ending at `col` (0-based, exclusive) in `line`, per the configured
--- `keyword_pattern`. An empty keyword yields `s == e == col`.
---@param line string
---@param col integer
---@return integer s, integer e
function M.keyword_bounds(line, col)
    local prefix = line:sub(1, col)
    local kw = prefix:match("(" .. config.keyword_pattern .. ")$")
    if kw then
        return col - #kw, col
    end
    return col, col
end

--- Snapshot a fresh context at the current cursor (bumps the generation).
---@param trigger_char string?    the trigger character that opened it, if any
---@param manual boolean?         opened by an explicit user trigger (<C-Space>)
---@param for_incomplete boolean? the re-request follows an isIncomplete response (TriggerKind 3)
---@return LvimCmpContext
function M.new(trigger_char, manual, for_incomplete)
    generation = generation + 1
    local win = api.nvim_get_current_win()
    local cursor = api.nvim_win_get_cursor(win)
    local line = api.nvim_get_current_line()
    local s, e = M.keyword_bounds(line, cursor[2])
    return {
        id = generation,
        bufnr = api.nvim_get_current_buf(),
        win = win,
        cursor = cursor,
        line = line,
        bounds = { s = s, e = e },
        keyword = line:sub(s + 1, e),
        trigger_char = trigger_char,
        manual = manual == true,
        for_incomplete = for_incomplete == true,
    }
end

--- The current generation (for stale checks without snapshotting).
---@return integer
function M.current_id()
    return generation
end

return M
