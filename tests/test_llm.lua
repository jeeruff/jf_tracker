-- tests/test_llm.lua — мост к модели (10 окт): разбор запроса, шаги run, клавиши, справка, снимок
local DIR = '.'
local LLM = dofile(DIR .. '/jf_tracker_llm.lua')
local fails = 0
local function eq(a, b, msg) if a ~= b then fails = fails + 1; print('FAIL ' .. msg .. ': ' .. tostring(a) .. ' ~= ' .. tostring(b)) end end

local id, op, pl = LLM.parse('42|run|:note C-4;;keys:jj')
eq(id, '42', 'id'); eq(op, 'run', 'op'); eq(pl, ':note C-4;;keys:jj', 'payload')
id, op, pl = LLM.parse('7|state')
eq(op, 'state', 'op no payload'); eq(pl, '', 'empty payload')
eq(LLM.parse(''), nil, 'empty')

local st = LLM.split_run(':note C-4 ;; keys:j<esc> ;; lpb 8 ;;  ')
eq(#st, 3, 'steps'); eq(st[1].kind, 'cmd', 'cmd kind'); eq(st[1].text, 'note C-4', 'colon stripped')
eq(st[2].kind, 'keys', 'keys kind'); eq(st[2].text, 'j<esc>', 'keys text'); eq(st[3].text, 'lpb 8', 'no colon')

local kc = LLM.key_codes('a<esc><cr><up>x<bogus')
eq(kc[1], 97, 'a'); eq(kc[2], 27, 'esc'); eq(kc[3], 13, 'cr'); eq(kc[4], 30064, 'up'); eq(kc[5], 120, 'x'); eq(kc[6], 60, '< literal')

local KH = { PAGES = { tracker = { title = 'tracker', e = { { k = ':lpb N', d = 'rows per beat' }, { k = 'j', d = 'down' } } } } }
local h = LLM.help_text(KH, '')
eq(h:find(':lpb N', 1, true) ~= nil, true, 'help lists :commands'); eq(h:find('  j ', 1, true), nil, 'help skips plain keys')
eq(LLM.help_text(KH, 'tracker'):find('down', 1, true) ~= nil, true, 'help page')

-- снимок: два трека, нота в строке 2, регион 0..8
local item = {}
local snap = { cols = { { name = 'A', track = 1, lanes = { {} }, pool = { { name = 'kick' } } }, { name = 'B', track = 2, lanes = { {} }, pool = {} } },
               inst_of = { [item] = 1 } }
local L = { flat = { { col = snap.cols[1], lane = {}, si = 1, sub = { [2] = { kind = 'audio', note = 'C-4', vol = '80', item = item }, [3] = { kind = 'cont' } } },
                     { col = snap.cols[2], lane = {}, si = 1, sub = {} } } }
local txt = LLM.state_text({ snap = snap, L = L, vim = { cur = { row = 1 }, inst = 1, mode = 'normal' }, state = { lpb = 4, focus = 'tracker' },
  seq = { { name = 'intro', r0 = 0, r1 = 8 } }, cur_col = function() return snap.cols[1] end, bpm = 120 })
eq(txt:find('0002 | C-4 01 80 | ...', 1, true) ~= nil, true, 'note row')
eq(txt:find('0003 | | | ...', 1, true) ~= nil, true, 'hold row')
eq(txt:find('slot 1 "intro" rows 0-7', 1, true) ~= nil, true, 'slot listed')
eq(txt:find('01 kick', 1, true) ~= nil, true, 'lib listed')

if fails == 0 then print('test_llm: ok') else print('test_llm: ' .. fails .. ' FAIL'); os.exit(1) end
