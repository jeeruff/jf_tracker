-- jf_tracker_instkeys.lua — клавиши модуля инструментов в духе Vim (2 окт).
--
-- Объект — инструмент (запись пула: уникальный сэмпл / слайс трека).
--   j k g G      выбор (пустые слоты .. — тоже)   h l   трек влево / вправо
--   dd           вырезать инструмент: его события на треках и item библиотеки
--                уходят (в регистр), v — диапазон
--   yy           взять в регистр (v — диапазон)
--   p P          положить копию из регистра в библиотеку трека курсора
--   yp yP        дублировать сразу (взять + положить)
--   v            диапазон от якоря, Esc — снять
--   Enter s      слайсер   Space  прослушать   a  слушать при выборе
--   /            fzf-поиск   Esc  назад в трекер
-- Ожидающий оператор показывает продолжения в статусе (IK.pending_hint).
--
-- Без reaper.*: действия — ctx.inst_* (main), тестируется стабами.

local IK = {}
IK.pending = nil
IK.anchor = nil          -- начало диапазона (v)
local ctx

local LEFT, RIGHT, UP, DOWN = 1818584692, 1919379572, 30064, 1685026670

function IK.init(c) ctx = c end

local HINT = {
  d = 'd: d cut instrument - its events and library item (v: range), p puts it back | Esc',
  y = 'y: y yank (v: range) | p duplicate after | P duplicate before | Esc',
}
function IK.pending_hint() return IK.pending and HINT[IK.pending] or nil end

-- диапазон инструментов: v-якорь..курсор, иначе один курсор
function IK.range(cur)
  local a = IK.anchor or cur
  return math.min(a, cur), math.max(a, cur)
end

-- c — код клавиши; cur — выбранный номер; n — инструментов (без пустых);
-- nslots — вместе с пустыми слотами. true — съедено; 'leave' — в трекер;
-- false — не наше (main отдаёт в vim).
function IK.key(c, cur, n, nslots)
  local ch = c < 256 and string.char(c) or ''
  if IK.pending then
    local op = IK.pending
    IK.pending = nil
    if c == 27 then return true end
    local r0, r1 = IK.range(cur)
    r1 = math.min(r1, n)
    if op == 'd' and ch == 'd' then if r0 <= r1 then ctx.inst_cut(r0, r1) end; IK.anchor = nil
    elseif op == 'y' and ch == 'y' then if r0 <= r1 then ctx.inst_yank(r0, r1) end; IK.anchor = nil
    elseif op == 'y' and (ch == 'p' or ch == 'P') then
      if r0 <= r1 then ctx.inst_yank(r0, r1, true); ctx.inst_put(ch == 'P') end
      IK.anchor = nil
    else ctx.msg(op .. ch .. ': not a lib command (? - help)') end
    return true
  end
  -- в диапазоне (v) d / y действуют сразу (x убран 5 окт: вырезать — только d)
  if IK.anchor and (ch == 'd' or ch == 'y') then
    local r0, r1 = IK.range(cur)
    r1 = math.min(r1, n)
    if r0 <= r1 then if ch == 'y' then ctx.inst_yank(r0, r1) else ctx.inst_cut(r0, r1) end end
    IK.anchor = nil
    return true
  end
  if c == 27 then
    if IK.anchor then IK.anchor = nil; return true end
    return 'leave'
  end
  -- automation — строка после всех слотов (5 окт): j с последнего слота — туда, k — обратно
  if ctx.midi_on and ctx.midi_on() then                -- midi — под automation (10 окт)
    if (ch == 'k' or c == UP) and ctx.auto_select then ctx.auto_select(); return true end
    if ch == 'j' or c == DOWN or ch == 'G' then return true end
  end
  if ctx.auto_on and ctx.auto_on() then
    if ch == 'k' or c == UP then ctx.inst_select(math.max(1, nslots)); return true end
    if ch == 'j' or c == DOWN then if ctx.midi_select then ctx.midi_select() end; return true end
  end
  if ch == 'd' or ch == 'y' then IK.pending = ch; ctx.msg(ch .. '...'); return true end
  if (ch == 'j' or c == DOWN) and cur >= nslots and ctx.auto_select then ctx.auto_select()
  elseif ch == 'j' or c == DOWN then ctx.inst_select(math.min(math.max(1, nslots), cur + 1))
  elseif ch == 'k' or c == UP then ctx.inst_select(math.max(1, cur - 1))
  elseif ch == 'J' or ch == 'K' then ctx.lib_step(ch == 'J' and 1 or -1)   -- исходник ниже / выше (3 окт)
  elseif ch == 'g' then ctx.inst_select(1)
  elseif ch == 'G' then if ctx.midi_select then ctx.midi_select() elseif ctx.auto_select then ctx.auto_select() else ctx.inst_select(math.max(1, n)) end   -- G — в самый низ: midi (10 окт)
  elseif ch == 'v' then IK.anchor = IK.anchor and nil or cur
  elseif ch == 'p' then ctx.inst_put(false)
  elseif ch == 'P' then ctx.inst_put(true)
  elseif c == 13 then ctx.open_slicer()                         -- Enter — выбрать: сэмпл во вкладке item
  elseif ch == 's' then if ctx.slice_hydra then ctx.slice_hydra() end   -- s — сразу меню нарезки (5 окт)
  elseif ch == ' ' then ctx.inst_listen()
  elseif ch == 'a' then ctx.inst_listen_toggle()
  elseif ch == '/' then ctx.inst_find()
  elseif ch == 'h' or c == LEFT then ctx.inst_track(-1)
  elseif ch == 'l' or c == RIGHT then ctx.inst_track(1)
  else return false end
  return true
end

return IK
