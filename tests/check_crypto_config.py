"""Check recovery actions against the selected init source and HAL uniqueness."""
import argparse
import pathlib
import re
import shlex
import xml.etree.ElementTree as ET

parser = argparse.ArgumentParser()
parser.add_argument('--source-root', type=pathlib.Path)
parser.add_argument('--builtins', type=pathlib.Path)
args = parser.parse_args()
root = pathlib.Path(__file__).resolve().parents[1]
builtins = args.builtins or (args.source_root / 'system/core/init/builtins.cpp' if args.source_root else None)
if not builtins:
    parser.error('provide --source-root or --builtins')
source = builtins.read_text()
source = source[source.index('const BuiltinFunctionMap& GetBuiltinFunctionMap()'):]
commands = {name: (int(low), None if high == 'kMax' else int(high))
            for name, low, high in re.findall(r'\{"(\w+)",\s*\{(\d+),\s*(\d+|kMax)', source)}
assert commands, 'No init builtin table found'
rc = root / 'recovery/root/init.recovery.qcom.rc'
action = False
for n, line in enumerate(rc.read_text().splitlines(), 1):
    words = shlex.split(line, comments=True)
    if not words:
        continue
    if not line[0].isspace():
        action = words[0] == 'on'
        continue
    if not action:
        continue
    assert words[0] in commands, f'{rc.name}:{n}: unknown init command {words[0]}'
    low, high = commands[words[0]]
    argc = len(words) - 1
    assert argc >= low and (high is None or argc <= high), f'{rc.name}:{n}: invalid argument count'

# Framework ramdisk fragments are merged into the same manifest.
seen = {}
for path in (root / 'recovery/root').rglob('*.xml'):
    if 'vintf' not in path.parts:
        continue
    doc = ET.parse(path).getroot()
    if doc.tag != 'manifest' or doc.get('type') != 'framework':
        continue
    for hal in doc.findall('hal'):
        if hal.get('format') != 'aidl':
            continue
        for fq in hal.findall('fqname'):
            key = (hal.findtext('name'), fq.text)
            assert key not in seen, f'Duplicate framework HAL {key}: {seen.get(key)}, {path}'
            seen[key] = path
print('Recovery init command/argument and VINTF checks passed')
