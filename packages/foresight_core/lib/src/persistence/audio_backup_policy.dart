import '../platform_services.dart';

/// Authoritative owner configuration only; never caller-supplied backup roots.
/// Creation and new-profile restore share these exclusions.
List<String> audioBackupForbiddenRoots({
  required RuntimeConfiguration configuration,
  required String profileDirectory,
  String? runtimeDirectory,
}) => List.unmodifiable({
  profileDirectory,
  if (runtimeDirectory != null) runtimeDirectory,
  for (final key in [
    'FORESIGHT_INSTALL_ROOT',
    'FORESIGHT_RUNTIME',
    'FORESIGHT_LITERT_CACHE',
    'PYTHONPYCACHEPREFIX',
  ])
    if (configuration[key] case final String value when value.isNotEmpty) value,
});
