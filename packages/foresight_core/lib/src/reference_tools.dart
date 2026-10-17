/// The original google_search definition before the backend's tool wrapper.
Map<String, dynamic> referenceGoogleSearchTool() => {
  'name': 'google_search',
  'description':
      'Performs a Google search for the given query and returns a summary of the top results. Use this ONLY when you do not already know the answer from your internal knowledge, or when the information requires real-time/current data that may have changed recently.',
  'parameters': {
    'type': 'object',
    'properties': {
      'query': {
        'type': 'string',
        'description': "The search query, formulated from the user's question.",
        'nullable': false,
      },
    },
    'required': ['query'],
  },
};

typedef ReferenceToolCallback = Future<Object?> Function(Map<String, dynamic>);

class ReferenceToolDispatcher {
  ReferenceToolDispatcher(this.callbacks);
  final Map<String, ReferenceToolCallback> callbacks;

  Map<String, dynamic> _error(String name, String message) => {
    'tool_name': name,
    'status': 'error',
    'message': message,
    'type': 'tool_response',
  };

  Future<Map<String, dynamic>> execute(Object? call) async {
    if (call is! Map || call['function'] is! Map) {
      return _error('unknown', 'Invalid tool_call format');
    }
    String? name;
    try {
      final function = call['function'] as Map<String, dynamic>;
      name = function['name'] as String?;
      final rawArgs = function['arguments'];
      final Map<String, dynamic> args;
      if (rawArgs is Map<String, dynamic>) {
        args = rawArgs;
      } else if (rawArgs is String) {
        // Deliberately do not JSON-decode a string: original wraps it as query.
        args = {'query': rawArgs};
      } else {
        return _error(
          name ?? 'unknown',
          'Invalid function arguments format in tool_call',
        );
      }
      final query = args['query'] as String?;
      if (name == null) {
        return _error('unknown', 'Invalid function format in tool_call');
      }
      final callback = callbacks[name];
      if (callback == null) return _error(name, 'Tool "$name" not registered');
      final result = await callback(args);
      return {
        'tool_name': name,
        'tool_response': result,
        'status': 'success',
        'type': 'tool_response',
        'original_query': query ?? '',
      };
    } catch (error) {
      return _error(name ?? 'unknown', error.toString());
    }
  }

  Future<Map<String, dynamic>> handle(
    List<dynamic> calls, {
    int maxTokens = 20000,
  }) async => referenceToolResultMessage(
    await Future.wait(calls.map(execute)),
    maxTokens: maxTokens,
  );
}

/// Original tool results are combined into a user-role text message.
Map<String, dynamic> referenceToolResultMessage(
  List<Map<String, dynamic>> results, {
  int maxTokens = 20000,
}) {
  final text = StringBuffer()
    ..writeln('The search results for the previous request are provided below:')
    ..writeln('---');
  for (final result in results) {
    final name = result['tool_name'];
    if (result['status'] == 'success') {
      text
        ..writeln('Result for tool "$name":')
        ..writeln(result['tool_response']);
    } else {
      text.writeln('Error from tool "$name": ${result['message']}');
    }
    text.writeln('---');
  }
  var body = text.toString();
  // The reference bounds UTF-16 units, not UTF-8 bytes or actual token count.
  if (body.length > maxTokens * 4) body = body.substring(0, maxTokens * 4);
  return {
    'role': 'user',
    'content': [
      {'type': 'text', 'text': body},
    ],
  };
}
