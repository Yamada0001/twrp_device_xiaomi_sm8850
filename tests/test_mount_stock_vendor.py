"""Execute production shell with temporary paths and fake mount/properties.
No real mounts, block devices or device properties are touched.
"""
import os
import pathlib
import shlex
import shutil
import subprocess
import tempfile

root = pathlib.Path(__file__).resolve().parents[1]
ramdisk = root / 'recovery/root'
rc = (ramdisk / 'init.recovery.qcom.rc').read_text()
service = next(shlex.split(line) for line in rc.splitlines()
               if line.startswith('service twrp.mount-stock-vendor '))
assert service[2:] == ['/system/bin/sh', '/system/bin/mount-stock-vendor.sh'], \
    'Mount helper must remain accessible when stock /vendor and /odm hide the ramdisk'
source = (ramdisk / service[3].lstrip('/')).read_text()
for path in ['vendor/etc/init/android.hardware.secure_element-service.qti.rc',
             'vendor/etc/init/android.hardware.security.onekeymint-service-qti.rc',
             'odm/etc/init/android.hardware.weaver-service.nxp.rc']:
    assert ['setenv', 'LD_PRELOAD', '/system/lib64/libbinder.so'] in [
        shlex.split(line, comments=True) for line in (ramdisk / path).read_text().splitlines()
    ], f'{path}: stock Binder must not shadow the recovery Binder runtime'
touch_service = (ramdisk / 'odm/etc/init/vendor.xiaomi.hw.touchfeature-service.rc').read_text()
assert 'service odm.touch_report /system/bin/touch_report' in touch_service, \
    'Touch report daemon must stay visible after stock ODM is mounted'
assert 'setenv LD_LIBRARY_PATH /odm/lib64:' in touch_service, \
    'Touch report must resolve its implementation from mounted stock ODM'
bash = r'C:\Program Files\Git\bin\bash.exe' if os.name == 'nt' else shutil.which('bash')
assert bash, 'bash is required'

PRELUDE = r'''
getprop() {
    case "$1" in
        ro.boot.slot_suffix) printf '%s' "$TEST_SLOT";;
        ro.twrp.weaver) printf '%s' "$TEST_WEAVER";;
        *) return 1;;
    esac
}
setprop() { printf 'PROP %s %s\n' "$1" "$2"; }
logger_stub() { :; }
sleep() { :; }
insmod() {
    printf 'INSMOD %s\n' "$*" >> "$TEST_BASE/driver-commands"
    # The stock module must remain accessible even while TWRP replaces vendor.
    [ "$1" = "$TEST_BASE/mnt/twrp-vendor-dlkm/lib/modules/nxp-nci.ko" ] || return 1
    [ -e "$1" ] || return 1
    [ "$TEST_MODULE" = "failure" ] && return 1
    [ "$TEST_MODULE" = "no-node" ] || touch "$TEST_BASE/dev/nq-nci"
    return 0
}
mount() {
    target="${@: -1}"
    printf 'MOUNT %s\n' "$*"
    case "$target" in *"$TEST_FAIL") [ -n "$TEST_FAIL" ] && return 1;; esac
    printf 'node %s erofs ro 0 0\n' "$target" >> "$TEST_BASE/proc/mounts"
    case "$target" in */firmware_mnt) mkdir -p "$target/image";; esac
    return 0
}
'''


def run_case(slot='_a', missing='', fail_mount='', existing=False,
             weaver='nxp', module='success', driver_ready=False, hidden_firmware=False):
    with tempfile.TemporaryDirectory(prefix='crypto-mount-') as temp:
        temp_path = pathlib.Path(temp)
        base = subprocess.check_output([bash, '-c', 'cd "$1" && pwd', 'test', temp], text=True).strip()
        script = source.replace('/system/bin/log', 'logger_stub')
        for path in ['/proc/mounts', '/tmp/recovery.log', '/etc/fstab', '/dev/nq-nci', '/dev/block',
                     '/sys/module/smcinvoke_dlkm', '/mnt/twrp-vendor-dlkm', '/vendor', '/odm']:
            script = script.replace(path, base + path)
        for path in ['proc', 'tmp', 'dev/block/mapper', 'dev/block/bootdevice/by-name',
                     'vendor/firmware_mnt', 'mnt/twrp-vendor-dlkm/lib/modules', 'odm',
                     'sys/module', 'etc']:
            (temp_path / path).mkdir(parents=True, exist_ok=True)
        for name, path in [('vendor', 'dev/block/mapper/vendor' + slot),
                           ('odm', 'dev/block/mapper/odm' + slot),
                           ('vendor_dlkm', 'dev/block/mapper/vendor_dlkm' + slot),
                           ('modem', 'dev/block/bootdevice/by-name/modem' + slot)]:
            if name != missing:
                (temp_path / path).touch()
        if missing != 'module':
            (temp_path / 'mnt/twrp-vendor-dlkm/lib/modules/nxp-nci.ko').touch()
        if missing != 'dependency':
            (temp_path / 'sys/module/smcinvoke_dlkm').mkdir()
        if missing != 'fstab':
            (temp_path / 'etc/fstab').touch()
        mounts = temp_path / 'proc/mounts'
        mounts.touch()
        if existing or hidden_firmware:
            mounts.write_text(''.join(f'node {base}/{target} erofs ro 0 0\n'
                                     for target in ['vendor', 'odm', 'mnt/twrp-vendor-dlkm', 'vendor/firmware_mnt']))
            if not hidden_firmware:
                (temp_path / 'vendor/firmware_mnt/image').mkdir()
        if driver_ready:
            (temp_path / 'dev/nq-nci').touch()
        testfile = temp_path / 'run.sh'
        testfile.write_text(PRELUDE + script, newline='\n')
        env = dict(os.environ, TEST_SLOT=slot, TEST_FAIL=fail_mount, TEST_BASE=base,
                   TEST_WEAVER=weaver, TEST_MODULE=module)
        result = subprocess.run([bash, str(testfile)], env=env, text=True, capture_output=True, timeout=10)
        driver_log = temp_path / 'driver-commands'
        if driver_log.exists():
            result.stdout += driver_log.read_text()
        return result


success_cases = [{}, {'slot': '_b'}, {'existing': True, 'driver_ready': True},
                 {'weaver': 'goodix'}, {'driver_ready': True, 'missing': 'vendor_dlkm'},
                 {'existing': True}, {'hidden_firmware': True, 'driver_ready': True}]
failure_cases = [{'slot': 'invalid'}, {'missing': 'vendor'}, {'missing': 'odm'},
                 {'missing': 'modem'}, {'fail_mount': 'firmware_mnt'}, {'fail_mount': 'odm'},
                 {'missing': 'vendor_dlkm'}, {'fail_mount': 'twrp-vendor-dlkm'},
                 {'missing': 'module'}, {'missing': 'dependency'}, {'missing': 'fstab'},
                 {'module': 'failure'}, {'module': 'no-node'}]
for kwargs in success_cases:
    result = run_case(**kwargs)
    assert result.returncode == 0, result.stderr + result.stdout
    assert 'PROP twrp.stock_vendor_mounted 1' in result.stdout
    if kwargs.get('weaver') == 'goodix' or kwargs.get('driver_ready'):
        assert 'INSMOD ' not in result.stdout
    else:
        assert 'INSMOD ' in result.stdout
    if kwargs.get('existing'):
        assert 'MOUNT ' not in result.stdout
    if kwargs.get('hidden_firmware'):
        assert 'MOUNT -t vfat' in result.stdout
for kwargs in failure_cases:
    result = run_case(**kwargs)
    assert result.returncode != 0, result.stdout
    assert 'PROP twrp.stock_vendor_mounted 1' not in result.stdout, result.stdout
print(f'{len(success_cases) + len(failure_cases)} mount/driver success/failure/idempotency scenarios passed')
