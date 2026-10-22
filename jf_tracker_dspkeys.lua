-- jf_tracker_dspkeys.lua — клавиши DSP-панели в духе Vim (2 окт).
--
-- Объект — эффект (блок) цепочки трека курсора, внутри — параметр.
--   h l          эффект влево / вправо      j k        параметр
--   w W          следующий / предыдущий модуль (по кругу, N w; и из слайдера параметра)
--   i            INSERT параметра (22 окт): число или начало имени значения, Enter / Esc; вне — цифры и буквы ноты KEYS
--   + - ^A ^X    значение (Shift — грубо)   Enter b    тоггл / bypass
--   dd           удалить эффект (v — диапазон)
--   dc           распаковать контейнер (дети в цепочку, контейнер долой)
--   dm da        снять модуляцию параметра / удалить его автоматизацию
--   yy p P       взять эффект, вставить копию после / перед
--   cc           упаковать эффект (v — диапазон) в новый контейнер
--   aa           огибающая выбранного параметра (автоматизация)
--   ap           выбрать параметр для автоматизации (fzf)
--   am           параметр ребёнка контейнера → нативный макрос контейнера
--                (container_map; модуляция макроса — нативная, LFO / ACS / link)
--   af /         добавить эффект (fzf)
--   v            выделить диапазон эффектов (h l тянут), Esc — снять
--   o            окно эффекта, Space play, Esc — назад в трекер
--   t            цепочка трека ↔ take FX инструмента (обрабатывает main)
--   Enter на drumrs5k — режим пэдов (19 окт): h l нота ∓1, j k ряд (∓4), x вырезать пэд, yy взять,
--                yp дубль на свободную ноту рядом, p вставить на ноту курсора, M mute, S solo,
--                Enter послушать, r пэд в роутере, G group (играют вместе), C choke group, Esc — обратно к эффектам
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
  d = 'd: d delete fx (v: range) | m remove modulation of the parameter | a remove its automation | c unpack container | Esc',
  y = 'y: y copy fx, then p after / P before | Esc',
  c = 'c: c pack fx (v: range) into a new container | Esc',
  a = 'a: a automate parameter (envelope) | d delete its automation | i automation item over the item under the cursor | m map to the container (native macro) | p pick parameter | f add fx | F take fx on the note | Esc',
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
    if DK.pads and op == 'y' then
      if ch == 'y' then ctx.pad_yank(sel.fx) elseif ch == 'p' then ctx.pad_dup(sel.fx) end
      return true
    end
    local r0, r1 = DK.range(sel)
    if op == 'd' and ch == 'd' then ctx.dsp_delete(r0, r1); DK.anchor = nil
    elseif op == 'd' and ch == 'c' then ctx.dsp_unpack(sel.fx)
    elseif op == 'd' and ch == 'm' then ctx.dsp_unmodulate(sel.fx, sel.param)
    elseif op == 'd' and ch == 'a' then ctx.dsp_unautomate(sel.fx, sel.param)
    elseif op == 'y' and ch == 'y' then ctx.dsp_yank(sel.fx)
    elseif op == 'c' and ch == 'c' then ctx.dsp_pack(r0, r1); DK.anchor = nil
    elseif op == 'a' and ch == 'a' then ctx.dsp_automate(sel.fx, sel.param)
    elseif op == 'a' and ch == 'p' then ctx.dsp_pick_param(sel.fx)
    elseif op == 'a' and ch == 'f' then ctx.fx_picker()
    elseif op == 'a' and ch == 'F' then ctx.dsp_take_slice()       -- aF (7 окт): take FX на слайс / ноту под курсором трекера
    elseif op == 'a' and ch == 'd' then ctx.dsp_unautomate(sel.fx, sel.param)
    elseif op == 'a' and ch == 'i' then ctx.dsp_autoitem(sel.fx, sel.param)
    elseif op == 'a' and ch == 'm' then ctx.dsp_map_macro(sel.fx, sel.param)
    else ctx.msg(op .. ch .. ': not a DSP command (? - help)') end
    return true
  end
  -- в диапазоне (v) d / x / c действуют сразу
  if DK.anchor and (ch == 'd' or ch == 'x') then local r0, r1 = DK.range(sel); ctx.dsp_delete(r0, r1); DK.anchor = nil; return true end
  if DK.anchor and ch == 'c' then local r0, r1 = DK.range(sel); ctx.dsp_pack(r0, r1); DK.anchor = nil; return true end
  if DK.anchor and ch == 'y' then ctx.dsp_yank(sel.fx); DK.anchor = nil; return true end
  -- 22 окт: INSERT параметра (i): набор числа или начала имени значения, Enter — записать, Esc — отмена;
  -- вне него цифры и буквы — ноты KEYS (DSP их не перехватывает)
  if DK.ins then
    if c == 27 then DK.ins = nil; ctx.msg('parameter: entry cancelled'); return true end
    if c == 13 then local buf = DK.ins.buf; DK.ins = nil; if buf ~= '' and ctx.dsp_type_entry then ctx.dsp_type_entry(sel.fx, sel.param, buf) end; return true end
    if c == 8 then DK.ins.buf = DK.ins.buf:sub(1, -2); return true end
    if c == UP or c == DOWN then sel.param = math.max(1, math.min(math.max(1, np), sel.param + (c == DOWN and 1 or -1))); DK.ins.buf = ''; return true end
    if c >= 32 and c < 127 then DK.ins.buf = DK.ins.buf .. string.char(c); return true end
    return true
  end
  if ch == 'i' and not DK.pads and np > 0 then
    DK.ins = { buf = '' }; DK.pslider = true; DK.num = nil
    ctx.msg('-- INSERT parameter --  type a number (023 = 0.23) or the start of a value (hp, saw, off), Enter - set, Esc - cancel')
    return true
  end
  -- 22 окт: w / W — следующий / предыдущий модуль (как w в трекере — к следующему событию), по кругу, N w;
  -- из слайдера параметра тоже (он закрывается); в режиме пэдов w — буква параметра vel lo
  if (ch == 'w' or ch == 'W') and not DK.pads then
    local cnt0 = tonumber(DK.num or '') or 1; DK.num = nil; DK.pslider = nil; DK.pads_back = nil
    local m = math.max(1, n)
    sel.fx = ((sel.fx - 1 + (ch == 'W' and -cnt0 or cnt0)) % m) + 1; sel.param = 1
    return true
  end
  -- 19 окт: режим пэдов drumrs5k
  if DK.pads and ctx.pad_param_key and ctx.pad_param_key(sel, ch) then DK.pads = nil; DK.pslider = true; DK.pads_back = true; return true end   -- буква параметра — к нему (h l значение)
  if DK.pads then
    if not (ctx.pad_rack and ctx.pad_rack(sel.fx)) then DK.pads = nil
    else
      if c == 27 then DK.pads = nil; ctx.msg('DSP: effects (h l), Enter on the rack - pads again'); return true end
      if ch == 'h' or c == LEFT then ctx.pad_nav(sel.fx, -1); return true end
      if ch == 'l' or c == RIGHT then ctx.pad_nav(sel.fx, 1); return true end
      if ch == 'k' or c == UP then ctx.pad_nav(sel.fx, 4); return true end
      if ch == 'j' or c == DOWN then ctx.pad_nav(sel.fx, -4); return true end
      if ch == 'x' or c == 8 or c == 6579564 then ctx.pad_cut(sel.fx); return true end
      if ch == 'y' then DK.pending = 'y'; ctx.msg('y: y take the pad, p duplicate it onto the next free note | Esc'); return true end
      if ch == 'p' or ch == 'P' then ctx.pad_paste(sel.fx); return true end
      if ch == 'M' or ch == 'S' then ctx.pad_ms(sel.fx, ch == 'S'); return true end
      if c == 13 then ctx.pad_listen(sel.fx); return true end
      if ch == 'r' then ctx.pad_route_cur(sel.fx); return true end
      if ch == 'G' or ch == 'C' then ctx.pad_group_cur(sel.fx, ch == 'C' and 'choke' or 'group'); return true end   -- 19 окт: G — group, C — choke group
    end
  end
  -- 21 окт: счётчик: 20 h / l — шаг ×20, 23 j / k — через 23 параметра, 3w; 22 окт: только когда клавиатура не играет
  -- (KEYS — цифры ноты); значение числом — в INSERT параметра (i)
  if ch:match('^%d$') and not DK.digits_play then
    DK.num = ((DK.num or '') .. ch):sub(-3)   -- 22 окт: счётчик до 3 цифр (было — без предела, 32 цифры в статусе)
    ctx.msg(('%s - h l: step x%s, j k: %s params, w: %s modules, Esc: cancel'):format(DK.num, DK.num, DK.num, DK.num)); return true
  end
  local num = DK.num; DK.num = nil
  if num and c == 27 then ctx.msg('count cancelled'); return true end
  local cnt = num and tonumber(num) or nil
  if cnt and (ch == 'j' or c == DOWN or ch == 'k' or c == UP) then
    sel.param = math.max(1, math.min(math.max(1, np), sel.param + ((ch == 'j' or c == DOWN) and cnt or -cnt))); return true
  end
  -- 8 окт: режим слайдера параметра (f на параметр / щелчок): h l — значение
  -- (H L крупно), j k — соседний параметр, Esc — обратно к эффектам
  if DK.pslider then
    if cnt and (ch == 'h' or ch == 'l' or ch == 'H' or ch == 'L' or c == LEFT or c == RIGHT) then
      ctx.dsp_value(sel.fx, sel.param, ((ch == 'h' or ch == 'H' or c == LEFT) and -1 or 1) * cnt, ch == 'H' or ch == 'L'); return true
    end
    if c == 27 then
      DK.pslider = nil
      if DK.pads_back then DK.pads_back = nil; DK.pads = true; ctx.msg('pads again: h l j k move'); return true end   -- 19 окт: из параметра пэда — к пэдам
      ctx.msg('DSP: h l - effects again'); return true
    end
    if ch == 'h' or ch == 'l' or ch == 'H' or ch == 'L' or c == LEFT or c == RIGHT then
      ctx.dsp_value(sel.fx, sel.param, (ch == 'h' or ch == 'H' or c == LEFT) and -1 or 1, ch == 'H' or ch == 'L'); return true
    end
  end
  if c == 27 then
    if DK.anchor then DK.anchor = nil; return true end
    return 'leave'
  end
  if ch == 'd' or ch == 'y' or ch == 'c' or ch == 'a' then
    DK.pending = ch; ctx.msg(ch .. '...'); return true
  end
  if ch == 'h' or c == LEFT then sel.fx = math.max(1, sel.fx - (cnt or 1)); sel.param = 1
  elseif ch == 'l' or c == RIGHT then sel.fx = math.min(math.max(1, n), sel.fx + (cnt or 1)); sel.param = 1
  elseif ch == 'j' or c == DOWN then sel.param = math.min(math.max(1, np), sel.param + 1)
  elseif ch == 'k' or c == UP then sel.param = math.max(1, sel.param - 1)
  elseif ch == 'g' then sel.param = 1
  elseif ch == 'G' then sel.param = math.max(1, np)
  elseif ch == 'v' then DK.anchor = DK.anchor and nil or sel.fx
  elseif ch == '+' or ch == '=' or c == 1 then ctx.dsp_value(sel.fx, sel.param, 1, mods.shift)
  elseif ch == '-' or c == 24 then ctx.dsp_value(sel.fx, sel.param, -1, mods.shift)
  elseif c == 13 and ctx.pad_rack and ctx.pad_rack(sel.fx) then
    DK.pads = true; ctx.msg('pads: h l j k move, x cut, yy yp p, M mute, S solo, Enter listen, r router, Esc back')   -- 19 окт
  elseif c == 13 then ctx.dsp_enter(sel.fx, sel.param)
  elseif ch == 'b' then ctx.dsp_bypass(sel.fx)
  elseif ch == 'o' then ctx.dsp_show(sel.fx)
  elseif ch == 'x' or c == 8 or c == 6579564 then ctx.dsp_delete(sel.fx, sel.fx)
  elseif ch == 'p' then ctx.dsp_paste(sel.fx, true)
  elseif ch == 'P' then ctx.dsp_paste(sel.fx, false)
  elseif ch == '/' then ctx.dsp_find()                            -- 7 окт: поиск по добавленным эффектам и параметрам (добавить — af)
  elseif ch == 'A' then ctx.dsp_pick_param(sel.fx)
  elseif ch == ' ' then ctx.play_stop()
  else return false end
  return true
end

return DK
