/// Validated executable metadata, never an application/profile path resolver.
/// The native reserve parser independently enforces its fixed framing bounds.
final class DiagnosticStorageCommand {
  DiagnosticStorageCommand({
    required this.nativeId,
    required this.dartId,
    required this.catalogId,
    required List<String> arguments,
  }) : arguments = List.unmodifiable(arguments);
  final String nativeId, dartId, catalogId;
  final List<String> arguments;
}
