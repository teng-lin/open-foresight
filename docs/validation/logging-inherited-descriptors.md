# Logging child inherited-descriptor gate

`native/diagnostic_inherited.c` is a private startup component for an execed
diagnostic child, before profile or application authority. It accepts no
descriptor or path argument. The fixed inherited fd 10 must be the private
16 KiB kernel mailbox with the required UID, mode, access, size and Linux seals
or Darwin PSXSHM type. An ordinary candidate is neither closed nor mutated.

The gate removes that mailbox's intentional CLOEXEC exception, validates exact
`/dev/null` standard descriptors, and refuses every other non-CLOEXEC descriptor.
Linux scans actual procfs descriptors with a fixed 4 KiB getdents64 buffer and
finite entry/call limits, including descriptors above the current RLIMIT. Darwin
uses the public `PROC_PIDLISTFDS` API with a fixed 16 KiB buffer, refuses exact
fills/growth, and checks descriptor flags in two passes. The descriptor ceiling
is 2,048. There is no RLIMIT scan or guessed fallback.

After the gate, the component maps the mailbox and closes its known kernel fd.
The eventual child context owns the returned native mapping. This API is not a
Dart-mirrored pointer layout and is not a parent allocation API. Authentication,
watcher startup, HELLO/probe proof, JSON preflight and storage authority remain
separate work; mapping alone grants none of them.

Strict C11 native fixtures passed on Linux x86-64 and Apple Silicon macOS 26.6
with deployment target 15.0; Linux ASan/UBSan also passed. Actual controls include
a fresh mapping across exec, an unrelated inherited regular file at fd 5,003
above a lowered RLIMIT, 2,048 additional CLOEXEC descriptors, wrong standard-I/O
access mode, and external-process POSIX-lock preservation. Calling the gate with
an ordinary file at fd 10 preserves both its descriptor flags and its held lock.

Private probes also passed with the pinned raw Dart VM and compiled Dart AOT
executable on both hosts, under an environment containing only LANG/LC_ALL and
with stdin/stdout/stderr redirected to `/dev/null`. A test-only C shim keeps the
mapping native; Dart receives only a closed result code. These are tiny standalone
SDK probes, not the service's actual internal worker mode or installed acceptance.
The private probe sources and logs are under `/var/tmp/of-inherited-vm` on Linux
and `/private/var/tmp/of-log-inherited` on Mac.

Full native/Dart/application gates, independent source review, oldest-host and
installed execution remain required for the integrated worker. No child watchdog
or whole-logging acceptance follows from this descriptor-only component.
