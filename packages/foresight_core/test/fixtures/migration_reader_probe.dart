import 'dart:io';
import 'package:foresight_core/src/store.dart';

void main(List<String> arguments) {
  final store = Store.readOnly(arguments.single);
  try {
    store.rows('SELECT COUNT(*) FROM preferences');
    stdout.writeln('reader_opened');
  } finally {
    store.close();
  }
}
