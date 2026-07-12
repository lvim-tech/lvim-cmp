-- lvim-cmp.docs: the documentation float — the selected item's resolved documentation +
-- detail rendered as markdown in the menu primitive's sibling docs slot. Selection
-- settles through ONE debounce timer (config `docs.delay` while the float is closed,
-- the shorter `docs.update_delay` while it is open), then the item resolves
-- (completionItem/resolve — cached on the item, so accept reuses it) and the float
-- shows; a stale resolve is dropped by generation. Empty documentation hides the float
-- instead of showing a blank box. <C-d> mutes/unmutes auto-docs for the session (and is
-- the way to peek when `docs.auto = false`).
--
---@module "lvim-cmp.docs"

local config = require("lvim-cmp.config")
local sources = require("lvim-cmp.sources")
local menu = require("lvim-cmp.menu")

local lsp_util = vim.lsp.util
local uv = vim.uv

local M = {}

---@type uv.uv_timer_t?  the settle debounce (nil while idle)
local timer = nil

---@type integer  selection generation — a newer selection drops an in-flight resolve/show
local gen = 0

---@type boolean  the float is currently shown (menu.hide() clears it via M.reset)
local shown = false

---@type boolean  the docs_toggle key muted auto-docs for this session
local muted = false

---@type LvimCmpItem?  the item the float currently describes (dedup on re-rank)
local shown_item = nil

--- Stop (and close) the settle timer.
local function stop_timer()
    if timer and not timer:is_closing() then
        timer:stop()
        timer:close()
    end
    timer = nil
end

--- Flatten one documentation-ish value (string | MarkupContent | MarkedString[]) into
--- markdown lines, appended to `out`.
---@param value any
---@param out string[]
local function append_markdown(value, out)
    if not value then
        return
    end
    local lines = lsp_util.convert_input_to_markdown_lines(value)
    for _, l in ipairs(lines or {}) do
        out[#out + 1] = l
    end
end

--- Build the float's markdown lines for `item`: the detail as a fenced code block (in
--- the buffer's language), then the documentation. A detail the documentation already
--- contains is skipped (servers often repeat the signature in both fields). Empty → nil
--- (hide, don't show blank).
---@param item LvimCmpItem
---@param ft string  the completion buffer's filetype (the detail fence language)
---@return string[]?
local function build_lines(item, ft)
    local out = {}
    local detail = item.raw.detail
    local doc = item.raw.documentation
    local doc_value = type(doc) == "table" and doc.value or doc
    if type(detail) == "string" and detail ~= "" then
        if type(doc_value) == "string" and doc_value:find(detail, 1, true) then
            detail = nil -- the documentation repeats it
        end
    else
        detail = nil
    end
    if detail then
        out[#out + 1] = "```" .. ft
        for _, l in ipairs(vim.split(detail, "\n", { plain = true })) do
            out[#out + 1] = l
        end
        out[#out + 1] = "```"
    end
    append_markdown(item.raw.documentation, out)
    -- trim trailing blank lines (convert_input often leaves them)
    while #out > 0 and out[#out]:match("^%s*$") do
        out[#out] = nil
    end
    if #out == 0 then
        return nil
    end
    return out
end

--- Resolve `item` and render the float (or hide it when the docs are empty). Guarded
--- by the selection generation — a newer selection wins.
---@param item LvimCmpItem
---@param ft string
local function resolve_and_show(item, ft)
    local my_gen = gen
    sources.resolve(item, function(resolved)
        if my_gen ~= gen or not menu.visible() then
            return
        end
        local lines = build_lines(resolved, ft)
        if lines then
            menu.docs_show(lines)
            shown = true
            shown_item = item
        else
            M.hide()
        end
    end)
end

--- The selection settled on `item` (nil = nothing selected). Debounced entry point the
--- engine calls on every selection/re-rank change.
---@param item LvimCmpItem?
---@param bufnr integer  the completion buffer (fence language for the detail block)
function M.on_select(item, bufnr)
    gen = gen + 1
    stop_timer()
    if not item or muted or not config.docs.auto then
        M.hide()
        return
    end
    if shown and item == shown_item then
        return -- re-rank kept the same item under the cursor; the float is already right
    end
    local delay = shown and config.docs.update_delay or config.docs.delay
    local ft = vim.bo[bufnr].filetype
    local my_gen = gen
    timer = uv.new_timer()
    if not timer then
        return
    end
    timer:start(
        delay,
        0,
        vim.schedule_wrap(function()
            stop_timer()
            if my_gen == gen and menu.visible() then
                resolve_and_show(item, ft)
            end
        end)
    )
end

--- Scroll the open float by `delta` screen lines (sign = direction). No-op returning
--- false when the float is not shown, so the bound key can fall back to its raw meaning.
---@param delta integer
---@return boolean handled
function M.scroll(delta)
    if not shown then
        return false
    end
    return menu.docs_scroll(delta)
end

--- Hide the float (the menu stays).
function M.hide()
    gen = gen + 1
    stop_timer()
    if shown then
        menu.docs_hide()
    end
    shown = false
    shown_item = nil
end

--- Mute/unmute auto-docs for the session (<C-d>). Unmuting (or toggling with
--- `docs.auto = false`) shows the current selection's docs immediately.
---@param item LvimCmpItem?  the currently selected item
---@param bufnr integer
function M.toggle(item, bufnr)
    if shown then
        muted = true
        M.hide()
        return
    end
    muted = false
    if item and menu.visible() then
        gen = gen + 1
        stop_timer()
        resolve_and_show(item, vim.bo[bufnr].filetype)
    end
end

--- Full reset (the engine tears the session down): timer, float state, generation.
--- The mute choice survives — it is a session preference, not menu state.
function M.reset()
    gen = gen + 1
    stop_timer()
    shown = false
    shown_item = nil
end

return M
