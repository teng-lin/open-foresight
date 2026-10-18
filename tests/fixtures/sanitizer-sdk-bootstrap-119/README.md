These are the original sanitizer workflow bytes and five cache-keyed file
SHA-256 values from PR119 source `2c083383ae9fad6f016a90bc9aee1cd8284f19c0`,
which produced the preserved SDK caches in run `39167769695`.

The workflow checksum is independently fixed in the regression test. Tests
verify current builder bytes against this manifest and reconstruct the original
recipe locally, so shallow checkouts and Docker contexts need no Git history or
network access to prove that cache migration preserves the original inputs.
