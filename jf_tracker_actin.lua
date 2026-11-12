-- jf_tracker_actin.lua (12 ноя) — вход с контроллера через экшены REAPER (нативный MIDI / OSC learn).
--
-- Своих привязок у трекера нет: в actions/ лежит по скрипту на цель, их учит сам REAPER (Actions → shortcut /
-- MIDI CC / OSC) — привязки глобальные, едут во все проекты. Скрипт читает get_action_context (режим,
-- разрешение, значение) и дописывает строку «цель режим разрешение значение» в ExtState jf_tracker/in;
-- трекер в кадре забирает их (AI.parse) и применяет к слайдеру (AI.apply): цель value — слайдер под
-- курсором модуля в фокусе (reform, humanizer …), next / prev — курсор по строкам, enter — Enter модуля,
-- reform:scale и подобные — конкретная строка модуля.
-- Слайдер — { min, max, step, get, set, toggle } (строки RF.ROWS / HU.ROWS как есть).
-- Без reaper.*: тест tests/test_actin.lua.
local AI = {}

-- экшены: файл actions/jf_tracker_<file>.lua, имя для списка экшенов REAPER
AI.ACTIONS = {
  { file = 'value', target = 'value', label = 'value of the slider under the cursor (knob)' },
  { file = 'next', target = 'next', label = 'next slider (button)' },
  { file = 'prev', target = 'prev', label = 'previous slider (button)' },
  { file = 'enter', target = 'enter', label = 'Enter in the pane in focus: keep / apply (button)' },
  { file = 'reform_scale', target = 'reform:scale', label = 'reform: time scale (knob)' },
  { file = 'reform_curve', target = 'reform:curve', label = 'reform: time curve (knob)' },
  { file = 'reform_shift', target = 'reform:shift', label = 'reform: shift by rows (knob)' },
  { file = 'human_amt', target = 'humanizer:amt', label = 'humanizer: amount (knob)' },
}

-- текст ExtState → список событий { target, mode, res, val } (строка на событие; мусор пропускается)
function AI.parse(s)
  local out = {}
  for line in (s or ''):gmatch('[^\n]+') do
    local target, mode, res, val = line:match('^(%S+)%s+(%-?%d+)%s+(%d+)%s+(%-?[%d%.]+)')
    if target then out[#out + 1] = { target = target, mode = tonumber(mode), res = tonumber(res), val = tonumber(val) } end
  end
  return out
end

-- относительные энкодеры: режим 1 — 127 = -1 (дополнительный код), 2 — 63 = -1 (64 ± n), 3 — 65 = -1 (знак в 7-м бите)
function AI.delta(mode, val)
  if mode == 1 then return val >= 64 and val - 128 or val end
  if mode == 2 then return val - 64 end
  if mode == 3 then return val >= 64 and -(val - 64) or val end
  return 0
end

local function clamp(r, v) return math.max(r.min, math.min(r.max, v)) end
local function quant(r, v)
  if r.step >= 1 then return math.floor(v + 0.5) end
  return math.floor(v / r.step + 0.5) * r.step
end

-- событие → слайдер; get() / set(v) — значение; → true, если значение сменилось
-- abs (режим 0, OSC — тоже): доля val / res по диапазону; rel: шаг строки на щелчок энкодера
function AI.apply(sl, mode, res, val)
  local cur = sl.get()
  if sl.toggle then
    local on
    if mode == 0 or mode == -1 then on = val >= (res or 127) / 2 else local d = AI.delta(mode, val); if d == 0 then return false end; on = d > 0 end
    if on == (cur and true or false) then return false end
    sl.set(on); return true
  end
  local v
  if mode == 0 or mode == -1 then
    local frac = math.max(0, math.min(1, val / math.max(1, res or 127)))
    v = quant(sl, sl.min + frac * (sl.max - sl.min))
  else
    local d = AI.delta(mode, val)
    if d == 0 then return false end
    v = quant(sl, (cur or sl.min) + d * sl.step)
  end
  v = clamp(sl, v)
  if v == cur then return false end
  sl.set(v); return true
end

-- текст экшен-скрипта (actions/jf_tracker_<file>.lua)
function AI.script(a)
  return ('-- jf_tracker: %s - an action for the native REAPER learn (MIDI CC / OSC / shortcut), 12 ноя.\n' ..
    '-- Значение → трекер через ExtState jf_tracker/in (строка «цель режим разрешение значение»).\n' ..
    'local _, _, _, _, mode, res, val = reaper.get_action_context()\n' ..
    'reaper.SetExtState(\'jf_tracker\', \'in\', reaper.GetExtState(\'jf_tracker\', \'in\') .. (\'%s %%d %%d %%s\\n\'):format(mode or -1, res or 127, tostring(val or 0)), false)\n'):format(a.label, a.target)
end

return AI
