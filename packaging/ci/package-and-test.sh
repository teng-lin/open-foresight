#!/usr/bin/env bash
# Runs in a disposable native distro container, never on the user's host.
set -euo pipefail
task_format=${1:?Expected deb, rpm, or arch}
task_version=${2:?Expected version}
task_release=${3:?Expected release}
task_mode=${4:-all}
case "$task_mode" in all|prepare|build|test) ;; *) exit 2;; esac
bash /work/packaging/ci/prepare-document-sandbox.sh "$task_format" package-test
case "$task_format" in
  deb)
    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y --no-install-recommends python3 binutils xz-utils xvfb xauth dbus-x11 libgl1-mesa-dri libegl-mesa0 libglx-mesa0 desktop-file-utils
    ;;
  rpm)
    dnf install -y python3 python3-rpm rpm-build binutils xorg-x11-server-Xvfb xorg-x11-xauth dbus-x11 mesa-dri-drivers mesa-libEGL mesa-libGL desktop-file-utils findutils tar gzip shadow-utils
    ;;
  arch)
    pacman -S --noconfirm --needed python binutils xorg-server-xvfb xorg-xauth dbus mesa desktop-file-utils
    ;;
  *) exit 2;;
esac
if [[ "$task_mode" == prepare ]]; then exit 0; fi
cd /work
if [[ "$task_mode" != test ]]; then
python3 packaging/check_preview_version.py "$task_format" "$task_version"
mkdir -p build/package-input dist/packages
(cd artifacts && sha256sum --check ./*.tar.gz.sha256)
tar -xzf artifacts/*.tar.gz -C build/package-input
if [[ "$task_format" == arch ]]; then
  chown -R package-test:package-test build/package-input dist/packages
  runuser -u package-test -- python3 packaging/package_linux.py \
    --bundle build/package-input/open-foresight --format arch --version "$task_version" --release "$task_release"
elif [[ "$task_format" == deb ]]; then
  python3 packaging/package_linux.py --bundle build/package-input/open-foresight --format deb --version "$task_version" --release "$task_release"
else
  python3 packaging/package_linux.py --bundle build/package-input/open-foresight --format rpm --version "$task_version" --release "$task_release"
fi
fi
if [[ "$task_mode" == build ]]; then
  printf 'Package bytes created; installation validation has not run.\n'
  exit 0
fi
case "$task_format" in
  deb) sha256sum --check dist/packages/*.deb.sha256; apt-get install -y "$(realpath dist/packages/*.deb)";;
  rpm) sha256sum --check dist/packages/*.rpm.sha256; dnf install -y dist/packages/*.rpm;;
  arch) sha256sum --check dist/packages/*.pkg.tar.zst.sha256; pacman -U --noconfirm dist/packages/*.pkg.tar.zst;;
esac
desktop-file-validate /usr/share/applications/io.openforesight.App.desktop
install -d -o package-test -g package-test /home/package-test/.local/share/open-foresight
# Expand HOME inside the package-test shell rather than the root shell.
# shellcheck disable=SC2016
runuser -u package-test -- sh -c 'printf preserve > "$HOME/.local/share/open-foresight/install-test-sentinel"'
runuser -u package-test -- xvfb-run -a dbus-run-session -- python3 packaging/smoke_installed.py
# Reinstall/upgrade the same version, then uninstall. All per-user data remains.
case "$task_format" in
  deb) apt-get install -y --reinstall "$(realpath dist/packages/*.deb)"; apt-get remove -y open-foresight;;
  rpm) dnf reinstall -y dist/packages/*.rpm; dnf remove -y open-foresight;;
  arch) pacman -U --noconfirm dist/packages/*.pkg.tar.zst; pacman -R --noconfirm open-foresight-bin;;
esac
test ! -e /usr/bin/open-foresight
test ! -e /opt/open-foresight
test "$(cat /home/package-test/.local/share/open-foresight/install-test-sentinel)" = preserve
printf 'Native %s installation, startup, reinstall, removal and data preservation passed.\n' "$task_format"
