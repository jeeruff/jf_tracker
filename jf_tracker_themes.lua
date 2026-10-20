-- jf_tracker_themes.lua — темы трекера (3 окт).
--
-- reaper (по умолчанию) — нативная палитра: цвета темы REAPER, ничего не
-- подменяется. Остальные — для полноэкранной работы, где единство с REAPER
-- не так важно, а эстетика — очень: modus vivendi / operandi (Протесилаос
-- Ставру), solarized dark / light, gruvbox dark, catppuccin mocha, mono — всё в оттенках серого,
-- кроме ячейки курсора; protracker — палитра ProTracker 2.
--
-- TH.apply(U, name) переписывает базовые цвета U (BG PANEL TEXT GREY DIM LINE
-- AMBER CYAN GREEN RED) и фон шапок (U.HDR / U.HDRSEL); производные цвета
-- пересчитывает draw.init. Цвета треков, items, регионов — свои у проекта,
-- темы их не трогают (в mono их гасит серый фильтр отрисовки).
-- Без reaper.*: тестируется tests/test_themes.lua.

local TH = {}

TH.LIST = { 'reaper', 'modus-vivendi', 'modus-operandi', 'solarized-dark', 'solarized-light', 'gruvbox', 'catppuccin', 'mono', 'protracker', 'impulse' }

local function hex(s)
  local r, g, b = s:match('#?(%x%x)(%x%x)(%x%x)')
  return { tonumber(r, 16) / 255, tonumber(g, 16) / 255, tonumber(b, 16) / 255 }
end

-- bg — окно, panel — панели, text / grey — текст / приглушённый, dim — линии
-- сетки, line — рамки, amber — акцент и курсор, cyan / green / red — роли
TH.PAL = {
  ['modus-vivendi'] = { bg = '#000000', panel = '#1e1e1e', text = '#ffffff', grey = '#989898', dim = '#303030', line = '#646464',
    amber = '#fec43f', cyan = '#00d3d0', green = '#44bc44', red = '#ff5f59', hdr = '#303030', hdrsel = '#535353' },
  ['modus-operandi'] = { bg = '#ffffff', panel = '#f2f2f2', text = '#000000', grey = '#595959', dim = '#d0d0d0', line = '#9f9f9f',
    amber = '#884900', cyan = '#005e8b', green = '#006800', red = '#a60000', hdr = '#e0e0e0', hdrsel = '#c4c4c4' },
  -- 20 окт: Solarized (Ethan Schoonover): base03..base3 и акценты как есть; текст на базу контрастнее канона
  -- (base2 / base02 — правило 7:1), приглушённый — base1 / base01; светлая — акцент orange (yellow 3:1 не держит);
  -- линии сетки — шаг от фона (своего тона в палитре нет)
  ['solarized-dark'] = { bg = '#002b36', panel = '#073642', text = '#eee8d5', grey = '#93a1a1', dim = '#0d3f4b', line = '#586e75',
    amber = '#b58900', cyan = '#2aa198', green = '#859900', red = '#dc322f', hdr = '#073642', hdrsel = '#1c4f5c' },
  ['solarized-light'] = { bg = '#fdf6e3', panel = '#eee8d5', text = '#073642', grey = '#586e75', dim = '#e6dfca', line = '#93a1a1',
    amber = '#cb4b16', cyan = '#2aa198', green = '#859900', red = '#dc322f', hdr = '#eee8d5', hdrsel = '#ddd6c1' },
  gruvbox = { bg = '#282828', panel = '#32302f', text = '#ebdbb2', grey = '#a89984', dim = '#3c3836', line = '#665c54',
    amber = '#fe8019', cyan = '#8ec07c', green = '#b8bb26', red = '#fb4934', hdr = '#3c3836', hdrsel = '#504945' },
  catppuccin = { bg = '#1e1e2e', panel = '#181825', text = '#cdd6f4', grey = '#a6adc8', dim = '#313244', line = '#585b70',
    amber = '#fab387', cyan = '#94e2d5', green = '#a6e3a1', red = '#f38ba8', hdr = '#313244', hdrsel = '#45475a' },
  mono = { bg = '#101010', panel = '#181818', text = '#d8d8d8', grey = '#969696', dim = '#2c2c2c', line = '#5c5c5c',
    amber = '#e8e8e8', cyan = '#b4b4b4', green = '#c8c8c8', red = '#f4f4f4', hdr = '#262626', hdrsel = '#3a3a3a', mono = true },
  -- ProTracker 2 (4 окт): чёрное поле паттерна, серые панели в духе Amiga,
  -- светло-серый текст, жёлтый акцент (скопы), синий, малиновый курсор PT
  protracker = { bg = '#000000', panel = '#3a3a3a', text = '#cccccc', grey = '#a0a0a0', dim = '#2a2a2a', line = '#888888',
    amber = '#ffdd88', cyan = '#7799ff', green = '#77cc77', red = '#dd0044', hdr = '#555555', hdrsel = '#888888' },
  -- Impulse Tracker (4 окт): чёрное поле, сине-серые панели DOS, жёлтая подсветка
  impulse = { bg = '#000000', panel = '#2c3a48', text = '#e0e4e8', grey = '#a8b4c0', dim = '#1a222c', line = '#7c8c9c',
    amber = '#ffd040', cyan = '#70c0e0', green = '#60d060', red = '#e04848', hdr = '#3a4a5a', hdrsel = '#56687a' },
}

-- цвет ячейки курсора в mono — единственное цветное (просьба 3 окт)
TH.MONO_CURSOR = hex('#ffb000')

-- свои темы (5 окт): файл Data/jf_tracker_themes/<имя>.txt, строки key = #rrggbb
-- (ключи как у PAL); main читает папку и зовёт TH.add
TH.KEYS = { 'bg', 'panel', 'text', 'grey', 'dim', 'line', 'amber', 'cyan', 'green', 'red', 'hdr', 'hdrsel' }
function TH.parse(txt)
  local p = {}
  for k, v in (txt or ''):gmatch('([%w_]+)%s*=%s*(#?%x%x%x%x%x%x)') do p[k:lower()] = v:sub(1, 1) == '#' and v or ('#' .. v) end
  for _, k in ipairs(TH.KEYS) do if not p[k] then return nil, 'missing ' .. k end end
  return p
end
function TH.add(name, p)
  TH.PAL[name] = p
  for _, n in ipairs(TH.LIST) do if n == name then return end end
  TH.LIST[#TH.LIST + 1] = name
end
-- палитра U → текст шаблона (для своей темы из текущей)
function TH.template(U, name)
  local function h(c) c = c or { 0, 0, 0 }; return ('#%02x%02x%02x'):format(math.floor(c[1] * 255 + 0.5), math.floor(c[2] * 255 + 0.5), math.floor(c[3] * 255 + 0.5)) end
  local src = { bg = U.BG, panel = U.PANEL, text = U.TEXT, grey = U.GREY, dim = U.DIM, line = U.LINE, amber = U.AMBER, cyan = U.CYAN,
                green = U.GREEN, red = U.RED, hdr = U.HDR or U.PANEL, hdrsel = U.HDRSEL or U.LINE }
  local out = { '# jf_tracker theme "' .. name .. '" - edit the colours, keep the keys; options -> theme -> reload my themes',
    '# bg window, panel panels, text / grey text and dimmed text, dim grid lines, line frames,',
    '# amber accent and cursor, cyan / green / red roles, hdr / hdrsel track header and selected header', '' }
  for _, k in ipairs(TH.KEYS) do out[#out + 1] = ('%-7s = %s'):format(k, h(src[k])) end
  return table.concat(out, '\n') .. '\n'
end

function TH.valid(name) return name == 'reaper' or TH.PAL[name] ~= nil end

-- применить тему к U; false — reaper (нативная палитра, U не трогается)
function TH.apply(U, name)
  local p = TH.PAL[name or '']
  U.HDR, U.HDRSEL, U.MONO, U.MONO_CURSOR = nil, nil, nil, nil
  if not p then return false end
  U.BG, U.PANEL, U.TEXT, U.GREY = hex(p.bg), hex(p.panel), hex(p.text), hex(p.grey)
  U.DIM, U.LINE = hex(p.dim), hex(p.line)
  -- 15 окт: DIM (третий уровень: пустые строки, отменённые шаги undo, «нет …») терялся — ярче на четверть пути к TEXT
  U.DIM = { U.DIM[1] + (U.TEXT[1] - U.DIM[1]) * 0.25, U.DIM[2] + (U.TEXT[2] - U.DIM[2]) * 0.25, U.DIM[3] + (U.TEXT[3] - U.DIM[3]) * 0.25 }
  -- 15 окт: подписи (GREY — второй уровень) на 10 % тише, во всех темах; уровни: TEXT важное, GREY второстепенное, DIM вспомогательное
  U.GREY = { U.GREY[1] * 0.9 + U.BG[1] * 0.1, U.GREY[2] * 0.9 + U.BG[2] * 0.1, U.GREY[3] * 0.9 + U.BG[3] * 0.1 }
  U.AMBER, U.CYAN, U.GREEN, U.RED = hex(p.amber), hex(p.cyan), hex(p.green), hex(p.red)
  U.HDR, U.HDRSEL = hex(p.hdr), hex(p.hdrsel)
  U.MONO = p.mono or nil
  U.MONO_CURSOR = p.mono and TH.MONO_CURSOR or nil
  return true
end

-- серый по яркости (mono)
function TH.grey(c)
  local l = 0.299 * c[1] + 0.587 * c[2] + 0.114 * c[3]
  return { l, l, l }
end

TH.hex = hex
return TH
