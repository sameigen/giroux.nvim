local state = require("giroux.state")
return {
  ["state: ORDER ranks needs-you first and idle-ish last"] = function()
    assert(state.rank("?") < state.rank("●"), "questions outrank working")
    assert(state.rank("●") < state.rank("✓"), "working outranks done")
    assert(state.rank("✓") < state.rank("○"), "done outranks idle")
    assert(state.rank("nonsense") == 9, "unknown sorts last")
  end,
  ["state: LABEL covers every ordered glyph"] = function()
    for glyph in pairs(state.ORDER) do
      assert(state.LABEL[glyph], "no label for " .. glyph)
    end
  end,
}
