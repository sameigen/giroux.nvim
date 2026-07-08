-- Minimal test runner: nvim -l tests/run.lua [name-filter]
-- Discovers tests/*_spec.lua; each spec returns { ["test name"] = fn, ... }.
-- A test fails by error()/assert. No framework, no setup hooks — keep specs flat.

local root = vim.fs.dirname(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)))
vim.opt.runtimepath:prepend(root)
package.path = root .. "/tests/?.lua;" .. package.path -- so specs can require("helpers")

-- selene: allow(global_usage) -- `arg` is nvim -l's argv; _G access is deliberate
local filter = _G.arg and _G.arg[1] or nil
local specs = vim.fn.glob(root .. "/tests/*_spec.lua", false, true)
table.sort(specs)

-- A spec may skip itself when a dependency is unavailable (zsh, BSD stat,
-- a real platform) by raising an error whose message starts with "SKIP:".
-- That's counted as skipped, never as a failure — pure logic runs anywhere,
-- platform/integration specs no-op off-platform (e.g. in Linux CI).
local pass, fail, skip = 0, 0, 0
for _, spec_path in ipairs(specs) do
  local spec_name = vim.fs.basename(spec_path):gsub("%_spec%.lua$", "")
  local tests = dofile(spec_path)
  local names = vim.tbl_keys(tests)
  table.sort(names)
  for _, name in ipairs(names) do
    if not filter or name:find(filter, 1, true) or spec_name:find(filter, 1, true) then
      local ok, err = pcall(tests[name])
      if ok then
        pass = pass + 1
      elseif type(err) == "string" and err:find("SKIP:", 1, true) then
        skip = skip + 1
        io.write(("SKIP [%s] %s — %s\n"):format(spec_name, name, err:match("SKIP:%s*(.*)") or ""))
      else
        fail = fail + 1
        io.stderr:write(("FAIL [%s] %s\n  %s\n"):format(spec_name, name, tostring(err)))
      end
    end
  end
end

io.write(("%d passed, %d failed, %d skipped\n"):format(pass, fail, skip))
os.exit(fail == 0 and 0 or 1)
