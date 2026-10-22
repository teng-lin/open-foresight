import 'dart:convert';

import 'package:foresight_core/desktop.dart';

void main(List<String> arguments) {
  final period = OutputStatsPeriod.capture(DateTime.parse(arguments.single));
  print(jsonEncode({'key': period.key, ...period.toArguments()}));
}
