local roster = require("giroux.roster")

local function sess(o)
  return vim.tbl_extend(
    "force",
    { node = "x", path = "/p/s.jsonl", project = "~/p", state = "○", mtime = 0, pending = {} },
    o
  )
end

return {
  ["roster: group by machine, needs-you first within a group"] = function()
    local items = {
      sess({ node = "gintoki", project = "~/a", state = "○" }),
      sess({ node = "gintoki", project = "~/b", state = "?" }),
      sess({ node = "neoeig", project = "~/c", state = "●" }),
    }
    local r = roster.build(items, "machine", {})
    -- headers: gintoki has a ? so it sorts before neoeig (most-urgent member)
    local headers = {}
    for _, row in ipairs(r.rows) do
      if row.kind == "header" then
        headers[#headers + 1] = row.group
      end
    end
    assert(vim.deep_equal(headers, { "gintoki", "neoeig" }), vim.inspect(headers))
    -- first item under gintoki is the ? one
    local first_item
    for _, row in ipairs(r.rows) do
      if row.kind == "item" then
        first_item = row.item
        break
      end
    end
    assert(first_item.state == "?", "needs-you floats to the top of its group")
  end,

  ["roster: header carries count + needs-you/dead badge"] = function()
    local items = {
      sess({ node = "g", state = "?" }),
      sess({ node = "g", state = "✗" }),
      sess({ node = "g", state = "○" }),
    }
    local r = roster.build(items, "machine", {})
    local header
    for _, l in ipairs(r.lines) do
      if l:find("g (3)", 1, true) then
        header = l
      end
    end
    assert(header, "count: " .. vim.inspect(r.lines))
    assert(header:find("^▾ %? g "), "leads with the most-urgent glyph (?): " .. tostring(header))
    assert(header:find("?1", 1, true) and header:find("✗1", 1, true), "badge: " .. tostring(header))
  end,

  ["roster: done (✓) ranks above idle and below working"] = function()
    local items = {
      sess({ node = "g", state = "○", project = "~/idle" }),
      sess({ node = "g", state = "✓", project = "~/done" }),
      sess({ node = "g", state = "●", project = "~/work" }),
    }
    local r = roster.build(items, "machine", {})
    local order = {}
    for _, row in ipairs(r.rows) do
      if row.kind == "item" then
        order[#order + 1] = row.item.state
      end
    end
    assert(vim.deep_equal(order, { "●", "✓", "○" }), vim.inspect(order))
  end,

  ["roster: folded header telegraphs the group's most-urgent glyph + ✓ count"] = function()
    local items = {
      sess({ node = "g", state = "○" }),
      sess({ node = "g", state = "✓" }),
    }
    local r = roster.build(items, "machine", { ["machine\0g"] = true }) -- folded
    local header
    for _, l in ipairs(r.lines) do
      if l:find("g (2)", 1, true) then
        header = l
      end
    end
    assert(header and header:find("^▸ ✓ g "), "folded group leads with ✓: " .. tostring(header))
    assert(header:find("✓1", 1, true), "done count in badge: " .. tostring(header))
  end,

  ["roster: collapsed group hides its items but keeps the header"] = function()
    local items = { sess({ node = "g", state = "○" }), sess({ node = "h", state = "○" }) }
    -- fold keys are namespaced by grouping mode: "machine\0g"
    local r = roster.build(items, "machine", { ["machine\0g"] = true })
    local n_items, g_header = 0, nil
    for _, row in ipairs(r.rows) do
      if row.kind == "item" then
        n_items = n_items + 1
      elseif row.kind == "header" and row.group == "g" then
        g_header = row
      end
    end
    assert(g_header, "collapsed header still shown")
    assert(g_header.ckey == "machine\0g", "header carries the namespaced fold key")
    assert(n_items == 1, "only the expanded group's item is rendered, got " .. n_items)
  end,

  ["roster: fold key is namespaced — no cross-mode bleed"] = function()
    -- folding repo "loper" must NOT fold a machine named "loper"
    local items = { sess({ node = "loper", project = "~/loper", state = "○" }) }
    local folded_as_repo = { ["repo\0loper"] = true }
    local r = roster.build(items, "machine", folded_as_repo)
    local item_rows = 0
    for _, row in ipairs(r.rows) do
      if row.kind == "item" then
        item_rows = item_rows + 1
      end
    end
    assert(item_rows == 1, "machine 'loper' stays expanded despite a folded repo 'loper'")
  end,

  ["roster: group by state buckets by glyph, attention order"] = function()
    local items = {
      sess({ state = "○", node = "a" }),
      sess({ state = "?", node = "b" }),
    }
    local r = roster.build(items, "state", {})
    local headers = {}
    for _, row in ipairs(r.rows) do
      if row.kind == "header" then
        headers[#headers + 1] = row.group
      end
    end
    assert(headers[1] == "needs you", "needs-you group first: " .. vim.inspect(headers))
  end,

  ["roster: _line drops the grouped dimension's column"] = function()
    local it = sess({ node = "gintoki", project = "~/Code/loper", title = "t", state = "●" })
    assert(not roster._line(it, "node"):find("gintoki", 1, true), "node column dropped when grouped by machine")
    assert(roster._line(it, "node"):find("loper", 1, true), "project still shown")
    assert(roster._line(it, "project"):find("gintoki", 1, true), "node shown when grouped by repo")
  end,
}
