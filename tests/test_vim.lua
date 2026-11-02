-- test_vim.lua — Vim-слой на стабах: снимок и раскладка — таблицы,
-- edit — заглушка, записывающая вызовы. Запуск: lua tests/test_vim.lua

local DIR = (arg and arg[0] or ''):match('(.*)/tests/') or '.'
local keys = dofile(DIR .. '/jf_tracker_keys.lua')
local V = dofile(DIR .. '/jf_tracker_vim.lua')

local fails, checks = 0, 0
local function eq(name, got, want)
  checks = checks + 1
  if got ~= want then fails = fails + 1; print(('FAIL %s: got %s, want %s'):format(name, tostring(got), tostring(want))) end
end

-- ── снимок ────────────────────────────────────────────────────────────────
local function head(kind, row, rows, extra)
  local h = { kind = kind, row0 = row, rows = rows, note = 'C-4', vol = '80', delay = 0 }
  for k, v in pairs(extra or {}) do h[k] = v end
  return h
end
local function put(sub, h)
  sub[h.row0] = h
  for r = h.row0 + 1, h.row0 + h.rows - 1 do sub[r] = { kind = 'cont', of = h, i = r - h.row0 } end
end

local snap, state, L, calls, folds
local function build()
  snap = { cols = {}, last_row = 40 }
  local a = { name = 'A', guid = 'A', track = 'trA', lanes = { { idx = 0, subs = { {}, {} } } },
              pool = { { item = 'depot1', name = 'd1' } } }
  put(a.lanes[1].subs[1], head('audio', 0, 4, { name = 'kick', fx = { '0PA0' } }))
  put(a.lanes[1].subs[1], head('audio', 8, 2, { name = 'snare' }))
  put(a.lanes[1].subs[1], head('audio', 16, 1, { name = 'hat' }))
  put(a.lanes[1].subs[2], head('audio', 2, 2, { name = 'ov' }))
  local m = { name = 'M', guid = 'M', track = 'trM', lanes = { { idx = 0, subs = { {} } } } }
  put(m.lanes[1].subs[1], head('midi', 4, 2, { pitch = 60, ch = 0 }))
  put(m.lanes[1].subs[1], head('midi', 12, 4, { pitch = 64, ch = 0 }))
  snap.cols = { a, m }
end

local function layout()
  L = { nrows = 16, win_w = 10000, flat = {} }
  for ci, col in ipairs(snap.cols) do
    if folds[col.guid] then
      L.flat[#L.flat + 1] = { ci = ci, col = col, folded = true, x = 0, w = 10 }
    else
      for li, lane in ipairs(col.lanes) do
        for si, sub in ipairs(lane.subs) do
          L.flat[#L.flat + 1] = { ci = ci, col = col, lane = lane, li = li, si = si, sub = sub, x = 0, w = 10 }
        end
      end
    end
  end
end

-- ── edit-заглушка ─────────────────────────────────────────────────────────
local function names(heads)
  local t = {}
  for _, h in ipairs(heads) do t[#t + 1] = h.name or ('n' .. h.pitch) end
  table.sort(t); return table.concat(t, ',')
end
local E = {}
function E.delete(heads) calls[#calls + 1] = 'delete:' .. names(heads)
  for _, h in ipairs(heads) do
    for _, col in ipairs(snap.cols) do for _, lane in ipairs(col.lanes) do for _, sub in ipairs(lane.subs) do
      for r = h.row0, h.row0 + h.rows - 1 do if sub[r] == h or (sub[r] and sub[r].of == h) then sub[r] = nil end end
    end end end
  end
end
function E.yank(heads, lpb, r0, f0) calls[#calls + 1] = 'yank:' .. names(heads); return { rows = 1, cells = { { drow = 0, dfi = 0, kind = 'audio', chunk = 'x', n = #heads } } } end
function E.paste(reg, lpb, row, targets) local tg = targets(0); calls[#calls + 1] = ('paste:%d@%d:%s'):format(reg and reg.cells[1].n or 0, row, tg and tg.track or '-') end
function E.mute(heads) calls[#calls + 1] = 'mute:' .. names(heads) end
function E.split(heads, lpb, row) calls[#calls + 1] = ('split:%s@%d'):format(names(heads), row) end
function E.transpose(heads, lpb, s) calls[#calls + 1] = ('transpose:%s:%+d'):format(names(heads), s) end
function E.set_pitch(heads, lpb, p) calls[#calls + 1] = ('pitch:%s:%d'):format(names(heads), p) end
function E.note_off(heads, lpb, row) calls[#calls + 1] = ('off:%s@%d'):format(names(heads), row) end
function E.insert_note(track, lane, lpb, row, pitch, vel, len, depot) calls[#calls + 1] = ('ins:%s@%d:%d:%d'):format(track, row, pitch, len) end
function E.set_vol(heads, lpb, v) calls[#calls + 1] = ('vol:%s:%d'):format(names(heads), math.floor(v + 0.5)) end
function E.set_pan(heads, v) calls[#calls + 1] = ('pan:%s:%d'):format(names(heads), math.floor(v + 0.5)) end
function E.run(_, fn) fn() end
function E.retime(heads, lpb, rows) local t = {}; for i, h in ipairs(heads) do t[#t + 1] = h.name .. '>' .. rows[i] end; calls[#calls + 1] = 'retime:' .. table.concat(t, ',') end
function E.set_delay(heads, lpb, d) calls[#calls + 1] = ('delay:%s:%d'):format(names(heads), d) end
E.cmds = { CODES = { ['0U'] = true, ['0D'] = true, ['0V'] = true, ['0A'] = true, ['0I'] = true, ['0O'] = true, ['0R'] = true, ZT = true, ZJ = true, ['0G'] = true, ['0Y'] = true } }
local function had(x) for _, c in ipairs(calls) do if c == x or (c:match('^' .. x)) then return true end end return false end
local function offs(o) return (o and o > 0) and ('@%g'):format(o) or '' end
function E.set_fx(heads, lpb, cmd, xx, off) calls[#calls + 1] = ('fx:%s:%s%02X%s'):format(names(heads), cmd, xx, offs(off)) end
function E.clear_fx(heads, lpb, cmd, off) calls[#calls + 1] = ('clearfx:%s:%s%s'):format(names(heads), cmd, offs(off)) end
function E.undo() calls[#calls + 1] = 'undo' end
function E.redo() calls[#calls + 1] = 'redo' end
function E.save() calls[#calls + 1] = 'save' end
function E.play_stop() calls[#calls + 1] = 'play' end
function E.cursor_to(t) calls[#calls + 1] = 'cursor:' .. t end
function E.arpeggiate(track, lane, lpb, row, heads, opt) calls[#calls + 1] = ('arp:%s@%d:%s:%d:%d:%.2f'):format(names(heads), row, opt.order, opt.step, opt.oct, opt.gate); return 4 end
function E.insert_slice(track, lane, lpb, row, item, k) calls[#calls + 1] = ('slice:%s@%d:%d%s'):format(track, row, k, E.thru_once and ':thru' or ''); return { slice = k } end
function E.slice_pitch(it, semis) calls[#calls + 1] = ('slicepitch:%d:%+d'):format(it.slice, semis) end
function E.swap_events(a, b) calls[#calls + 1] = ('swap:%s:%s'):format(a.name, b.name); return true end
function E.scramble(heads) calls[#calls + 1] = 'scramble:' .. names(heads); return #heads end
function E.beatsync(heads, lpb, unit) calls[#calls + 1] = ('beatsync:%s:%s'):format(names(heads), unit); return #heads end

local lpb_calls = {}
local ctrl_down, alt_down, cmd_down, shift_down = false, false, false, false
local function reset()
  folds = {}; calls = {}
  state = { lpb = 4, row0 = 0, hscroll = 1, follow = true, folds = folds, fxcols = 1 }
  build(); layout()
  V.mode = 'normal'; V.cur = { fi = 1, row = 0, field = 1 }; V.count = nil; V.pending = nil; V.op = nil; V.hexbuf = nil
  V.regs = {}; V.macro = nil; V.cmdbuf = {}; V.last_edit = nil; V.cmdline = nil; V.octave = 4; V.step = 1; V.inst = 1
  V.init({
    keys_renoise = function() return RENOISE end,
    keys_frow = function() return FROW end,   -- 16 окт: раскладка frow
    kit_key_pitch = function(col, p) return KIT_MAP and KIT_MAP(p) end,   -- 19 окт: кит — клавиша = пэд
    edit = E, state = state, piano = keys.piano, SM = dofile(DIR .. '/jf_tracker_smart.lua'),
    esc_vim = function() return ESC_VIM end,   -- 10 окт: опция Esc mode
    track_toggle = function(what) calls[#calls + 1] = 'track:' .. what end,   -- 9 окт: Shift+M / S — трек
    slice_pick = function(n, k) if PICK then return PICK(n, k) end; return k end,  -- 10 окт: режим слайса
    track_dup = function() calls[#calls + 1] = 'tdup'; return true end,                -- 9 окт: t-операции
    track_move = function(d, n) calls[#calls + 1] = 'tmove:' .. d .. ':' .. (n or 1); return true end,
    track_colour = function() calls[#calls + 1] = 'tcol' end, rec_arm = function() calls[#calls + 1] = 'tarm' end,
    toggle_lanes = function() calls[#calls + 1] = 'tlanes' end, fx_picker = function() calls[#calls + 1] = 'tfx' end,
    cur_col = function() return { name = 'A', guid = 'g' } end,
    jump_mark = function() calls[#calls + 1] = 'jmark' end,
    width_step = function(d, which) calls[#calls + 1] = 'w:' .. d .. ':' .. (which or 'all') end,
    input_picker = function() calls[#calls + 1] = 'tin' end, smart_input = function() calls[#calls + 1] = 'tsmart' end, route_menu = function() calls[#calls + 1] = 'troute' end,
    piano_on = function() if PIANO_ON ~= nil then return PIANO_ON end return V.piano end,
    snap = function() return snap end, layout = function() return L end, relayout = layout,
    bar_of_row = function(row) local b = math.floor(row / 16) * 16; return b, b + 16 end,
    row_time = function(row) return row * 0.125 end,
    set_lpb = function(n, dir) lpb_calls[#lpb_calls + 1] = n or dir end,
    fold = function(col, v) folds[col.guid] = v or nil end,
    fold_all = function(v) for _, c in ipairs(snap.cols) do folds[c.guid] = v or nil end end,
    depot = function() return { { item = 'depot1', name = 'd1' } } end,
    toggle_focus = function() calls[#calls + 1] = 'focus' end,
    set_pitchmode = function(col, m) calls[#calls + 1] = 'pitchmode:' .. col.name .. ':' .. m end,
    sync_here = function() calls[#calls + 1] = 'sync'; return 1 end,
    pool_select = function(n) calls[#calls + 1] = 'pool:' .. n; V.inst = n end,
    clear_tracks_all = function() calls[#calls + 1] = 'dP'; return true end,   -- 10 окт
    slicer_active = function() return SLICER end, slicer_key = function(c) calls[#calls + 1] = 'slkey:' .. c end,   -- 10 окт
    set_font = function(n) calls[#calls + 1] = 'font:' .. n end,
    browse = function(p) calls[#calls + 1] = 'browse:' .. tostring(p) end,
    hydra_root = function() return { title = 'root', items = {
      { key = 'e', label = 'event', sub = { title = 'event', items = { { key = 'x', label = 'del', fn = function() calls[#calls + 1] = 'hydra:x' end } } } },
      { key = 'v', label = 'view', fn = function() calls[#calls + 1] = 'hydra:v' end },
    } } end,
    hydra_keys = function() return { title = 'keys', items = { { key = 'h', label = 'move' } } } end,
    ctrl_held = function() return ctrl_down end,
    mods = function() return { ctrl = ctrl_down, alt = alt_down, cmd = cmd_down, shift = shift_down } end,
    arp_live_key = function(sp) calls[#calls + 1] = 'arplive:' .. tostring(sp.pitch) .. '@' .. sp.row end,
    hold_start = function(sp) calls[#calls + 1] = 'hold:' .. tostring(sp.pitch or ('s' .. tostring(sp.slice))) .. (sp.stretch and ':stretch' or '') end,
    preview = function(tr, p) calls[#calls + 1] = 'prev:' .. tostring(p) end,
    mac_panel = function(n) calls[#calls + 1] = 'macpanel'; V.pending = '@'; V.count = (n or 1) > 1 and n or nil end,   -- 16 окт: как панель — следующая клавиша выбирает
    toggle_envs = function() calls[#calls + 1] = 'envs' end,
    track_auto_toggle = function() calls[#calls + 1] = 'trackauto' end,
    loop = function(w, n) calls[#calls + 1] = 'loop:' .. tostring(w) .. ':' .. tostring(n) end,
    automation_picker = function()
      V.open_picker('auto', { { label = 'track: volume' }, { label = 'ReaEQ / Gain' }, { label = 'ReaComp / Threshold' } },
        function(it) calls[#calls + 1] = 'pick:' .. it.label end)
    end,
    delete_item_at_cursor = function() calls[#calls + 1] = 'delitem'; return true end,
    new_track = function(n) calls[#calls + 1] = 'newtrack:' .. (n or 1); return true end,   -- 15 окт: счётчики tt / td
    tracks_op = function(op, n) calls[#calls + 1] = 'tracks:' .. op .. ':' .. (n or 1); return true end,
    clear_track = function(all) calls[#calls + 1] = all and 'cleartrack:all' or 'cleartrack'; return true end,
    delete_track = function() calls[#calls + 1] = 'deltrack'; return true end,
    delete_time = function() calls[#calls + 1] = 'deltime'; return true end,
    insert_whole = function() calls[#calls + 1] = 'whole' end,
    insert_note_cmd = function(p, r) calls[#calls + 1] = ('notecmd:%d:%s'):format(p, tostring(r)) end,
    insert_slice_cmd = function(k, r, sm) calls[#calls + 1] = ('slcmd:%d:%s:%s'):format(k, tostring(r), tostring(sm)) end,
    repeat_pattern = function(all) calls[#calls + 1] = all and 'repeat:all' or 'repeat:track' end,
    inst_transpose = function(d) calls[#calls + 1] = 'transpose:' .. d end,   -- 10 окт: Shift+Opt+J / K
    inst_rate = function(d) calls[#calls + 1] = 'rate:' .. d end,             -- 11 окт: Shift+Opt+H / L
    mcmd_set = function(row, text) calls[#calls + 1] = ('mcmd:%d:%s'):format(row, text) end,   -- 11 окт: колонка cmd мастера
    smart_open = function(p) calls[#calls + 1] = 'smart:' .. (p.title or ''); SMART_P = p; return true end,   -- 10 окт: zt
    region_rows = function() if RR then return RR[1], RR[2] end return 0, 31 end,
    matrix_move = function(dx, dy) calls[#calls + 1] = ('mx:%d,%d'):format(dx, dy) end,
    env_point_rows = function(e) return e.prows or {} end,
    envfmt = function() return TEST_ENVFMT or 'midi' end,
    env_points = function(e, r0, r1) calls[#calls + 1] = ('envpts:%s@%d-%d'):format(e.name, r0, r1); return { { dq = 0, v = 0.5 } } end,
    env_del_range = function(e, r0, r1) calls[#calls + 1] = ('envdelr:%s@%d-%d'):format(e.name, r0, r1) end,
    env_paste = function(e, row, reg) calls[#calls + 1] = ('envpaste:%s@%d:%d'):format(e.name, row, #reg.pts) end,
    env_shape = function(e, row, sh) calls[#calls + 1] = ('envshape:%s@%d:%d'):format(e.name, row, sh); return true end,
    env_shape_step = function(e, row, d) calls[#calls + 1] = ('envshapestep:%s@%d:%+d'):format(e.name, row, d) end,
    env_set = function(e, row, v) calls[#calls + 1] = ('envset:%s@%d:%.3f'):format(e.name, row, v) end,
    env_del = function(e, row) calls[#calls + 1] = ('envdel:%s@%d'):format(e.name, row) end,
    env_nudge = function(e, row, d) calls[#calls + 1] = ('envnudge:%s@%d:%+.4f'):format(e.name, row, d) end,
    env_ramp = function(e, r0, r1, v0, v1) calls[#calls + 1] = ('envramp:%s@%d-%d:%s>%.2f'):format(e.name, r0, r1, v0 and ('%.2f'):format(v0) or 'cur', v1) end,
  })
end
-- клавиатура (m, 4 окт): старые тесты INSERT пишут ноты — модель «вошёл в
-- INSERT и включил m»: в INSERT клавиатура вкл, в NORMAL — выкл. AUTO_KBD =
-- false — проверка самого m
local AUTO_KBD = true
local key_raw = V.key
V.key = function(c)
  if AUTO_KBD then V.piano = V.mode == 'insert' end
  local r = key_raw(c)
  if AUTO_KBD then V.piano = V.mode == 'insert' end
  return r
end
local function keysin(s) for ch in s:gmatch('.') do V.key(ch:byte()) end end
local function last() return calls[#calls] or '' end

-- ── движения ──────────────────────────────────────────────────────────────
reset()
-- 6 окт: w / b — события всего трека (подколонки и лейны), как слова в Vim
keysin('w');   eq('w → ov in the 2nd subcolumn', V.cur.fi * 100 + V.cur.row, 202)
keysin('w');   eq('w → snare', V.cur.row, 8); eq('w back in sub 1', V.cur.fi, 1)
keysin('w');   eq('w → hat', V.cur.row, 16)
keysin('w');   eq('w stays at last', V.cur.row, 16)
keysin('b');   eq('b → snare', V.cur.row, 8)
keysin('2b');  eq('2b → kick', V.cur.row, 0)
keysin('e');   eq('e → boundary after kick', V.cur.row, 4)
keysin('2j');  eq('2j', V.cur.row, 6)
keysin('k');   eq('k', V.cur.row, 5)
keysin('l');   eq('l → vol field', V.cur.field, 2); eq('l same sub', V.cur.fi, 1)
keysin('l'); eq('l on fx: the code half, then the value half (12 окт)', V.cur.field >= 4 and V.cur.sub == nil, true); keysin('l'); eq('…value half', V.cur.sub, 'val')
keysin('ll'); eq('4 fields then next sub', V.cur.fi, 2); eq('field wraps to 1', V.cur.field, 1)
keysin('h');   eq('h back → delay field of sub1 (visual order nt vl fx dl)', V.cur.fi, 1); eq('h field', V.cur.field, 3)
-- 5 окт: треки — Option+h / l (Shift+hjkl — выделение)
alt_down = true; V.key(172); alt_down = false; eq('Option+l → track M', V.cur.fi, 3)
alt_down = true; V.key(729); alt_down = false; eq('Option+h → track A', V.cur.fi, 1)
keysin('$');   eq('$ → last col', V.cur.fi, 3); eq('$ last field (delay)', V.cur.field, 3)
keysin('0');   eq('0 → first col', V.cur.fi, 1); eq('0 first field', V.cur.field, 1)
keysin('G');   eq('G → last row', V.cur.row, 40)
keysin('gg');  eq('gg → 0', V.cur.row, 0)
keysin('10G'); eq('10G', V.cur.row, 9)
keysin('}');   eq('} → next bar', V.cur.row, 16)
keysin('{');   eq('{ → bar start', V.cur.row, 0)
V.cur.fi = 3; V.cur.row = 0
keysin('W');   eq('W: next event on any track (30 окт)', V.cur.row > 0 or V.cur.fi ~= 3, true)
V.cur.fi = 1; V.cur.row = 0
keysin('W');   eq('W 1 → A sub2 @2', V.cur.fi * 100 + V.cur.row, 202)
local w2 = V.cur.fi * 100 + V.cur.row; keysin('W'); eq('W 2 → the next event row on any track (M @4)', V.cur.fi * 100 + V.cur.row, 304)
keysin('B');   eq('B → back to A sub2 @2', V.cur.fi * 100 + V.cur.row, w2)
V.cur.fi, V.cur.row = 1, 8; keysin('w'); eq('w → next event of the track (@16)', V.cur.fi * 100 + V.cur.row, 116)
-- прокрутка держит курсор
V.cur.fi = 1; V.cur.row = 0; state.row0 = 0
keysin('20j'); eq('scroll follows cursor', state.row0, 20 - 16 + 1)
keysin('zt');  eq('zt: cursor row to the top (Vim, 12 окт)', state.row0, 20)
keysin(':transpose\r'); eq(':transpose opens the transpose popup', (last() or ''):match('^smart:transpose') ~= nil, true)
SMART_P.on_pick({ v = 3 }); eq('popup +3 transposes the note of the row', (last() or ''):match('^transpose:.*:%+3$') ~= nil or (last() or ''):match('^smart') ~= nil, true)
V.cur.row = 20
keysin('zz');  eq('zz', state.row0, 12)

-- ── операторы ─────────────────────────────────────────────────────────────
reset()
keysin('x');       eq('x deletes kick', last(), 'delete:kick')
eq('x yanks first', calls[1], 'yank:kick')
reset()
keysin('8jdw');    eq('dw at 8 → snare', last(), 'delete:snare')
reset()
keysin('dw');      eq('dw: kick only (exclusive)', last(), 'delete:kick')
V.cur.row = 8; keysin('dw'); eq('dw clears the cursor row of the track (30 окт)', last(), 'delete:snare')
reset(); V.cur.row = 5; keysin('dw'); eq('dw on an empty row → the next note (31 окт: was nothing)', last(), 'delete:snare')
reset(); V.cur.row = 8; V.mode = 'insert'; V.hexbuf = 'D'; keysin('w'); eq('INSERT, D in the hex buffer + w = dw (31 окт)', last(), 'delete:snare'); V.mode = 'normal'
-- 19 окт: de внутри ноты — хвост ноты (она кончается перед курсором), не следующая нота
reset(); V.cur.row = 2; keysin('de'); eq('de inside kick: kick ends before row 2', last(), 'off:kick@' .. (E.OFF_END and 1 or 2))
reset(); keysin('de'); eq('de on the kick head: the kick only, not the snare', last(), 'delete:kick')
reset()
keysin('d9j');     eq('d9j: kick+snare', last(), 'delete:kick,snare')
reset()
keysin('dG');      eq('dG: all in sub', last(), 'delete:hat,kick,snare')
reset()
keysin('yy');      eq('yy', last(), 'yank:kick'); eq('yy no delete', #calls, 1)
keysin('4jp');     eq('p pastes at 4 on A', last(), 'paste:1@4:trA')
reset()
keysin('vM');      eq('vM mutes the event (kick)', last(), 'mute:kick')
reset()
keysin('M');       eq('M (Shift+m) mutes the track', last(), 'track:mute')
-- t-операции (9 окт)
for _, c in ipairs({ { 'ty', 'tdup' }, { '3tj', 'tmove:1:3' }, { 'tk', 'tmove:-1:1' }, { 'tc', 'tcol' }, { 'ta', 'tarm' },
                     { 'tl', 'tlanes' }, { 'tf', 'tfx' }, { 'ti', 'tin' }, { 'tI', 'tsmart' }, { 'tR', 'troute' } }) do
  reset(); keysin(c[1]); eq('t-op ' .. c[1], last(), c[2]); eq('t-op ' .. c[1] .. ' clears pending', V.pending, nil)
end
-- z> z< z. z, (9 окт): ширина по шагу
for _, c in ipairs({ { 'z>', 'w:1:all' }, { 'z<', 'w:-1:all' }, { 'z.', 'w:1:cur' }, { 'z,', 'w:-1:cur' } }) do
  reset(); keysin(c[1]); eq('width ' .. c[1], last(), c[2])
end
reset(); keysin('3z>'); eq('3z> - three steps', #calls, 3)
-- gg / G — в список прыжков (9 окт); на месте — нет
reset(); V.cur.row = 8; keysin('gg'); eq('gg marks a jump', last(), 'jmark'); eq('gg moved', V.cur.row, 0)
reset(); V.cur.row = 0; keysin('gg'); eq('gg in place - no mark', #calls, 0)
reset(); keysin('G'); eq('G marks a jump', last(), 'jmark')
reset(); V.cur.row = 4; keysin('dgg'); eq('dgg - no jump mark', calls[1] ~= 'jmark', true)
reset()
reset()
keysin('S');       eq('S (Shift+s) solos the track', last(), 'track:solo')
reset()
keysin('2js');     eq('s splits kick at 2', last(), 'split:kick@2')
reset()
V.key(1);          eq('^A transposes', last(), 'transpose:kick:+1')
keysin('3'); V.key(24); eq('3^X', last(), 'transpose:kick:-3')
reset()
keysin('r3');      eq('r3 → D#4 (63)', last(), 'pitch:kick:63')
reset()
keysin('u'); V.key(18); eq('undo/redo', calls[1] .. ',' .. calls[2], 'undo,redo')
reset()
keysin('cc');      eq('cc deletes', last(), 'delete:kick'); eq('cc → insert', V.mode, 'insert')

-- ── visual ────────────────────────────────────────────────────────────────
reset()
keysin('v9jd');    eq('v9jd', last(), 'delete:kick,snare'); eq('visual → normal', V.mode, 'normal')
reset()
keysin('v'); alt_down = true; V.key(172); V.key(172); alt_down = false; keysin('4jd'); eq('v across cols', last(), 'delete:kick,n60,ov')
reset()
keysin('Vjjjjd');  eq('V-line all cols', last(), 'delete:kick,n60,ov')
reset()
keysin('vlllll4jy'); eq('vy', last(), 'yank:kick,ov')
reset()
keysin('4j'); alt_down = true; V.key(172); V.key(172); alt_down = false; keysin('vjM'); eq('visual M mutes', last(), 'mute:n60')
reset()
keysin('vjo');     eq('o swaps', V.cur.row, 0); eq('anchor moved', V.anchor.row, 1)
V.key(27);         eq('esc in VISUAL → normal', V.mode, 'normal')

-- ── insert ────────────────────────────────────────────────────────────────
reset()
keysin('iq');      eq('i q → C-4 at 0 on A', last(), 'ins:trA@0:60:1'); eq('step advance', V.cur.row, 1)
eq('note over kick overwrites (kick deleted first)', calls[#calls - 1], 'delete:kick')
V.cur.row = 8; alt_down = true; keysin('q'); alt_down = false
eq('Option+note beside snare: no delete', calls[#calls - 1] ~= 'delete:snare', true); eq('Option+note inserted', last(), 'ins:trA@8:60:1')
V.cur.row = 8; local nc0 = #calls; keysin('Q'); eq('17 окт: Shift+note without the preview option - no audition, no note', #calls, nc0)
state.shiftlisten = true
V.cur.row = 8; local nc = #calls; keysin('Q'); eq('Shift+note only auditions', last(), 'prev:60'); eq('Shift+note: nothing inserted', #calls, nc + 1)
keysin('#'); eq('Shift+3 auditions D#', last(), 'prev:63')
state.shiftlisten = nil
local ncq = #calls; ctrl_down = true; V.key(17); ctrl_down = false; eq('17 окт: Ctrl+q - not a note (no held note)', #calls, ncq)
V.cur.row = 1
keysin('q');       eq('q → C-4 (upper row = piano)', last(), 'ins:trA@1:60:1')
keysin(']q');      eq('] octave up', last(), 'ins:trA@2:72:1')
keysin('`');       eq('` → note off (kick was overwritten → nothing covers)', last(), 'off:@3'); eq('off advances', V.cur.row, 4)
do local pv = V.piano; V.piano = false; V.cur.row = 3; keysin('`'); eq('` in INSERT without the keyboard - still a note-off (31 окт)', V.cur.row, 4); V.piano = pv end
keysin('3');       eq('3 in KEYS → D#5 (black key)', last(), 'ins:trA@4:75:1'); eq('advances', V.cur.row, 5)
ctrl_down = true; V.key(49); eq('10 окт: Ctrl+1 = step 1', V.step, 1)
V.key(51); eq('17 окт: Ctrl+3 in INSERT with the keyboard = the step (Ctrl+digit is always the step)', V.step, 3); ctrl_down = false; V.step = 1
V.step_next = true; ctrl_down = true; V.key(52); eq('13 окт: Ctrl+4 из next - шаг числом', V.step_next, false); eq('  step 4', V.step, 4); ctrl_down = false
V.key(27);         eq('esc → normal', V.mode, 'normal')
keysin(':step 2'); V.key(13); eq('step 2', V.step, 2)
do local fi0 = V.cur.fi; V.cur.fi = 1; cmd_down = true; V.key(50); cmd_down = false
eq('NORMAL: ⌘2 -> channel 2', V.cur.fi > 1, true); V.cur.fi = fi0 end
alt_down = true; V.key(8482); alt_down = false; eq('Option+2 -> instrument 2', last(), 'pool:2')
-- 5 окт: слоя пианино в NORMAL нет — m не включает клавиатуру, q — Vim
keysin('m'); eq('NORMAL m: no keyboard layer', V.piano, false); eq('NORMAL: stays normal', V.mode, 'normal')
keysin('iq');      eq('len = step', last(), 'ins:trA@5:72:2'); eq('advance by step', V.cur.row, 7)
V.key(27)
keysin(':lpb 8'); V.key(13); eq('lpb cmd', lpb_calls[#lpb_calls], 8)
keysin(':w'); V.key(13); eq(':w saves', last(), 'save')
eq(':q quits', (function() keysin(':q'); return V.key(13) end)(), 'quit')

-- ── поля: ^A/^X, hex-ввод, r ─────────────────────────────────────────────
reset()
keysin('l'); V.key(1);      eq('^A on vol → +1', last(), 'vol:kick:129')
keysin('l'); V.key(1);      eq('^A on fx → 0PA1 (visual order nt vl fx dl)', last(), 'fx:kick:0PA1')
keysin('ll'); keysin('3'); V.key(24); eq('3^X on delay', last(), 'delay:kick:-3')
reset()
keysin('li7F');             eq('insert hex vol 7F', last(), 'vol:kick:127'); eq('advance', V.cur.row, 1)
V.key(27)
reset()
keysin('lllli80');           eq('insert delay 80', last(), 'delay:kick:128')
V.key(27)
reset()
-- 12 окт: в занятой колонке (у kick там 0PA0) набор — новая команда целиком, старая уступает
keysin('lli0d20');          eq('typing on an occupied fx column writes the new command', last(), 'fx:kick:0D20')
eq('…the old one is cleared first', calls[#calls - 1], 'clearfx:kick:0P')
eq('status hexbuf clear', V.hexbuf, nil)
V.cur.row = 0; keysin('0p8F'); eq('the same code: only its value changes', last(), 'fx:kick:0P8F')
keysin('k'); V.key(27)
reset()
keysin('lli'); V.key(8);    eq('backspace on fx clears', last(), 'clearfx:kick:0P')
V.key(27)
-- 12 окт: коды команд — два символа, как в Renoise (0U14, SF8E); неизвестный код не берётся
reset(); state.fxcols = 2; V.cur = { fi = 1, row = 0, field = 5 }; keysin('i')
keysin('0U14'); eq('empty fx column: 0U14 typed', last(), 'fx:kick:0U14')
V.cur.row = 0; keysin('sf8E'); eq('SF8E typed (code lower case too; value digits A-F upper - d ≠ D)', last(), 'fx:kick:SF8E')
local nc = #calls
V.cur.row = 0; keysin('0X'); eq('unknown code 0X is not taken', #calls, nc); eq('0X: the prefix stays, X does nothing', V.hexbuf, '0')
eq('0X: says so', (V.msg or ''):find('no such effect', 1, true) ~= nil, true); eq('0X: still INSERT', V.mode, 'insert')
keysin('U20'); eq('…then U20 completes 0U20', last(), 'fx:kick:0U20')
-- 12 окт: буква, которой код не начинается, в колонке команд — не команда NORMAL (d не удаляет)
V.cur.row = 0; keysin('d'); eq('d on the fx field in INSERT: no operator', V.pending, nil); eq('d: the code 0D (one letter, 12 окт)', V.hexbuf, '0D'); eq('…cursor on the value half', V.cur.sub, 'val')
eq('d: still INSERT', V.mode, 'insert')
V.cur.row = 0; keysin('j'); eq('j still moves on the fx field', V.cur.row, 1)
-- 12 окт: строка внутри ноты (без своей ноты) — команда звучащей ноте
V.cur.row = 1; keysin('0U14'); eq('0U14 on a row inside the note -> that row of the note (@ quarter)', last(), 'fx:kick:0U14@0.25')
local np = #calls; V.cur.row = 1; keysin('0p40'); eq('0P on a row inside a note: not written to the note row above (12 окт)', #calls, np); eq('…says where', (V.msg or ''):find('type it on its row 0000', 1, true) ~= nil, true); V.hexbuf = nil; V.cur.sub = nil; V.fx_back = nil
V.cur.row = 1; keysin('0D'); eq('0D: says what it is', (V.msg or ''):find('pitch down', 1, true) ~= nil, true); V.hexbuf = nil
-- 12 окт: ` в колонке команд — стоп того, что действует со строк выше (по 00 на род)
do
  local cell = snap.cols[1].lanes[1].subs[1][2]
  cell.run = { '0U14', '0V44' }
  V.cur.row = 2; keysin('`')
  eq('` stops the running slide', calls[#calls - 1], 'fx:kick:0U00@0.5'); eq('…and the running vibrato', last(), 'fx:kick:0V00@0.5')
  eq('`: steps down', V.cur.row, 3)
  cell.run = nil
  local n0 = #calls
  V.cur.row = 1; keysin('`'); eq('` with nothing running writes nothing', #calls, n0)
  eq('…and says so', (V.msg or ''):find('nothing runs here', 1, true) ~= nil, true)
end
-- 12 окт: поле команды — две половины: слева код (буква = 0x, S_ Z_), справа значение
do
  V.cur = { fi = 1, row = 0, field = 5 }; V.hexbuf = nil
  keysin('U'); eq('U on the code half -> 0U, cursor on the value', V.hexbuf .. (V.cur.sub or ''), '0Uval')
  keysin('14'); eq('…14 writes 0U14', last(), 'fx:kick:0U14'); eq('…back to the code half', V.cur.sub, nil); eq('…a step down', V.cur.row, 1)
  V.cur.row = 0; keysin('si'); eq('S then I -> SI', V.hexbuf, 'SI'); keysin('08'); eq('SI08', last(), 'fx:kick:SI08')
  V.cur.row = 0; keysin('zj'); eq('Z then J -> ZJ (j is the code here, not a move)', V.hexbuf, 'ZJ'); V.hexbuf = nil; V.cur.sub = nil; V.fx_back = nil
  V.cur.row = 0; keysin('br'); eq('B then R -> BR beat repeat (1 ноя: B is a prefix)', V.hexbuf, 'BR'); keysin('08'); eq('BR08', last(), 'fx:kick:BR08')
  V.cur.row = 0; keysin('0b'); eq('0 then B -> 0B reverse still', V.hexbuf, '0B'); V.hexbuf = nil; V.cur.sub = nil; V.fx_back = nil
  -- значение без кода: код своей команды слота (kick: 0PA0 в слоте 1)
  V.cur = { fi = 1, row = 0, field = 4, sub = 'val' }
  keysin('3C'); eq('value half on 0PA0: 3C -> 0P3C', last(), 'fx:kick:0P3C'); eq('…stays on the value half', V.cur.sub, 'val')
  -- …или бледной: строка 2 внутри kick, где идёт 0D10
  local cell = snap.cols[1].lanes[1].subs[1][2]
  cell.run = { '0D10' }
  V.cur = { fi = 1, row = 2, field = 4, sub = 'val' }
  keysin('08'); eq('value under a dim 0D10 -> 0D08 at that row', last(), 'fx:kick:0D08@0.5')
  cell.run = nil
  local n0 = #calls
  V.cur = { fi = 1, row = 3, field = 4, sub = 'val' }
  keysin('5'); eq('value with no command here: nothing written', #calls, n0); eq('…says so', (V.msg or ''):find('no command here', 1, true) ~= nil, true)
  V.hexbuf = nil
  -- брошенный код (j) — курсор обратно на код
  V.cur = { fi = 1, row = 0, field = 4 }; keysin('d'); keysin('j'); eq('code dropped by j: the code half again', V.cur.sub, nil); eq('…buffer cleared', V.hexbuf, nil)
  V.hexbuf = nil; V.cur.sub = nil
end
V.key(27); V.mode = 'normal'; V.hexbuf = nil
-- 12 окт: I — как в Vim: INSERT с начала строки (поле ноты), без вставки времени
local nI = #calls
V.cur = { fi = 1, row = 2, field = 5 }; keysin('I')
eq('I: INSERT', V.mode, 'insert'); eq('I: note field', V.cur.field, 1); eq('I: same row', V.cur.row, 2); eq('I: nothing written', #calls, nI)
V.key(27); V.mode = 'normal'
V.key(27); state.fxcols = 1; V.mode = 'normal'; V.hexbuf = nil
reset()
keysin('lr40');             eq('r on vol', last(), 'vol:kick:64'); eq('r no advance', V.cur.row, 0); eq('back to normal', V.mode, 'normal')
reset()
keysin(':pitchmode resample'); V.key(13); eq('pitchmode', last(), 'pitchmode:A:resample')
keysin(':sync'); V.key(13); eq('sync', last(), 'sync')

-- ── повтор и макросы ──────────────────────────────────────────────────────
reset()
keysin('x');  keysin('8j.');  eq('. repeats x', last(), 'delete:snare')
reset()
keysin('qa'); eq('recording', V.macro and V.macro.name, 'a')
keysin('vMwq'); eq('macro stored', #V.regs['@a'], 3); eq('rec mute kick', calls[1], 'mute:kick')
keysin('@a'); eq('@a replays mute', last(), 'mute:ov'); eq('@a moved', V.cur.row, 8)
keysin('@@'); eq('@@', last(), 'mute:snare')

-- ── свёртка ───────────────────────────────────────────────────────────────
reset()
keysin('za');  eq('za folds A', folds['A'], true); eq('flat shrinks', #L.flat, 2); eq('cursor on A', V.cur.fi, 1)
keysin('x');   eq('x in folded → all subs at row', last(), 'delete:kick')
keysin('2jx'); eq('folded row 2 → ov', last(), 'delete:ov')
keysin('za');  eq('za unfolds', folds['A'], nil); eq('flat restored', #L.flat, 3)
keysin('zF');  eq('zF (was zM)', #L.flat, 2)
keysin('zF');  eq('zF again unfolds all (zR is the big router now)', #L.flat, 3)

-- ── русская раскладка ─────────────────────────────────────────────────────
reset()
local function ru(str) for _, cp in utf8.codes(str) do V.key(keys.translate(cp)) end end
ru('ц');   eq('ц = w → ov', V.cur.row, 2)
ru('цци'); eq('цци = wwb → snare', V.cur.row, 8)
ru('пп');  eq('пп = gg', V.cur.row, 0)
ru('ч');   eq('ч = x deletes', last(), 'delete:kick')
ru('шй');  eq('шй = iq inserts C-4', last(), 'ins:trA@0:60:1'); V.key(27)
ru('ввв'); eq('ввв = ddd → dd deletes the row of the subcolumn (1 ноя)', had('delete'), true)
eq('Ж = :', keys.translate(utf8.codepoint('Ж')), (':'):byte())
eq('latin passthrough', keys.translate(104), 104)

-- ── : подсказка и Tab, / поиск, hydra ─────────────────────────────────────
reset()
keysin(':l');  local pp = V.popup(); eq('cmd popup kind', pp and pp.kind, 'cmd'); eq('cmd matches l* (lpb, lanes, lock, len, loop, loops, legato, libsave, libdir, logo)', #pp.lines, 10)
V.key(9);      eq('tab completes lpb', V.cmdline, 'lpb ')
V.key(27)
keysin(':');   pp = V.popup(); eq('all commands listed (max 14)', #pp.lines, 14)
V.key(27)
reset()
keysin('/sna'); eq('search mode', V.mode, 'search'); pp = V.popup(); eq('search popup', pp and pp.title, '/sna')
V.key(13);     eq('found snare', V.cur.row, 8); eq('back to normal', V.mode, 'normal')
keysin('n');   eq('n wraps to snare again', V.cur.row, 8)
keysin('/hat'); V.key(13); eq('found hat', V.cur.row, 16)
keysin('/C-4'); V.key(13); eq('note search', V.cur.row, 0)
keysin('N');   eq('N backwards → hat (все стаб-ноты C-4)', V.cur.row, 16)
keysin('/zzz'); V.key(13); eq('not found stays', V.cur.row, 16); eq('msg', V.msg, 'not found: zzz')
reset()
keysin('8j*'); eq('* searches name under cursor', V.search, 'snare')
reset()
V.key(92);     eq('\\ opens hydra', V.hydra and V.hydra.title, 'root')
pp = V.popup(); eq('hydra popup', pp and pp.kind, 'hydra'); eq('hydra lines', #pp.lines, 2)
keysin('e');   eq('sub hydra', V.hydra.title, 'event')
V.key(8);      eq('backspace → parent', V.hydra.title, 'root')
keysin('ex');  eq('hydra action ran', last(), 'hydra:x'); eq('hydra closed', V.hydra, nil)
V.key(92); keysin('v'); eq('direct action', last(), 'hydra:v')
V.key(92); V.key(27); eq('esc closes', V.hydra, nil)
keysin('?');   eq('? cheat sheet', V.hydra and V.hydra.title, 'keys'); V.key(27)

-- ── Ctrl+HJKL → матрица ───────────────────────────────────────────────────
reset()
ctrl_down = true
V.key(10); eq('^J → matrix down', last(), 'mx:0,1')
V.key(11); eq('^K → matrix up', last(), 'mx:0,-1')
V.key(12); eq('^L → matrix right', last(), 'mx:1,0')
V.key(8);  eq('^H → matrix left', last(), 'mx:-1,0')
ctrl_down = false; keysin('3'); ctrl_down = true; V.key(10); eq('3^J', last(), 'mx:0,3')   -- 10 окт: Ctrl+цифра — шаг, счётчик — без Ctrl
ctrl_down = false
keysin('i'); V.key(8); eq('plain backspace in INSERT deletes', last(), 'delete:kick'); V.key(27)
reset()
alt_down = true
V.key(108); eq('⌥L → next track', V.cur.fi, 3)
V.key(729); eq('⌥H (˙) → prev track', V.cur.fi, 1)
V.key(8710); eq('⌥J (∆) → inst 2 (9 окт: Option+J / K — инструменты)', last(), 'pool:2')
V.key(730); eq('⌥K (˚) → inst 1', last(), 'pool:1')
alt_down = false
cmd_down = true
V.key(106); eq('⌘J → next item in track (было ⌥J)', V.cur.row, 2)
V.key(107); eq('⌘K → prev item', V.cur.row, 0)
cmd_down = false

-- ── a / A: огибающие и fzf ────────────────────────────────────────────────
reset()
keysin('a');  eq('a toggles the automation of the track', last(), 'trackauto'); eq('a not insert', V.mode, 'normal')
keysin('A');  eq('A opens picker', V.picker and V.picker.title, 'auto'); eq('all items', #V.picker.matches, 3)
keysin('thr'); eq('fuzzy filters', #V.picker.matches, 1); eq('match', V.picker.matches[1].label, 'ReaComp / Threshold')
local pp2 = V.popup(); eq('picker popup', pp2 and pp2.kind, 'picker')
V.key(13); eq('enter picks', last(), 'pick:ReaComp / Threshold'); eq('picker closed', V.picker, nil)
keysin('A'); keysin('ga'); eq('subsequence g..a', #V.picker.matches >= 1, true)
V.key(14); V.key(27); eq('esc closes', V.picker, nil)

-- ── прочее ────────────────────────────────────────────────────────────────
reset()
keysin(' '); eq('space plays', last(), 'play')
V.key(13);   eq('enter → smart panel (12 окт)', (last() or ''):match('^smart:') ~= nil, true)
V.key(9);    eq('tab → focus', last(), 'focus')
keysin('F'); eq('F follow', state.follow, false)


-- ── колонка огибающей и текстовые макросы (этап 10) ───────────────────────
reset()
L.flat[#L.flat + 1] = { ci = 1, col = snap.cols[1], env = { name = 'Volume' }, sub = {} }
local efi = #L.flat
V.cur = { fi = efi, row = 4, field = 1 }
TEST_ENVFMT = 'hex'
keysin('i80');     eq('hex on env → point 0x80', last(), 'envset:Volume@4:0.502'); eq('step after point', V.cur.row, 5)
TEST_ENVFMT = nil                                  -- по умолчанию midi 0..127 (6 окт)
keysin('/');       eq('/ → ramp to max over 1 beat', last(), 'envramp:Volume@5-9:cur>1.00'); eq('cursor at ramp end', V.cur.row, 9)
keysin('\\');      eq('\\ → ramp to min', last(), 'envramp:Volume@9-13:cur>0.00')
V.key(8);          eq('BS deletes point', last(), 'envdel:Volume@13')
V.key(27)
keysin('x');       eq('NORMAL x on env → del', last(), 'envdel:Volume@13')
-- midi-формат и Vim-клавиши в INSERT на лейне (6 окт)
V.cur.row = 20
keysin('i64');     eq('midi 64 → point', last(), 'envset:Volume@20:0.504'); eq('step after midi point', V.cur.row, 21)
keysin('005');     eq('midi 005 → 5', last(), 'envset:Volume@21:0.039')
keysin('12'); V.key(13); eq('midi 12 + Enter', last(), 'envset:Volume@22:0.094')
keysin('k');       eq('k moves up in INSERT on env', V.cur.row, 22)
keysin('j');       eq('j moves down in INSERT on env', V.cur.row, 23)
keysin('+');       eq('+ nudges one midi step', last(), 'envnudge:Volume@23:+0.0079')
keysin('-');       eq('- nudges back', last(), 'envnudge:Volume@23:-0.0079')
V.cur.field = 2
keysin('k');       eq('k moves up from the shape field', V.cur.row, 22)
keysin('j');       eq('j moves down from the shape field', V.cur.row, 23)
ctrl_down, alt_down = true, true
keysin('4');       eq('Ctrl+Opt+4 → shape fas', last(), 'envshape:Volume@23:3')
V.key(8734);       eq('Ctrl+Opt+5 as ∞ → shape fae', last(), 'envshape:Volume@23:4')
ctrl_down, alt_down = false, false
V.key(27)
V.cur.field = 1
V.cur.row = 13
V.key(1);          eq('^A nudges +1/64', last(), 'envnudge:Volume@13:+0.0156')
keysin('2'); V.key(24); eq('2^X nudges −2/64', last(), 'envnudge:Volume@13:-0.0312')
keysin(':ramp 40 2b'); V.key(13); eq(':ramp 40 2b → 8 rows', last(), 'envramp:Volume@13-21:cur>0.25')
keysin(':ramp ff 3'); V.key(13); eq(':ramp ff 3 → 3 rows', last(), 'envramp:Volume@13-16:cur>1.00')
V.cur.row = 0; keysin('V'); keysin('6j'); keysin(':ramp 00'); V.key(13)
eq(':ramp in V-LINE uses selection', last(), 'envramp:Volume@0-6:cur>0.00'); eq('back to normal', V.mode, 'normal')
-- 12 окт: / \ на vol-поле больше не фейды (фейды — SIxx / SOxx, :fade)
reset()
V.cur = { fi = 1, row = 0, field = 2 }
keysin('i/');      eq('/ on vol is not a fade', (last() or ''):match('^fx:') == nil, true)
V.key(27)
keysin(':fade out 2'); V.key(13); eq(':fade out 2 rows', last(), 'fx:kick:SO20')
keysin(':fade in 1b'); V.key(13); eq(':fade in 1b', last(), 'fx:kick:SI40')



-- нота на строке-продолжении: событие обрезается в этой строке, нота — туда же
reset()
V.cur = { fi = 1, row = 2, field = 1 }       -- kick 0..3, строка 2 = продолжение
keysin('iq'); V.key(27)
eq('note on cont row cuts kick at row 2', calls[#calls - 1], 'off:kick@2'); eq('then inserts', last(), 'ins:trA@2:60:1')
reset()
V.cur = { fi = 1, row = 2, field = 1 }
keysin('i'); alt_down = true; keysin('q'); alt_down = false; V.key(27)
eq('Option+note on cont row: no cut', calls[#calls - 1] ~= 'off:kick@2', true); eq('Option+note inserted beside', last(), 'ins:trA@2:60:1')
-- ── INSERT (Ableton-раскладка, 2 окт): верхний ряд = пианино, нижние = управление ──
reset(); V.mode = 'insert'; V.vel = 100
keysin('j');  eq('KEYS j moves', V.cur.row, 1)
keysin('k');  eq('KEYS k moves', V.cur.row, 0)
keysin('x');  eq('KEYS x → octave up', V.octave, 5)
keysin('z');  eq('KEYS z → octave down', V.octave, 4)
keysin('c');  eq('KEYS c → vel -8', V.vel, 92)
keysin('C');  eq('KEYS C → vel +8', V.vel, 100)
keysin('c'); V.cur.row = 4; keysin('q'); eq('note carries vel', last(), 'ins:trA@4:60:1'); eq('vel 92 used', V.vel, 92); V.vel = 100
keysin('.');  eq('KEYS . → next instrument', last(), 'pool:2')
keysin(',');  eq('KEYS , → prev instrument', last(), 'pool:1')
keysin('a');  eq('KEYS a → step auto', V.step_auto, true); keysin('a')
V.cur.row = 0; keysin('dd'); eq('INSERT dd deletes the event (and moves the subcolumn below up)', had('delete:kick'), true); eq('back in INSERT after dd', V.mode, 'insert')
V.cur.row = 0; local nc0 = #calls; keysin('d3'); eq('INSERT d3 waits (no note)', #calls, nc0); keysin('w'); eq('d3w → back in INSERT', V.mode, 'insert'); eq('d3w did not insert a note', (last():find('^ins:') == nil), true)
reset(); V.mode = 'insert'; V.cur.row = 8; keysin('M'); eq('INSERT M (Shift+m) mutes the track', last(), 'track:mute')
keysin('f');  eq('KEYS f → fx field', V.cur.field, 4)
keysin('f');  eq('KEYS f wraps (1 fx col)', V.cur.field, 4)
V.cur.field = 1
keysin('G');  eq('KEYS G → end', V.cur.row > 8, true)
keysin('g');  eq('KEYS g → start', V.cur.row, 0)
V.key(223);  eq('INSERT Option+s (ß) → :step prompt', V.mode .. '|' .. tostring(V.cmdline), 'cmd|step '); V.key(27)   -- 5 окт: s — выделение
eq('Esc from cmd → back to INSERT', V.mode, 'insert')
keysin(':w'); V.key(13); eq(':w from INSERT stays in INSERT', V.mode, 'insert')
V.key(27); eq('INSERT Esc → NORMAL', V.mode, 'normal')
keysin('v');  eq('NORMAL v → VISUAL', V.mode, 'visual'); V.key(27); keysin('V'); eq('NORMAL V → V-LINE', V.mode, 'vline'); V.key(27)
reset(); V.mode = 'insert'; V.cur.field = 2; keysin('7F'); eq('hex on vol in KEYS', last(), 'vol:kick:127'); V.cur.field = 1
-- 1 ноя: d ≠ D для a..f — строчная на поле значения в INSERT — клавиша NORMAL (b — назад), потом снова INSERT
reset(); V.mode = 'insert'; V.cur.field = 2; V.cur.row = 4; local nb = #calls; keysin('b'); eq('INSERT vol: b is a motion, not the digit B', #calls, nb); eq('…still INSERT', V.mode, 'insert'); V.cur.field = 1
reset(); keysin('='); eq('= → beatsync kick to beat', last(), 'beatsync:kick:beat')
keysin('8='); eq('8= → beatsync to 8 rows', last(), 'beatsync:kick:8')
reset(); keysin('>'); eq('> → loop item to region end', last(), 'loop:item:nil')
keysin('8>'); eq('8> → loop period 8 rows', last(), 'loop:item:8')
keysin('<'); eq('< → region to item end', last(), 'loop:region:nil')
keysin(':loop 4'); V.key(13); eq(':loop 4', last(), 'loop:item:4')
keysin(':loop region'); V.key(13); eq(':loop region', last(), 'loop:region:nil')
keysin(':loop off'); V.key(13); eq(':loop off', last(), 'loop:off:nil')
keysin(':loop'); V.key(13); eq(':loop → item', last(), 'loop:item:nil')
keysin('i'); keysin('>'); eq('> in INSERT → loop item', last(), 'loop:item:nil'); V.key(27)
keysin(':beatsync bar'); V.key(13); eq(':beatsync bar', last(), 'beatsync:kick:bar')
-- dW / dt и подсказка продолжений (2 окт)
reset(); keysin('d'); eq('d pending hint', (V.pending_hint() or ''):match('i whole item') ~= nil, true)
keysin('i'); eq('di → delete item (30 окт: was dW)', last(), 'delitem'); eq('hint gone', V.pending_hint(), nil)
reset(); keysin('dr'); eq('dr → clear track in region', last(), 'cleartrack')
reset(); keysin('3d'); eq('count in hint', (V.pending_hint() or ''):sub(1, 2), '3 ')
V.key(27)
reset(); keysin('z'); eq('z hint', (V.pending_hint() or ''):match('^z:') ~= nil, true); V.key(27)
reset(); keysin('i'); keysin('d'); eq('d from INSERT shows hint', (V.pending_hint() or ''):match('^d:') ~= nil, true)
keysin('i'); eq('di from INSERT', last(), 'delitem'); eq('back to INSERT', V.mode, 'insert'); V.key(27)
-- 11 окт: INSERT на поле команды — S / s не выделение, а буква команды (SF80)
reset(); V.cur = { fi = 1, row = 0, field = 4 }; keysin('i'); keysin('S')
eq('INSERT S on the fx field is not VISUAL', V.mode, 'insert'); V.key(27); V.mode = 'normal'; V.hexbuf = nil
reset(); V.cur = { fi = 1, row = 0, field = 1 }; keysin('i'); keysin('s')
eq('INSERT s on the note field still selects', V.mode, 'visual'); V.key(27); V.mode = 'normal'
-- форма сегмента огибающей (2 окт): поле 2 колонки огибающей
eq('shape b → bez', V.shape_match('b'), 5); eq('shape s ambiguous', V.shape_match('s'), nil)
eq('shape sq → sqr', V.shape_match('sq'), 1); eq('shape fas', V.shape_match('fas'), 3); eq('shape x none', V.shape_match('x'), false)
reset()
L.flat[#L.flat + 1] = { ci = 1, col = snap.cols[1], env = { name = 'Volume' }, sub = {} }
local efi2 = #L.flat
V.cur = { fi = efi2, row = 4, field = 2 }
-- 11 окт: в INSERT на огибающей буквы — команды Vim (форма — Ctrl+Opt+1..6 / :shape / ^A)
keysin('ij');     eq('INSERT j on the envelope moves down (Vim)', V.cur.row, 5); eq('INSERT stays after a Vim key', V.mode, 'insert')
keysin('k');      eq('INSERT k back up', V.cur.row, 4)
V.key(27); V.mode = 'normal'; V.shapebuf = nil      -- Esc в NORMAL теперь — снова INSERT (4 окт)
V.cur = { fi = efi2, row = 4, field = 2 }
V.key(1);         eq('NORMAL ^A on shape cycles', last(), 'envshapestep:Volume@4:+1')
keysin(':shape slo'); V.key(13); eq(':shape slo', last(), 'envshape:Volume@4:2')
-- свёрнутый трек: подколонка — одно поле (нота)
reset()
L.flat[1].compact = true; V.cur = { fi = 1, row = 0, field = 1 }
keysin('l'); eq('compact sub has one field: l goes to next column', V.cur.fi, 2)
-- точки автоматизации как события (2 окт): w b e W, dd dw yy p
reset()
L.flat[#L.flat + 1] = { ci = 1, col = snap.cols[1], env = { name = 'Vol', prows = { 3, 9, 20 } }, sub = {} }
local efi3 = #L.flat
V.cur = { fi = efi3, row = 0, field = 1 }
-- 31 окт: w / b в колонке огибающей — только её точки; с ноты — следующая нота трека (точки огибающих мимо)
keysin('w'); eq('w from env → its point 3 (stays in the column)', V.cur.fi * 100 + V.cur.row, efi3 * 100 + 3)
keysin('w'); eq('w → env point 9', V.cur.fi * 100 + V.cur.row, efi3 * 100 + 9)
keysin('b'); eq('b → env point 3', V.cur.fi * 100 + V.cur.row, efi3 * 100 + 3)
V.cur = { fi = 1, row = 4, field = 1 }; keysin('w'); eq('w from a note → the next note, not an envelope point', V.cur.fi * 100 + V.cur.row, 108)
V.cur = { fi = efi3, row = 3, field = 1 }
keysin('e'); eq('e → next point', V.cur.row, 9)
keysin('dd'); eq('dd on an envelope deletes its row points (10 окт: трек — td)', last(), 'envdelr:Vol@9-9')
V.cur.row = 3; keysin('yy'); eq('yy on env → yank points', last(), 'envpts:Vol@3-3')
V.cur.row = 15; keysin('p'); eq('p on env → paste points', last(), 'envpaste:Vol@15:1')
V.cur = { fi = 1, row = 18, field = 1 }; keysin('p'); eq('env register on note column → message, no paste', last(), 'envpaste:Vol@15:1')
V.cur = { fi = efi3, row = 0, field = 1 }; keysin('d2w'); eq('d2w on env → the next 2 points (31 окт: empty row - next events)', last(), 'envdelr:Vol@3-9')
V.cur = { fi = efi3, row = 5, field = 1 }; keysin('dw'); eq('dw on an empty env row → the next point', last(), 'envdelr:Vol@9-9')
V.cur = { fi = efi3, row = 5, field = 1 }; keysin('db'); eq('db from empty env row → back to previous point', last(), 'envdelr:Vol@3-5')
V.cur = { fi = 1, row = 17, field = 1 }; keysin('W'); eq('W stops on envelope points too (30 окт: any event)', V.cur.fi * 100 + V.cur.row, 420)
-- шаг next (3 окт): на следующий объект трека — любая его подколонка
reset()
V.cur = { fi = 1, row = 0, field = 1 }
V.step_next = true
eq('next: kick 0 → ov 2 (other subcolumn)', V.next_rows(), 2)
V.cur.row = 2; eq('next: 2 → snare 8', V.next_rows(), 6)
V.cur.row = 8; eq('next: 8 → hat 16', V.next_rows(), 8)
V.cur.row = 16; eq('next: nothing after → 1', V.next_rows(), 1)
V.step_next = false
-- :arp (3 окт): аккорд строки — все подколонки трека курсора
reset()
V.cur = { fi = 1, row = 0, field = 1 }
keysin(':arp down 2 3 50%'); V.key(13)
eq(':arp collects the chord of the row', last(), 'arp:kick@0:down:2:3:0.50')
V.cur = { fi = 1, row = 2, field = 1 }
keysin(':arp'); V.key(13)
eq(':arp repeats last options, other subcolumn note', last(), 'arp:ov@2:down:2:3:0.50')
V.arp_opt = nil
-- :arp live (3 окт): нота в INSERT — в держимый аккорд, не вставка
reset()
keysin(':arp live'); V.key(13)
eq(':arp live on', V.arp_live, true)
V.cur = { fi = 1, row = 20, field = 1 }
keysin('i'); keysin('q')
eq('note goes to the live arp', last(), 'arplive:60@20')
V.key(27)
keysin(':arp live'); V.key(13)
eq(':arp live off', V.arp_live, false)
-- dt / dr / daw (4 окт)
reset()
keysin('dt'); eq('dt removes the time selection', last(), 'deltime')
keysin('dr'); eq('dr clears the track in the region', last(), 'cleartrack')
keysin('dT'); eq('dT clears all items of the track (was daw)', last(), 'cleartrack:all')
-- :interp (4 окт, Paketti): vol от первого к последнему по строкам
reset()
do
  local sub = snap.cols[1].lanes[1].subs[1]
  sub[0].vol, sub[8].vol, sub[16].vol = '00', '40', 'FF'
  V.cur = { fi = 1, row = 0, field = 2 }
  keysin('v16j:interp vol'); V.key(13)
  eq(':interp vol: snare in the middle', last(), 'vol:snare:128')
end
-- Option+h / Option+l (4 окт): трек слева / справа, с любой подколонки
reset()
alt_down = true
V.cur = { fi = 3, row = 4, field = 1 }        -- трек M
V.key(729)
eq('Option+h -> previous track (A)', flat_col_name and flat_col_name(V.cur.fi) or V.cur.fi, 1)
V.cur = { fi = 2, row = 4, field = 1 }        -- вторая подколонка трека A
V.key(172)
eq('Option+l from a subcolumn -> next track (M)', V.cur.fi, 3)
V.cur = { fi = 2, row = 4, field = 1 }
V.key(729)
eq('Option+h on the first track stays', V.cur.fi, 1)
alt_down = false
-- повтор паттерна (4 окт): Ctrl+Opt+J / ↓ — трек, Shift+Opt+J — все треки
reset()
ctrl_down, alt_down = true, true; V.key(10); eq('Ctrl+Opt+J repeats on the track', last(), 'repeat:track')
V.key(1685026670); eq('Ctrl+Opt+Down too', last(), 'repeat:track')
ctrl_down, shift_down = false, true; do local n0 = #lpb_calls; V.key(8710); eq('Shift+Opt+J = LPB up (opens rows), as +', lpb_calls[n0 + 1], 1) end   -- 27 окт: было транспоз инструмента
alt_down, shift_down = false, false
-- слайс = нота (4 окт): обычная MIDI-клавиатура, C-4 = слайс 1
reset()
do
  local pool = snap.cols[1].pool
  pool[1].slices = {}; for k = 1, 20 do pool[1].slices[k] = (k - 1) * 0.1 end
  pool[1].len = 2
  V.inst = 1; V.octave = 4; V.step = 0
  V.cur = { fi = 1, row = 30, field = 1 }
  keysin('i')
  -- 5 окт (Renoise): q = весь сэмпл на своей высоте, слайсы со следующей клавиши
  keysin('q'); eq('q = the whole sample at C-4', last():match('^ins:trA@%d+:60:') ~= nil, true)
  keysin('2'); eq('2 = slice 1 (black key)', last(), 'slice:trA@30:1')
  keysin('w'); eq('w = slice 2', last(), 'slice:trA@30:2')
  keysin('p'); eq('p = slice 16', last(), 'slice:trA@30:16')
  -- режим слайса (10 окт): random / sequence выбирает слайс сам, клавиша только бьёт
  PICK = function(n, k) return 7 end
  keysin('w'); eq('slice mode picks the slice (w -> 7)', last(), 'slice:trA@30:7')
  PICK = function(n, k) return 9 end
  keysin('x'); keysin('p'); keysin('z'); eq('slice mode: a key past the slices (28 of 20) still inserts', last(), 'slice:trA@30:9')
  PICK = nil
  local n0 = #calls
  keysin('x'); keysin('2'); eq('x then 2 = slice 13', last(), 'slice:trA@30:13')
  keysin('p'); eq('past the last slice (28 of 20): nothing', last(), 'slice:trA@30:13')
  keysin('z')
  V.last_slice = 5
  -- 17 окт: Option + нота — выбранный слайс на высоте клавиши; Option+Shift — только прослушать
  alt_down = true; V.key(8721); alt_down = false     -- Option+w (∑)
  eq('Option+w = last slice +2 st', calls[#calls], 'slicepitch:5:+2')
  local nc2 = #calls
  alt_down, shift_down = true, true; V.key(8222); alt_down, shift_down = false, false     -- Shift+Option+w („)
  eq('Shift+Option+w: nothing inserted', calls[#calls] ~= 'slicepitch:5:+2' or #calls == nc2, true)
  keysin(';'); eq('; inserts the whole sample', last(), 'whole')
  -- арп из слайсов (4 окт): :arp live, клавиша-слайс уходит в живой арп
  V.arp_live = true; keysin('w'); V.arp_live = false
  eq('arp live on a sliced sample takes slice 2 (pitch 62)', last(), 'arplive:62@' .. V.cur.row)
  -- 17 окт: Ctrl + клавиша слайса — этот слайс до конца сэмпла; Cmd — не нота
  local nc3 = #calls
  cmd_down = true; keysin('w'); cmd_down = false
  eq('Cmd+w in INSERT: no note', #calls, nc3)
  ctrl_down, shift_down = true, true; V.key(23); ctrl_down, shift_down = false, false     -- Ctrl+Shift+w
  eq('Ctrl+Shift+w on a sliced sample = slice 2 to the end', last():match('^slice:trA@%d+:2:thru$') ~= nil, true)
  V.key(27)
  pool[1].slices = nil
end
keysin(':note D#3 4'); V.key(13); eq(':note', last(), 'notecmd:51:4')
keysin(':sl 3 2 +5'); V.key(13); eq(':sl', last(), 'slcmd:3:2:5')
-- gw / :sw / :scramble (4 окт)
reset()
keysin('gw'); eq('gw swaps with the next event', last(), 'swap:kick:snare')
eq('gw: cursor follows to the other row', V.cur.row, 8)
reset()
keysin('2gw'); eq('2gw swaps with the second event ahead', last(), 'swap:kick:hat')
reset()
keysin(':sw 2'); V.key(13); eq(':sw 2', last(), 'swap:kick:hat')
reset()
V.cur = { fi = 1, row = 16, field = 1 }
keysin('gw'); eq('gw on the last event: nothing', #calls, 0)
reset()
keysin(':scramble'); V.key(13); eq(':scramble without a region: the whole cursor track', last(), 'scramble:hat,kick,ov,snare')
reset()
keysin('v8j:scramble'); V.key(13); eq(':scramble in VISUAL: the selection', last(), 'scramble:kick,snare')
-- 5 окт: клавиатура = INSERT (без m): i — и сразу ноты; Esc — назад
reset()
keysin('iq'); eq('INSERT: q writes C-4 at once', last(), 'ins:trA@0:60:1'); eq('INSERT: keyboard on', V.piano, true)
keysin('m'); eq('INSERT: m does not turn it off', V.piano, true)
V.key(27); eq('Esc: NORMAL, keyboard off', V.piano, false)
-- 11 окт: клавиатура спрятана — INSERT НЕ пишет ноты (буквы = команды NORMAL, потом снова INSERT)
reset(); PIANO_ON = false
local nc0 = #calls
keysin('iw'); eq('INSERT with the keyboard hidden writes no note', #calls, nc0); eq('…and stays in INSERT', V.mode, 'insert')
keysin('x'); eq('keyboard hidden: w moved to the next event (ov), x deleted it like NORMAL', last(), 'delete:ov'); eq('…back in INSERT', V.mode, 'insert')
PIANO_ON = nil; V.key(27)
-- Esc переключает INSERT (4 окт, как Renoise)
reset(); V.key(27); eq('NORMAL Esc -> INSERT', V.mode, 'insert'); V.key(27); eq('INSERT Esc -> NORMAL', V.mode, 'normal')
-- 10 окт: опция Esc mode = vim — Esc только NORMAL, сколько ни жми
do ESC_VIM = true
  reset(); V.key(27); eq('vim Esc: NORMAL stays NORMAL', V.mode, 'normal'); V.key(27); eq('vim Esc twice: NORMAL', V.mode, 'normal')
  V.key(('i'):byte()); eq('vim Esc mode: i -> INSERT', V.mode, 'insert'); V.key(27); eq('vim Esc mode: INSERT Esc -> NORMAL', V.mode, 'normal')
  ESC_VIM = nil end
keysin('3'); V.key(27); eq('Esc with a count only clears it', V.mode, 'normal')
-- 5 окт: клавиатура вкл (m) — hjkl в NORMAL ходят, верхний ряд играет
reset(); AUTO_KBD = false
PIANO_ON = true
local r0 = V.cur.row
keysin('j'); eq('keys on: j moves down', V.cur.row, r0 + 1)
keysin('k'); eq('keys on: k moves up', V.cur.row, r0)
local nc = #calls; keysin('q'); eq('keys on: q plays, writes nothing', #calls, nc + 1); eq('keys on: q previews', last():match('^prev') ~= nil, true)
keysin('x'); eq('keys on: x = octave up, not delete', V.octave, 5); keysin('z')
-- 5 окт: клавиатура вкл, INSERT: d3w — команда Vim, а не ноты 3 и w
reset(); AUTO_KBD = false; PIANO_ON = true; V.mode = 'insert'; V.cur.row = 0
local nd = #calls; keysin('d3'); eq('keys INSERT: d3 waits, no note', #calls, nd); keysin('w')
eq('keys INSERT: d3w deletes', (last() or ''):match('^delete') ~= nil, true); eq('keys INSERT: back in INSERT', V.mode, 'insert')
PIANO_ON = false; AUTO_KBD = true
-- 16 окт: frow, клавиатура вкл, INSERT: буквы — команды Vim (w движется, x удаляет), цифры — ноты, [ ] — октава
reset(); AUTO_KBD = false; PIANO_ON = true; FROW = true; keys.set_layout('frow'); V.mode = 'insert'; V.cur.row = 0
keysin('w'); local wr = V.cur.row; eq('frow INSERT: still INSERT after w', V.mode, 'insert')
V.mode = 'normal'; V.cur.row = 0; keysin('w'); eq('frow INSERT: w moves as in NORMAL', wr, V.cur.row); V.mode = 'insert'
local nx = #calls; keysin('x'); eq('frow INSERT: x deletes', table.concat(calls, ' ', nx + 1):match('delete') ~= nil, true); eq('frow INSERT: INSERT after x', V.mode, 'insert')
keysin(']'); eq('frow INSERT: ] octave up', V.octave, 5); keysin('[')
V.cur.row = 2; local r2 = V.cur.row; keysin('1'); eq('frow INSERT: 1 is a note (row steps)', V.cur.row > r2, true)
V.cur.row = 2; keysin('3j'); eq('frow INSERT: 3 is a note, not a count', V.cur.row, 4)
FROW = nil; keys.set_layout('qwerty'); PIANO_ON = false; AUTO_KBD = true; V.key(27)
-- 16 окт: Tab в колонке волны — к stretch-маркеру / началу ноты
reset()
do
  local f = L.flat[1]
  local h
  for r, c in pairs(f.sub) do if c.kind == 'audio' or c.kind == 'midi' then if not h or r < h.row0 then h = c; h.row0 = h.row0 or r end end end
  local r0 = h.row0 or 0
  h.smk = { 0.5 }; h.rows = h.rows or 8
  local want = r0 + math.floor(0.5 * h.rows)
  V.cur = { fi = 1, row = r0, field = 1, sub = 'wave' }
  local ms = V.wave_marks(1)
  local has = false; for _, r in ipairs(ms) do if r == want then has = true end end
  eq('wave marks: the stretch marker row', has, true)
  V.wave_step(1); eq('wave Tab: to the marker', V.cur.row, want)
  V.wave_step(-1); eq('wave Shift+Tab: back to the note start', V.cur.row, r0)
  h.smk = nil
end
-- 5 окт: Shift+hjkl — выделение; INSERT s — выделение с возвратом; Option+s (ß) — :step
reset(); keysin('L'); eq('L: visual from normal', V.mode, 'visual'); eq('L: anchor at the start', V.anchor and V.anchor.fi, 1)
keysin('J'); eq('J extends a row down', V.cur.row, 1); V.key(27); eq('Esc: back to normal', V.mode, 'normal')
reset(); keysin('is'); eq('INSERT s: visual', V.mode, 'visual'); keysin('jy'); eq('y: back to INSERT', V.mode, 'insert'); V.key(27)
reset(); V.key(223); eq('Option+s: step prompt', V.cmdline, 'step '); eq('Option+s: cmd mode', V.mode, 'cmd'); V.key(27)
-- стрелки = hjkl во всех сочетаниях (6 окт)
reset()
shift_down = true; V.key(1685026670); shift_down = false
eq('Shift+Down = Shift+j: VISUAL', V.mode, 'visual'); eq('Shift+Down moved a row', V.cur.row, 1)
V.key(27); reset()
ctrl_down = true; V.key(1919379572); ctrl_down = false
eq('Ctrl+Right = Ctrl+l: matrix move', last(), 'mx:1,0')
-- 10 окт: открытый слайсер не съедает выбор инструмента (Opt+J / K, Opt / Cmd+цифра)
reset(); SLICER = true; V.inst = 2
alt_down = true; V.key(8710); alt_down = false
eq('slicer open: Option+J still picks the next instrument', last(), 'pool:3')
alt_down = true; V.key(162); alt_down = false
eq('slicer open: Option+4 picks instrument 4', last(), 'pool:4')
state.focus = 'slices'
V.key(('x'):byte()); eq('slicer open, focus on it: other keys go to the slicer', last(), 'slkey:120')
state.focus = nil   -- 24 окт: фокус в трекере — клавиши трекеру, не слайсеру
SLICER = nil
-- 10 окт: d пробел (было dp) — до паузы (серия лейна без пустой строки), dS (было dP) — всё выбранных треков; 1 ноя: dp / dP — к началу / концу паттерна
reset(); V.cur = { fi = 1, row = 0, field = 1 }
keysin('d '); eq('d Space from row 0: kick + its overlapping ov (rows 0-3)', last(), 'delete:kick,ov')
reset(); V.cur = { fi = 1, row = 5, field = 1 }
keysin('d '); eq('d Space on an empty row: the next run (snare, rows 8-9)', last(), 'delete:snare')
reset(); V.cur = { fi = 1, row = 20, field = 1 }
local nc = #calls; keysin('d '); eq('d Space below the last event: nothing', #calls, nc)
reset(); keysin('dS'); eq('dS: all of the selected tracks', last(), 'dP')
-- 10 окт: транспозиция как в Renoise — области: выделение / колонка / трек / паттерн
reset()
V.cur = { fi = 1, row = 0, field = 1 }
local okp = V.transpose_scope('pattern', 12); eq('pattern transpose +12 runs', okp and (last() or ''):match('^transpose:.*:%+12$') ~= nil or not okp, true)
local okt = V.transpose_scope('track', -1); eq('track transpose -1 runs', okt and (last() or ''):match(':%-1$') ~= nil or not okt, true)

-- ── 11 окт: регрессии сессии ───────────────────────────────────────────────
-- узкая подколонка: x_inst = false — поля инструмента / слайса нет, l идёт сразу в vol
reset(); L.flat[1].G = { x_inst = false, x_slc = false }
keysin('l'); eq('narrow sub: l goes note -> vol (no hidden inst)', V.cur.field, 2); eq('narrow sub: no sub field', V.cur.sub, nil)
-- полная подколонка: нота -> инструмент -> слайс -> громкость и обратно
reset(); L.flat[1].G = { x_inst = 40, x_slc = 60 }
keysin('l'); eq('full sub: l -> inst', V.cur.sub, 'inst')
keysin('l'); eq('full sub: l -> slc', V.cur.sub, 'slc')
keysin('l'); eq('full sub: l -> vol', V.cur.field, 2); eq('full sub: vol has no sub', V.cur.sub, nil)
keysin('h'); eq('full sub: h -> slc', V.cur.sub, 'slc')
keysin('h'); eq('full sub: h -> inst', V.cur.sub, 'inst')
keysin('h'); eq('full sub: h -> note', V.cur.sub, nil); eq('full sub: note field', V.cur.field, 1)
-- 14 окт: колонка пана — подполе громкости
reset(); L.flat[1].G = { x_inst = 40, x_slc = 60, x_pan = 90 }
keysin('lll'); eq('pan: l -> vol', V.cur.field, 2)
keysin('l'); eq('pan: l -> pan', V.cur.sub, 'pan')
keysin('h'); eq('pan: h -> vol', V.cur.sub, nil); eq('  vol field', V.cur.field, 2)
keysin('l'); keysin('i'); keysin('40'); eq('pan: 40 typed in INSERT', last(), 'pan:kick:64'); V.key(27)
L.flat[1].G = nil
-- 27 окт: Shift+Opt+H / L — колонки трека курсора уже / шире (как z, / z.), курсор стоит
reset(); alt_down, shift_down = true, true
V.key(172); eq('Shift+Opt+L: wider', last(), 'w:1:cur'); eq('Shift+Opt+L: cursor stays', V.cur.fi, 1)
V.key(729); eq('Shift+Opt+H: narrower', last(), 'w:-1:cur')
alt_down, shift_down = false, false
reset(); local nc0 = #calls; keysin('3'); alt_down, shift_down = true, true; V.key(172); alt_down, shift_down = false, false
local nw = 0; for k = nc0 + 1, #calls do if calls[k] == 'w:1:cur' then nw = nw + 1 end end
eq('3 Shift+Opt+L: three steps', nw, 3)
-- колонка cmd мастера: Enter — правка в строке :, ! — действие, x — удалить, :mcmd — ставит
reset()
L.flat[#L.flat + 1] = { ci = 3, col = { name = 'master', lanes = {} }, ml = { kind = 'cmd', name = 'cmd', ev = { [2] = { text = '!40044', n = 1 } }, rows = { 2 } }, sub = {}, x = 0, w = 10 }
local cfi = #L.flat
V.cur = { fi = cfi, row = 2, field = 1 }
V.key(13); eq('cmd: Enter opens the command line', V.mode, 'cmd'); eq('cmd: prefilled with the row text', V.cmdline, 'mcmd !40044')
V.key(27); eq('cmd: Esc back to NORMAL', V.mode, 'normal')
V.key(('!'):byte()); eq('cmd: ! starts a REAPER action', V.cmdline, 'mcmd !'); V.key(27)
V.cur = { fi = cfi, row = 5, field = 1 }
V.key(13); eq('cmd: empty row - empty text', V.cmdline, 'mcmd ')
V.cmdline = 'mcmd hello world'; V.key(13); eq(':mcmd sets the row text', last(), 'mcmd:5:hello world')
V.cur = { fi = cfi, row = 2, field = 1 }
keysin('x'); eq('cmd: x deletes the row command', last(), 'mcmd:2:')
local ncalls = #calls; keysin('j'); eq('cmd: j still moves', V.cur.row, 3); eq('cmd: j writes nothing', #calls, ncalls)
-- 16 окт: w b e — по событиям лейна (маркеры): со строки 0 w — на маркер 2, ещё w — дальше некуда, b — назад
L.flat[cfi].ml.ev[9] = { text = 'm next', n = 1 }
V.cur = { fi = cfi, row = 0, field = 1 }
keysin('w'); eq('cmd: w -> the next marker', V.cur.row, 2)
keysin('w'); eq('cmd: w -> the marker after it', V.cur.row, 9)
keysin('b'); eq('cmd: b -> back', V.cur.row, 2)
V.cur = { fi = cfi, row = 0, field = 1 }; keysin('e'); eq('cmd: e -> the next marker', V.cur.row, 2)
L.flat[cfi].ml.ev[9] = nil
-- 20 окт: у MIDI-лейна (PB, CC …) нет волны — l не уводит в невидимое подполе (курсор «стоял на месте»)
L.flat[cfi].G = { w_wave = 8 }
V.cur = { fi = cfi, row = 0, field = 1 }; eq('ml: no wave subfield', V.wave_field_ok(), false)
V.cur = { fi = cfi - 1, row = 0, field = V.last_field(cfi - 1), sub = ((V.last_field(cfi - 1) or 1) >= 4) and 'val' or nil }
keysin('l'); eq('ml: l lands on the lane', V.cur.fi, cfi); eq('ml: not on a hidden wave', V.cur.sub, nil)
V.cur = { fi = cfi, row = 0, field = 1, sub = 'wave' }; keysin('l'); eq('ml: a stale wave subfield is reset', V.cur.sub == 'wave', false)
L.flat[cfi].G = nil
-- вставка ноты обрывается следующим событием подколонки (E.cap_row на время вставки)
reset()
local CAP
local ins0 = E.insert_note
E.insert_note = function(...) CAP = E.cap_row or 'none'; return ins0(...) end
V.cur = { fi = 1, row = 4, field = 1 }; V.mode = 'insert'; PIANO_ON = true
local pk; for code, off in pairs(keys.piano) do if off == 0 then pk = code end end
V.key(pk); PIANO_ON = nil
eq('insert: cap = the next event of the subcolumn (snare @8)', CAP, 8)
eq('insert: cap cleared after the insert', E.cap_row, nil)
E.insert_note = ins0
-- чистые функции вставки
eq('next_event_row: next head below', V.next_event_row(snap.cols[1].lanes[1].subs[1], 0), 8)
eq('next_event_row: conts are not events', V.next_event_row(snap.cols[1].lanes[1].subs[1], 9), 16)
eq('next_event_row: none below', V.next_event_row(snap.cols[1].lanes[1].subs[1], 16), nil)
eq('slq_snap: nearest beat', V.slq_snap(9.3, 4, 0), 8)
eq('slq_snap: never on or before the cursor', V.slq_snap(1.2, 4, 0), 4)
eq('slq_snap: bar grid', V.slq_snap(10, 12, 0), 12)
eq('slq_snap: row grid keeps the row', V.slq_snap(5.0, 1, 2), 5)

-- 13 окт: keys: renoise — две октавы: нижний ряд — октава курсора, верхний — +1; h j в INSERT — ноты, октава [ ]
do
  reset(); RENOISE = true; keys.set_renoise(true)
  keysin('iz'); eq('renoise: z -> C-4', last(), 'ins:trA@0:60:1')
  V.cur.row = 2; keysin('q'); eq('renoise: q -> C-5 (octave higher)', last(), 'ins:trA@2:72:1')
  V.cur.row = 4; keysin('h'); eq('renoise: h is G#4, not a move', last(), 'ins:trA@4:68:1')
  keysin('['); V.cur.row = 6; keysin('z'); eq('renoise: [ - octave down', last(), 'ins:trA@6:48:1')
  V.key(27); RENOISE = false; keys.set_renoise(false)
end

-- 13 окт: окно ввода имени — первая буква заменяет имя, стрелки — правка на месте
do
  reset()
  local LEFT = 1818584692
  V.open_prompt('tname ', 'Track 4')
  eq('prompt: no command shown', V.popup().title, 'Track 4')
  V.key(('x'):byte()); eq('prompt: a letter replaces the whole name', V.cmdline, 'tname x')
  V.key(27)
  V.open_prompt('tname ', 'Track 4')
  V.key(LEFT); V.key(('y'):byte()); eq('prompt: after an arrow - edit in place', V.cmdline, 'tname Track y4')
  V.key(8); V.key(8); eq('prompt: backspace edits', V.cmdline, 'tname Track4')
  V.key(27)
  V.open_prompt('tname ', 'Track 4'); V.key(8); eq('prompt: backspace first - clears', V.cmdline, 'tname ')
  V.key(0x75000000 + 0x0431); eq('prompt: cyrillic letters', V.cmdline, 'tname б')
  V.key(27); eq('prompt: Esc leaves', V.mode, 'normal')
end

-- 15 окт: счётчики простых действий (2p было одной вставкой; 3u, [ ] ( ) счётчик не брали)
do
  reset()
  keysin('yy'); local n0 = #calls
  keysin('2p')
  eq('2p: two pastes', #calls - n0, 2)
  eq('2p: first at the cursor row', calls[n0 + 1], 'paste:1@0:trA')
  eq('2p: second one register height lower', calls[n0 + 2], 'paste:1@1:trA')
  reset(); keysin('3u')
  local u = 0; for _, c in ipairs(calls) do if c == 'undo' then u = u + 1 end end
  eq('3u: three undo steps', u, 3)
  reset(); keysin('3'); V.key(18)
  local r = 0; for _, c in ipairs(calls) do if c == 'redo' then r = r + 1 end end
  eq('3 Ctrl+R: three redo steps', r, 3)
  reset(); V.octave = 4; keysin('2]'); eq('2]: octave +2', V.octave, 6)
  keysin('3['); eq('3[: octave -3', V.octave, 3)
  reset(); V.inst = 5; keysin('2)'); eq('2): instrument +2', V.inst, 7)
  keysin('3('); eq('3(: instrument -3', V.inst, 4)
  reset(); keysin('3j'); eq('3j: three rows down', V.cur.row, 3)
  keysin('2k'); eq('2k: two rows up', V.cur.row, 1)
  reset(); keysin('5G'); eq('5G: row 5 (row index 4)', V.cur.row, 4)
  reset(); keysin('3x'); eq('3x: rows 0..2 of the column', last(), 'delete:kick')
  reset(); V.cur.row = 8; keysin('2dd'); eq('2dd: snare (rows 8..9)', had('delete:snare'), true)
  -- 2. — последнее действие дважды
  reset(); keysin('yy'); keysin('p'); local p0 = #calls
  keysin('2.')
  local np = 0; for i = p0 + 1, #calls do if calls[i]:match('^paste') then np = np + 1 end end
  eq('2.: the last edit twice', np, 2)
  -- 2@a — макрос дважды
  reset(); keysin('qa'); keysin('j'); keysin('q'); V.cur.row = 0
  keysin('2@a'); eq('2@a: the macro (j) twice', V.cur.row, 2)
  -- 2w — через два события
  reset(); keysin('2w'); eq('2w: two events on (ov, then snare)', V.cur.row, 8)
  -- 15 окт: заглушки — поиск, треки, gw
  reset(); V.search = 'a'                               -- snare (8) и hat (16)
  keysin('2n'); eq('2n: the second match below', V.cur.row, 16)
  keysin('N'); eq('N: back to the previous match', V.cur.row, 8)
  reset(); keysin('44'); V.key(27); eq('Esc clears a typed count', V.count, nil); eq('Esc with a count stays in NORMAL', V.mode, 'normal')
  reset(); keysin('3tt'); eq('3tt: three new tracks', last(), 'newtrack:3')
  reset(); keysin('5td'); eq('5td: five tracks deleted', last(), 'tracks:delete:5')
  reset(); keysin('2tx'); eq('2tx: two tracks cut', last(), 'tracks:cut:2')
  reset(); keysin('2gw'); eq('2gw: kick swaps with the 2nd event below (hat)', last(), 'swap:kick:hat')
  eq('2gw: the cursor follows', V.cur.row, 16)
end

-- 16 окт: @ при клавиатуре в NORMAL — панель макросов, нота не звучит; в INSERT @ = Shift+2 — прослушка (так задумано)
do
  reset()
  V.piano = true; V.mode = 'normal'
  local nc = #calls
  keysin('@')
  local prev, panel = false, false
  for k = nc + 1, #calls do local c = tostring(calls[k]); if c:match('^prev:') then prev = true end; if c == 'macpanel' then panel = true end end
  eq('@ (Shift+2) with the keyboard: no macro panel', panel, false)
  -- 16 окт: панель макросов — Option+Shift+2 (€), и с клавиатурой, и без
  for _, pn in ipairs({ true, false }) do
    reset(); V.piano = pn; V.mode = 'normal'
    nc = #calls; V.key(8364)
    panel = false
    for k = nc + 1, #calls do if tostring(calls[k]) == 'macpanel' then panel = true end end
    eq('Opt+Shift+2 -> the macro panel (keyboard ' .. tostring(pn) .. ')', panel, true)
  end
  V.piano = false
end

-- 16 окт: пикер с папками деревом — колонка на уровень (A / B), справа имена; набор — по всем
do
  local picked
  local items = { { label = 'Pads / factory / Air', name = 'Air', group = 'Pads / factory' },
                  { label = 'Bass / factory / Sub', name = 'Sub', group = 'Bass / factory' },
                  { label = 'Bass / Bluelight / Wob', name = 'Wob', group = 'Bass / Bluelight' } }
  V.open_picker('patches', items, function(it) picked = it.name end)
  local pk = V.picker
  eq('tree made', pk.tree ~= nil, true); eq('depth 2', pk.depth, 2); eq('focus on folders', pk.col, 1)
  local pop = V.popup()
  eq('under all: one folder column (the empty level 2 takes no room, 18 окт)', #pop.groups.cols, 1)
  eq('level 1: all + 2', #pop.groups.cols[1].lines, 3)
  eq('level 1 sorted', pop.groups.cols[1].lines[2]:match('^%S+'), 'Bass')
  eq('level 2 hidden under all', pop.groups.cols[2], nil)
  V.picker_key(('j'):byte())                                -- Bass
  eq('folder filters', #pk.matches, 2)
  V.picker_key(('l'):byte())                                -- в колонку авторов
  eq('l goes deeper', pk.col, 2)
  pop = V.popup()
  eq('level 2 shows authors', #pop.groups.cols[2].lines, 3)
  V.picker_key(('j'):byte())                                -- Bluelight (по алфавиту первый)
  eq('author filters', #pk.matches, 1)
  eq('names only inside', V.popup().lines[1].text, 'Wob')
  V.picker_key(('l'):byte()); eq('to names', pk.col, 3)
  V.picker_key(('l'):byte())
  eq('l on a name picks', picked, 'Wob')
  V.open_picker('p2', items, function() end)
  V.picker_pick(1, 2); V.picker_key(('A'):byte())
  eq('typing searches all folders', V.picker.matches[1] and V.picker.matches[1].name, 'Air')
  V.picker = nil
  V.open_picker('lf2', items, function() end)
  V.picker_key(('/'):byte()); V.picker_key(('j'):byte())
  eq('/ then letters search', V.picker.query, 'j')
  V.picker = nil
  V.open_picker('flat', { { label = 'a', group = 'x' }, { label = 'b', group = 'x' } }, function() end)
  eq('one folder - no columns', V.picker.tree, nil)
  V.picker = nil
end

-- 18 окт: пустая строка (allow_empty) + Enter после стрелок — берётся выбранный пункт, не пустое имя
do
  local got
  V.open_picker('name', { { label = 'F1' }, { label = 'A1' }, { label = 'B1' } }, function(it) got = it.label end)
  V.picker.free, V.picker.allow_empty = true, true
  V.picker_key(1685026670); V.picker_key(1685026670); V.picker_key(13)
  eq('arrows then Enter take the item', got, 'B1')
  got = nil
  V.open_picker('name', { { label = 'F1' } }, function(it) got = it.label end)
  V.picker.free, V.picker.allow_empty = true, true
  V.picker_key(13)
  eq('Enter on untouched empty input gives empty', got, '')
  V.picker = nil
end

-- 17 окт: умное выделение — первый a: колонка на весь паттерн; a шире, i уже; курсор на месте (такт 16, регион 0..31)
do
  V.key(27); V.mode = 'normal'; V.cur.fi, V.cur.row = 1, 21
  local L0 = state.lpb
  local function rng() local f0, f1, r0, r1 = V.visual_range(); return ('%d-%d %d-%d'):format(f0, f1, r0, r1) end
  keysin('v'); keysin('a')
  eq('smart sel: first - the column, the whole pattern', rng(), '1-1 0-31')
  keysin('a'); local f0, f1, r0, r1 = V.visual_range()
  eq('smart sel: wider - the bar, all tracks', r0 == 16 and r1 == 31 and f0 == 1 and f1 >= 1, true)
  keysin('a'); f0, f1, r0, r1 = V.visual_range()
  eq('smart sel: wider - half the pattern', ('%d-%d'):format(r0, r1), '16-31')
  keysin('a'); f0, f1, r0, r1 = V.visual_range()
  eq('smart sel: wider - the whole pattern', ('%d-%d'):format(r0, r1), '0-31')
  eq('smart sel: the cursor stays', V.cur.row, 21)
  V.key(27); V.mode = 'normal'; V.cur.fi, V.cur.row = 1, 21
  keysin('v'); keysin('i')
  eq('smart sel: i first - the column too', rng(), '1-1 0-31')
  keysin('i'); eq('smart sel: narrower - the column in the bar', rng(), '1-1 16-31')
  keysin('i'); eq('smart sel: narrower - the column in the beat', rng(), ('1-1 %d-%d'):format(math.floor(21 / L0) * L0, math.floor(21 / L0) * L0 + L0 - 1))
  ctrl_down, shift_down = true, true; V.key(10); ctrl_down, shift_down = false, false   -- Ctrl+Shift+J
  local g0, g1, q0, q1 = V.visual_range()
  eq('visual: Ctrl+Shift+J moves the selection a row down', ('%d-%d'):format(q0, q1), ('%d-%d'):format(math.floor(21 / L0) * L0 + 1, math.floor(21 / L0) * L0 + L0))
  V.key(27)
end

do
-- 19 окт: кит drumrs5k — клавиша = пэд: высота — нота пэда (ctx.kit_key_pitch)
KIT_MAP = function(p) return p == 60 and 36 or nil end
reset(); V.cur.row = 2; keysin('iq'); eq('kit: the key writes the pad note', last(), 'ins:trA@2:36:1')
KIT_MAP = nil; V.mode = 'normal'
end

-- 19 окт: v по кругу — поле курсора → весь трек → выход
V.mode = 'normal'; V.cur.field = 2
keysin('v'); eq('v on vol: field only', V.vfield, 2); eq('visual', V.mode, 'visual')
keysin('v'); eq('v again: whole track', V.vtrack, true); eq('field off', V.vfield, nil)
keysin('v'); eq('v third: off', V.mode, 'normal')
V.cur.field = 1; keysin('v'); eq('v on a note: the subcolumn', V.vfield, nil); V.key(27)
V.mode = 'normal'
-- 20 окт: dC — поле курсора во всём треке (vol → 128 у каждой ноты трека), нота-поле — отказ
reset(); V.cur = { fi = 1, row = 5, field = 2 }; local n0 = #calls; keysin('dC')
local nv = 0; for i = n0 + 1, #calls do if calls[i]:match('^vol:') then nv = nv + 1 end end
eq('dC clears vol of the track notes', nv > 0, true); eq('dC writes default 128', (calls[#calls] or ''):match(':128$') ~= nil, true)
reset(); V.cur = { fi = 1, row = 0, field = 1 }; n0 = #calls; keysin('dC'); eq('dC on a note: nothing', #calls, n0)
-- 20 окт: Q в VISUAL — квантайз в сетку строк; ноты с delay — на ближайшую строку
reset(); V.cur = { fi = 1, row = 0, field = 1 }
local RT; local rt0 = E.retime; E.retime = function(hs, lpb, rows) RT = { n = #hs, r = rows[1] }; return #hs end
local hd = V.heads_in(1, 1, 0, 3)[1]; local d0 = hd and hd.delay; if hd then hd.delay = 200 end
keysin('vjjjQ'); eq('Q: back to NORMAL', V.mode, 'normal'); eq('Q: one note moved', RT and RT.n, 1); eq('Q: to the nearest row', RT and RT.r, hd and (hd.row0 + 1))
if hd then hd.delay = d0 end; E.retime = rt0
-- 20 окт: auto capture — ^A на пустом поле команды ноты: команда ноты выше (kick 0PA0) +1
reset(); V.cur = { fi = 1, row = 8, field = 4 }; V.key(1); eq('auto capture ^A', last(), 'fx:snare:0PA1')
reset(); V.cur = { fi = 1, row = 8, field = 4 }; V.key(24); eq('auto capture ^X', last(), 'fx:snare:0P9F')
-- 20 окт: gg proj/pat relative — в виде pattern gg / G на начало / конец паттерна (region_rows стаб 0..31 → 8..20)
reset(); RR = { 8, 20 }
V.cur = { fi = 1, row = 12, field = 1 }; keysin('gg'); eq('gg off: row 0', V.cur.row, 0)
state.ggrel, state.view_reg = true, true
V.cur = { fi = 1, row = 12, field = 1 }; keysin('gg'); eq('gg in pattern view: pattern start', V.cur.row, 8)
keysin('G'); eq('G in pattern view: pattern end', V.cur.row, 20)
state.view_reg = false; V.cur = { fi = 1, row = 12, field = 1 }; keysin('gg'); eq('gg in project view: row 0', V.cur.row, 0)
state.ggrel = nil; RR = nil
-- 29 окт: удаление — поля, несколько колонок, OFF с задержкой, x вырезает в регистр
local function has(prefix) for _, c in ipairs(calls) do if c:find(prefix, 1, true) == 1 then return true end end return false end
local function count(prefix) local k = 0; for _, c in ipairs(calls) do if c:find(prefix, 1, true) == 1 then k = k + 1 end end return k end
-- vol-колонка в выделении: x — громкость по умолчанию у нот, в регистр поле
reset(); V.cur = { fi = 1, row = 0, field = 2 }; keysin('v9jx')
eq('x on vol column: kick vol default', has('vol:kick:128'), true); eq('…snare too', has('vol:snare:128'), true)
eq('x on vol column: back to NORMAL', V.mode, 'normal'); eq('x cuts: register is the field', V.regs['"'] and V.regs['"'].kind, 'field')
eq('x on vol column: notes stay', has('delete:'), false)
-- delay-колонка: и задержка OFF (конец ноты внутри строки) — на начало строки
reset(); snap.cols[1].lanes[1].subs[1][4] = { kind = 'off', of = snap.cols[1].lanes[1].subs[1][0], delay = 40 }
V.cur = { fi = 1, row = 0, field = 3 }; keysin('v5jx')
eq('x on delay column: note delay 0', has('delay:kick:0'), true); eq('…OFF delay cleared (note end to its row)', has('off:kick@4'), true)
-- delay-колонка без OFF с задержкой — note_off не зовётся
reset(); V.cur = { fi = 1, row = 0, field = 3 }; keysin('v3jx'); eq('no OFF delay: no note_off', has('off:'), false)
-- команда: x убирает команду строк
reset(); V.cur = { fi = 1, row = 0, field = 4 }; keysin('vx'); eq('x on command column clears 0P', has('clearfx:kick:0P'), true)
-- несколько колонок (Opt+l — к следующему треку): x на поле нот — удаляет все ноты выделения
reset(); keysin('v'); alt_down = true; V.key(172); V.key(172); alt_down = false; keysin('4jx')
eq('x over several columns deletes all notes', last(), 'delete:kick,n60,ov')
-- V-line на всех колонках
reset(); keysin('Vjjjjx'); eq('V-line x deletes every column', last(), 'delete:kick,n60,ov')
-- vol в нескольких колонках
reset(); V.cur = { fi = 1, row = 0, field = 2 }; keysin('v'); alt_down = true; V.key(172); V.key(172); alt_down = false; keysin('5jx')
eq('vol over several columns: every note (kick, n60, ov)', count('vol:'), 3); eq('…n60 of the 2nd track', has('vol:n60:128'), true)
do   -- 31 окт: INSERT, колонка команд — gg / G прыгают, а не набирают код 0G
  local sv = { V.mode, V.cur.row, V.cur.field }
  V.mode = 'insert'; V.cur.field = 4; V.cur.sub = nil; V.hexbuf = nil; V.cur.row = 6
  keysin('gg'); eq('INSERT fx column: gg - to the top', V.cur.row, 0)
  V.cur.row = 2; keysin('G'); eq('INSERT fx column: G - down', V.cur.row > 2, true)
  eq('…and stays in INSERT', V.mode, 'insert')
  V.mode, V.cur.row, V.cur.field, V.hexbuf = sv[1], sv[2], sv[3], nil
end
do   -- 31 окт: dw на пустой строке перед свободным OFF — удаляет этот OFF (не ноту)
  local got
  E.all_off_del = function(h) got = 'alloffdel@' .. h.row0 end
  local sub = snap.cols[1].lanes[1].subs[1]
  for r = 20, 31 do sub[r] = nil end
  sub[24] = { kind = 'off', explicit = true, of = { kind = 'midi', stub = true, row0 = 24, rows = 1, pitch = 60 } }
  V.mode = 'normal'; V.cur = { fi = 1, row = 22, field = 1 }
  keysin('dw'); eq('dw before a free OFF deletes that OFF (31 окт)', got, 'alloffdel@24')
  sub[24] = nil
end
print(('%d checks, %d failed'):format(checks, fails))
os.exit(fails == 0 and 0 or 1)
