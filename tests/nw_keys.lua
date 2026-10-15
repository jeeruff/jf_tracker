-- nw_keys.lua — клавиши в живой трекер без веб-интерфейса (15 окт): запускается через
-- REAPER -nonewinst, читает tests/shots/nw_in.txt (строки «код,cap»), подаёт по одной через
-- ExtState jf_tracker/inject, ждёт inject_ack, пишет ответы в tests/shots/nw_out.txt, в конце DONE.
-- Строка «lua: код» — выполнить код (результат — в ответ). Работает в открытом проекте (inject_any).
local DIR = debug.getinfo(1, 'S').source:sub(2):match('(.*)/')
local IN, OUT = DIR .. '/shots/nw_in.txt', DIR .. '/shots/nw_out.txt'
local lines = {}
local f = io.open(IN, 'r'); if f then for l in f:lines() do lines[#lines + 1] = l end; f:close() end
local out = io.open(OUT, 'w')
local function put(s) out:write(s .. '\n'); out:flush() end
reaper.SetExtState('jf_tracker', 'inject_any', '1', false)
local i, tok, t0 = 0, nil, 0
local pid = tostring(math.floor(reaper.time_precise() * 1000) % 1000000)
local function finish() reaper.SetExtState('jf_tracker', 'inject_any', '', false); put('DONE'); out:close() end
local function step()
  if tok then
    local a = reaper.GetExtState('jf_tracker', 'inject_ack')
    if a:sub(1, #tok + 1) == tok .. ' ' then put(tok .. ' ' .. a:sub(#tok + 2)); tok = nil
    elseif reaper.time_precise() - t0 > 4 then put(tok .. ' TIMEOUT'); return finish() end
    if tok then return reaper.defer(step) end
  end
  i = i + 1
  local l = lines[i]
  if not l then return finish() end
  local code = l:match('^lua:%s*(.*)$')
  if code then
    local fn, err = load(code)
    local ok, r = false, err
    if fn then ok, r = pcall(fn) end
    put('lua ' .. (ok and 'ok ' or 'ERR ') .. tostring(r))
    return reaper.defer(step)
  end
  tok = l .. '#' .. i .. '.' .. pid
  t0 = reaper.time_precise()
  reaper.SetExtState('jf_tracker', 'inject', tok, false)
  reaper.defer(step)
end
step()
