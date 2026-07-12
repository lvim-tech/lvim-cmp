-- lvim-cmp: :checkhealth lvim-cmp.
-- Diagnoses what makes a completion engine misbehave invisibly: the required runtime
-- (vim.snippet, client:request), the shared dependencies (lvim-ui menu preset,
-- lvim-fuzzy + which matcher backend actually loaded, lvim-utils palette), whether the
-- trigger autocmds/keymaps are wired, an internally inconsistent config, and every
-- source's live status (the current buffer's completion-capable clients, the snippet
-- collections discovered — including unparsable files, the buffer word-index stats).
-- Read-only.
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
    local buffers_mode = config.sources.buffer.buffers
    if buffers_mode ~= "current" and buffers_mode ~= "visible" and buffers_mode ~= "all" then
        health.error(
            ('sources.buffer.buffers must be "current" | "visible" | "all" (got %s)'):format(vim.inspect(buffers_mode))
        )
        problems = problems + 1
    end
    for _, dep in ipairs(config.sources.buffer.fallback_for or {}) do
        if config.sources[dep] == nil then
            health.warn(("sources.buffer.fallback_for names an unknown source: %s (ignored)"):format(dep))
        end
    end
    for _, field in ipairs({ "delay", "update_delay", "max_width", "max_height" }) do
        if type(config.docs[field]) ~= "number" or config.docs[field] < 0 then
            health.error(("docs.%s must be a number >= 0"):format(field))
            problems = problems + 1
        end
    end
    for _, d in ipairs(config.menu.direction_priority or {}) do
        if d ~= "s" and d ~= "n" then
            health.error(('menu.direction_priority entries must be "s" or "n" (got %s)'):format(vim.inspect(d)))
            problems = problems + 1
        end
    end
    local detail = config.menu.detail
    if detail ~= "kind" and detail ~= "lsp" and detail ~= false then
        health.error(('menu.detail must be "kind" | "lsp" | false (got %s)'):format(vim.inspect(detail)))
        problems = problems + 1
    end
    for _, field in ipairs({ "icon_padding", "label_padding" }) do
        for _, side in ipairs({ "left", "right" }) do
            local pad = config.menu[field] and config.menu[field][side]
            if type(pad) ~= "number" or pad < 0 then
                health.error(("menu.%s.%s must be a number >= 0"):format(field, side))
                problems = problems + 1
            end
        end
    end
    for _, key in ipairs({ "row", "row_selected", "chip", "chip_selected" }) do
        local v = config.menu.tint and config.menu.tint[key]
        if type(v) ~= "number" or v < 0 or v > 1 then
            health.error(("menu.tint.%s must be a number in 0..1"):format(key))
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

    -- per-source status
    if config.sources.lsp.enabled then
        local clients = vim.lsp.get_clients({ bufnr = 0, method = "textDocument/completion" })
        if #clients > 0 then
            local names = {}
            for _, c in ipairs(clients) do
                names[#names + 1] = c.name
            end
            health.ok(
                ("source lsp: %d completion-capable client(s) in the current buffer: %s"):format(
                    #clients,
                    table.concat(names, ", ")
                )
            )
        else
            health.info("source lsp: no attached client offers completion in the current buffer")
        end
    else
        health.info("source lsp: disabled")
    end

    if config.sources.snippets.enabled then
        local stats = require("lvim-cmp.sources.snippets").stats()
        if stats.files > 0 then
            health.ok(("source snippets: %d file(s) across %d language(s)"):format(stats.files, stats.languages))
        else
            health.info(
                "source snippets: no VS Code-format collection found "
                    .. '(stdpath("config")/snippets or sources.snippets.paths)'
            )
        end
        for _, path in ipairs(stats.broken) do
            health.warn(("source snippets: unparsable JSON skipped: %s"):format(path))
        end
    else
        health.info("source snippets: disabled")
    end

    if config.sources.path.enabled then
        health.ok('source path: enabled (trigger characters "/" and "~")')
    else
        health.info("source path: disabled")
    end

    if config.sources.buffer.enabled then
        local stats = require("lvim-cmp.sources.buffer").stats()
        health.ok(
            ("source buffer: enabled (%s buffers; %d indexed, %d words cached)"):format(
                config.sources.buffer.buffers,
                stats.buffers,
                stats.words
            )
        )
    else
        health.info("source buffer: disabled")
    end

    check_config(health)
end

return M
