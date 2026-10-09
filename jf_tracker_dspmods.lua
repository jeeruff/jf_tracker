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
    -- slixer (9 окт): пульт — колонка = группа (заголовок над ней), по 6
    -- строк; переключатели — словами (labels), не квадратиками
    match = 'jf_slixer',
    title = 'slixer',
    cols = 4, rows = 6,
    groups = { 'SLICE', 'PLAY', 'LEVEL', 'ARP / TIME' },
    params = {
      { 'Slice mode',            'mode',    labels = { 'trans', 'equal', 'pitch' } },
      { 'Transient sensitivity', 'sens' },
      { 'Equal parts',           'parts' },
      { 'Pitch-change sens',     'pitch s' },
      { 'Zero-cross',            'zero-x',  labels = { 'off', 'on' } },
      { 'Q by transients',       'q trans', labels = { 'off', 'on' } },

      { 'Trigger mode',          'trigger', labels = { '1shot', 'gate' } },
      { 'LOOP',                  'loop',    labels = { 'off', 'on' } },
      { 'Voice mode',            'voice',   labels = { 'poly', 'mono' } },
      { 'Legato',                'legato',  labels = { 'off', 'on' } },
      { 'Glide',                 'glide' },
      { 'Slice pre-roll',        'pre-roll' },

      { 'Master gain',           'gain' },
      { 'Stretch (all slices)',  'stretch' },
      { 'FX dry/wet',            'dry/wet' },
      { 'Playthrough',           'thru',    labels = { 'off', 'on' } },
      { 'Pitch wheel range',     'bend' },
      { 'Max capture',           'capture' },

      { 'ARP: on',               'arp',     labels = { 'off', 'on' } },
      { 'ARP: rate',             'rate',    labels = { '1', '2', '4', '8', '8T', '16', '32' } },
      { 'ARP: order',            'order',   labels = { 'up', 'dn', 'ud', 'rnd', 'pl' } },
      { 'ARP: gate',             'gate' },
      { 'Input quantize',        'quant',   labels = { 'off', '32', '16T', '16', '8T', '8', '4' } },
      { 'Lock loop to project',  'tl sync', labels = { 'off', 'on' } },
    },
  },
  {
    -- jf_rec (4 окт): ретро-буфер прямо в DSP — первая колонка: волна кольца
    -- (старое слева, голова справа), выделение протяжкой, буквы all / play /
    -- stop / put / lib — те же действия, что во вкладке rec
    match = 'jf_rec',
    title = 'rec',
    cols = 2,
    view = 'rec',
    params = {
      { 'view', 'view' },
    },
  },
  {
    -- гранулятор (2 окт): первая колонка — облако вживую из gmem jf_grgrain
    -- (16 колонок волны, зёрна, окно зума, голова записи); тянуть по нему =
    -- нативный параметр Position
    match = 'jf_grgrain',
    title = 'grain',
    cols = 3,
    view = 'grain', view_param = 'position',
    params = {
      { 'Position',              'position' },
      { 'Grain Size',            'size' },
      { 'Density',               'density' },
      { 'Spray',                 'spray' },
      { 'Pitch (semitones)',     'pitch' },
      { 'Pitch Jitter',          'pitch jit' },
      { 'Size Jitter',           'size jit' },
      { 'Reverse Grains',        'reverse' },
      { 'Grain Shape',           'shape' },
      { 'Position Drift',        'drift' },
      { 'Stereo Spread',         'spread' },
      { 'Freeze Buffer',         'freeze' },
      { 'Feedback into Buffer',  'feedback' },
      { 'Cloud Filter',          'filter' },
      { 'Filter Reso',           'reso' },
      { 'Pitch Quantize',        'quantize' },
      { 'Zoom',                  'zoom' },
      { 'Record',                'record' },
      { 'Follow track audio',    'follow' },
      { 'Mix',                   'mix' },
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
    -- chord follow (8 окт): ноты трека — к аккорду лейна аккордов трекера (:chord)
    match = 'jf_tracker_chordfollow',
    title = 'chord follow',
    cols = 1,
    params = {
      { 'Mode',            'mode' },
      { 'Range',           'range' },
      { 'Bass split',      'bass split' },
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
    -- ReaEQ (4 окт): кривая АЧХ по полосам (вид eq), параметры — f g q полос
    match = 'reaeq',
    title = 'ReaEQ',
    -- 7 окт: полосы — из имён параметров (Freq- / Gain- / BW-<полоса>), любое
    -- число и тип (пресет на 11 полос зовёт их «Band (alt 2) N»); список ниже — запасной
    dyn_eq = true,
    cols = 3,
    view = 'eq',
    params = {
      { 'Freq-Low Shelf', '1 lo f' }, { 'Gain-Low Shelf', '1 lo g' }, { 'BW-Low Shelf', '1 lo q' },
      { 'Freq-Band 2', '2 f' }, { 'Gain-Band 2', '2 g' }, { 'BW-Band 2', '2 q' },
      { 'Freq-Band 3', '3 f' }, { 'Gain-Band 3', '3 g' }, { 'BW-Band 3', '3 q' },
      { 'Freq-High Shelf', '4 hi f' }, { 'Gain-High Shelf', '4 hi g' }, { 'BW-High Shelf', '4 hi q' },
      { 'Global Gain', 'gain' },
    },
  },
  {
    -- ReaXcomp (4 окт): полосы по частоте, порог и ratio каждой (вид xcomp)
    match = 'reaxcomp',
    title = 'ReaXcomp',
    cols = 3,
    view = 'xcomp',
    params = {
      { '1-Band top frequency', '1 top' }, { '1-Threshold', '1 thr' }, { '1-Ratio', '1 ratio' }, { '1-Gain', '1 gain' },
      { '2-Band top frequency', '2 top' }, { '2-Threshold', '2 thr' }, { '2-Ratio', '2 ratio' }, { '2-Gain', '2 gain' },
      { '3-Band top frequency', '3 top' }, { '3-Threshold', '3 thr' }, { '3-Ratio', '3 ratio' }, { '3-Gain', '3 gain' },
      { '4-Band top frequency', '4 top' }, { '4-Threshold', '4 thr' }, { '4-Ratio', '4 ratio' }, { '4-Gain', '4 gain' },
    },
  },
  {
    -- ReaComp (4 окт): кривая компрессии (вид comp)
    match = 'reacomp',
    title = 'ReaComp',
    cols = 3,
    view = 'comp',
    params = {
      { 'Threshold', 'thresh' }, { 'Ratio', 'ratio' }, { 'Knee', 'knee' },
      { 'Attack', 'attack' }, { 'Release', 'release' }, { 'Pre-comp', 'pre-comp' },
      { 'RMS size', 'rms' }, { 'Auto Make Up', 'auto gain' }, { 'Auto Release', 'auto rel' },
      { 'Lowpass', 'det lp' }, { 'Hipass', 'det hp' }, { 'Dry', 'dry' }, { 'Wet', 'wet' },
    },
  },
  {
    -- ReaDelay (4 окт): повторы на шкале времени (вид delay)
    match = 'readelay',
    title = 'ReaDelay',
    cols = 2,
    view = 'delay',
    params = {
      { '1: Length (musical)', 'length' }, { '1: Feedback', 'feedback' }, { '1: Length (time)', 'ms' },
      { '1: Lowpass', 'lowpass' }, { '1: Hipass', 'hipass' }, { '1: Stereo width', 'width' },
      { '1: Pan', 'pan' }, { 'Wet', 'wet' }, { 'Dry', 'dry' },
    },
  },
  {
    -- ReaVerbate (4 окт): комната — размер, затухание, ширина (вид verb)
    match = 'reaverbate',
    title = 'ReaVerbate',
    cols = 2,
    view = 'verb',
    params = {
      { 'Room size', 'room' }, { 'Dampening', 'damp' }, { 'Width', 'width' }, { 'Delay', 'pre-delay' },
      { 'Lowpass', 'lowpass' }, { 'Hipass', 'hipass' }, { 'Wet', 'wet' }, { 'Dry', 'dry' },
    },
  },
  {
    -- ReaGate (4 окт): шкала уровня с порогом (вид gate)
    match = 'reagate',
    title = 'ReaGate',
    cols = 2,
    view = 'gate',
    params = {
      { 'Threshold', 'thresh' }, { 'Hysteresis', 'hyst' }, { 'Attack', 'attack' }, { 'Hold', 'hold' },
      { 'Release', 'release' }, { 'Pre-open', 'pre-open' }, { 'Lowpass', 'det lp' }, { 'Hipass', 'det hp' }, { 'Wet', 'wet' }, { 'Dry', 'dry' },
    },
  },
  {
    -- ReaLimit (4 окт): порог и потолок на шкале (вид limit)
    match = 'realimit',
    title = 'ReaLimit',
    cols = 2,
    view = 'limit',
    params = { { 'Threshold', 'thresh' }, { 'Ceiling', 'ceiling' }, { 'Release', 'release' } },
  },
  {
    -- Amigo Sampler (PotenzaDSP, 5 окт): лента сэмпла — Start / End / Loop
    -- Start, режимы и Sample Rate лоу-фай шкалой (вид amigo); 2184 параметра
    -- плагина — в основном MIDI-назначения, здесь только звук
    match = 'amigo',
    title = 'Amigo',
    cols = 3,
    view = 'amigo',
    params = {
      { 'Sample Start', 'start' }, { 'Sample End', 'end' }, { 'Loop Start', 'loop at' }, { 'Loop', 'loop', exact = true },
      { 'Sample Rate', 'rate hz' }, { 'Lin Interp', 'smooth' }, { 'Pitch', 'pitch' }, { 'Finetune', 'fine' },
      { 'Base Note', 'base' }, { 'Volume', 'volume' }, { 'Attack', 'attack' }, { 'Release', 'release' },
      { 'Gate', 'gate' }, { 'Reverse', 'reverse' }, { 'Ping Pong', 'ping pong' }, { 'Slice Mode', 'mode' },
      { 'Polyphony', 'poly' }, { 'Glide', 'glide' }, { 'Chord', 'chord' }, { 'Hold', 'hold' },
      { 'Velocity', 'velocity' }, { 'Stretch', 'stretch' }, { 'Stretch Length', 'str len' }, { 'Cycle Length', 'cycle' },
      { 'LFO Amount', 'lfo amt' }, { 'LFO Rate', 'lfo rate' }, { 'LFO Shape', 'lfo shape' }, { 'LFO Modulation', 'lfo to' },
    },
  },
  {
    -- ReaVerb (5 окт): спектрограмма импульса (вид ir); после ReaVerbate в
    -- списке — «reaverb» — подстрока «reaverbate»
    match = 'reaverb',
    title = 'ReaVerb',
    cols = 2,
    view = 'ir',
    params = { { 'Wet', 'wet' }, { 'Dry', 'dry' }, { 'Pre-verb', 'pre-verb' }, { 'Width', 'width' }, { 'Pan', 'pan' } },
  },
  {
    -- ReaPitch (4 окт): сдвиг — полутоны, центы, октавы, форманта
    match = 'reapitch',
    title = 'ReaPitch',
    cols = 2,
    params = {
      { '1: Shift (semitones)', 'semis' }, { '1: Shift (cents)', 'cents' }, { '1: Shift (oct)', 'oct' },
      { '1: Formant adjust (semitones)', 'formant' }, { '1: Volume', 'volume' }, { '1: Pan', 'pan' }, { 'Wet', 'wet' }, { 'Dry', 'dry' },
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
