-- The keyword under the cursor: what the completion query is, and which bytes a confirmed item
-- replaces.
--
-- The bounds are BYTE offsets (0-based start, exclusive end = the cursor column) because that is
-- what nvim_buf_set_text takes. So the contract worth stating is not "s is 6" but "slicing the
-- line with these bounds gives back the keyword" — which keeps holding when the text before the
-- cursor contains multibyte characters, and is where an offset bug would otherwise hide.

local context = require("lvim-cmp.context")
local config = require("lvim-cmp.config")

--- The keyword the bounds point at, by slicing the line with them.
---@param line string
---@param col integer
---@return string
local function sliced(line, col)
    local s, e = context.keyword_bounds(line, col)
    return line:sub(s + 1, e)
end

describe("lvim-cmp.context.keyword_bounds")

it("finds the word ending at the cursor", function()
    eq("foo", sliced("local foo", 9))
    eq(6, (context.keyword_bounds("local foo", 9)))
end)

it("gives an empty keyword where there is none", function()
    local s, e = context.keyword_bounds("local ", 6)
    eq(6, s)
    eq(6, e)
    eq("", sliced("local ", 6))
end)

it("starts at an underscore and carries digits, underscores and dashes", function()
    eq("_private", sliced("_private", 8))
    eq("a1_b-c", sliced("a1_b-c", 6))
end)

it("will not start a keyword with a digit", function()
    eq("abc", sliced("123abc", 6), "the keyword starts at the first letter")
end)

it("stops at the cursor, not at the end of the word", function()
    eq("foo", sliced("foobar", 3))
end)

it("stops at a dot, so a member is its own keyword", function()
    eq("fn", sliced("vim.fn", 6))
end)

it("answers at the start of the line", function()
    local s, e = context.keyword_bounds("", 0)
    eq(0, s)
    eq(0, e)
end)

it("counts BYTES, so multibyte text before the cursor does not shift the keyword", function()
    -- `—` is three bytes and one cell. A bound measured in characters would slice one or two
    -- bytes into it and hand the source a mangled query — or replace the wrong bytes on confirm.
    local line = "— foo"
    eq("foo", sliced(line, #line))
    local s = (context.keyword_bounds(line, #line))
    eq(#line - 3, s, "three bytes of keyword, however wide the text before it")
end)

it("follows the configured pattern", function()
    local saved = config.keyword_pattern
    config.keyword_pattern = "[%a]+" -- letters only: no dash, no digits, no underscore
    eq("bar", sliced("foo-bar", 7), "with this pattern the dash ends the keyword")
    config.keyword_pattern = saved
    eq("foo-bar", sliced("foo-bar", 7), "and the default takes the dash again")
end)

describe("lvim-cmp.context.new")

it("bumps the generation on every snapshot, so a stale response can be dropped", function()
    local first = context.new()
    local second = context.new()
    truthy(second.id > first.id, ("ids did not advance: %s then %s"):format(first.id, second.id))
    eq(context.current_id(), second.id)
end)

it("carries the trigger character and the manual flag it was opened with", function()
    local ctx = context.new(".", true)
    eq(".", ctx.trigger_char)
    eq(true, ctx.manual)
    local plain = context.new()
    eq(nil, plain.trigger_char)
    truthy(plain.manual ~= true, "an unasked-for context is not a manual one")
end)
