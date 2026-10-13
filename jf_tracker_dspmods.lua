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
    -- первая колонка (9 окт, часть 2) — волна деки: срезы, выбранный —
    -- янтарём, головки играющих голосов — зелёным (gmem jf_slixer)
    match = 'jf_slixer',
    title = 'slixer',
    cols = 4, rows = 6,                        -- 10 окт: волна — полосой сверху (не колонкой)
    view = 'slixer',
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
      { 'Input passthrough',     'input',   labels = { 'off', 'pass' } },   -- 11 окт: аудио трека сквозь slixer (Max capture — в окне плагина)

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
    -- ReaSamplOmatic5000 (2 окт; 10 окт — заново): волна — полосой сверху (start / end тянутся,
    -- ADSR поверх), над ней кнопки: режим freely / sample / note (named config MODE —
    -- в параметрах его нет), browse, item, list (файлы), detect pitch. Имена параметров —
    -- точные (TrackFX_GetParamName 7.x; «Mode» раньше находил «Round-robin mode»)
    match = 'reasamplomatic5000',
    title = 'RS5K',
    cols = 3,
    rs5k = true,
    wave = { start = 'sample start offset', stop = 'sample end offset' },
    params = {
      { 'Volume',                       'volume',   exact = true },
      { 'Pan',                          'pan',      exact = true },
      { 'Gain for minimum velocity',    'min vol' },
      { 'Note range start',             'note lo',  show = 'note' },
      { 'Note range end',               'note hi',  show = 'note' },
      { 'Pitch for start note',         'root',     show = 'root' },
      { 'Pitch adjust',                 'pitch' },
      { 'Pitchbend range',              'bend' },
      { 'Attack',                       'attack',   exact = true },
      { 'Decay',                        'decay',    exact = true },
      { 'Sustain',                      'sustain',  exact = true },
      { 'Release',                      'release',  exact = true },
      { 'Obey note-offs',               'note-off', labels = { 'off', 'on' } },
      { 'Loop (requires note-offs)',    'loop',     labels = { 'off', 'on' } },
      { 'Loop start offset',            'loop at' },
      { 'Crossfade loop length',        'xfade' },
      { 'Minimum velocity',             'vel lo',   exact = true },
      { 'Maximum velocity',             'vel hi',   exact = true },
      { 'Probability of hitting',       'chance' },
      { 'Round-robin mode',             'r-robin',  labels = { 'off', 'on' } },
      { 'Max voices',                   'voices' },
      { 'Portamento',                   'porta' },
      { 'MIDI channel',                 'channel',  show = 'chan' },
      { 'Sample start offset',          'start' },
      { 'Sample end offset',            'end' },
    },
  },
  {
    -- jf_phatfx (13 окт): много алгоритмов в одном — секциями по смыслу (заголовок над своими
    -- параметрами, поток по колонкам), XY-пэд фильтра (Pad X / Pad Y) первой колонкой, колонки шире
    match = 'jf_phatfx',
    title = 'phatfx',
    cols = 6, colw = 24,
    xy = { x = 'pad x', y = 'pad y (resonance)' },
    params = {
      { head = 'FILTER' },
      { 'Pad X', 'pad x', exact = true }, { 'Pad Y (Resonance)', 'pad y', exact = true }, { 'Filter Mode', 'mode', exact = true },
      { 'Pad Jitter', 'jitter', exact = true }, { 'Pad Chaos', 'chaos', exact = true },
      { head = 'DRIVE' },
      { 'Drive', 'drive', exact = true }, { 'Drive Type', 'type', exact = true }, { 'Drive Bias', 'bias', exact = true },
      { 'Drive Tone', 'tone', exact = true }, { 'Drive Dry/Wet', 'dry/wet', exact = true },
      { head = 'CRUSH' },
      { 'Crush', 'crush', exact = true }, { 'Crush Type', 'type', exact = true }, { 'Crush Mix', 'mix', exact = true }, { 'Crush Downsample', 'downsample', exact = true },
      { head = 'COMP' },
      { 'Comp', 'comp', exact = true }, { 'Comp Type', 'type', exact = true }, { 'Comp Attack', 'attack', exact = true },
      { 'Comp Release', 'release', exact = true }, { 'Comp Dry/Wet', 'dry/wet', exact = true },
      { head = 'PITCH' },
      { 'Pitch Mode', 'mode', exact = true }, { 'Pitch (semitones)', 'semi', exact = true }, { 'Pitch Fine (cents)', 'fine', exact = true }, { 'Pitch Mix', 'mix', exact = true },
      { 'Pitch 2 Mode', 'mode 2', exact = true }, { 'Pitch 2 (semitones)', 'semi 2', exact = true }, { 'Pitch 2 Fine (cents)', 'fine 2', exact = true }, { 'Pitch 2 Mix', 'mix 2', exact = true },
      { head = 'MOD' },
      { 'ModFX Type', 'type', exact = true }, { 'ModFX Amount', 'amount', exact = true }, { 'ModFX Rate (Hz)', 'rate', exact = true },
      { 'ModFX Depth', 'depth', exact = true }, { 'ModFX Feedback', 'feedback', exact = true },
      { 'Autopan', 'autopan', exact = true }, { 'Autopan Rate (sync index)', 'pan rate', exact = true },
      { head = 'DELAY' },
      { 'Delay Mix', 'mix', exact = true }, { 'Delay Algorithm', 'algo', exact = true }, { 'Delay Time (sync index)', 'time', exact = true }, { 'Delay Feedback', 'feedback', exact = true },
      { head = 'REVERB' },
      { 'Reverb', 'reverb', exact = true }, { 'Reverb Algorithm', 'algo', exact = true }, { 'Reverb Size', 'size', exact = true },
      { 'Reverb Damping', 'damping', exact = true }, { 'Reverb Predelay (ms)', 'predelay', exact = true },
      { head = 'LFO' },
      { 'LFO Amount', 'amount', exact = true }, { 'LFO Dest', 'dest', exact = true }, { 'LFO Shape', 'shape', exact = true },
      { 'LFO Rate', 'rate', exact = true }, { 'LFO Free Rate (Hz)', 'free hz', exact = true },
      { head = 'MOTION' },
      { 'Motion Loop', 'loop', exact = true }, { 'Motion Record Arm', 'rec', exact = true }, { 'Motion Speed', 'speed', exact = true },
      { 'Motion Beatsync', 'sync', exact = true }, { 'Motion Return (s)', 'return', exact = true },
      { head = 'EQ / OUT' },
      { 'EQ Low (dB)', 'low', exact = true }, { 'EQ Mid (dB)', 'mid', exact = true }, { 'EQ High (dB)', 'high', exact = true },
      { 'Input (dB)', 'input', exact = true }, { 'Output (dB)', 'output', exact = true }, { 'Mix', 'mix', exact = true },
      { 'Compensate Loudness', 'loudness', exact = true }, { 'Morph A/B', 'morph', exact = true },
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
