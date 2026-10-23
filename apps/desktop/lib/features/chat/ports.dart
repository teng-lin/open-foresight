import 'package:flutter/widgets.dart';
import 'package:foresight_core/desktop.dart' show Citation;

abstract interface class ChatActivity {
  bool get asking;
  double get answerFontSize;
}

abstract interface class ChatCommands {
  void cite(Citation citation);
  void setAnswerFontSize(double value);
  void setQuestion(int? meetingScope, String text);
  Future<void> askQuestion({int? meetingScope});
  void citation(Map<String, Object?> citation);
  Widget chat({int? meetingScope, bool compact = false});
}

abstract interface class ChatPort implements ChatActivity, ChatCommands {}
