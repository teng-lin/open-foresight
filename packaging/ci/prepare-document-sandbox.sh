#!/usr/bin/env bash
# Disposable distro containers only. Fail before GTK/package/model setup.
set -euo pipefail
task_format=${1:?deb rpm or arch}
task_user=${2:?ordinary smoke-test user}
[[ "$task_user" =~ ^[a-z][a-z0-9-]*$ ]] || exit 2
case "$task_format" in
  deb)
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y --no-install-recommends bubblewrap passwd
    ;;
  rpm) dnf install -y bubblewrap shadow-utils ;;
  arch) pacman -Syu --noconfirm --needed bubblewrap shadow ;;
  *) exit 2;;
esac
useradd --create-home "$task_user"
printf 'Checking isolated document namespaces as ordinary user %s.\n' "$task_user"
# Keep the production launcher's namespace, capability, mount and environment
# restrictions. Only the selected document/extractor is replaced by /usr/bin/true.
runuser -u "$task_user" -- /usr/bin/bwrap \
  --unshare-all --die-with-parent --new-session --cap-drop ALL \
  --ro-bind /usr /usr --ro-bind-try /lib /lib --ro-bind-try /lib64 /lib64 \
  --ro-bind-try /etc/fonts /etc/fonts --proc /proc --dev /dev --tmpfs /tmp \
  --dir /input --chdir /input --clearenv \
  --setenv HOME /tmp --setenv PATH /nonexistent -- /usr/bin/true
