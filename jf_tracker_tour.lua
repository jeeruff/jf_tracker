-- jf_tracker_tour.lua — интерактивный тур (4 окт): ячейка tutorial главного модуля.
--
-- Шаг = модуль, о котором он рассказывает (всплывашка рисуется на нём),
-- текст и проверка действия: шаг засчитан, когда пользователь сделал то, что
-- предложено (подвигал hjkl, вошёл в INSERT, выбрал звук …). Стрелки назад /
-- вперёд и выход — в активной зоне главного модуля (T.draw_zone). Позже сюда
-- же: больше шагов, описание грида monome.
-- env — снимок состояния за кадр: { fi, row, mode, inst, toptab, hydra,
-- playing, khelp, change, focus }; base — env в начале шага.

local T = { active = false, step = 1, ok = false, ok_t = 0, hover = nil }

T.STEPS = {
  -- 2 ноя: у шага — короткое объяснение (text) и шаги «нажмите …» (todo), звёздочками, как в справке
  -- 2 ноя: тур идёт в новой пустой вкладке (main открывает её, если в текущей есть треки или файл) — первый трек tt
  { mod = 'tracker', focus = 'tracker', title = 'A clean project',
    ticks = { function() return true end, function(e, b) return (e.ntr or 0) > (b.ntr or 0) end },
    text = 'The tour works in a new empty project tab, so your own project stays as it was - its tab is still open in REAPER. An empty project has no tracks yet.',
    todo = { 'A new empty tab is open.', 'Press t t - a new track appears; the tour puts a break (amen_8bit) into its lib.', 'Once: type :autofloat if REAPER still opens a window for every new effect - that window takes the keyboard away from the tracker.' },   -- 5 ноя
    give = 'amen',
    check = function(e, b) return (e.ntr or 0) > (b.ntr or 0) end },
  -- 5 окт: сначала философия (почему jf), потом hjkl, потом f — куда угодно
  { mod = 'tracker', focus = 'tracker', title = 'Why jf',
    ticks = { function() return true end, function(e, b) return e.row ~= b.row end },
    text = 'Your index fingers rest on f and j - the two keys with bumps. That is the name: jf = hands on the home row. Every module answers to letters, the mouse is optional.',
    todo = { 'Put your fingers on f and j.', 'Press j - the cursor goes one row down.' },
    check = function(e, b) return e.row ~= b.row end },
  { mod = 'tracker', focus = 'tracker', title = 'Move',
    ticks = { function(e, b, s) if e.fi ~= b.fi then s.moved = e.fi end; return s.moved ~= nil end, function(e, b, s) return s.moved and e.fi ~= s.moved end },
    text = 'h j k l move the cursor: left, down, up, right. gg - the start, G - the end, { } - a bar back / on.',
    todo = { 'Press l a few times - the cursor walks right across the columns.', 'Press h to come back.' },
    check = function(e, b) return e.fi ~= b.fi end },
  { mod = 'tracker', focus = 'tracker', title = 'Jump anywhere',
    ticks = { function(e) return e.hints end, function(e, b) return e.hj ~= b.hj end },
    text = 'f puts two-letter labels on everything on screen - any module, button or bar line. Type the two letters of a label and you are there.',
    todo = { 'Press f - yellow labels appear.', 'Type the two letters of any label (for example a a).' },
    check = function(e, b) return e.hj ~= b.hj end },
  -- 2 ноя: панели и каналы — сразу после f
  { mod = 'tracker', focus = 'tracker', title = 'Panes and tracks', roam = true,
    -- 2 ноя: сначала второй трек (с одним Opt+H / L некуда идти); tt ставит курсор на новый — ход считается от него
    ticks = { function(e, b, s) if (e.ntr or 0) >= 2 then s.tk1 = e.tk; return true end end, function(e, b, s) return e.tk ~= s.tk1 end,
      function(e, b, s) s.f0 = s.f0 or e.focus; return e.focus ~= s.f0 end, function(e, b, s) return e.focus == 'tracker' end },
    text = 'Opt+H / Opt+L go to the previous / next track (channel). Cmd+h j k l move the focus to the pane on the left, below, above, on the right - the framed pane gets the keys.',
    todo = { 'Press t t once more - a second track (skip it if there are two).', 'Press Opt+H or Opt+L - the cursor goes to the other track.', 'Press Cmd+l (or Cmd+j) - the focus goes to another pane.', 'Press Cmd+h (or Cmd+k) to come back to the tracker.' },
    check = function(e, b) return e.tk ~= b.tk end },
  -- 1 ноя: режимы — отдельным шагом, до записи нот
  { mod = 'tracker', focus = 'tracker', title = 'Two modes: NORMAL and INSERT',
    ticks = { function(e) return e.mode == 'insert' end, function(e, b, s) return s.t1 and e.mode == 'normal' end, function(e, b, s) return s.t2 end },
    text = 'jf_tracker works in modes, like Vim. NORMAL (where you start): keys move and edit - j moves, x deletes. INSERT: keys write notes. The big word at the bottom left says which mode you are in.',
    todo = { 'Press i - the word says INSERT, the cursor turns red.', 'Press Esc - back to NORMAL.', '(Esc also enters INSERT - a habit kept from Renoise; with the keyboard on, i is a note, so then use Esc.)' },
    check = function(e, b, s) if e.mode == 'insert' then s.seen = true end; return s.seen and e.mode == 'normal' end },
  { mod = 'tracker', focus = 'tracker', title = 'Write notes',
    ticks = { function(e) return e.mode == 'insert' end, function(e, b) return e.mode == 'insert' and e.change ~= b.change end, function(e, b, s) return s.t2 and e.mode == 'normal' end },
    text = 'In INSERT the keyboard writes notes. Layout frow: 1 f1 2 f2 3 ... are the notes, [ ] the octave. Layout qwerty: q 2 w 3 e ..., z / x the octave. m turns the note keyboard off and on.',
    todo = { 'Press i to enter INSERT.', 'Press a few note keys - notes appear and the cursor moves on.', 'Press Esc to leave INSERT.' },
    check = function(e, b, s) if e.mode == 'insert' and e.change ~= b.change then s.seen = true end; return s.seen and e.mode == 'normal' end },
  { mod = 'inst', focus = 'inst', title = 'Pick a sound',
    ticks = { function(e, b) return e.inst ~= b.inst end },
    text = 'The lib on the right holds every sound of the project. The note keys write the sound picked here. From the tracker Opt+J / Opt+K pick the previous / next sound.',
    todo = { 'Press j or k - another sound is picked.' },
    check = function(e, b) return e.inst ~= b.inst end },
  -- 2 ноя: вкладка item уже открыта (тур сам ставит фокус) — шаг про саму нарезку; Ctrl+W i — без g
  { mod = 'top', focus = 'top', title = 'Slice a break',
    ticks = { function(e, b) return e.change ~= b.change end },
    text = 'The item tab shows the picked sample - here the amen break. Ctrl+W i brings the focus here from anywhere. s opens the slice menu: s8 - eight equal slices, st - at the transients. In INSERT the note keys then write the slices: 1 = slice 1, f1 = slice 2, 2 = slice 3 ... Ctrl+Shift+1 writes the whole sample.',
    todo = { 'Press s, then 8 - the break gets eight slices.' },
    check = function(e, b) return e.change ~= b.change end },
  { mod = 'tracker', focus = 'tracker', title = 'Edit like text',
    ticks = { function(e, b) return e.change ~= b.change end, function(e, b, s) s.c1 = s.c1 or e.change; return e.change ~= s.c1 end },
    text = 'Edits work like in a text editor. x deletes, dw / d3j delete with a motion, yy copies the row, p pastes, u undoes, . repeats the last edit.',
    todo = { 'Put the cursor on a note and press x - it is gone.', 'Press u - it is back.' },
    check = function(e, b) return e.change ~= b.change end },
  { mod = 'tracker', focus = 'tracker', title = 'Select',
    ticks = { function(e) return e.mode == 'visual' or e.mode == 'vline' end, function(e, b, s) return s.t1 and e.row ~= b.row end, function(e, b, s) return s.t2 and e.mode == 'normal' end },
    text = 'v starts a block selection, V selects whole rows. Then d deletes it, y copies it, :interp vol ramps the volumes in it.',
    todo = { 'Press v.', 'Press j a few times - the block grows.', 'Press Esc to drop it.' },
    check = function(e) return e.mode == 'visual' or e.mode == 'vline' end },
  { mod = 'tracker', focus = 'tracker', title = 'Commands',
    ticks = { function(e) return e.mode == 'cmd' end, function(e, b, s) return s.t1 end, function(e, b, s) return s.t1 and e.mode ~= 'cmd' end },
    text = ': opens the command line: :arp up 2, :legato, :macro, :pt, :big ... Tab completes a command name.',
    todo = { 'Press : (Shift+;).', 'Type ar and press Tab - it completes to arp.', 'Press Esc to close it.' },
    check = function(e) return e.mode == 'cmd' end },
  { mod = 'tracker', focus = 'tracker', title = 'Menus',
    ticks = { function(e) return e.hydra end, function(e, b, s) return s.t1 and not e.hydra end },
    text = '\\ opens the menu of what is under the cursor - the same as the right click. \\ twice opens the main menu of everything (v view, P project, o options). Every item has its letter.',
    todo = { 'Press \\ - the menu of the cursor cell opens.', 'Press Esc to close it.' },
    check = function(e) return e.hydra end },
  -- 27 окт: карта сэмплов — найти звук случайно, а не листая списки
  { mod = 'map', focus = 'tracker', title = 'Find a sound by chance', roam = true,
    ticks = { function(e) return e.focus == 'map' end, function(e, b, s) return true end },
    text = 'The map pane shows every sound file of the browser folder as dots in groups - kick, snare, loop ... A click on a dot plays it, r plays a random one, v changes the view, Shift+click on a group goes into it (Esc - back).',
    todo = { 'Press Ctrl+W, then g, then w - the map pane gets the focus.', 'Click a few dots, or press r.' },
    check = function(e) return e.focus == 'map' end },
  { mod = 'ctrl', focus = 'tracker', title = 'Play',
    ticks = { function(e) return e.playing end, function(e, b, s) return s.t1 and not e.playing end },
    text = 'Space plays and stops. It is all plain REAPER underneath: close the tracker window and the tracks, items and MIDI stay and play.',
    todo = { 'Press Space - it plays.', 'Press Space again to stop.' },
    check = function(e) return e.playing end },
  { mod = 'dsp', focus = 'tracker', title = 'Help',
    ticks = { function(e) return e.khelp_big end, function(e, b, s) return s.t1 and not e.khelp_big end },
    text = 'F1 opens the whole help: sections on the left, / finds anything. ? shows the keys of the module you are in, and the help pane follows the focus.',
    todo = { 'Press F1 - the help opens.', 'Press F1 again to close it.' },
    check = function(e) return e.khelp_big end },
}

function T.start() T.active, T.step, T.base, T.state, T.ok, T.finished, T.hold = true, 1, nil, {}, false, false, false; T.want_focus = T.STEPS[1].focus end
function T.stop() T.active = false end
function T.go(d)
  T.step = math.max(1, math.min(#T.STEPS, T.step + d))
  T.base, T.state, T.ok, T.hold = nil, {}, false, false
  T.want_focus = T.STEPS[T.step].focus        -- main переводит фокус (5 окт)
end

-- кадр: проверка действия; засчитанный шаг через 0.8 с переходит дальше
function T.tick(env, now)
  if not T.active then return end
  local st = T.STEPS[T.step]
  local fresh = not T.base
  T.focus_now = env.focus
  if not T.base then T.base = env end
  -- 2 ноя: пункты шага отмечаются по очереди (s.t1, s.t2 …): следующий — только после предыдущего
  local S = T.state
  if st.ticks then
    for k, f in ipairs(st.ticks) do
      if not S['t' .. k] then
        if (k == 1 or S['t' .. (k - 1)]) and f(env, T.base, S) then S['t' .. k] = true else break end
      end
    end
  end
  local all = st.ticks and S['t' .. #st.ticks]
  if all and st.give and not S.given then S.given = true; T.want_give = st.give end   -- 2 ноя: main кладёт звук в lib (шаг 1 — амен)
  if not T.ok and (all or (not st.ticks and st.check(env, T.base, S))) then T.ok, T.ok_t = true, now end
  -- 2 ноя: шаг, уже выполненный в первом кадре (назад на «Slice a break» — вкладка item уже открыта), не уходит сам вперёд
  if T.ok and fresh then T.hold = true end
  if T.ok and not T.hold and now - T.ok_t > 0.8 then
    if T.step < #T.STEPS then T.go(1) else T.ok = true; T.finished = true end
  end
end

-- активная зона главного модуля: шаг, заголовок, < > x; возвращает hover
function T.draw_zone(U, L, x, y, w, h, fit)
  local mx, my = gfx.mouse_x, gfx.mouse_y
  T.hover = nil
  if not T.active then return end
  local st = T.STEPS[T.step]
  U.text(x, y, fit(('tour %d/%d  %s'):format(T.step, #T.STEPS, st.title), w), U.AMBER)
  local by = y + L.rh + 2
  local bx = x
  for _, b in ipairs({ { '<', 'prev' }, { '>', 'next' }, { 'x', 'stop' } }) do
    local bw = U.measure(b[1]) + 2 * L.pad
    local hot = mx >= bx and mx < bx + bw and my >= by and my < by + L.rh
    U.set(hot and U.tint(U.AMBER, 0.3) or U.BG); gfx.rect(bx, by, bw, L.rh, 1)
    U.set(hot and U.AMBER or U.LINE); gfx.rect(bx, by, bw, L.rh, 0)
    U.text(bx + L.pad, by, b[1], hot and U.AMBER or U.TEXT)
    if hot then T.hover = b[2] end
    bx = bx + bw + 4
  end
  if T.ok then U.text(bx + L.pad, by, fit(T.finished and 'done - well played' or 'ok', x + w - bx - L.pad), U.GREEN) end
  -- 2 ноя: главы тура списком (вместо быстрых опций): пройденные тусклее, текущая янтарём; щелчок — к главе
  local cy = by + L.rh + 4
  T.chap_hot = nil
  for i, s in ipairs(T.STEPS) do
    if cy + L.rh > y + h then break end
    local hot = mx >= x and mx < x + w and my >= cy and my < cy + L.rh
    if i == T.step then U.set(U.tint(U.AMBER, 0.2)); gfx.rect(x, cy, w, L.rh, 1) elseif hot then U.set(U.tint(U.TEXT, 0.08)); gfx.rect(x, cy, w, L.rh, 1) end
    U.text(x + L.pad, cy, fit(('%2d. %s'):format(i, s.title), w - 2 * L.pad), i == T.step and U.AMBER or (i < T.step and U.GREY or (hot and U.TEXT or U.TEXT)))
    if hot then T.hover = 'chap:' .. i end
    cy = cy + L.rh
  end
  return T.hover
end

-- всплывашка шага на его модуле (rects — D.module_rects); перенос по словам
function T.draw_bubble(U, L, rects, W, H, fit)
  if not T.active then return end
  local st = T.STEPS[T.step]
  local r = rects[st.mod] or rects.tracker
  if not r then return end
  local bw = math.min(math.max(L.cw * 30, math.floor(r[3] * 0.6)), W - 2 * L.pad)
  -- 2 ноя: объяснение, потом шаги звёздочками (* Press i ...), перенос с отступом под звёздочкой
  local lines = {}
  local function wrap(txt, first, rest, col)
    local cur, pre = '', first
    for word in txt:gmatch('%S+') do
      local try = cur == '' and word or (cur .. ' ' .. word)
      if U.measure(pre .. try) > bw - 2 * L.pad and cur ~= '' then lines[#lines + 1] = { pre .. cur, col }; cur, pre = word, rest else cur = try end
    end
    if cur ~= '' then lines[#lines + 1] = { pre .. cur, col } end
  end
  wrap(st.text, '', '', U.TEXT)
  -- 2 ноя: фокус ушёл в другой модуль (щелчок мимо) — клавиши шага туда не дойдут: сказать, как вернуться
  if not T.ok and not st.roam and st.focus and T.focus_now and T.focus_now ~= st.focus then
    lines[#lines + 1] = { '', U.TEXT }
    local NM = { inst = 'the lib', top = 'the top panel', fxb = 'the fx list', browser = 'the browser', tracker = 'the tracker', map = 'the map' }
    wrap(('The keys go to %s now. Click %s, or press Cmd+h j k l to get there.'):format(NM[T.focus_now] or T.focus_now, NM[st.focus] or st.focus), '! ', '  ', U.RED or U.AMBER)
  end
  if st.todo then
    lines[#lines + 1] = { '', U.TEXT }
    for k, d in ipairs(st.todo) do
      local done = T.ok or T.state['t' .. k]
      wrap(d, done and '+ ' or '* ', '  ', done and U.GREY or (d:sub(1, 1) == '(' and U.GREY or U.TEXT))
    end
  end
  local bh = (#lines + 1) * L.rh + 2 * L.pad
  local bx = math.max(L.pad, math.min(W - bw - L.pad, r[1] + math.floor((r[3] - bw) / 2)))
  local by = math.max(2, math.min(H - bh - 2, r[2] + math.floor((r[4] - bh) / 2)))
  U.set(U.PANEL); gfx.rect(bx, by, bw, bh, 1)
  U.set(T.ok and U.GREEN or U.AMBER); gfx.rect(bx, by, bw, bh, 0); gfx.rect(bx + 1, by + 1, bw - 2, bh - 2, 0)
  U.text(bx + L.pad, by + L.pad, fit(('%d. %s%s'):format(T.step, st.title, T.ok and '  - ok' or ''), bw - 2 * L.pad), T.ok and U.GREEN or U.AMBER)
  for i, l in ipairs(lines) do
    local yy = by + L.pad + i * L.rh
    local mk = l[1]:sub(1, 2)
    if mk == '* ' or mk == '+ ' then U.text(bx + L.pad, yy, mk == '+ ' and '+' or '*', mk == '+ ' and U.GREEN or U.AMBER); U.text(bx + L.pad + U.measure('* '), yy, l[1]:sub(3), l[2])   -- 2 ноя: сделанный пункт — зелёный +
    else U.text(bx + L.pad, yy, l[1], l[2]) end
  end
end

return T
