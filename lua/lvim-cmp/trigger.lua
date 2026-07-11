-- lvim-cmp.trigger: the autocmd wiring — the blink-verified event model. InsertCharPre
-- only RECORDS the typed character (mutating anything there is unsafe); the driver is
-- TextChangedI, which consumes that record — so a text change WITH a recorded char is a
-- typed insertion and one WITHOUT is a deletion/other edit (the show_on_backspace gate).
-- CursorMovedI is the bounds check for non-typing movement; InsertLeave (via ModeChanged,
-- which also covers <C-c>) always tears the session down.
--
---@module "lvim-cmp.trigger"

local engine = require("lvim-cmp.engine")

local api = vim.api

local M = {}

---@type integer? the augroup (nil while not wired)
local group = nil

---@type string? the char InsertCharPre recorded, consumed by the next TextChangedI
local pending_char = nil

--- Install the autocmds. Idempotent (re-wires cleanly).
function M.setup()
    M.teardown()
    group = api.nvim_create_augroup("LvimCmp", { clear = true })

    api.nvim_create_autocmd("InsertCharPre", {
        group = group,
        callback = function()
            pending_char = vim.v.char
        end,
    })

    api.nvim_create_autocmd("TextChangedI", {
        group = group,
        callback = function()
            local char = pending_char
            pending_char = nil
            engine.on_text_changed(char)
        end,
    })

    api.nvim_create_autocmd("CursorMovedI", {
        group = group,
        callback = function()
            engine.on_cursor_moved()
        end,
    })

    api.nvim_create_autocmd("InsertEnter", {
        group = group,
        callback = function()
            engine.on_insert_enter()
        end,
    })

    -- ModeChanged *:n covers InsertLeave AND the <C-c> escape (which skips InsertLeave)
    api.nvim_create_autocmd("ModeChanged", {
        group = group,
        pattern = "i*:*",
        callback = function()
            if not vim.api.nvim_get_mode().mode:match("^i") then
                engine.on_insert_leave()
            end
        end,
    })

    api.nvim_create_autocmd("BufLeave", {
        group = group,
        callback = function()
            engine.hide()
        end,
    })
end

--- Remove the autocmds (disable).
function M.teardown()
    if group then
        api.nvim_del_augroup_by_id(group)
        group = nil
    end
    pending_char = nil
end

--- Whether the trigger wiring is installed.
---@return boolean
function M.installed()
    return group ~= nil
end

return M
