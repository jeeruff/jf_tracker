-- test_fxclass.lua — классификатор параметров без REAPER: lua tests/test_fxclass.lua
package.path = './?.lua;' .. package.path
local FC = dofile('jf_tracker_fxclass.lua')
local n, bad = 0, 0
local function eq(name, got, want)
  n = n + 1
  if got ~= want then bad = bad + 1; print(('FAIL %s: got %s, want %s'):format(name, tostring(got), tostring(want))) end
end
local function split(s) local g, b = FC.split(s); return g .. '|' .. b end

-- подгруппы
eq('amp1attack', split('amp1attack'), 'amp1|attack')
eq('f1cutoff', split('f1cutoff'), 'f1|cutoff')
eq('Osc 2 Pitch', split('Osc 2 Pitch'), 'osc 2|Pitch')
eq('LFO1 Rate', split('LFO1 Rate'), 'lfo1|Rate')
eq('Filter Cutoff', split('Filter Cutoff'), 'filter|Cutoff')
eq('ampAttack', split('ampAttack'), 'amp|Attack')
eq('plain Cutoff', split('Cutoff'), '|Cutoff')
eq('unknown first word kept', split('Room Size'), '|Room Size')

-- категории: единицы важнее имени
eq('dB -> gain', FC.class('Output', '-6.0 dB', 'slider'), 'gain')
eq('Hz -> filter', FC.class('Freq', '1200 Hz', 'slider'), 'filter')
eq('LFO Hz -> mod', FC.class('LFO Rate', '2.5 Hz', 'slider'), 'mod')
eq('ms -> time', FC.class('Thing', '35 ms', 'slider'), 'time')
eq('toggle -> mode', FC.class('Cutoff', '', 'toggle'), 'mode')
eq('name cutoff', FC.class('f1cutoff', '0.5', 'slider'), 'cutoff')   -- 2 ноя: своя категория
eq('filter freq is cutoff', FC.class('Filter 1 Freq', '0.5', 'slider'), 'cutoff')
eq('low cut is a filter', FC.class('Low Cut', '0.5', 'slider'), 'filter')
eq('reso stays filter', FC.class('Resonance', '0.5', 'slider'), 'filter')
eq('name attack', FC.class('amp1attack', '0.2', 'slider'), 'time')
eq('name ratio', FC.class('Ratio', '4.0:1', 'slider'), 'dyn')
eq('name pan', FC.class('Pan', 'C', 'slider'), 'stereo')
eq('name mix', FC.class('Dry/Wet', '50', 'slider'), 'mix')
eq('percent fallback mix', FC.class('Blorp', '50%', 'slider'), 'mix')
eq('other', FC.class('Blorp', '0.3', 'slider'), 'other')

-- служебное
eq('bypass junk', FC.junk('Bypass'), true); eq('wet junk', FC.junk('Wet'), true)
eq('midi cc junk', FC.junk('MIDI CC 7'), true); eq('param N junk', FC.junk('Param 12'), true)
eq('hidden jsfx junk', FC.junk('-Hidden'), true); eq('real param not junk', FC.junk('Cutoff'), false)

-- автомодуль: служебное выброшено, группы вместе, важное раньше
local list = {
  { i = 0, name = 'amp1attack', units = '5 ms', kind = 'slider' },
  { i = 1, name = 'f1cutoff', units = '800 Hz', kind = 'slider' },
  { i = 2, name = 'f1reso', units = '0.3', kind = 'slider' },
  { i = 3, name = 'Bypass', units = '', kind = 'toggle' },
  { i = 4, name = 'amp1release', units = '200 ms', kind = 'slider' },
  { i = 5, name = 'Master Volume', units = '-3 dB', kind = 'slider' },
  { i = 6, name = 'Param 7', units = '', kind = 'slider' },
}
local a = FC.auto(list, 10)
eq('auto drops junk', #a, 5)
local pos = {}
for k, it in ipairs(a) do pos[it.i] = k end
eq('f1 params together', math.abs(pos[1] - pos[2]), 1)
eq('amp1 params together', math.abs(pos[0] - pos[4]), 1)
eq('labels readable', a[pos[1]].name, 'f1 cutoff')
eq('category carried', a[pos[5]].cat, 'gain')
-- предел
eq('auto max', #FC.auto(list, 2), 2)

-- макро первыми (4 окт)
do
  local list = {
    { i = 0, name = 'Main Vol', units = '%', kind = 'slider' },
    { i = 1, name = 'Filter Cutoff', units = 'Hz', kind = 'slider' },
    { i = 2, name = 'Macro 2', units = '%', kind = 'slider' },
    { i = 3, name = 'Macro 1', units = '%', kind = 'slider' },
    { i = 4, name = 'Env 1 Attack', units = 'ms', kind = 'slider' },
  }
  local out = FC.auto(list, 4)
  eq('macro 1 first', out[1].i, 3)
  eq('macro 2 second', out[2].i, 2)
  eq('macros count in max', #out, 4)
  eq('macro8', FC.is_macro('macro8'), true)
  eq('not a numbered macro', FC.is_macro('Macro Depth'), false)
end
-- 22 окт: вкладки автомодуля
do
  eq('section: osc prefix', FC.section('Osc 2 Pitch'), 'osc')
  eq('section: lfo prefix beats rate', FC.section('LFO1 Rate'), 'lfo')
  eq('section: filter word', FC.section('Filter Cutoff'), 'filter')
  eq('section: env by attack', FC.section('Amp Attack'), 'env')
  eq('section: none', FC.section('Master Volume'), nil)
  local big = {}
  for k = 1, 10 do big[#big + 1] = { i = #big, name = 'Osc 1 Param' .. k, units = '' } end
  for k = 1, 10 do big[#big + 1] = { i = #big, name = 'Filter knob' .. k, units = '' } end
  for k = 1, 10 do big[#big + 1] = { i = #big, name = 'LFO1 Rate' .. k, units = '' } end
  local pg = FC.pages(big)
  eq('pages: main + 3 sections', pg and #pg, 4)
  eq('pages: main first', pg and pg[1].name, 'main')
  eq('pages: order osc filter lfo', pg and (pg[2].name .. ' ' .. pg[3].name .. ' ' .. pg[4].name), 'osc filter lfo')
  eq('pages: filter page has its 10', pg and #pg[3].items, 10)
  eq('pages: small plugin - no tabs', FC.pages({ { i = 0, name = 'Osc 1 Pitch' }, { i = 1, name = 'Filter Cutoff' } }), nil)
  local one = {}
  for k = 1, 30 do one[#one + 1] = { i = k, name = 'Knob ' .. k, units = '' } end
  eq('pages: no sections - no tabs', FC.pages(one), nil)
end
print(('%d checks, %d failed'):format(n, bad))
os.exit(bad == 0 and 0 or 1)
