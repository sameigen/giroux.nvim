local statsheet = require("giroux.statsheet")
require("giroux").setup({})

return {
  ["statsheet: _error_lines surfaces the exit code, not an empty sheet"] = function()
    local lines = statsheet._error_lines(1)
    assert(#lines > 0, "error render must not be empty")
    local text = table.concat(lines, "\n")
    assert(text:find("exit 1", 1, true), text)
    assert(text:find("giroux:", 1, true), text)
  end,
}
