import '../sql_support_test_bootstrap.dart';
// Exit immediately after atomic payload publication, before any completion
// manifest. The next real Store upgrade must ignore and reclaim this orphan.
import 'dart:io';

import 'package:foresight_core/src/persistence/backup_files.dart';
import 'package:foresight_core/src/persistence/snapshot_vfs.dart';
import 'package:foresight_core/src/persistence/sqlite_runtime.dart';

Future<void> main(List<String> arguments) async {
  bootstrapSqlSupportFixture();
  final directory = BackupDirectory('${arguments.single}.backups');
  const name = 'snapshot-1-00000000000000000000000000000000.db';
  final file = directory.open('$name.partial', create: true);
  final journal = directory.open('$name.json.partial', create: true);
  final vfs = SnapshotVfs(file, writable: true, journal: journal);
  vfs.registered(() {
    final db = sqlite3.open('/snapshot', vfs: vfs.name);
    try {
      db.execute('CREATE TABLE payload(value TEXT)');
    } finally {
      db.dispose();
    }
  });
  journal.close();
  directory.remove('$name.json.partial');
  file.sync();
  file.close();
  directory.publish('$name.partial', name);
  stdout.writeln('published_without_manifest');
  await stdout.flush();
  exit(79);
}
