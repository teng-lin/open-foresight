#!/usr/bin/env bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends python3 binutils xvfb xauth dbus-x11 libgl1-mesa-dri libegl1
apt-get install -y /packages/*.deb
useradd --create-home package-test
runuser -u package-test -- xvfb-run -a dbus-run-session -- python3 /work/packaging/smoke_installed.py
apt-get remove -y open-foresight
