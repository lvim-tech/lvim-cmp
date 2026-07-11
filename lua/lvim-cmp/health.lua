-- lvim-cmp: :checkhealth lvim-cmp.
-- Diagnoses what makes a completion engine misbehave invisibly: the required runtime
-- (vim.snippet, client:request), the shared dependencies (lvim-ui menu preset,
-- lvim-fuzzy + which matcher backend actually loaded, lvim-utils palette), whether the
-- trigger autocmds/keymaps are wired, an internally inconsistent config, and — from the
-- current buffer — which attached clients actually offer completion. Read-only.
--
---@module "lvim-cmp.health"

local config = require("lvim-cmp.config")

local M = {}

--- Validate the live config; error on each violation, ok when clean.
---@param health table  the vim.health reporter
local function check_config(health)
    local problems = 0

    if type(config.enabled) ~= "boolean" and type(config.enabled) ~= "function" then
        health.error(("enabled must be a boolean or fun(bufnr) (got %s)"):format(type(config.enabled)))
        problems = problems + 1
    end
    if type(config.debounce_ms) ~= "number" or config.debounce_ms < 0 then
        health.error(("debounce_ms must be a number >= 0 (got %s)"):format(vim.inspect(config.debounce_ms)))
        problems = problems + 1
    end
    if type(config.keyword_pattern) ~= "string" or not pcall(string.match, "abc", config.keyword_pattern .. "$") then
        health.error(("keyword_pattern is not a valid Lua pattern: %s"):format(vim.inspect(config.keyword_pattern)))
        problems = problems + 1
    end
    if type(config.trigger.min_keyword_length) ~= "number" or config.trigger.min_keyword_length < 0 then
        health.error("trigger.min_keyword_length must be a number >= 0")
        problems = problems + 1
    end
    for _, d in ipairs(config.menu.direction_priority or {}) do
        if d ~= "s" and d ~= "n" then
            health.error(('menu.direction_priority entries must be "s" or "n" (got %s)'):format(vim.inspect(d)))
            problems = problems + 1
        end
    end
    for name, list in pairs(config.keys or {}) do
        if type(list) ~= "table" then
            health.error(("keys.%s must be a list of lhs strings"):format(name))
            problems = problems + 1
        end
    end
    if problems == 0 then
        health.ok("config valid")
    end
end

--- Run the health report.
function M.check()
    local health = vim.health
    health.start("lvim-cmp")

    if vim.fn.has("nvim-0.11") == 1 then
        health.ok("Neovim >= 0.11")
    else
        health.error("Neovim >= 0.11 is required (client:request, vim.snippet, vim.str_byteindex)")
    end

    -- shared dependencies
    local ok_ui, ui = pcall(require, "lvim-ui")
    if ok_ui and type(ui.menu) == "function" then
        health.ok("lvim-ui found (menu primitive available)")
    else
        health.error("lvim-ui with the `menu` primitive is required — the completion popup cannot render")
    end
    local ok_fuzzy, lvim_fuzzy = pcall(require, "lvim-fuzzy")
    if ok_fuzzy then
        health.ok(("lvim-fuzzy found — backend: %s"):format(lvim_fuzzy.backend()))
        if type(lvim_fuzzy.positions) ~= "function" then
            health.error("lvim-fuzzy is too old — no positions() (matched-char highlighting needs it)")
        end
    else
        health.error("lvim-fuzzy is required (ranking + filtering)")
    end
    local ok_utils = pcall(require, "lvim-utils.utils")
    local ok_colors, colors = pcall(require, "lvim-utils.colors")
    if ok_utils and ok_colors and type(colors.blend) == "function" then
        health.ok("lvim-utils found (palette + merge)")
    else
        health.warn("lvim-utils not found — theming and setup() merging degrade")
    end

    -- wiring
    local trigger = require("lvim-cmp.trigger")
    local keymaps = require("lvim-cmp.keymaps")
    if trigger.installed() and keymaps.installed() then
        health.ok("enabled — trigger autocmds + insert-mode keymaps installed")
    elseif config.enabled == false then
        health.info("disabled (config.enabled = false)")
    else
        health.warn("not wired — was setup() called?")
    end

    -- the current buffer's completion-capable clients
    local clients = vim.lsp.get_clients({ bufnr = 0, method = "textDocument/completion" })
    if #clients > 0 then
        local names = {}
        for _, c in ipairs(clients) do
            names[#names + 1] = c.name
        end
        health.ok(("current buffer: %d completion-capable client(s): %s"):format(#clients, table.concat(names, ", ")))
    else
        health.info("current buffer: no attached client offers completion (the lsp source will be silent here)")
    end

    check_config(health)
end

return M
