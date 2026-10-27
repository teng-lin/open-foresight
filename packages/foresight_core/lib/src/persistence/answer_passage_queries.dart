import 'package:sqlite3/sqlite3.dart';
import '../answer_ranking.dart';
import 'source_contents.dart';
import 'read_schema_guard.dart';

List<Map<String, Object?>> readAnswerPassages(
  Database db,
  String question,
  Map<String, Object?> revisions,
  List<Map<String, Object?>> semantic, {
  required int supportedVersion,
}) => readSnapshot(db, () {
  final documents = db
      .select(
        "SELECT id,title,content,revision,generated FROM sources WHERE deleted=0 AND state='indexed'",
      )
      .where((row) => revisions[row['id']] == row['revision'])
      .map((row) => materializeSource(db, Map<String, Object?>.from(row)))
      .toList();
  return rankAnswerPassages(question, documents, semantic);
}, supportedVersion: supportedVersion);
