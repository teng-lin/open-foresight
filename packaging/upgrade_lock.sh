# Inlined into Debian prerm/preinst, RPM pre/preun, and Arch pre_upgrade/pre_remove.
# A held lock belongs to a running service or recording. Never signal it.

installation_identity() {
  printf '%s' "$(readlink -f -- "$1")" | sha256sum | cut -c1-24
}

# Prints "allow" or "refuse". Exit 0 allows the package change; exit 1 refuses
# it before files under the install root are replaced.
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
  # Non-blocking exclusive POSIX record lock (F_SETLK / lockf), same family as
  # Dart FileLock.shared. Debian preinst uses Essential perl-base. The packed
  # buffer is the 32-byte Linux LP64 record-lock structure.
  if perl -e '
use Fcntl qw(F_SETLK F_WRLCK O_RDWR O_NOFOLLOW);
sysopen(my $fh, $ARGV[0], O_RDWR | O_NOFOLLOW) or exit 2;
my $buf = pack("ssx4qqix4", F_WRLCK, 0, 0, 0, 0);
length($buf) == 32 or exit 2;
fcntl($fh, F_SETLK, $buf) or exit 1;
exit 0;
' -- "$lock"; then
    printf '%s\n' allow
    return 0
  fi
  printf '%s\n' refuse
  return 1
}

refuse_upgrade_if_recording() {
  root=$1
  if [ ! -d "$root" ]; then
    return 0
  fi
  identity=$(installation_identity "$root")
  for dir in /tmp/of-install-*; do
    [ -d "$dir" ] || continue
    case $(basename -- "$dir") in
      of-install-[0-9]*-"$identity") ;;
      *) continue ;;
    esac
    lock=$dir/lock
    if [ -e "$lock" ] || [ -L "$lock" ]; then
      if ! upgrade_lock_decision "$lock" >/dev/null; then
        printf '%s\n' "Open Foresight holds the install lock at $lock. A recording or the application service is running. Package files were not changed and no process was stopped." >&2
        return 1
      fi
    fi
  done
  return 0
}
