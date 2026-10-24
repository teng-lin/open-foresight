/// Resolve a live bundled-runtime setting without importing native ownership.
String resolveLiteRtRunner(String registered, String? bundled) =>
    bundled ?? registered;
