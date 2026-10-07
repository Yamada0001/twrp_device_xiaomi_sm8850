"""Execute production shell with temporary paths and fake mount/properties.
No real mounts, block devices or device properties are touched.
"""
import os
import pathlib
import shutil
import subprocess
import tempfile

root = pathlib.Path(__file__).resolve().parents[1]
source = (root / 'recovery/root/odm/bin/mount-stock-vendor.sh').read_text()
bash = r'C:\Program Files\Git\bin\bash.exe' if os.name == 'nt' else shutil.which('bash')
assert bash, 'bash is required'

PRELUDE = r'''
getprop() { printf '%s' "$TEST_SLOT"; }
setprop() { printf 'PROP %s %s\n' "$1" "$2"; }
logger_stub() { :; }
sleep() { :; }
mount() {
    target="${@: -1}"
    printf 'MOUNT %s\n' "$*"
    case "$target" in *"$TEST_FAIL") [ -n "$TEST_FAIL" ] && return 1;; esac
    printf 'node %s erofs ro 0 0\n' "$target" >> "$TEST_BASE/proc/mounts"
    case "$target" in */firmware_mnt) mkdir -p "$target/image";; esac
    return 0
}
'''


def run_case(slot='_a', missing='', fail_mount='', existing=False):
    with tempfile.TemporaryDirectory(prefix='crypto-mount-') as temp:
        temp_path = pathlib.Path(temp)
        base = subprocess.check_output([bash, '-c', 'cd "$1" && pwd', 'test', temp], text=True).strip()
        script = source.replace('/system/bin/log', 'logger_stub')
        for path in ['/proc/mounts', '/tmp/recovery.log', '/dev/block', '/vendor', '/odm']:
            script = script.replace(path, base + path)
        for path in ['proc', 'tmp', 'dev/block/mapper', 'dev/block/bootdevice/by-name', 'vendor/firmware_mnt', 'odm']:
            (temp_path / path).mkdir(parents=True, exist_ok=True)
        for name, path in [('vendor', 'dev/block/mapper/vendor_a'), ('odm', 'dev/block/mapper/odm_a'), ('modem', 'dev/block/bootdevice/by-name/modem_a')]:
            if name != missing:
                (temp_path / path).touch()
        mounts = temp_path / 'proc/mounts'
        mounts.touch()
        if existing:
            mounts.write_text(''.join(f'node {base}/{target} erofs ro 0 0\n' for target in ['vendor', 'odm', 'vendor/firmware_mnt']))
            (temp_path / 'vendor/firmware_mnt/image').mkdir()
        testfile = temp_path / 'run.sh'
        testfile.write_text(PRELUDE + script, newline='\n')
        env = dict(os.environ, TEST_SLOT=slot, TEST_FAIL=fail_mount, TEST_BASE=base)
        return subprocess.run([bash, str(testfile)], env=env, text=True, capture_output=True, timeout=10)


for kwargs in [{}, {'existing': True}]:
    result = run_case(**kwargs)
    assert result.returncode == 0, result.stderr + result.stdout
    assert 'PROP twrp.stock_vendor_mounted 1' in result.stdout
    assert 'vendor_dlkm' not in result.stdout
    if kwargs:
        assert 'MOUNT ' not in result.stdout
for kwargs in [{'slot': 'invalid'}, {'missing': 'vendor'}, {'missing': 'odm'}, {'missing': 'modem'}, {'fail_mount': 'firmware_mnt'}, {'fail_mount': 'odm'}]:
    result = run_case(**kwargs)
    assert result.returncode != 0, result.stdout
    assert 'PROP twrp.stock_vendor_mounted 1' not in result.stdout, result.stdout
print('8 mount success/failure/idempotency scenarios passed')
