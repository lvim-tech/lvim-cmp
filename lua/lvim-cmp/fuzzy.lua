-- lvim-cmp.fuzzy: the matcher facade over the shared lvim-fuzzy engine. The boundary
-- discipline lives here: the candidate FILTER TEXTS cross into the engine ONCE per
-- source response (`prepare`), each keystroke is a single `match(query)` call, and
-- matched-char columns (`positions`) are computed only for the menu's VISIBLE rows.
-- Ranking is lvim-fuzzy's deterministic total order — identical on the native and Lua
-- backends, so completion never ranks differently across installs.
--
---@module "lvim-cmp.fuzzy"

local lvim_fuzzy = require("lvim-fuzzy")
local config = require("lvim-cmp.config")

local M = {}

---@class LvimCmpFuzzySet
---@field ctx LvimFuzzyContext   the prepared lvim-fuzzy context
---@field n integer              candidate count

--- Upload a fixed candidate set (once per source response).
---@param filter_texts string[]
---@return LvimCmpFuzzySet
function M.prepare(filter_texts)
    return { ctx = lvim_fuzzy.prepare(filter_texts), n = #filter_texts }
end

--- Rank the prepared set against `query` (once per keystroke). Returns ranked
--- `{ index, score }` pairs (1-based indices into the prepared candidate array),
--- capped at `config.fuzzy.max_results`. An empty query returns the source order.
--- `boosts` (optional, parallel to the candidate set) folds per-item score offsets
--- (exact-prefix / proximity) into the ranking before the cap — see engine.rerank.
---@param set LvimCmpFuzzySet
---@param query string
---@param boosts integer[]?
---@return { index: integer, score: integer }[] results
---@return integer count
function M.match(set, query, boosts)
    local results, count = lvim_fuzzy.match(query, set.ctx, boosts)
    local cap = config.fuzzy.max_results
    if cap and cap > 0 and count > cap then
        local out = {}
        for k = 1, cap do
            out[k] = results[k]
        end
        return out, cap
    end
    return results, count
end

--- Matched-char byte columns of `query` inside ONE candidate text — the exact
--- alignment the scorer credits. Called lazily, only for visible menu rows.
---@param text string
---@param query string
---@return integer[]?
function M.positions(text, query)
    if query == "" then
        return nil
    end
    return lvim_fuzzy.positions(text, query)
end

return M
