# Google Drive and Calendar sign-in

The setup instructions were caused by release packaging omitting the application
OAuth registration. The original Foresight bundles this registration. End users
authorize an account in their browser; they do not create a Cloud project.

Mac and Linux release workflows now consume `FORESIGHT_GOOGLE_CLIENT_JSON` and
require a valid application registration before assembling a release. Both
packagers normalize the Desktop client JSON and reject account-token fields.
Mac runtime configuration points both the desktop and the shared service to the
bundled file; Linux uses the existing common launcher. Private profile overrides
continue to take precedence. Unconfigured developer builds retain the setup UI.

Drive file, folder, and last-year imports now start sign-in directly when needed.
They remain available before connecting. Cancellation stops the import. Settings
and Calendar use the same connection.

## Reference evidence

Inspected `/Applications/Foresight.app`, build `1.0.0.28.20261005`:

- Executable SHA-256: `fa98b856bfbe9b40cdebfb9f975f7867ec5c0a3ca75b81214a096a60b6db8326`.
- Info.plist SHA-256: `11a819a7620a5ec66a7f71b00b63e55a2776561d140939a7f81506d4b9af484e`.
- REA plist evidence `ev_491b939eef561a86a4480b4724ade316465e487bce0ca28843eb27dadd0b7412`
  observes the bundled `GIDClientID` and callback URL schemes.
- That production client ID appears at executable file offset `0x5d7dca0`.
  Its corresponding application secret is at `0x60a9b70`. A bounded token-endpoint
  probe with a deliberately malformed authorization code returned `invalid_grant`
  for this pair; mismatched pairs returned `invalid_client`. This establishes the
  client pairing, not completed consent, redirect acceptance, or account access.

The importer reads these immutable bytes only after checking the exact executable
hash. It does not inspect profiles, Keychain, saved accounts, or refresh tokens.
Registration values are never printed or committed. Provision only the Google
registration with:

```sh
python3 tools/reference_distribution_config.py --google-only --github-repository owner/repo
```

For a local build, use `--google-output /private/path/google-client.json` and pass
that path to the packager's `--google-client` option. The output is exclusive and
owner-readable. For source development, set `FORESIGHT_GOOGLE_CLIENT` to that file.

## Validation

- Packaging tests cover required configuration, explicit-file precedence,
  normalization, private output, rejection of account tokens, and redacted errors.
- Widget tests cover direct sign-in from Settings, Calendar, and all three Drive
  imports, cancellation without imports, and the developer setup fallback.
- Core Google and remote-facade tests cover PKCE, state validation, consent,
  refresh/revocation, Drive imports, Calendar synchronization, and service routing
  using controlled fixtures.
- `tool/verify_google_configuration.dart` was run against the extracted production
  registration in relocated Mac resources, without direct credential overrides.
  It verified default configuration resolution, the read-only scopes, PKCE and
  the loopback browser invitation, then cancelled without contacting Google or
  creating account state. Mac CI runs this check against the packaged resources.

An actual Google account consent and live Drive/Calendar import were not performed
in this change. The original project remains externally controlled; independent
distributors can supply their own application registration.
