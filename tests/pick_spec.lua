local pick = require("giroux.pick")

local function P(s)
  return { p = s }
end
local function fmt(it)
  return it.p
end

return {
  ["pick: empty query keeps the caller's order"] = function()
    local items = { P("z"), P("a"), P("m") }
    local out = pick.rank(items, "", fmt)
    assert(#out == 3 and out[1].p == "z" and out[3].p == "m", "order preserved for empty query")
    assert(vim.deep_equal(pick.rank(items, "   ", fmt), items), "whitespace-only is empty too")
  end,

  ["pick: a query fuzzy-filters and drops non-matches"] = function()
    local items = { P("alpha/one"), P("beta/two"), P("alpha/three") }
    local out = pick.rank(items, "alph", fmt)
    local names = vim.tbl_map(fmt, out)
    assert(#out == 2, "only the two alpha entries match, got " .. vim.inspect(names))
    assert(not vim.tbl_contains(names, "beta/two"), "beta is filtered out")
  end,

  ["pick: handle drives filter + choose without keystrokes"] = function()
    local chosen, called = nil, false
    local items = { P("a/one"), P("b/two"), P("a/three") }
    pick.open({
      items = items,
      title = "t",
      format = fmt,
      on_choice = function(c)
        called, chosen = true, c
      end,
    })
    pick._active.set_query("thre") -- narrows to a/three
    pick._active.choose()
    assert(called, "on_choice fired")
    assert(chosen and chosen.p == "a/three", "chose the filtered match: " .. tostring(chosen and chosen.p))
    assert(pick._active == nil, "picker closed after choose")
  end,

  ["pick: move selects, choose picks the selection"] = function()
    local chosen
    pick.open({
      items = { P("one"), P("two"), P("three") },
      format = fmt,
      on_choice = function(c)
        chosen = c
      end,
    })
    pick._active.move(1) -- sel 1 -> 2
    pick._active.choose()
    assert(chosen and chosen.p == "two", "moved then chose second: " .. tostring(chosen and chosen.p))
  end,

  ["pick: cancel fires on_choice(nil) exactly once"] = function()
    local calls, last = 0, "sentinel"
    pick.open({
      items = { P("x") },
      format = fmt,
      on_choice = function(c)
        calls = calls + 1
        last = c
      end,
    })
    pick._active.cancel()
    assert(calls == 1, "exactly one on_choice call, got " .. calls)
    assert(last == nil, "cancel -> nil")
  end,
}
