#!/usr/bin/env python3
"""make_index.py - release files and the ReaPack index (5 Oct).

The dev repo (jf_tracker) stays private; releases go to the public repo
jeeruff/jf_tracker-release: only the shipped files of a tag, one commit per
version, and index.xml on its main branch. ReaPack imports
https://github.com/jeeruff/jf_tracker-release/raw/main/index.xml

Usage (tools/release.sh runs both):
  make_index.py --export v0.7.0 DIR   copy the shipped files of the dev tag into DIR
  make_index.py --index DIR           add the current version to DIR/index.xml
  make_index.py --check               print the index entry, write nothing
"""
import datetime
import re
import subprocess
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
NAME = 'jf_tracker'
RAW = 'https://github.com/jeeruff/jf_tracker-release/raw'
# not shipped: development files
SKIP = re.compile(r'^(tests/|tools/|\.gitignore$|index\.xml$|CHECK\.md$|PAKETTI\.md$|DEVELOPMENT\.md$)')


def git(*a, raw=False):
    r = subprocess.run(['git', '-C', str(ROOT), *a], check=True, capture_output=True, text=not raw)
    return r.stdout


def version():
    src = (ROOT / 'jf_tracker_version.lua').read_text()
    return re.search(r"V\.VERSION = '([^']+)'", src).group(1)


def shipped(tag):
    return [f for f in git('ls-tree', '-r', '--name-only', tag).split('\n') if f and not SKIP.match(f)]


def changes(ver):
    # пункты CHANGES этой версии — в changelog ReaPack
    src = (ROOT / 'jf_tracker_version.lua').read_text()
    m = re.search(r"v = '" + re.escape(ver) + r"'.*?items = \{(.*?)\n\s*\}", src, re.S)
    if not m:
        return ''
    return '\n'.join('- ' + s.replace('\\\\', '\\').replace("\\'", "'") for s in re.findall(r"'((?:[^'\\]|\\.)*)'", m.group(1)))


def export(tag, out):
    out = Path(out)
    files = shipped(tag)
    for f in files:
        p = out / f
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(git('show', '%s:%s' % (tag, f), raw=True))
    print('exported %d files of %s' % (len(files), tag))


def package(cat, name, ptype, desc):
    for p in cat.findall('reapack'):
        if p.get('name') == name:
            return p
    return ET.SubElement(cat, 'reapack', name=name, type=ptype, desc=desc)


def add_version(pkg, ver, tag, files, main=None, log=''):
    for v in pkg.findall('version'):
        if v.get('name') == ver:
            pkg.remove(v)
    now = datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
    v = ET.SubElement(pkg, 'version', name=ver, author='jeeruff', time=now)
    if log:
        ET.SubElement(v, 'changelog').text = log
    for f in files:
        attrs = {'file': f.split('/')[-1] if f.startswith('effects/') else f}
        if f == main:
            attrs['main'] = 'main'
        ET.SubElement(v, 'source', attrs).text = '%s/%s/%s' % (RAW, tag, f)


def build(index_path):
    ver = version()
    tag = 'v' + ver
    if git('tag', '--list', tag).strip():
        files = shipped(tag)
    else:
        files = [f for f in git('ls-files').split('\n') if f and not SKIP.match(f)]
    scripts = [f for f in files if not f.startswith('effects/')]
    effects = [f for f in files if f.startswith('effects/')]
    if index_path and index_path.exists():
        root = ET.parse(index_path).getroot()
    else:
        root = ET.Element('index', version='1', name=NAME)
    cat = root.find('category')
    if cat is None:                       # пустой Element ложен — только is None
        cat = ET.SubElement(root, 'category', name=NAME)
    add_version(package(cat, 'jf_tracker.lua', 'script', 'jf_tracker - tracker view of REAPER with Vim keys'),
                ver, tag, scripts, main='jf_tracker.lua', log=changes(ver))
    add_version(package(cat, 'jf_tracker effects.jsfx', 'effect', 'jf_tracker helpers: jf_rec (retro sampler), jf_tracker_scope'),
                ver, tag, effects)
    ET.indent(root)
    out = '<?xml version="1.0" encoding="utf-8"?>\n' + ET.tostring(root, encoding='unicode') + '\n'
    return out, tag, len(scripts), len(effects)


def main():
    a = sys.argv[1:]
    if a[:1] == ['--export'] and len(a) == 3:
        export(a[1], a[2])
    elif a[:1] == ['--index'] and len(a) == 2:
        p = Path(a[1]) / 'index.xml'
        out, tag, ns, ne = build(p)
        p.write_text(out)
        print('index.xml: %s, %d scripts, %d effects' % (tag, ns, ne))
    elif a[:1] == ['--check']:
        print(build(None)[0])
    else:
        sys.exit(__doc__)


if __name__ == '__main__':
    main()
