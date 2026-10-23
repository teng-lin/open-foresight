import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:foresight_test_support/macos_integration_runtime.dart';

import '../../../tests/service/remote_client_probe.dart' as probe;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native facade preserves read-only reads and reconnect semantics',
    (tester) async {
      prepareMacosIntegrationRuntime(registerTearDown: addTearDown);
      await tester.pumpWidget(const MaterialApp(home: Scaffold()));
      final report = await tester.runAsync(probe.runRemoteClientProbe);
      expect(report, isNotNull);
      final path = Platform.environment['FORESIGHT_REMOTE_FACADE_REPORT'];
      expect(path, isNotNull);
      await File(path!).writeAsString(jsonEncode(report));
    },
  );
}
