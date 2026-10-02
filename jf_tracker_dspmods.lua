-- jf_tracker_dspmods.lua — реестр модулей DSP-панели. ФАЙЛ ПОЛЬЗОВАТЕЛЯ.
--
-- Эффект без записи здесь показывается «как есть»: первые параметры,
-- виджет по типу (тоггл / ступени / полоска). Запись в реестре — кураторский
-- вид: какие параметры показать, в каком порядке, с какой подписью, в
-- сколько колонок. Параметры ищутся по ПОДСТРОКЕ имени (как его отдаёт
-- TrackFX_GetParamName), поэтому индексы слайдеров не важны.
--
-- match — подстрока имени FX (без префикса «JS: » / «VST: »), без регистра.

local DM = {}

DM.modules = {
  {
    match = 'jf_slixer',
    title = 'slixer',
    cols = 2,
    params = {
      { 'Slice mode',            'slice mode' },
      { 'Transient sensitivity', 'sens' },
      { 'Equal parts',           'parts' },
      { 'Zero-cross',            'zero-x' },
      { 'Trigger mode',          'trigger' },
      { 'LOOP',                  'loop' },
      { 'Stretch (all slices)',  'stretch' },
      { 'Master gain',           'gain' },
      { 'Voice mode',            'voice' },
      { 'Legato',                'legato' },
      { 'Glide',                 'glide' },
      { 'Input quantize',        'quantize' },
      { 'ARP: on',               'arp' },
      { 'ARP: rate',             'arp rate' },
      { 'ARP: order',            'arp order' },
      { 'FX dry/wet',            'dry/wet' },
    },
  },
  {
    -- ReaSamplOmatic5000 (2 окт): первая колонка — волна сэмпла с ручками
    -- start / end (wave = подстроки этих параметров), правее — главное
    match = 'reasamplomatic5000',
    title = 'RS5K',
    cols = 3,
    wave = { start = 'sample start offset', stop = 'sample end offset' },
    params = {
      { 'Volume',              'volume' },
      { 'Pan',                 'pan' },
      { 'Note range start',    'note lo' },
      { 'Note range end',      'note hi' },
      { 'Pitch for start',     'root' },
      { 'Pitch offset',        'pitch' },
      { 'Mode',                'mode' },
      { '# of voices',         'voices' },
      { 'Attack',              'attack' },
      { 'Decay',               'decay' },
      { 'Sustain',             'sustain' },
      { 'Release',             'release' },
      { 'Obey note-offs',      'note-off' },
      { 'Loop',                'loop' },
      { 'Sample start offset', 'start' },
      { 'Sample end offset',   'end' },
    },
  },
  {
    -- TG33 / SY22 vector (2 окт): первая колонка — XY-пэд вектора (CC16 / CC17),
    -- тянется мышью одним жестом; xy = подстроки параметров X и Y
    match = 'jf_tg33_xy',
    title = 'TG33 vector',
    cols = 3,
    xy = { x = 'vector x', y = 'vector y' },
    params = {
      { 'Vector X',           'x' },
      { 'Vector Y',           'y' },
      { 'Gesture Loop',       'loop' },
      { 'Gesture Record Arm', 'rec' },
      { 'Gesture Speed',      'speed' },
      { 'Beatsync',           'beatsync' },
      { 'Variate Amount',     'variate %' },
      { 'Variate',            'variate' },
      { 'Glitch',             'glitch' },
      { 'Return Time',        'return' },
      { 'Program',            'program' },
      { 'FX Type',            'fx type' },
      { 'FX Balance',         'fx bal' },
      { 'MIDI Channel',       'channel' },
    },
  },
  {
    -- генератор гармонии (2 окт): аккорды с ноги, latch, сложность по CC
    match = 'jf_chord_latch',
    title = 'chord latch',
    cols = 2,
    params = {
      { 'Complexity (via CC)',  'complexity' },
      { 'Style',                'style' },
      { 'Voicing Order',        'order' },
      { 'Pool Window Size',     'window' },
      { 'Voicing Spread',       'spread' },
      { 'Hold Mode',            'hold' },
      { 'Transpose',            'octave' },
      { 'Fixed Velocity',       'velocity' },
      { 'Articulation Preset',  'articul.' },
      { 'Fade In / Attack',     'attack' },
      { 'Fade Out / Release',   'release' },
      { 'Full Auto',            'auto' },
      { 'Auto Chord Duration',  'auto dur' },
      { 'Slow Arp (drip',       'arp' },
      { 'Slow Arp Interval',    'arp rate' },
      { 'Latch Wall Mode',      'wall' },
    },
  },
  {
    match = 'reaeq',
    title = 'ReaEQ',
    cols = 2,
    params = {
      { 'Freq-Low Shelf', 'lo freq' }, { 'Gain-Low Shelf', 'lo gain' },
      { 'Freq-Band 2', 'b2 freq' }, { 'Gain-Band 2', 'b2 gain' },
      { 'Freq-Band 3', 'b3 freq' }, { 'Gain-Band 3', 'b3 gain' },
      { 'Freq-High Shelf', 'hi freq' }, { 'Gain-High Shelf', 'hi gain' },
    },
  },
}

-- найти запись по имени FX
function DM.match(fxname)
  local n = (fxname or ''):lower()
  for _, m in ipairs(DM.modules) do
    if n:find(m.match, 1, true) then return m end
  end
  return nil
end

return DM
