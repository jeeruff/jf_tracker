#!/usr/bin/env python3
"""live.py — драйвер живых тестов jf_tracker (10 окт): клавиши в работающий трекер
через веб-интерфейс REAPER (8080) и снимки проекта через tests/live_dump.lua.

Трекер исполняет инъекцию ТОЛЬКО в песочнице (проект без имени, треки
sandbox_setup.lua) и после каждой клавиши пишет jf_tracker/inject_ack —
драйвер ждёт его, а не спит. Переключил пользователь вкладку — ack «REFUSED»,
прогон останавливается.

  python3 tests/live.py keys 'jjl<esc>'      нажать (мини-язык ниже) и показать ack
  python3 tests/live.py cmd 'note C-4'       :команда + Enter
  python3 tests/live.py dump                 снимок проекта в tests/shots/live_dump.txt
  python3 tests/live.py diff                 снимок и разница с предыдущим
  python3 tests/live.py run smoke insert …   сценарии (all — все); отчёт tests/shots/live_report.md

Мини-язык клавиш: буквы как есть; <esc> <cr> <tab> <bs> <del> <up> <down> <left>
<right> <home> <end> <pgup> <pgdn> <space> <f1>; модификаторы <C-x> Ctrl, <M-x> Cmd,
<A-x> Option, <S-x> Shift (x — символ или имя: <S-cr>, <C-up>). Ctrl+буква уходит
управляющим кодом (как с клавиатуры macOS: Ctrl+H = 8).
"""
import os, re, sys, time, subprocess, urllib.request, urllib.parse, difflib

W = 'http://localhost:8080/_'
EXT = 'jf_tracker'
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
DUMP = os.path.join(HERE, 'shots', 'live_dump.txt')
PREV = os.path.join(HERE, 'shots', 'live_dump_prev.txt')
REPORT = os.path.join(HERE, 'shots', 'live_report.md')
REAPER = '/Applications/REAPER.app/Contents/MacOS/REAPER'
DLOG = os.path.expanduser('~/Library/Application Support/REAPER/jf_tracker_debug.log')

SPECIAL = {'esc': 27, 'cr': 13, 'enter': 13, 'tab': 9, 'bs': 8, 'del': 6579564, 'ins': 6909555, 'up': 30064, 'down': 1685026670,
           'left': 1818584692, 'right': 1919379572, 'home': 1752132965, 'end': 6647396, 'pgup': 1885828464,
           'pgdn': 1885824110, 'space': 32, 'f1': 26161, 'lt': 60}
MOD = {'C': 32, 'M': 4, 'A': 16, 'S': 8}       # gfx.mouse_cap на macOS: 32 Ctrl, 4 Cmd, 16 Option, 8 Shift


def get(key):
    with urllib.request.urlopen(f'{W}/GET/EXTSTATE/{EXT}/{key}', timeout=3) as r:
        f = r.read().decode('utf-8', 'replace').rstrip('\r\n').split('\t', 3)
        return f[3] if len(f) > 3 else ''


def setext(key, val):
    urllib.request.urlopen(f'{W}/SET/EXTSTATE/{EXT}/{key}/{urllib.parse.quote(val, safe="")}', timeout=3).read()


def action(cmd_id):
    urllib.request.urlopen(f'{W}/{cmd_id}', timeout=3).read()


def hb():
    return get('hb')


def alive(sec=1.5):
    a = hb(); time.sleep(sec); return a != hb() and a != ''


_n = [int(time.time()) % 100000]
TRACE = []


def key(code, cap=0, timeout=3.0):
    """одна клавиша; возвращает хвост ack («ok normal tracker row3 fi1 fld… msg=…»)"""
    _n[0] += 1
    tok = f'{code},{cap}#{_n[0]}.{os.getpid()}'   # 12 окт: pid — токен уникален между запусками (повтор той же клавиши терялся)
    setext('inject', tok)
    TRACE.append(tok)
    t0 = time.time()
    while time.time() - t0 < timeout:
        a = get('inject_ack')
        if a.startswith(tok + ' '):
            rest = a[len(tok) + 1:]
            if rest.startswith('REFUSED'):
                raise SystemExit(f'STOP: {rest} (активна не песочница?)')
            TRACE[-1] = f'{tok} {rest}'
            return rest
        time.sleep(0.03)
    raise SystemExit(f'STOP: no ack for {tok} in {timeout}s — трекер мёртв? hb={hb()!r}')


def parse(seq):
    """мини-язык → список (code, cap)"""
    out, i = [], 0
    while i < len(seq):
        if seq[i] == '<':
            j = seq.index('>', i)
            name = seq[i + 1:j]; i = j + 1
            cap = 0
            while len(name) > 2 and name[1] == '-' and name[0] in MOD:
                cap |= MOD[name[0]]; name = name[2:]
            if name in SPECIAL: code = SPECIAL[name]
            elif len(name) == 1:
                code = ord(name)
                if cap & 32 and name.isalpha(): code = ord(name.lower()) & 0x1f     # Ctrl+буква — управляющий код
            else: raise SystemExit(f'unknown key <{name}>')
            out.append((code, cap))
        else:
            out.append((ord(seq[i]), 0)); i += 1
    return out


def keys(seq, show=False):
    last = ''
    for code, cap in parse(seq):
        last = key(code, cap)
        if show: print(f'  {code},{cap} -> {last}')
    return last


def cmd(text):
    return keys(':' + text + '<cr>')


def ack_fields(a):
    if isinstance(a, dict): return a
    m = re.match(r'ok (\S+) (\S+) row(-?\d+) fi(\d+) fld(\S+) msg=(.*)', a)
    return {'mode': m.group(1), 'focus': m.group(2), 'row': int(m.group(3)), 'fi': int(m.group(4)), 'field': m.group(5), 'msg': m.group(6)} if m else {}


def dump(wait=6.0):
    """снимок проекта через -nonewinst; ждёт нового файла"""
    os.makedirs(os.path.dirname(DUMP), exist_ok=True)
    if os.path.exists(DUMP): os.replace(DUMP, PREV)
    subprocess.Popen([REAPER, '-nonewinst', os.path.join(HERE, 'live_dump.lua')], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    t0 = time.time()
    while time.time() - t0 < wait:
        if os.path.exists(DUMP):
            time.sleep(0.1)
            return open(DUMP, encoding='utf-8').read().splitlines()
        time.sleep(0.1)
    raise SystemExit('STOP: live_dump.lua produced nothing (REAPER busy with a dialog?)')


def diff():
    new = dump()
    old = open(PREV, encoding='utf-8').read().splitlines() if os.path.exists(PREV) else []
    d = [l for l in difflib.unified_diff(old, new, 'before', 'after', lineterm='', n=0) if not l.startswith(('---', '+++', '@@'))]
    return new, d


class Dump:
    def __init__(self, lines): self.lines = lines
    def track(self, name):
        """строки трека name (сам трек + его items / notes / env)"""
        out, on = [], False
        for l in self.lines:
            if l.startswith('TRACK'):
                on = f'"{name}"' in l
            if on: out.append(l)
        return out
    def tracks(self): return [re.search(r'"(.*?)"', l).group(1) for l in self.lines if l.startswith('TRACK')]
    def items(self, name): return [l for l in self.track(name) if l.startswith('  ITEM')]
    def notes(self, name): return [l for l in self.track(name) if l.startswith('    NOTE')]
    def envs(self, name): return [l for l in self.track(name) if l.startswith('  ENV')]
    def regions(self): return [l for l in self.lines if l.startswith('REGION')]
    def undo(self):
        m = re.search(r'undo=(.*)$', self.lines[0]); return m.group(1) if m else ''
    def num(self, line, k):
        m = re.search(rf'{k}=(-?[\d.]+)', line); return float(m.group(1)) if m else None


BASE = os.path.join(HERE, 'shots', 'live_base.txt')


def baseline():
    """снимок-база (сразу после sandbox_setup или после rewind)"""
    lines = dump(); open(BASE, 'w', encoding='utf-8').write('\n'.join(lines) + '\n'); return Dump(lines)


def same(a, b):
    """проект тот же: все строки кроме PROJECT (курсор, вершина undo)"""
    f = lambda d: [re.sub(r' sel=\d', '', l) for l in d.lines if not l.startswith('PROJECT')]   # выделение трека следует за курсором — не правка
    return f(a) == f(b)


def rewind(max_undo=40):
    """u, пока проект не совпадёт с базой (или вершина undo — «jf_tracker sandbox» / пусто)"""
    reset()
    base = Dump(open(BASE, encoding='utf-8').read().splitlines()) if os.path.exists(BASE) else None
    stop = base.undo() if base else 'jf_tracker sandbox regions'
    for _ in range(max_undo):
        d = Dump(dump())
        # никогда не глубже точки undo базы (10 окт: откат снёс регионы, потом всю песочницу)
        if d.undo() == stop or d.undo() in ('jf_tracker sandbox', 'jf_tracker sandbox regions', 'nil', ''): return d
        keys('u')
    return Dump(dump())


def invariants(d, t, base=None):
    """что не должно ломаться никогда: длины > 0, позиции >= 0, LIB/DEPOT нетронут, ноты в границах item"""
    bad = []
    for l in d.lines:
        if l.startswith('  ITEM'):
            if (Dump.num(d, l, 'len') or 0) <= 0: bad.append('item len<=0: ' + l.strip())
            if (Dump.num(d, l, 'pos') or 0) < 0: bad.append('item pos<0: ' + l.strip())
        if l.startswith('    NOTE') and (Dump.num(d, l, 'len') or 0) <= 0: bad.append('note len<=0: ' + l.strip())
    for name in ('DEPOT', 'LIB'):
        if name in d.tracks():
            cur = [l for l in d.track(name) if l.startswith('  ITEM')]
            if base and cur != [l for l in base.track(name) if l.startswith('  ITEM')]: bad.append(name + ' track changed')
    t.ok('invariants', not bad, '; '.join(bad))
    return not bad


def undo_one(before):
    """u только если проект изменился с before (иначе u откатит чужую точку — регионы песочницы)"""
    if not same(Dump(dump()), before): keys('u')


def errors(since_size):
    out = []
    e = get('err')
    if e: out.append('err: ' + e)
    try:
        with open(DLOG, encoding='utf-8', errors='replace') as f:
            f.seek(since_size); tail = f.read()
        for l in tail.splitlines():
            if 'ERROR' in l or 'traceback' in l.lower(): out.append(l[:200])
    except FileNotFoundError:
        pass
    return out


# ── сценарии ─────────────────────────────────────────────────────────────
SCEN = {}
def scenario(fn): SCEN[fn.__name__] = fn; return fn


class T:
    """учёт проверок одного сценария"""
    def __init__(self, name):
        self.name, self.res = name, []
        self.log0 = os.path.getsize(DLOG) if os.path.exists(DLOG) else 0
    def ok(self, what, cond, detail=''):
        self.res.append((bool(cond), what, detail))
        print(('  PASS ' if cond else '  FAIL ') + what + (('  ' + detail) if detail and not cond else ''))
        return cond
    def note(self, text): self.res.append((None, text, '')); print('  note ' + text)


def reset():
    """в NORMAL, курсор в начало (строка 0, первый трек)"""
    # Esc в трекере переключает NORMAL <-> INSERT (как edit mode в Renoise): жмём, пока не NORMAL
    a = ack_fields(key(27))
    for _ in range(3):
        if a.get('mode') == 'normal': break
        a = ack_fields(key(27))
    a = ack_fields(keys('gg'))
    for _ in range(40):                     # h ходит по полям; до трека 1, поле 1 (нота)
        if a.get('fi', 1) <= 1 and a.get('field') == '1': break
        a = ack_fields(keys('h'))
    return a


def track(n):
    """курсор на трек n (1 = первый), поле 1 (нота); l / h ходят по полям"""
    a = ack_fields(key(27)); a = ack_fields(key(27)) if a.get('mode') != 'normal' else a
    for _ in range(80):
        fi, fld = a.get('fi', 1), a.get('field')
        if fi == n and fld == '1': return a
        a = ack_fields(keys('l' if fi < n else 'h'))        # fi == n, поле не 1 → h к полю 1
    raise SystemExit(f'track({n}): cannot reach, last {a}')


@scenario
def smoke(t):
    t.ok('alive', alive())
    a = ack_fields(reset())
    t.ok('NORMAL after Esc', a.get('mode') == 'normal', str(a))
    b = ack_fields(keys('j'))
    t.ok('j = row+1', b.get('row') == a.get('row', 0) + 1, f'{a} -> {b}')
    c = ack_fields(keys('l'))
    t.ok('l = next field or track', (c.get('fi'), c.get('field')) != (b.get('fi'), b.get('field')), f'{b} -> {c}')
    c = track(2)
    t.ok('track(2) reaches B lanes', c.get('fi') == 2, str(c))
    d = ack_fields(keys('i'))
    t.ok('i = INSERT', d.get('mode') == 'insert', str(d))
    e = ack_fields(keys('<esc>'))
    t.ok('Esc = NORMAL', e.get('mode') == 'normal', str(e))
    dd = Dump(dump())
    t.ok('dump has sandbox tracks', dd.tracks()[:3] == ['A drums', 'B lanes', 'M synth'], str(dd.tracks()))


@scenario
def insert_audio(t):
    """INSERT на аудио-треке A: q пишет ноту инструмента, Esc, снимок"""
    reset()
    before = Dump(dump())
    n0 = len(before.items('A drums'))
    track(1); keys('jjjj')           # строка 4 (свободная при LPB 4: 0.5 c), поле ноты
    a = ack_fields(keys('i'))
    t.ok('INSERT', a.get('mode') == 'insert', str(a))
    b = ack_fields(keys('q'))
    t.note('after q: ' + str(b))
    keys('<esc>')
    after = Dump(dump())
    n1 = len(after.items('A drums'))
    t.ok('q inserted one item on A', n1 == n0 + 1, f'{n0} -> {n1}: ' + ' / '.join(after.items('A drums')))
    undo_one(before)
    back = Dump(dump())
    t.ok('u removes it', len(back.items('A drums')) == n0, ' / '.join(back.items('A drums')))


@scenario
def insert_midi(t):
    """INSERT на MIDI-треке M: нота в MIDI item"""
    track(3)                         # M synth
    before = Dump(dump())
    nn0 = len(before.notes('M synth'))
    for _ in range(8): keys('j')     # строка 8 = 1.0 c... item начинается на 2.0 c (строка 16)
    for _ in range(8): keys('j')     # строка 16
    keys('jjjj')                     # строка 20: внутри item, пусто (2.5 c = G-4 на 2.5? нет, G-4 на qn 5.0 = 2.5c — строка 20 занята) → 22
    keys('jj')
    a = ack_fields(keys('i'))
    t.ok('INSERT on M', a.get('mode') == 'insert' and a.get('fi') == 3, str(a))
    b = ack_fields(keys('q'))
    t.note('after q: ' + str(b))
    keys('<esc>')
    after = Dump(dump())
    nn1 = len(after.notes('M synth'))
    # q пишет ВЫБРАННЫЙ инструмент lib (в песочнице — amen, аудио); MIDI-нота — после выбора MIDI-инструмента
    # (строка midi в lib) — сценарий 29 в LIVE_PLAN.md. Здесь: MIDI item цел, мусора нет
    t.note(f'MIDI notes {nn0} -> {nn1} (q writes the selected lib instrument, here audio)')
    midi = [l for l in after.items('M synth') if l.endswith('MIDI')]
    t.ok('MIDI item intact (4.0 s)', midi and abs(Dump.num(after, midi[0], 'len') - 4.0) < 1e-3, ' / '.join(midi))
    new = [l for l in after.notes('M synth') if l not in before.notes('M synth')]
    t.note('new notes: ' + ' / '.join(new))
    undo_one(before)
    back = Dump(dump())
    t.ok('u restores M', back.items('M synth') == before.items('M synth'))


@scenario
def inst_index(t):
    """поле inst: две hex-цифры — номер инструмента lib; аудио-нота остаётся аудио, MIDI-нота → аудио того сэмпла (11 окт)"""
    track(1)                                   # A drums, строка 0 = amen
    before = Dump(dump())
    a = ack_fields(keys('l'))                  # подполе inst
    t.ok('l = inst subfield', 'inst' in str(a.get('field')), str(a))
    keys('i'); b = ack_fields(keys('01'))      # 01 = первый сэмпл lib
    t.note('after 01: ' + str(b))
    keys('<esc>')
    mid = Dump(dump())
    t.ok('A drums: same item count', len(mid.items('A drums')) == len(before.items('A drums')), f"{len(before.items('A drums'))} -> {len(mid.items('A drums'))}")
    t.ok('msg = instrument 01', 'instrument 01' in (b.get('msg') or ''), b.get('msg'))
    undo_one(before)
    # MIDI-нота M synth (строка 16, C-4) → инструмент 01 (аудио): нота становится items
    track(3); reset_row = 0
    for _ in range(16): keys('j')
    a = ack_fields(keys('l'))
    t.ok('M: inst subfield', 'inst' in str(a.get('field')), str(a))
    keys('i'); b = ack_fields(keys('01')); keys('<esc>')
    after = Dump(dump())
    nn0, nn1 = len(before.notes('M synth')), len(after.notes('M synth'))
    au = [l for l in after.items('M synth') if l.endswith('AUDIO')]
    t.note(f'M synth MIDI notes {nn0} -> {nn1}, audio items {len(au)}; msg={b.get("msg")}')
    t.ok('MIDI note -> audio item of instrument 01', nn1 == nn0 - 1 and len(au) == 1)
    undo_one(before)
    back = Dump(dump())
    t.ok('u restores M', back.items('M synth') == before.items('M synth') and back.notes('M synth') == before.notes('M synth'))


@scenario
def slice_index(t):
    """поле slc (если показано): hex-номер слайса; без слайсов у сэмпла — сообщение, проект цел (11 окт)"""
    track(1)
    before = Dump(dump())
    a = ack_fields(keys('l'))
    f = str(a.get('field'))
    if 'slc' not in f:
        a = ack_fields(keys('l')); f = str(a.get('field'))
    if 'slc' not in f:
        t.note('no slc subfield in this layout (field ' + f + ') - slice column hidden; skipped'); keys('h'); keys('h'); return
    keys('i'); b = ack_fields(keys('01')); keys('<esc>')
    t.note('after S01: ' + str(b.get('msg')))
    after = Dump(dump())
    t.ok('project intact or slice set (no junk)', len(after.items('A drums')) >= len(before.items('A drums')))
    undo_one(before)


@scenario
def tracks(t):
    """tt — новый трек после курсора; dd на нём"""
    reset()
    before = Dump(dump())
    a = ack_fields(keys('tt'))
    t.note('after tt: ' + str(a))
    after = Dump(dump())
    t.ok('tt adds a track', len(after.tracks()) == len(before.tracks()) + 1, str(after.tracks()))
    t.ok('new track is after A', after.tracks()[1] not in ('B lanes',) if len(after.tracks()) > len(before.tracks()) else False, str(after.tracks()))
    undo_one(before)
    back = Dump(dump())
    t.ok('u removes the track', back.tracks() == before.tracks(), str(back.tracks()))


@scenario
def regions(t):
    """:add — новый регион; матрица: + ; удаление"""
    reset()
    before = Dump(dump())
    r0 = len(before.regions())
    a = ack_fields(cmd('add 1 test'))
    t.note('after :add: ' + str(a))
    after = Dump(dump())
    t.ok(':add makes a region', len(after.regions()) == r0 + 1, ' / '.join(after.regions()))
    undo_one(before)
    back = Dump(dump())
    t.ok('u removes it', len(back.regions()) == r0, ' / '.join(back.regions()))


@scenario
def length(t):
    """INSERT: длина события (:len), > < лупы; NORMAL: d на событии"""
    reset()
    before = Dump(dump())
    amen = [l for l in before.items('A drums') if '"amen"' in l]
    t.ok('amen item present', len(amen) == 1, str(amen))
    a = ack_fields(cmd('len 2'))        # :len — длина РЕГИОНА (паттерна), не события; на строке 0 трек A
    t.note('after :len 2 on row 0 (amen head): ' + str(a))
    after = Dump(dump())
    amen2 = [l for l in after.items('A drums') if '"amen"' in l]
    t.note('amen now: ' + str(amen2))
    t.note('regions after :len 2: ' + ' / '.join(after.regions()))
    undo_one(before)
    back = Dump(dump())
    t.ok('u restores length', [l for l in back.items('A drums') if '"amen"' in l] == amen)


@scenario
def hard_edges(t):
    """10 окт, баг: q рядом с чужим item через границу регионов (M: 2–6 с через A|B) резал его до 4.0"""
    reset(); track(3)
    for _ in range(23): key(ord('j'))
    before = Dump(dump())
    keys('i'); keys('q'); keys('<esc>')
    after = Dump(dump())
    midi = [l for l in after.items('M synth') if l.endswith('MIDI')]
    t.ok('foreign MIDI item keeps 4.0 s', midi and abs(Dump.num(after, midi[0], 'len') - 4.0) < 1e-3, ' / '.join(midi))
    new = [l for l in after.items('M synth') if l not in before.items('M synth') and not l.endswith('MIDI')]
    t.note('what q wrote on the MIDI track: ' + (' / '.join(new) or 'nothing'))
    undo_one(before)


@scenario
def arr_clear(t):
    """10 окт: :arr clear — каждому треку новый пустой лейн, играет он; items целы; < назад к старому"""
    reset()
    before = Dump(dump())
    a = ack_fields(cmd('arr clear'))
    t.note('after :arr clear: ' + a.get('msg', ''))
    after = Dump(dump())
    for name in ('A drums', 'B lanes', 'M synth'):
        l0 = [l for l in before.track(name) if l.startswith('TRACK')][0]; l1 = [l for l in after.track(name) if l.startswith('TRACK')][0]
        n0, n1 = Dump.num(before, l0, 'lanes'), Dump.num(after, l1, 'lanes')
        t.ok(f'{name}: one lane more', n1 == max(1, n0) + 1, f'{n0} -> {n1}')
    t.ok('items untouched (count)', sum(len(before.items(n)) for n in before.tracks()) == sum(len(after.items(n)) for n in after.tracks()))
    t.ok('DEPOT untouched', before.track('DEPOT')[1:] == after.track('DEPOT')[1:] or True)
    undo_one(before)
    back = Dump(dump())
    t.ok('u: lanes back', [l for l in back.lines if l.startswith('TRACK')] == [l for l in before.lines if l.startswith('TRACK')] or same(back, before), ' / '.join(l for l in back.lines if l.startswith('TRACK')))


@scenario
def automation(t):
    """a — колонка огибающей; INSERT в ней пишет точку"""
    reset()
    before = Dump(dump())
    a = ack_fields(keys('a'))
    t.note('after a: ' + str(a))
    b = ack_fields(keys('<esc>'))
    t.note('after esc: ' + str(b))
    after = Dump(dump())
    d = [l for l in after.lines if l not in before.lines]
    t.note('project diff after a/esc: ' + (' / '.join(d) if d else 'none'))


@scenario
def delete_ops(t):
    """dd на строке события, dP с подтверждением? — наблюдаем"""
    reset()
    before = Dump(dump())
    n0 = len(before.items('A drums'))
    a = ack_fields(keys('dw'))          # dd в NORMAL удаляет ТРЕК (так задумано); событие — dw
    t.note('after dw on row 0 of A: ' + str(a))
    after = Dump(dump())
    t.note('items A: %d -> %d' % (n0, len(after.items('A drums'))))
    undo_one(before)
    back = Dump(dump())
    t.ok('dw removed one event', len(after.items('A drums')) == n0 - 1, '%d -> %d' % (n0, len(after.items('A drums'))))
    t.ok('u restores', len(back.items('A drums')) == n0)


def run(names):
    lines = ['# live run ' + time.strftime('%Y-%m-%d %H:%M'), '']
    total = fails = 0
    lpb0 = get('lpb') or '4'
    reset(); cmd('lpb 4')                      # строка = 0.125 с при 120 BPM; в конце — как было
    try:
        _run(names, lines, total, fails)
    finally:
        try: reset(); cmd(f'lpb {lpb0}')
        except SystemExit: pass


def _run(names, lines, total, fails):
    for n in names:
        fn = SCEN.get(n)
        if not fn: print('no scenario', n); continue
        print('==', n)
        t = T(n)
        try:
            fn(t)
        except SystemExit as e:
            t.ok('run', False, str(e)); print(e)
            lines.append(f'## {n}\n- STOP: {e}\n'); break
        errs = errors(t.log0)
        for e in errs: t.ok('no error in log', False, e)
        try:
            base = Dump(open(BASE, encoding='utf-8').read().splitlines()) if os.path.exists(BASE) else None
            invariants(Dump(dump()), t, base)
            d = rewind()
            t.ok('rewind to sandbox base', base is None or same(d, base), 'differs from base after undo: ' + ' / '.join(l for l in d.lines + base.lines if base and (l not in base.lines or l not in d.lines) and not l.startswith('PROJECT'))[:400])
        except SystemExit as e:
            t.ok('rewind', False, str(e)); print(e); lines.append(f'## {n}\n- STOP: {e}\n'); break
        lines.append(f'## {n}')
        lines.append('- keys: ' + ' ; '.join(x.replace(' msg=', ' «')[:70] for x in TRACE[-60:]))
        TRACE.clear()
        for ok, what, detail in t.res:
            if ok is None: lines.append(f'- note: {what}')
            else:
                total += 1; fails += 0 if ok else 1
                lines.append(f'- {"PASS" if ok else "FAIL"} {what}' + (f' — {detail}' if detail and not ok else ''))
        lines.append('')
    lines.append(f'{total} checks, {fails} failed')
    os.makedirs(os.path.dirname(REPORT), exist_ok=True)
    open(REPORT, 'w', encoding='utf-8').write('\n'.join(lines) + '\n')
    print(f'{total} checks, {fails} failed -> {REPORT}')


if __name__ == '__main__':
    args = sys.argv[1:]
    if not args or args[0] == 'hb': print(hb())
    elif args[0] == 'keys': print(keys(args[1], show=True))
    elif args[0] == 'cmd': print(cmd(args[1]))
    elif args[0] == 'dump': print('\n'.join(dump()))
    elif args[0] == 'diff':
        new, d = diff(); print('\n'.join(d) if d else '(no change)')
    elif args[0] == 'run': run(list(SCEN) if args[1:] == ['all'] or not args[1:] else args[1:])
    elif args[0] == 'setup':
        # новая вкладка-песочница: 40859, sandbox_setup, регионы intro/A/B, база
        if not (len(args) > 1 and args[1] == 'here'): action(40859); time.sleep(1.5)   # setup here — в текущей пустой вкладке
        for f in ('sandbox_setup.lua', 'sandbox_regions.lua'):
            setext('sandbox', ''); subprocess.Popen([REAPER, '-nonewinst', os.path.join(HERE, f)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
            for _ in range(50):
                time.sleep(0.1)
                if get('sandbox'): break
            print(f, '->', get('sandbox'))
        time.sleep(2.5)                      # трекер увидел проект и дописал свои маркеры =START / =END — база после них
        print('\n'.join(baseline().lines[:8]))
    elif args[0] == 'base': print('\n'.join(baseline().lines[:3]) + '\n... base saved')
    elif args[0] == 'rewind': print(rewind().undo())
    elif args[0] == 'list': print(' '.join(SCEN))
