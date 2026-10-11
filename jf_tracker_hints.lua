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
function H.reset() if not H.active then H.targets = {} end end

H.LEVEL = { ptab = 1, tab = 1, viewbtn = 1, header = 1, ctrl = 1, btn = 1, mxbtn = 1, dsptarget = 1, dsprouting = 1,
            mx = 3, bar = 3, trsmark = 3, sess = 3, mxname = 3, mxdur = 3, fxbrow = 3 }
function H.add(kind, x, y, w, h, data)
  if H.active then return end        -- во время набора список заморожен
  H.targets[#H.targets + 1] = { kind = kind, x = x, y = y, w = w, h = h, data = data }
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
  -- 9 окт: меток 676, целей бывает больше (клетки матрицы, строки) —
  -- подписи панелей и вкладок, кнопки получают буквы первыми, массовые
  -- цели — последними (порядок внутри уровня — как рисовались)
  local order = {}
  for i, t in ipairs(H.targets) do order[i] = { t = t, i = i, lv = H.LEVEL[t.kind] or 2 } end
  table.sort(order, function(a, b) if a.lv ~= b.lv then return a.lv < b.lv end return a.i < b.i end)
  for _, o in ipairs(order) do
    local t = o.t
    t.label = nil
    local free = k < max
    if free then
      for _, p in ipairs(placed) do
        if t.x < p.x + lw + 1 and p.x < t.x + lw + 1 and t.y < p.y + lh and p.y < t.y + lh then free = false; break end
      end
    end
    if free then
      local a = math.floor(k / n) + 1
      local b = k % n + 1
      t.label = ALPHA:sub(a, a) .. ALPHA:sub(b, b)
      placed[#placed + 1] = t
      k = k + 1
    end
  end
  do local f = reaper and io.open('/private/tmp/claude-501/-Users-jeeruff/4c37a009-86dd-4ef8-9af2-720655b33b41/scratchpad/hints.log', 'w') --DBGH
    if f then f:write(('n=%d lw=%d lh=%d\n'):format(#H.targets, lw, lh)); for _, o in ipairs(order) do local t = o.t; f:write(('%s %s %d %d %d %d\n'):format(t.label or '--', t.kind, t.x, t.y, t.w, t.h)) end; f:close() end end --DBGH
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
  if not ALPHA:find(ch, 1, true) then return 'pending' end
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
      local x, y = t.x, t.y
      local bg = t.picked and U.GREEN or U.AMBER          -- 11 окт: отмеченная (Shift+F) — зелёная, с рамкой цели
      if t.picked then U.set(U.GREEN); gfx.rect(t.x, t.y, t.w, t.h, 0) end
      U.set(bg); gfx.rect(x, y, lw, lh, 1)
      U.set(U.BG); gfx.rect(x, y, lw, lh, 0)
      U.text(x + 2, y + 1 - (U.texth() > 0 and 0 or 0), t.label, U.BG, bg)
    end
  end
end

return H
