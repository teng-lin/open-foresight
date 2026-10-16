import 'dart:convert';

Map<String, dynamic> referenceTextMessage(String role, String text) => {
  'role': role,
  'content': [
    {'type': 'text', 'text': text},
  ],
};

/// Original history stores the plain query and structured assistant response,
/// before final citation selection/renumbering. Legacy answers have only text.
List<Map<String, dynamic>> referenceChatHistory(
  Iterable<Map<String, Object?>> answers,
) => [
  for (final answer in answers) ...[
    referenceTextMessage('user', answer['question'] as String),
    if (answer['model_response'] case final String response)
      jsonDecode(response) as Map<String, dynamic>
    else
      referenceTextMessage('assistant', answer['body'] as String),
  ],
];
