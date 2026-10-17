#!/usr/bin/env bash
# Install the downloaded release bytes; never rebuild a package in acceptance.
set -euo pipefail
[[ "${OPEN_FORESIGHT_ACCEPTANCE_DISPOSABLE:-}" == 1 && -f /.dockerenv && $(id -u) == 0 ]] || {
  echo 'Run only in an explicitly opted-in disposable container.' >&2; exit 2;
}
task_format=${1:?deb rpm or arch}
case "$task_format" in
  deb)
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y --no-install-recommends python3 xvfb xauth dbus-x11 libgl1-mesa-dri libegl-mesa0 libglx-mesa0 desktop-file-utils procps
    task_packages=(/assets/*.deb)
    [[ ${#task_packages[@]} == 1 && -f "${task_packages[0]}" ]]
    ;;
  rpm)
    dnf install -y python3 xorg-x11-server-Xvfb xorg-x11-xauth dbus-x11 mesa-dri-drivers mesa-libEGL mesa-libGL desktop-file-utils procps-ng shadow-utils
    task_packages=(/assets/*.rpm)
    [[ ${#task_packages[@]} == 1 && -f "${task_packages[0]}" ]]
    ;;
  arch)
    pacman -Syu --noconfirm --needed python xorg-server-xvfb xorg-xauth dbus mesa desktop-file-utils procps-ng
    task_packages=(/assets/*.pkg.tar.zst)
    [[ ${#task_packages[@]} == 1 && -f "${task_packages[0]}" ]]
    ;;
  *) exit 2;;
esac
# Verify bytes again inside the target environment, before executing the app.
python3 - "${task_packages[0]}" <<'PY'
import hashlib,json,sys
from pathlib import Path
p=Path(sys.argv[1]); report=json.loads(Path('/assets/installer.json').read_text())
with p.open('rb') as stream: actual=hashlib.file_digest(stream,'sha256').hexdigest()
assert actual==report['sha256'] and p.name==report['asset']
PY
case "$task_format" in
  deb) apt-get install -y "${task_packages[0]}";;
  rpm) dnf install -y "${task_packages[0]}";;
  arch) pacman -U --noconfirm "${task_packages[0]}";;
esac
desktop-file-validate /usr/share/applications/io.openforesight.App.desktop
useradd --create-home acceptance
install -d -o acceptance -g acceptance /home/acceptance/.local/share/open-foresight
printf preserve > /home/acceptance/.local/share/open-foresight/release-sentinel
chown acceptance:acceptance /home/acceptance/.local/share/open-foresight/release-sentinel
chown -R acceptance:acceptance /reports
# /models and /assets are read-only mounts; a setup regression cannot replace them.
runuser -u acceptance -- xvfb-run -a dbus-run-session -- \
  python3 /work/tools/test_installed_release.py --bundle /opt/open-foresight \
  --models /models --output /reports \
  --expected-revision "$(python3 -c 'import json; print(json.load(open("/assets/installer.json"))["source_commit"])')"
runuser -u acceptance -- python3 /work/tools/test_installed_persistence.py \
  --bundle /opt/open-foresight --profile /home/acceptance/.local/share/open-foresight \
  --state /reports/persistence.json --phase create
case "$task_format" in
  deb) apt-get install -y --reinstall "${task_packages[0]}";;
  rpm) dnf reinstall -y "${task_packages[0]}";;
  arch) pacman -U --noconfirm "${task_packages[0]}";;
esac
runuser -u acceptance -- python3 /work/tools/test_installed_persistence.py \
  --bundle /opt/open-foresight --profile /home/acceptance/.local/share/open-foresight \
  --state /reports/persistence.json --phase verify
case "$task_format" in
  deb) apt-get remove -y open-foresight;;
  rpm) dnf remove -y open-foresight;;
  arch) pacman -R --noconfirm open-foresight-bin;;
esac
test ! -e /usr/bin/open-foresight
test ! -e /opt/open-foresight
test "$(cat /home/acceptance/.local/share/open-foresight/release-sentinel)" = preserve
python3 - <<'PY'
import json,platform
from pathlib import Path
state=json.loads(Path('/reports/persistence.json').read_text())
assert state['status']=='verified_after_reinstall' and Path(state['database']).is_file()
report={'status':'passed','installer':json.loads(Path('/assets/installer.json').read_text()),
        'os_release':Path('/etc/os-release').read_text(),'architecture':platform.machine(),
        'ordinary_user_functional_tests':True,'reinstall':True,'uninstall':True,'user_data_preserved':True,
        'environment_kind':'container_xvfb','physical_desktop_hardware_tested':False}
Path('/reports/installation.json').write_text(json.dumps(report,indent=2)+'\n')
PY
