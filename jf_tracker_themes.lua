-- jf_tracker_themes.lua — темы трекера (3 окт).
--
-- reaper (по умолчанию) — нативная палитра: цвета темы REAPER, ничего не
-- подменяется. Остальные — для полноэкранной работы, где единство с REAPER
-- не так важно, а эстетика — очень: modus vivendi / operandi (Протесилаос
-- Ставру), gruvbox dark, catppuccin mocha, mono — всё в оттенках серого,
-- кроме ячейки курсора.
--
-- TH.apply(U, name) переписывает базовые цвета U (BG PANEL TEXT GREY DIM LINE
-- AMBER CYAN GREEN RED) и фон шапок (U.HDR / U.HDRSEL); производные цвета
-- пересчитывает draw.init. Цвета треков, items, регионов — свои у проекта,
-- темы их не трогают (в mono их гасит серый фильтр отрисовки).
-- Без reaper.*: тестируется tests/test_themes.lua.

local TH = {}

TH.LIST = { 'reaper', 'modus-vivendi', 'modus-operandi', 'gruvbox', 'catppuccin', 'mono' }

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
  gruvbox = { bg = '#282828', panel = '#32302f', text = '#ebdbb2', grey = '#a89984', dim = '#3c3836', line = '#665c54',
    amber = '#fe8019', cyan = '#8ec07c', green = '#b8bb26', red = '#fb4934', hdr = '#3c3836', hdrsel = '#504945' },
  catppuccin = { bg = '#1e1e2e', panel = '#181825', text = '#cdd6f4', grey = '#a6adc8', dim = '#313244', line = '#585b70',
    amber = '#fab387', cyan = '#94e2d5', green = '#a6e3a1', red = '#f38ba8', hdr = '#313244', hdrsel = '#45475a' },
  mono = { bg = '#101010', panel = '#181818', text = '#d8d8d8', grey = '#8c8c8c', dim = '#2c2c2c', line = '#5c5c5c',
    amber = '#e8e8e8', cyan = '#b4b4b4', green = '#c8c8c8', red = '#f4f4f4', hdr = '#262626', hdrsel = '#3a3a3a', mono = true },
}

-- цвет ячейки курсора в mono — единственное цветное (просьба 3 окт)
TH.MONO_CURSOR = hex('#ffb000')

function TH.valid(name) return name == 'reaper' or TH.PAL[name] ~= nil end

-- применить тему к U; false — reaper (нативная палитра, U не трогается)
function TH.apply(U, name)
  local p = TH.PAL[name or '']
  U.HDR, U.HDRSEL, U.MONO, U.MONO_CURSOR = nil, nil, nil, nil
  if not p then return false end
  U.BG, U.PANEL, U.TEXT, U.GREY = hex(p.bg), hex(p.panel), hex(p.text), hex(p.grey)
  U.DIM, U.LINE = hex(p.dim), hex(p.line)
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
