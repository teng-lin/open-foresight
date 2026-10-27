#!/bin/sh
# Manual Linux-only synthetic graph qualification. No physical device or
# default user session is accessed. Run under dbus-run-session as a non-root
# user with PipeWire/WirePlumber tools installed. Preserve every fixture/log.
set -eu
[ "$#" -eq 1 ] && [ -x "$1" ] && [ "$(id -u)" -ne 0 ]
case "$1" in /*) ;; *) echo 'probe must be an absolute executable path' >&2; exit 2 ;; esac
[ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]
probe_executable=$1
probe_root=$(mktemp -d "${FORESIGHT_TEST_TEMP_ROOT:-/var/tmp}/of-output-XXXXXX")
chmod 700 "$probe_root"
install -d -m 700 "$probe_root/run" "$probe_root/config" "$probe_root/state" "$probe_root/cache" "$probe_root/logs"
printf 'output_graph_fixture=%s\n' "$probe_root"
export XDG_RUNTIME_DIR="$probe_root/run" PIPEWIRE_RUNTIME_DIR="$probe_root/run" PIPEWIRE_REMOTE=pipewire-0
export XDG_CONFIG_HOME="$probe_root/config" XDG_STATE_HOME="$probe_root/state" XDG_CACHE_HOME="$probe_root/cache" TMPDIR="$probe_root"
pipewire > "$probe_root/logs/pipewire.log" 2>&1 &
probe_pw_pid=$!
wireplumber > "$probe_root/logs/wireplumber.log" 2>&1 &
probe_wp_pid=$!
trap 'timeout 5 pw-dump > "$probe_root/logs/graph-final.json" 2>&1 || true; kill "$probe_wp_pid" "$probe_pw_pid" 2>/dev/null || true; wait "$probe_wp_pid" "$probe_pw_pid" 2>/dev/null || true' EXIT
probe_ready=false
for _probe_index in $(seq 1 100); do
  if timeout 2 pw-cli info 0 > "$probe_root/logs/core.txt" 2>&1; then probe_ready=true; break; fi
  sleep 0.05
done
[ "$probe_ready" = true ]
timeout 5 pw-cli create-node adapter '{ factory.name = support.null-audio-sink node.name = foresight_output_fixture_sink media.class = Audio/Sink audio.position = [ FL FR ] object.linger = true }' > "$probe_root/logs/null-sink.txt" 2>&1
probe_policy=false
for _probe_index in $(seq 1 100); do
  if timeout 2 wpctl inspect @DEFAULT_AUDIO_SINK@ > "$probe_root/logs/default-sink.txt" 2>&1 && grep -q foresight_output_fixture_sink "$probe_root/logs/default-sink.txt"; then probe_policy=true; break; fi
  sleep 0.05
done
[ "$probe_policy" = true ]
FORESIGHT_TEST_OUTPUT_GRAPH=1 timeout 30 "$probe_executable" foresight_output_fixture_sink > "$probe_root/logs/probe.txt" 2>&1
cat "$probe_root/logs/probe.txt"
