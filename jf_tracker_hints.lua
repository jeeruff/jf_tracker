-- jf_tracker_hints.lua — Vim-подсказки (как Vimium / easymotion / warpd).
--
-- `f` в NORMAL: на каждую интерактивную цель на экране вешается метка из
-- двух букв домашнего ряда; набрал метку — фокус и курсор прыгают туда, без
-- мыши. Цели собираются во время отрисовки (draw/matrix/browser зовут
-- H.add), поэтому список всегда соответствует тому, что видно.
--
-- Цель: { kind=, x=, y=, w=, h=, data= }. Виды и что делает прыжок — в main
-- (hint_go): bar (такт × трек, не каждое событие) / env → курсор трекера; header → трек; btn → M/S/R;
-- mx → ячейка матрицы; mxprev/mxnext → паттерн слота; mxbtn; tab; ctrl;
-- scope; pool → инструмент; mod → переключатель модуляции; dsp/dspparam;
-- browser → строка; sample → слайсер.
--
-- Без reaper.*: тестируется стабами.

local H = {}
H.active = false
H.targets = {}
H.typed = ''
-- 26 букв → 676 меток из двух (5 окт: 144 не хватало — lib, слайсы и браузер
-- рисуются последними и оставались без меток); домашний ряд — первым
local ALPHA = 'asdfghjklqweruiopzxcvnmtyb'

-- кадр: новый список целей; во время набора метки — заморожен (5 окт: reset
-- чистил его каждый кадр, и после f меток не было вовсе)
-- 21 окт: цели — из пула (таблица на цель каждый кадр была главным мусором кадра: сотни целей × 33 fps);
-- массив тоже свой, чистится на месте. Пока идёт набор (H.active) — список заморожен, пул не трогается
H.pool, H.pn, H.arr = {}, 0, {}
function H.reset()
  if H.active then return end
  local a = H.arr
  for i = #a, 1, -1 do a[i] = nil end
  H.targets, H.pn = a, 0
end

H.ALT = { dspbtn = true }
H.LEVEL = { ptab = 1, tab = 1, viewbtn = 1, header = 1, ctrl = 1, btn = 1, mxbtn = 1, dsptarget = 1, dsprouting = 1, dspbtn = 1, slx = 1,   -- 2 ноя: кнопки пульта slixer — как кнопки
            note = 0, beat = 0, bar = 0,   -- 20 окт: прыжки по трекеру — ноты, доли, такты — первыми буквами
            mx = 3, trsmark = 3, sess = 3, mxname = 3, mxdur = 3, fxbrow = 3 }
function H.add(kind, x, y, w, h, data)
  if H.active then return end        -- во время набора список заморожен
  local n = H.pn + 1
  H.pn = n
  local t = H.pool[n]
  if not t then t = {}; H.pool[n] = t end
  t.kind, t.x, t.y, t.w, t.h, t.data, t.label, t.picked = kind, x, y, w, h, data, nil, nil
  H.targets[#H.targets + 1] = t
end

-- назначить метки: aa, as, ad … (первая буква — «страница»)
-- 11 окт: filter(t) → только такие цели; H.multi — набор отмечает несколько, Enter отдаёт их
function H.start(filter)
  if filter then
    local keep = {}
    for _, t in ipairs(H.targets) do if filter(t) then keep[#keep + 1] = t end end
    H.targets = keep
  end
  for _, t in ipairs(H.targets) do t.picked = nil end
  if #H.targets == 0 then H.multi = false; return false end
  local n = #ALPHA
  local max = n * n
  -- 5 окт: метка, налезающая на уже поставленную, не ставится (кнопки R I M S
  -- уже метки) — её буквы достаются следующей цели; размер метки — с прошлой
  -- отрисовки
  local lw, lh = H.lw or 16, H.lh or 12
  local placed, k = {}, 0
  -- 19 окт: свои метки (data.fixed: кубик паттерна — его код a1 … ff) ставятся первыми, буквенные их обходят
  local fixed = {}
  H.digits = false
  for _, t in ipairs(H.targets) do
    local fx = type(t.data) == 'table' and t.data.fixed
    if fx and not fixed[fx] then fixed[fx] = true; t.label = fx; placed[#placed + 1] = t; if fx:match('%d') then H.digits = true end end
  end
  -- 9 окт: меток 676, целей бывает больше (клетки матрицы, строки) —
  -- подписи панелей и вкладок, кнопки получают буквы первыми, массовые
  -- цели — последними (порядок внутри уровня — как рисовались)
  local order = {}
  -- 2 ноя: модуль в фокусе (только что открыт / перешли в него) — его цели первыми: короткие буквы и место (H.focus_rect от main)
  local fr = H.focus_rect
  for i, t in ipairs(H.targets) do
    local lv = H.LEVEL[t.kind] or 2
    if fr then
      local cx, cy = t.x + (t.w or 0) / 2, t.y + (t.h or 0) / 2
      local pr = H.prev_rect
      if cx >= fr.x and cx < fr.x + fr.w and cy >= fr.y and cy < fr.y + fr.h then lv = lv - 10
      elseif pr and cx >= pr.x and cx < pr.x + pr.w and cy >= pr.y and cy < pr.y + pr.h then lv = lv - 5   -- 3 ноя: прошлый модуль — следом
      elseif lv <= 0 or lv >= 3 then lv = 50 end   -- 2 ноя: массовые метки (строки, клетки) чужого модуля — в самый конец: не съедают буквы
    end
    order[i] = { t = t, i = i, lv = lv }
  end
  table.sort(order, function(a, b) if a.lv ~= b.lv then return a.lv < b.lv end return a.i < b.i end)
  for _, o in ipairs(order) do
    local t = o.t
    if t.label and fixed[t.label] and type(t.data) == 'table' and t.data.fixed == t.label then goto hnext end
    t.label = nil
    t.lx, t.ly = nil, nil
    local free = false
    -- 11 окт: узкие кнопки вплотную (шапка эффекта DSP) — метка может встать строкой выше / ниже
    local spots = H.ALT[t.kind] and { { t.x, t.y }, { t.x, t.y - lh }, { t.x, t.y + lh } } or { { t.x, t.y } }
    -- 2 ноя: широкая цель (кнопка пульта slixer, строка) — занято слева, метка встаёт внутри правее / у правого края
    if (t.w or 0) >= 3 * lw then spots[#spots + 1] = { t.x + lw + 1, t.y }; spots[#spots + 1] = { t.x + t.w - lw, t.y } end
    if k < max then
      for _, sp in ipairs(spots) do
        local ok = true
        for _, p in ipairs(placed) do
          local px, py = p.lx or p.x, p.ly or p.y
          if sp[1] < px + lw + 1 and px < sp[1] + lw + 1 and sp[2] < py + lh and py < sp[2] + lh then ok = false; break end
        end
        if ok then free = true; if sp[2] ~= t.y then t.lx, t.ly = sp[1], sp[2] end; break end
      end
    end
    if free then
      local a = math.floor(k / n) + 1
      local b = k % n + 1
      t.label = ALPHA:sub(a, a) .. ALPHA:sub(b, b)
      while fixed[t.label] and k + 1 < max do k = k + 1; a = math.floor(k / n) + 1; b = k % n + 1; t.label = ALPHA:sub(a, a) .. ALPHA:sub(b, b) end
      placed[#placed + 1] = t
      k = k + 1
    end
    ::hnext::
  end
  if next(fixed) then k = k + 1 end
  if k == 0 then return false end
  H.active = true
  H.typed, H.upper = '', false
  return true
end

function H.stop() H.active = false; H.typed = ''; H.multi = false end

-- клавиша: 'cancel' | 'pending' | цель
function H.key(c)
  if c == 27 then H.stop(); return 'cancel' end
  if H.multi and c == 13 then
    local out = { kind = 'multi', picked = {} }
    for _, t in ipairs(H.targets) do if t.picked then out.picked[#out.picked + 1] = t end end
    H.stop(); return out
  end
  if c == 8 then H.typed = H.typed:sub(1, -2); return 'pending' end
  if c < 32 or c > 126 then return 'pending' end
  local ch = string.char(c):lower()
  if not ALPHA:find(ch, 1, true) and not (H.digits and ch:match('%d')) then return 'pending' end
  if H.typed == '' then H.upper = false end
  if string.char(c) ~= ch then H.upper = true end     -- 8 окт: метка заглавной (Shift) — вариант цели, у фейдера «туда и обратно»
  H.typed = H.typed .. ch
  for _, t in ipairs(H.targets) do
    if t.label == H.typed then
      if H.multi then t.picked = not t.picked; H.typed = ''; return 'pending' end
      H.stop(); return t
    end
  end
  if #H.typed >= 2 then H.typed = '' end   -- нет такой метки — заново
  return 'pending'
end

-- метки поверх всего: маленькие янтарные бирки у левого верха цели;
-- набранная буква подсвечена
function H.draw(U, L)
  if not H.active then return end
  local lw = U.measure('aa') + 4
  local lh = U.texth() + 2
  H.lw, H.lh = lw, lh
  for _, t in ipairs(H.targets) do
    if t.label and (H.typed == '' or t.label:sub(1, #H.typed) == H.typed) then
      local x, y = t.lx or t.x, t.ly or t.y
      local bg = t.picked and U.GREEN or U.AMBER          -- 11 окт: отмеченная (Shift+F) — зелёная, с рамкой цели
      if t.picked then U.set(U.GREEN); gfx.rect(t.x, t.y, t.w, t.h, 0) end
      U.set(bg); gfx.rect(x, y, lw, lh, 1)
      U.set(U.BG); gfx.rect(x, y, lw, lh, 0)
      U.text(x + 2, y + 1 - (U.texth() > 0 and 0 or 0), t.label, U.BG, bg)
    end
  end
end

return H
