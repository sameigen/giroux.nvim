local transcript = require("giroux.transcript")

local function feed_all(chunks)
  local lines = transcript.lines()
  local out = {}
  for _, c in ipairs(chunks) do
    vim.list_extend(out, lines:feed(c))
  end
  return out, lines
end

return {
  ["lines: whole-file single chunk"] = function()
    local out = feed_all({ '{"a":1}\n{"b":2}\n' })
    assert(#out == 2, "expected 2 lines, got " .. #out)
    assert(out[1].text == '{"a":1}')
    assert(out[1].offset == 0 and out[1].bytes == 8)
    assert(out[2].offset == 8)
  end,

  ["lines: byte-by-byte equals whole-file"] = function()
    local doc = '{"a":1}\n{"long":"' .. ("x"):rep(500) .. '"}\n{"c":3}\n'
    local whole = feed_all({ doc })
    local chunks = {}
    for i = 1, #doc do
      chunks[i] = doc:sub(i, i)
    end
    local bytewise = feed_all(chunks)
    assert(vim.deep_equal(whole, bytewise), "streaming must not change output")
  end,

  ["lines: partial tail buffers until newline"] = function()
    local lines = transcript.lines()
    assert(#lines:feed('{"a":') == 0)
    assert(lines:partial())
    local out = lines:feed("1}\n")
    assert(#out == 1 and out[1].text == '{"a":1}')
    assert(not lines:partial())
  end,

  ["lines: resume offset survives mid-record cut"] = function()
    local lines = transcript.lines()
    lines:feed('{"a":1}\n{"b":')
    assert(lines:resume_offset() == 8, "resume must point at the partial record start")
    -- reconnect: new assembler from the resume offset re-reads the partial record
    local resumed = transcript.lines(lines:resume_offset())
    local out = resumed:feed('{"b":2}\n')
    assert(out[1].offset == 8 and out[1].text == '{"b":2}')
  end,

  ["lines: blank lines skipped, offsets honest"] = function()
    local out = feed_all({ '{"a":1}\n\n\n{"b":2}\n' })
    assert(#out == 2)
    assert(out[2].offset == 10, "blank lines still advance offsets, got " .. out[2].offset)
  end,

  ["lines: crlf tolerated"] = function()
    local out = feed_all({ '{"a":1}\r\n' })
    assert(out[1].text == '{"a":1}')
    assert(out[1].bytes == 9, "bytes count includes the CR")
  end,

  ["lines: nonzero start offset"] = function()
    local lines = transcript.lines(100)
    local out = lines:feed('{"a":1}\n')
    assert(out[1].offset == 100)
    assert(lines:resume_offset() == 108)
  end,
}
