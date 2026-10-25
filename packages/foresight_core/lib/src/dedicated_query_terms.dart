import 'model_setup_status.dart';
import 'platform_services.dart';

/// The accepted revision is the authenticated model digest, not server metadata.
const dedicatedQueryTermsKey =
    'modelTerms.query-detector.$dedicatedQueryModelDigest';
Uri? dedicatedQueryTermsUri({RuntimeConfiguration? configuration}) {
  final uri = Uri.tryParse(
    (configuration ?? runtimeConfiguration)['FORESIGHT_QUERY_TERMS_URL'] ?? '',
  );
  return uri != null &&
          uri.scheme == 'https' &&
          uri.host.isNotEmpty &&
          uri.userInfo.isEmpty
      ? uri
      : null;
}
