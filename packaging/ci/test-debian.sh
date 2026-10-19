#!/usr/bin/env bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
bash /work/packaging/ci/prepare-document-sandbox.sh deb package-test
apt-get install -y --no-install-recommends python3 binutils xvfb xauth dbus-x11 libgl1-mesa-dri libegl-mesa0 libglx-mesa0
apt-get install -y /packages/*.deb
runuser -u package-test -- xvfb-run -a dbus-run-session -- python3 /work/packaging/smoke_installed.py
apt-get remove -y open-foresight
test ! -e /usr/bin/open-foresight
test ! -e /opt/open-foresight
test ! -e /usr/share/applications/io.openforesight.App.desktop
