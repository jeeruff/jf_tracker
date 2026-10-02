#!/bin/sh
# restart.sh — надёжный перезапуск трекера в живом REAPER (веб-интерфейс 8080).
# Сначала просим работающий экземпляр выйти (ExtState quit=1), ждём, потом
# запускаем через -nonewinst. Запуск поверх живого экземпляра гасит оба
# (REAPER убивает их без err/exit — см. память jf-tracker).
D=$(cd "$(dirname "$0")/.." && pwd); W='http://localhost:8080/_'
# REAPER не запущен → не стартовать его отсюда: -nonewinst тогда поднимает
# REAPER дочерним процессом этого скрипта (2 окт: так он попал в группу
# процессов фоновой задачи и мог быть убит вместе с ней)
if ! pgrep -x REAPER >/dev/null 2>&1 || ! curl -s -m 3 "$W/GET/EXTSTATE/jf_tracker/hb" >/dev/null; then
  echo "REAPER NOT RUNNING (or web interface 8080 silent) - start REAPER yourself"; exit 1
fi
curl -s -m 3 "$W/SET/EXTSTATE/jf_tracker/quit/1" >/dev/null; sleep 1.5
( /Applications/REAPER.app/Contents/MacOS/REAPER -nonewinst "$D/tests/run_tracker.lua" >/dev/null 2>&1 & ) ; sleep 2
sleep 4; a=$(curl -s "$W/GET/EXTSTATE/jf_tracker/hb" | cut -f4- | cut -c1-8); sleep 2; b=$(curl -s "$W/GET/EXTSTATE/jf_tracker/hb" | cut -f4- | cut -c1-8)
echo "hb $a -> $b err=$(curl -s "$W/GET/EXTSTATE/jf_tracker/err" | cut -f4-) load=$(curl -s "$W/GET/EXTSTATE/jf_tracker/err_load" | cut -f4-)"
[ "$a" != "$b" ] && echo ALIVE || echo DEAD
