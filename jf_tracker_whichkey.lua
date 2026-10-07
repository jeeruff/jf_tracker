-- jf_tracker_whichkey.lua — подсказка второй клавиши (7 окт, как which-key в
-- Emacs / Neovim): нажат префикс (d, z, g …) — главный модуль вместо быстрых
-- опций показывает, что можно нажать дальше. Таблица — по обработчикам
-- jf_tracker_vim.lua (key_normal: ветки p == 'z' / 'g' / операторы, motion);
-- новая клавиша там — строка здесь.

local WK = {}

-- описания короткие (7 окт): в главном модуле две колонки по ~12 знаков
local MOTIONS = {
  { 'w', 'next event' }, { 'b', 'prev event' }, { 'e', 'event end' },
  { 'j k', 'rows' }, { 'h l', 'fields' }, { '{ }', 'bars' },
  { '0 $', 'row start/end' }, { 'gg G', 'top / end' }, { 'H L', 'screen' },
  { '1..9', 'count: d3j' },
}

local T = {
  d = { title = 'd - delete', items = { { 'd', 'row (3dd)' }, { 'W', 'whole item' },
        { 't', 'time select' }, { 'r', 'track in rgn' }, { 'a w', 'all items' } } },
  y = { title = 'y - copy', items = { { 'y', 'row (3yy)' } } },
  c = { title = 'c - change', items = { { 'c', 'row + INSERT' } } },
  da = { title = 'da - delete all', items = { { 'w', 'every item of the track' } } },
  g = { title = 'g - go', items = { { 'g', 'top of the track' }, { 'w', 'swap with the next event (3gw - third)' } } },
  z = { title = 'z - view', items = { { 'z', 'row to middle' }, { 't b', 'row top / bot' },
        { 'a', 'fold track' }, { 'C', '1-char strip' }, { 'f', 'fold folder' },
        { 'M', 'fold <-> all' }, { 's', 'session' }, { 'r', 'router' },
        { 'R', 'big router' } } },
  r = { title = 'r - replace', items = { { 'key', 'the field under the cursor gets this value' } } },
  q = { title = 'q - record a macro', items = { { 'a..z', 'into this register; q again stops' } } },
  ['@'] = { title = '@ - play a macro', items = { { 'a..z', 'from this register' }, { '@', 'the last one again' } } },
  dsp_z = { title = 'z - router', items = { { 'z r', 'router in the DSP FX panel on / off' }, { 'R', 'big router' } } },
}

-- p — ожидающий префикс; op — оператор, если ждём g после него (dgg)
function WK.get(p, op)
  if not p then return nil end
  if op and p == 'g' then
    return { title = op .. 'g - to the top', items = { { 'g', 'from the cursor to the top of the track' } } }
  end
  local t = T[p]
  if not t then return nil end
  if p == 'd' or p == 'y' or p == 'c' then
    local items = {}
    for _, e in ipairs(t.items) do items[#items + 1] = e end
    for _, e in ipairs(MOTIONS) do items[#items + 1] = e end
    return { title = t.title .. ' + a motion', items = items }
  end
  return t
end

return WK
