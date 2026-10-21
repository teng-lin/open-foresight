import 'dart:async';
import 'dart:io';
import 'application.dart';
import 'helper.dart';
import 'service_socket.dart';
import 'service_ownership.dart';
import 'store.dart';

/// Resources owned by a failed start. This rollback never closes a live owner.
class ServiceStartupResources {
  ServiceStartupResources({
    required this.lock,
    required this.store,
    required this.helper,
    required this.application,
    required this.binding,
    required this.endpointRecord,
    required this.temporary,
    required this.publishedRecord,
    required this.adoptedRecord,
    this.claimed,
  });
  final RandomAccessFile lock;
  final Store? store;
  final Helper? helper;
  final Application? application;
  final ServiceSocketBinding? binding;
  final File endpointRecord, temporary;
  final bool publishedRecord, adoptedRecord;
  final String? claimed;
  Future<void> rollback() async {
    // Report cleanup failures, but keep the startup failure and always
    // release ownership.
    Future<void> cleanup(FutureOr<void> Function() step) async {
      try {
        await step();
      } catch (error) {
        stderr.writeln('Application service startup cleanup: $error');
      }
    }

    try {
      // Background timers would otherwise keep a worker isolate alive.
      await cleanup(() => application?.close());
      await cleanup(() => binding?.listener.close());
      // Only a socket this attempt published is its own to remove; one
      // that refused to clear the path, or replaced this one, belongs to
      // another owner.
      await cleanup(() => binding?.unpublish());
      await cleanup(() => helper?.close());
      await cleanup(() => store?.close());
      // Remove the record while the lock is still held, so no launcher sees
      // a record without an owner that this failed attempt left behind.
      await cleanup(() {
        if (publishedRecord &&
            !adoptedRecord &&
            FileSystemEntity.typeSync(
                  endpointRecord.path,
                  followLinks: false,
                ) !=
                FileSystemEntityType.notFound) {
          endpointRecord.deleteSync();
        }
      });
      // A claimed record this attempt neither set aside nor replaced goes
      // back, so the next owner adopts its runtime again.
      await cleanup(() {
        if (!publishedRecord &&
            claimed != null &&
            FileSystemEntity.typeSync(claimed!, followLinks: false) !=
                FileSystemEntityType.notFound) {
          renameServiceEndpointEntry(claimed!, endpointRecord.path);
        }
      });
      await cleanup(() {
        if (FileSystemEntity.typeSync(temporary.path, followLinks: false) ==
            FileSystemEntityType.file) {
          temporary.deleteSync();
        }
      });
    } finally {
      lock.closeSync();
    }
  }
}
