#!/usr/bin/env python3
"""make_index.py - ReaPack index.xml for the paid jf_tracker channel (5 Oct).

Adds the version from jf_tracker_version.lua as an entry pointing at tag
v<version>. URLs are {{BASE}}/v/<tag>/<path>; the gate worker
(jeeruff.com/jf_tracker/r/<license key>/) substitutes {{BASE}} with the
buyer's own base and serves the files of that tag from the private repo.

Usage:  tools/make_index.py            # index.xml for the current version
        tools/make_index.py --check    # print, write nothing
Release: bump VERSION, commit, `git tag v<version>`, run this, commit
index.xml, push master + the tag.
"""
import datetime
import re
import subprocess
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
INDEX = ROOT / 'index.xml'
NAME = 'jf_tracker'
# not shipped: development files
SKIP = re.compile(r'^(tests/|tools/|\.gitignore$|index\.xml$|CHECK\.md$|PAKETTI\.md$|DEVELOPMENT\.md$)')


def git(*a):
    return subprocess.run(['git', '-C', str(ROOT), *a], check=True, capture_output=True, text=True).stdout


def version():
    src = (ROOT / 'jf_tracker_version.lua').read_text()
    return re.search(r"V\.VERSION = '([^']+)'", src).group(1)


def changes(ver):
    # первые пункты CHANGES для этой версии — в changelog ReaPack
    src = (ROOT / 'jf_tracker_version.lua').read_text()
    m = re.search(r"v = '" + re.escape(ver) + r"'.*?items = \{(.*?)\n\s*\}", src, re.S)
    if not m:
        return ''
    return '\n'.join('- ' + s.replace('\\\\', '\\').replace("\\'", "'") for s in re.findall(r"'((?:[^'\\]|\\.)*)'", m.group(1)))


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
        ET.SubElement(v, 'source', attrs).text = '{{BASE}}/v/%s/%s' % (tag, f)


def main():
    ver = version()
    tag = 'v' + ver
    tags = git('tag', '--list', tag).split()
    if tag not in tags and '--check' not in sys.argv:
        sys.exit('no tag %s: commit and `git tag %s` first' % (tag, tag))
    files = [f for f in git('ls-files', '--', '.').split('\n') if f and not SKIP.match(f)]
    scripts = [f for f in files if not f.startswith('effects/')]
    effects = [f for f in files if f.startswith('effects/')]

    if INDEX.exists():
        root = ET.parse(INDEX).getroot()
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
    if '--check' in sys.argv:
        print(out)
    else:
        INDEX.write_text(out)
        print('index.xml: %s, %d scripts, %d effects' % (tag, len(scripts), len(effects)))


if __name__ == '__main__':
    main()
