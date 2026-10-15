#!/usr/bin/env python3
"""nw.py — живые тесты без веб-интерфейса (15 окт): REAPER -nonewinst + tests/nw_keys.lua.

  python3 tests/nw.py keys 'jjl<esc>'      клавиши (мини-язык live.py), ответы трекера
  python3 tests/nw.py cmd 'reload'         :команда + Enter
  python3 tests/nw.py lua 'return reaper.CountTracks(0)'   код в REAPER, результат
  python3 tests/nw.py restart              трекер заново (quit + run_tracker.lua)
  python3 tests/nw.py hb                   пульс трекера
"""
import os, sys, time, subprocess
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from live import parse
REAPER = '/Applications/REAPER.app/Contents/MacOS/REAPER'
IN, OUT = os.path.join(HERE, 'shots', 'nw_in.txt'), os.path.join(HERE, 'shots', 'nw_out.txt')


def run(lines, timeout=30):
    os.makedirs(os.path.dirname(IN), exist_ok=True)
    with open(IN, 'w') as f: f.write('\n'.join(lines) + '\n')
    if os.path.exists(OUT): os.remove(OUT)
    subprocess.Popen([REAPER, '-nonewinst', os.path.join(HERE, 'nw_keys.lua')], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    t0 = time.time()
    while time.time() - t0 < timeout:
        if os.path.exists(OUT):
            txt = open(OUT).read()
            if txt.rstrip().endswith('DONE'): return txt.rstrip().split('\n')[:-1]
        time.sleep(0.1)
    raise SystemExit('STOP: nw_keys.lua did not finish (REAPER busy / a dialog open?)')


def lua(code): return run(['lua: ' + code.replace('\n', ' ')])[0]


def keys(seq): return run([f'{c},{m}' for c, m in parse(seq)])


def hb(): return lua("return reaper.GetExtState('jf_tracker','hb')")


def restart():
    lua("reaper.SetExtState('jf_tracker','quit','1',false); return 'quit set'")
    time.sleep(1.5)
    subprocess.Popen([REAPER, '-nonewinst', os.path.join(HERE, 'run_tracker.lua')], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(4)
    a = hb(); time.sleep(1.5); b = hb()
    err = lua("return reaper.GetExtState('jf_tracker','err_load')")
    print('ALIVE' if a != b else 'DEAD', '|', b[:60], '|', err)


if __name__ == '__main__':
    what = sys.argv[1] if len(sys.argv) > 1 else 'hb'
    arg = sys.argv[2] if len(sys.argv) > 2 else ''
    if what == 'keys': print('\n'.join(keys(arg)))
    elif what == 'cmd': print('\n'.join(keys(':' + arg + '<cr>')))
    elif what == 'lua': print(lua(arg))
    elif what == 'restart': restart()
    else: print(hb())
