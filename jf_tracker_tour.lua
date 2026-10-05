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
  { mod = 'tracker', title = 'Move',
    text = 'h j k l move the cursor, gg / G - start / end, { } - bars. Try h j k l now.',
    check = function(e, b) return e.fi ~= b.fi or e.row ~= b.row end },
  { mod = 'tracker', title = 'Write notes',
    text = 'i - INSERT, m - the keyboard (as in Ableton): the top row q 2 w 3 e ... writes notes, z / x - octave. Press i, m, play a few keys, then Esc.',
    check = function(e, b, s) if e.mode == 'insert' then s.seen = true end; return s.seen and e.mode == 'normal' end },
  { mod = 'inst', title = 'Pick a sound',
    text = 'The lib: every sample of the project. Tab to it and j / k, or , . in INSERT. Pick another sound.',
    check = function(e, b) return e.inst ~= b.inst end },
  { mod = 'top', title = 'Slice a break',
    text = 'The item tab shows the selected sample: s opens the slice menu - s8 = eight slices, st = transients; in INSERT every key of the keyboard is a slice: q = slice 1 (C-4), 2 = slice 2, w = 3 ... Open the item tab (F2).',
    check = function(e) return e.toptab == 'sample' end },
  { mod = 'tracker', title = 'Edit like text',
    text = 'x deletes, dw / d3j / dG delete with a motion, yy p copy, u undo, . repeats. Make any edit.',
    check = function(e, b) return e.change ~= b.change end },
  { mod = 'tracker', title = 'Select',
    text = 'v selects a block, V whole rows; then d y M, or :interp vol to ramp the volumes. Press v.',
    check = function(e) return e.mode == 'visual' or e.mode == 'vline' end },
  { mod = 'tracker', title = 'Commands',
    text = ': opens the command line - :arp up 2, :legato, :macro, :pt, :big; Tab completes. Press :',
    check = function(e) return e.mode == 'cmd' end },
  { mod = 'tracker', title = 'Leader menu',
    text = '\\ opens the menu of everything: \\ o options as quick switches, \\ v view, \\ v a about. Press \\',
    check = function(e) return e.hydra end },
  { mod = 'ctrl', title = 'Play',
    text = 'Space - play / stop, F - follow the playhead; =START and =END bound the song. Press Space.',
    check = function(e) return e.playing end },
  { mod = 'dsp', title = 'Help',
    text = '? shows the keys of the focused module; Tab in the help searches all pages. Press ?',
    check = function(e) return e.khelp end },
}

function T.start() T.active, T.step, T.base, T.state, T.ok = true, 1, nil, {}, false end
function T.stop() T.active = false end
function T.go(d)
  T.step = math.max(1, math.min(#T.STEPS, T.step + d))
  T.base, T.state, T.ok = nil, {}, false
end

-- кадр: проверка действия; засчитанный шаг через 0.8 с переходит дальше
function T.tick(env, now)
  if not T.active then return end
  local st = T.STEPS[T.step]
  if not T.base then T.base = env end
  if not T.ok and st.check(env, T.base, T.state) then T.ok, T.ok_t = true, now end
  if T.ok and now - T.ok_t > 0.8 then
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
  return T.hover
end

-- всплывашка шага на его модуле (rects — D.module_rects); перенос по словам
function T.draw_bubble(U, L, rects, W, H, fit)
  if not T.active then return end
  local st = T.STEPS[T.step]
  local r = rects[st.mod] or rects.tracker
  if not r then return end
  local bw = math.min(math.max(L.cw * 30, math.floor(r[3] * 0.6)), W - 2 * L.pad)
  local lines, cur = {}, ''
  for word in st.text:gmatch('%S+') do
    local try = cur == '' and word or (cur .. ' ' .. word)
    if U.measure(try) > bw - 2 * L.pad and cur ~= '' then lines[#lines + 1] = cur; cur = word else cur = try end
  end
  if cur ~= '' then lines[#lines + 1] = cur end
  local bh = (#lines + 1) * L.rh + 2 * L.pad
  local bx = math.max(L.pad, math.min(W - bw - L.pad, r[1] + math.floor((r[3] - bw) / 2)))
  local by = math.max(2, math.min(H - bh - 2, r[2] + math.floor((r[4] - bh) / 2)))
  U.set(U.PANEL); gfx.rect(bx, by, bw, bh, 1)
  U.set(T.ok and U.GREEN or U.AMBER); gfx.rect(bx, by, bw, bh, 0); gfx.rect(bx + 1, by + 1, bw - 2, bh - 2, 0)
  U.text(bx + L.pad, by + L.pad, fit(('%d. %s%s'):format(T.step, st.title, T.ok and '  - ok' or ''), bw - 2 * L.pad), T.ok and U.GREEN or U.AMBER)
  for i, l in ipairs(lines) do U.text(bx + L.pad, by + L.pad + i * L.rh, l, U.TEXT) end
end

return T
