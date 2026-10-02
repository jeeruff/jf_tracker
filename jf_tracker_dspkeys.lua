-- jf_tracker_dspkeys.lua — клавиши DSP-панели в духе Vim (2 окт).
--
-- Объект — эффект (блок) цепочки трека курсора, внутри — параметр.
--   h l          эффект влево / вправо      j k        параметр
--   + - ^A ^X    значение (Shift — грубо)   Enter b    тоггл / bypass
--   dd           удалить эффект (v — диапазон)
--   dc           распаковать контейнер (дети в цепочку, контейнер долой)
--   yy p P       взять эффект, вставить копию после / перед
--   cc           упаковать эффект (v — диапазон) в новый контейнер
--   aa           огибающая выбранного параметра (автоматизация)
--   ap           выбрать параметр для автоматизации (fzf)
--   af /         добавить эффект (fzf)
--   v            выделить диапазон эффектов (h l тянут), Esc — снять
--   o            окно эффекта, Space play, Esc — назад в трекер
-- Ожидающий оператор показывает продолжения в статусе (DK.pending_hint).
--
-- Без reaper.*: действия — ctx.dsp_* (main), тестируется стабами.

local DK = {}
DK.pending = nil
DK.anchor = nil          -- начало диапазона эффектов (v)
local ctx

local LEFT, RIGHT, UP, DOWN = 1818584692, 1919379572, 30064, 1685026670

function DK.init(c) ctx = c end

local HINT = {
  d = 'd: d delete fx (v: range) | c unpack container | Esc',
  y = 'y: y copy fx, then p after / P before | Esc',
  c = 'c: c pack fx (v: range) into a new container | Esc',
  a = 'a: a automate parameter (envelope) | p pick parameter to automate | f add fx | Esc',
}
function DK.pending_hint() return DK.pending and HINT[DK.pending] or nil end

-- диапазон эффектов: v-якорь..курсор, иначе один курсор
function DK.range(sel)
  local a = DK.anchor or sel.fx
  return math.min(a, sel.fx), math.max(a, sel.fx)
end

-- c — код клавиши; sel = { fx=, param= } (меняется на месте); n — число
-- эффектов; np — число параметров выбранного; mods — модификаторы.
-- Возвращает true, если клавиша съедена; 'leave' — фокус в трекер.
function DK.key(c, sel, n, np, mods)
  mods = mods or {}
  local ch = c < 256 and string.char(c) or ''
  if DK.pending then
    local op = DK.pending
    DK.pending = nil
    if c == 27 then return true end
    local r0, r1 = DK.range(sel)
    if op == 'd' and ch == 'd' then ctx.dsp_delete(r0, r1); DK.anchor = nil
    elseif op == 'd' and ch == 'c' then ctx.dsp_unpack(sel.fx)
    elseif op == 'y' and ch == 'y' then ctx.dsp_yank(sel.fx)
    elseif op == 'c' and ch == 'c' then ctx.dsp_pack(r0, r1); DK.anchor = nil
    elseif op == 'a' and ch == 'a' then ctx.dsp_automate(sel.fx, sel.param)
    elseif op == 'a' and ch == 'p' then ctx.dsp_pick_param(sel.fx)
    elseif op == 'a' and ch == 'f' then ctx.fx_picker()
    else ctx.msg(op .. ch .. ': not a DSP command (? - help)') end
    return true
  end
  -- в диапазоне (v) d / x / c действуют сразу
  if DK.anchor and (ch == 'd' or ch == 'x') then local r0, r1 = DK.range(sel); ctx.dsp_delete(r0, r1); DK.anchor = nil; return true end
  if DK.anchor and ch == 'c' then local r0, r1 = DK.range(sel); ctx.dsp_pack(r0, r1); DK.anchor = nil; return true end
  if DK.anchor and ch == 'y' then ctx.dsp_yank(sel.fx); DK.anchor = nil; return true end
  if c == 27 then
    if DK.anchor then DK.anchor = nil; return true end
    return 'leave'
  end
  if ch == 'd' or ch == 'y' or ch == 'c' or ch == 'a' then
    DK.pending = ch; ctx.msg(ch .. '...'); return true
  end
  if ch == 'h' or c == LEFT then sel.fx = math.max(1, sel.fx - 1); sel.param = 1
  elseif ch == 'l' or c == RIGHT then sel.fx = math.min(math.max(1, n), sel.fx + 1); sel.param = 1
  elseif ch == 'j' or c == DOWN then sel.param = math.min(math.max(1, np), sel.param + 1)
  elseif ch == 'k' or c == UP then sel.param = math.max(1, sel.param - 1)
  elseif ch == 'g' then sel.param = 1
  elseif ch == 'G' then sel.param = math.max(1, np)
  elseif ch == 'v' then DK.anchor = DK.anchor and nil or sel.fx
  elseif ch == '+' or ch == '=' or c == 1 then ctx.dsp_value(sel.fx, sel.param, 1, mods.shift)
  elseif ch == '-' or c == 24 then ctx.dsp_value(sel.fx, sel.param, -1, mods.shift)
  elseif c == 13 then ctx.dsp_enter(sel.fx, sel.param)
  elseif ch == 'b' then ctx.dsp_bypass(sel.fx)
  elseif ch == 'o' then ctx.dsp_show(sel.fx)
  elseif ch == 'x' or c == 8 or c == 6579564 then ctx.dsp_delete(sel.fx, sel.fx)
  elseif ch == 'p' then ctx.dsp_paste(sel.fx, true)
  elseif ch == 'P' then ctx.dsp_paste(sel.fx, false)
  elseif ch == '/' then ctx.fx_picker()
  elseif ch == 'A' then ctx.dsp_pick_param(sel.fx)
  elseif ch == ' ' then ctx.play_stop()
  else return false end
  return true
end

return DK
