# Inlined into Debian prerm/preinst, RPM pre/preun, and Arch pre_upgrade/pre_remove.
# A held lock belongs to a running service or recording. Never signal it.

installation_identity() {
  printf '%s' "$(readlink -f -- "$1")" | sha256sum | cut -c1-24
}

# Prints "allow" or "refuse". The opener anchors every component instead of
# trusting a pathname stat followed by a second, privileged open.
upgrade_lock_decision() {
  lock=$1
  if [ -z "$lock" ] || [ -L "$lock" ]; then
    printf '%s\n' refuse
    return 1
  fi
  if [ ! -e "$lock" ]; then
    printf '%s\n' allow
    return 0
  fi
  # Released paths use POSIX record locks; new paths use flock. /proc/self/fd
  # keeps traversal anchored without requiring a non-Essential Perl extension.
  if perl -e '
use Fcntl qw(F_SETLK F_WRLCK O_RDWR O_RDONLY O_NOFOLLOW O_DIRECTORY O_NONBLOCK S_ISDIR S_ISREG LOCK_EX LOCK_NB);
my @parts = split(m{/+}, $ARGV[0]);
shift @parts;
my $leaf = pop @parts;
sysopen(my $dir, "/", O_RDONLY | O_DIRECTORY) or exit 2;
for my $part (@parts) {
  exit 2 if $part eq "." || $part eq "..";
  sysopen(my $next, "/proc/self/fd/".fileno($dir)."/$part", O_RDONLY | O_DIRECTORY | O_NOFOLLOW) or exit 2;
  my @info = stat($next);
  S_ISDIR($info[2]) or exit 2;
  # A sticky root-owned temp ancestor is safe; no other writable ancestor is.
  exit 2 if ($info[2] & 0022) && !($info[4] == 0 && ($info[2] & 01000));
  $dir = $next;
}
sysopen(my $fh, "/proc/self/fd/".fileno($dir)."/$leaf", O_RDWR | O_NOFOLLOW | O_NONBLOCK) or exit 2;
my @info = stat($fh);
S_ISREG($info[2]) && $info[3] == 1 && !($info[2] & 0077) or exit 2;
if (($ARGV[1] // "legacy") eq "flock") {
  flock($fh, LOCK_EX | LOCK_NB) or exit 1;
  exit 0;
}
my $buf = pack("ssx4qqix4", F_WRLCK, 0, 0, 0, 0);
length($buf) == 32 or exit 2;
fcntl($fh, F_SETLK, $buf) or exit 1;
exit 0;
' -- "$lock" "${2-legacy}"; then
    printf '%s\n' allow
    return 0
  fi
  printf '%s\n' refuse
  return 1
}

check_installation_lock_directory() {
  dir=$1
  uid=$2
  lock=$dir/lock
  if [ -L "$dir" ] || [ "$(stat -c %u -- "$dir")" != "$uid" ] ||
     [ "$(stat -c %a -- "$dir")" != 700 ] ||
     { [ -e "$lock" ] && [ "$(stat -c %u -- "$lock")" != "$uid" ]; } ||
     [ -L "$lock" ]; then
    printf '%s\n' "Ignoring untrusted install lock directory: $dir" >&2
    return 0
  fi
  if [ -e "$lock" ]; then
    if ! upgrade_lock_decision "$lock" "${3-legacy}" >/dev/null; then
      printf '%s\n' "Open Foresight holds the install lock at $lock. A recording or the application service is running. Package files were not changed and no process was stopped." >&2
      return 1
    fi
  fi
}

refuse_upgrade_if_recording() {
  root=$1
  [ -d "$root" ] || return 0
  identity=$(installation_identity "$root")
  # Released services use this protocol. Keep checking it during upgrades.
  for dir in /tmp/of-install-*; do
    [ -d "$dir" ] || continue
    case $(basename -- "$dir") in
      of-install-[0-9]*-"$identity") ;;
      *) continue ;;
    esac
    uid=${dir##*/of-install-}
    uid=${uid%-"$identity"}
    case "$uid" in ''|*[!0-9]*)
      printf '%s\n' "Ignoring untrusted install lock directory: $dir" >&2
      continue ;;
    esac
    check_installation_lock_directory "$dir" "$uid" || return 1
  done
  # Never glob arbitrary homes or use HOME/XDG values supplied to a root script.
  # NSS is also the source new services use for their fixed per-user cache path.
  accounts=$(getent passwd) || return 1
  printf '%s\n' "$accounts" | while IFS=: read -r account unused uid gid description account_home shell; do
    case "$uid" in ''|*[!0-9]*) continue ;; esac
    case "$account_home" in /*) ;; *) continue ;; esac
    dir=$account_home/.cache/open-foresight/install-locks/$identity
    [ -d "$dir" ] || continue
    check_installation_lock_directory "$dir" "$uid" flock || return 1
  done
}

# New services check this before AND after acquiring their shared lock. Publish
# it before enumeration so no new owner can race the final package-file change.
# Keep a marker after interrupted installation; an explicit successful retry
# removes it only after package-manager completion.
begin_installation_maintenance() {
  root=$1
  maintenance_created=0
  [ ! -L "$root" ] || return 1
  if [ ! -d "$root" ]; then
    install -d -m 755 -- "$root" || return 1
  fi
  [ "$(stat -c %u -- "$root")" = "$(id -u)" ] || return 1
  maintenance=$root/.installation-maintenance
  if [ -e "$maintenance" ] || [ -L "$maintenance" ]; then
    [ ! -L "$maintenance" ] && [ -f "$maintenance" ] &&
      [ "$(stat -c %u -- "$maintenance")" = "$(id -u)" ] &&
      [ "$(stat -c %a -- "$maintenance")" = 600 ] &&
      [ "$(stat -c %h -- "$maintenance")" = 1 ] || return 1
  else
    (umask 077; set -C; : > "$maintenance") || return 1
    maintenance_created=1
  fi
}

finish_installation_maintenance() {
  root=$1
  maintenance=$root/.installation-maintenance
  if [ ! -e "$maintenance" ] && [ ! -L "$maintenance" ]; then
    return 0
  fi
  [ ! -L "$maintenance" ] && [ -f "$maintenance" ] &&
    [ "$(stat -c %u -- "$maintenance")" = "$(id -u)" ] &&
    [ "$(stat -c %a -- "$maintenance")" = 600 ] &&
    [ "$(stat -c %h -- "$maintenance")" = 1 ] || return 1
  rm -- "$maintenance"
}

prepare_installation_change() {
  begin_installation_maintenance "$1" || return 1
  if ! refuse_upgrade_if_recording "$1"; then
    if [ "$maintenance_created" = 1 ]; then
      finish_installation_maintenance "$1" || return 1
    fi
    return 1
  fi
}
