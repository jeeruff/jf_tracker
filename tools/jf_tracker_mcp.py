"""jf_tracker_mcp.py — MCP-сервер трекера jf_tracker (10 окт).

Даёт модели (Claude Code / Claude Desktop / любой MCP-клиент) три инструмента:
  tracker_state — снимок трекера текстом (треки, курсор, lib, слоты, строки паттерна);
  tracker_help  — команды трекера (:команды) или страница справки клавиш;
  tracker_run   — выполнить :команды и клавиши (каждая :команда — один undo).

Как говорит с трекером: веб-интерфейс REAPER (Preferences → Control/OSC/web,
порт 8080) кладёт запрос в ExtState jf_tracker/llm_in, трекер раз в кадр его
читает и отвечает файлом <ресурсы REAPER>/Data/jf_tracker_llm_out.txt + меткой
llm_ack. В трекере мост включается опцией «LLM / MCP bridge» (off / ask / on);
при ask каждый run ждёт y во всплывашке трекера.

Запуск (без установки пакетов в систему):
  uv run --with mcp python tools/jf_tracker_mcp.py
Подключить к Claude Code:
  claude mcp add jf-tracker -- uv run --with mcp python "<путь>/tools/jf_tracker_mcp.py"
Порт веб-интерфейса — переменная JF_TRACKER_WEB (по умолчанию http://localhost:8080).
"""
import os
import time
import urllib.parse
import urllib.request

try:                                   # mcp 2.x: FastMCP переименован в MCPServer
    from mcp.server.mcpserver import MCPServer as FastMCP
except ImportError:                    # mcp 1.x
    from mcp.server.fastmcp import FastMCP

WEB = os.environ.get('JF_TRACKER_WEB', 'http://localhost:8080').rstrip('/') + '/_'
EXT = 'jf_tracker'
OUT = os.path.expanduser('~/Library/Application Support/REAPER/Data/jf_tracker_llm_out.txt')
MAX_PAYLOAD = 900          # веб-интерфейс режет ExtState на ~995 знаках — длинный run делится

mcp = FastMCP('jf-tracker')


def _get(key):
    with urllib.request.urlopen(f'{WEB}/GET/EXTSTATE/{EXT}/{key}', timeout=3) as r:
        f = r.read().decode('utf-8', 'replace').rstrip('\r\n').split('\t', 3)
        return f[3] if len(f) > 3 else ''


def _set(key, val):
    urllib.request.urlopen(f'{WEB}/SET/EXTSTATE/{EXT}/{key}/{urllib.parse.quote(val, safe="")}', timeout=3).read()


def _ask(op, payload='', timeout=15.0):
    """один запрос к трекеру; ответ — текст файла (без строки id)"""
    rid = f'{int(time.time() * 1000) % 100000000}'
    try:
        _set('llm_in', f'{rid}|{op}|{payload}')
    except Exception as e:      # REAPER не запущен / веб-интерфейс выключен
        return f'ERROR: no REAPER web interface at {WEB} ({e}). Enable it: Preferences > Control/OSC/web > Web browser interface, port 8080.'
    t0 = time.time()
    while time.time() - t0 < timeout:
        try:
            if _get('llm_ack') == rid:
                with open(OUT, encoding='utf-8', errors='replace') as f:
                    first, _, rest = f.read().partition('\n')
                if first == rid:
                    return rest
        except Exception:
            pass
        time.sleep(0.05)
    return ('ERROR: the tracker did not answer in %.0f s - is jf_tracker running, and is its option '
            '"LLM / MCP bridge" (options > sound and samples) set to ask or on? With ask, answer y in the tracker popup.' % timeout)


@mcp.tool()
def tracker_state(rows: int = 32) -> str:
    """Snapshot of the jf_tracker window in REAPER: BPM, LPB, cursor (row, track, instrument, mode),
    tracks, the lib of the cursor track, the slots (regions) of the song and the rows of the pattern
    under the cursor (cell = note, instrument number, volume hex; '|' = held; '...' = empty).
    Call this first and after changes."""
    return _ask('state', str(int(rows)))


@mcp.tool()
def tracker_help(page: str = '') -> str:
    """The tracker's :commands with their arguments (empty page), or one help page of keys
    (tracker, insert, matrix, inst, slices, sample, dsp, ...). Use it before tracker_run."""
    return _ask('help', page)


@mcp.tool()
def tracker_run(steps: list[str]) -> str:
    """Run tracker steps in order. A step is a command line like ':note C-4 2' or ':lpb 8'
    (the leading ':' is optional), or keys like 'keys:jjj' / 'keys:<esc>' (vim keys of the tracker;
    <cr> <esc> <tab> <bs> <up> <down> <left> <right> <space>). Every :command is one undo step
    (the user undoes with u). If the tracker option is 'ask', the user confirms with y first.
    Returns what each step reported."""
    out, batch, size = [], [], 0
    for st in steps:
        st = st.replace(';;', ';')
        if size + len(st) + 2 > MAX_PAYLOAD and batch:
            out.append(_ask('run', ';;'.join(batch), timeout=120))
            batch, size = [], 0
        batch.append(st); size += len(st) + 2
    if batch:
        out.append(_ask('run', ';;'.join(batch), timeout=120))
    return '\n'.join(out)


if __name__ == '__main__':
    mcp.run()
