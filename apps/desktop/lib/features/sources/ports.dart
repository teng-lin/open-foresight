abstract interface class SourceCommands {
  Future<bool> sourceById(String id, {int? expectedRevision});
  Future<void> source(Map<String, Object?> source);
  Future<void> findLocalFiles({List<String>? roots});
  Future<void> import();
  Future<void> importFolder();
  Future<void> importUrl();
}
