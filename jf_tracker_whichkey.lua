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
  { '0 $', 'row start/end' }, { 'gg G', 'top / end' }, { 'H L', 'prev / next track' },
  { '1..9', 'count: d3j' },
}

local T = {
  d = { title = 'd - delete', items = { { 'd', 'row (3dd)' }, { 'c', 'automation column' }, { 'W', 'whole item' }, { 'p', 'up to the pause' }, { 'P', 'all of sel. tracks' },
        { 't', 'time select' }, { 'r', 'track in rgn' }, { 'a w', 'all items' } } },
  y = { title = 'y - copy', items = { { 'y', 'row (3yy)' } } },
  c = { title = 'c - change', items = { { 'c', 'row + INSERT' } } },
  da = { title = 'da - delete all (the track, in the song)', items = { { 'w', 'every item of the track' }, { 'e', 'all automation' }, { 'l', 'notes of the cursor row' }, { 'j', 'notes below the cursor' }, { 'k', 'notes above the cursor' }, { 'h', 'notes except the cursor row' }, { 'E', 'automation of all tracks in the pattern' }, { 'L', 'the row on all tracks' }, { 'J K H', 'the same on all tracks' } } },
  g = { title = 'g - go', items = { { 'g', 'top of the track' }, { '12 Enter', 'go to row 0012 (also 12gg)' }, { 'w', 'swap with the next event (3gw - third)' }, { 's', 'smart panel: values of the field under the cursor, pick with the mouse' }, { 'm', 'metronome: on / off, speed, accents, pre-roll' }, { 't', 'module tab (menu; 3gt - the third)' }, { 'T', 'REAPER project tab (menu; 2gT - the second)' } } },
  z = { title = 'z - view', items = { { 'z', 'this module on the whole window (again - back)' }, { 'Z', 'fixed cursor: the row stays in the middle' }, { 'w', 'wave view: column / note / back / off / only' }, { 't', 'row to the top' }, { 'b', 'row to the bottom' },
        { 'a', 'fold track (compact) <-> open' }, { 'c', 'compact' }, { 'o', 'open' }, { 'e', 'envelope column view: curve / values / steps' }, { 'C', '1-char strip' }, { 'f', 'fold folder' },
        { 'M', 'fold <-> all' }, { 'm', 'mixer on / off' }, { '> <', 'all tracks wider / narrower' }, { '. ,', 'cursor track wider / narrower' }, { 's', 'session' }, { 'x', 'crossfade editor (REAPER)' }, { 'r', 'router' },
        { 'R', 'big router' } } },
  pane = { title = 'PANE (Ctrl+W) - Esc out', items = { { 'h j k l', 'focus neighbour' }, { 'H J K L', 'move pane' },
        { 'w W  1..9', 'next / prev / number' }, { 'g + key', 'go to panel' }, { 's v + key', 'split below / right' },
        { 'T + key', 'stack (tab)' }, { 'B', 'out of the stack' }, { 'X + key  x', 'swap / with last' },
        { '+ -  < >', 'height / width' }, { '=', 'equal' }, { 'z', 'zoom' }, { 'c', 'hide' }, { 'Space', 'next layout' }, { 'u', 'undo' } },
        panels = true },   -- 16 окт: клавиши панелей — из реестра панелей (main), по алфавиту, буква подсвечена
  ["'"] = { title = "' - harpoon (pinned places)", items = { { 'a', 'pin here: track row / matrix cell / DSP param' }, { '1..9', 'jump (focus goes there)' }, { "'", 'list by module (fzf)' }, { 'd', 'unpin this place' } } },
  T = { title = 'T - take (the note under the cursor)', items = { { 'f', 'add take fx (fzf)' }, { 'o', 'its take fx chain in DSP' } } },
  t = { title = 't - track', items = { { 't', 'new track (3tt)' }, { 'd', 'delete tracks (5td), to the buffer' }, { 'x', 'cut tracks' }, { 'p', 'paste tracks' }, { 's', 'new bus: tracks send to it' }, { 'r', 'new source: sends to tracks' },
        { 'n', 'rename' }, { 'c', 'colour' }, { 'y', 'duplicate' }, { 'a', 'rec arm (6ta - six tracks; t135a - tracks 1 3 5)' }, { 'i', 'input (list)' }, { 'I', 'input: the active one' },
        { 'l', 'fixed lanes on / off' }, { 'f', 'add fx (fzf)' }, { 'R', 'routing (S R O)' }, { 'T', 'track template (list) - after this track' }, { 'F', 'into a folder: the track to the left becomes it' }, { 'j k', 'move right / left (3tj)' } } },
  r = { title = 'r - replace', items = { { 'key', 'the field under the cursor gets this value' } } },
  q = { title = 'q - record a macro', items = { { 'a..z', 'into this register; q again stops' } } },
  ['@'] = { title = '@ - play a macro', items = { { 'a..z', 'from this register' }, { '@', 'the last one again' }, { 'Opt+Shift+2', 'big panel' } } },
  dsp_z = { title = 'z - router / pages', items = { { 'z r', 'router in the DSP FX panel on / off' }, { 'R', 'big router' }, { 'f', 'fold / unfold module pages (Surge: all in one pane / one page, tabs on the right)' } } },
  dsp_a = { title = 'a - add / automate', items = { { 'f', 'add fx (fzf)' }, { 'F', 'take fx on the note under the cursor' },
        { 'a', 'automate the parameter' }, { 'p', 'pick a parameter' }, { 'i', 'automation item' }, { 'd', 'remove automation' },
        { 'm', 'map to a container macro' } } },
  dsp_d = { title = 'd - delete', items = { { 'd', 'the fx (v: range)' }, { 'c', 'unpack the container' },
        { 'm', 'remove modulation' }, { 'a', 'remove automation' } } },
  dsp_y = { title = 'y - copy', items = { { 'y', 'the fx' } } },
  dsp_c = { title = 'c - container', items = { { 'c', 'pack the fx (v: range)' } } },
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
