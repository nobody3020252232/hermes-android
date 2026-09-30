// The API-server (8642) transport cannot reattach to a live run, but the server
// owns the turn from the moment the request is accepted. A dropped SSE stream
// therefore must not be reported as a failed send: the turn stays visible and
// the reply is picked up from the session history when it lands.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/chat_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({'verbose_mode': false});
  });

  testWidgets(
    'a dropped SSE stream keeps the turn and lands the server reply',
    (tester) async {
      final client = _DroppingSseChatHttpClient(_history());
      await _pumpChat(tester, client);
      final controller = _chatController(tester);
      expect(controller.position.pixels, controller.position.maxScrollExtent);

      await tester.enterText(find.byType(TextField), 'Long running task');
      await tester.tap(find.byTooltip('Send'));
      await tester.pump();
      await client.postStarted.future;
      client.emitToken('partial answer');
      await tester.pump();
      await tester.pump();

      // The socket dies mid-answer.
      client.dropStream(
        'ClientException: Connection closed while receiving data, '
        'uri=http://fixture.example/v1/chat/completions',
      );
      await tester.pump();
      await tester.pump();

      expect(
        find.textContaining('Send failed'),
        findsNothing,
        reason: 'the API server owns the turn once the request was accepted',
      );
      expect(find.text('Responding…'), findsOneWidget);
      expect(find.text('Connection lost — waiting for Hermes to finish…'),
          findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        '',
        reason: 'the draft must not come back',
      );
      expect(
        tester.widget<TextField>(find.byType(TextField)).enabled,
        isFalse,
        reason: 'the composer stays blocked while the turn is unresolved',
      );

      // The server finished the turn while the app was reconnecting: the reply
      // is already persisted, so the next history poll adopts it.
      client.serverMessages = [
        ..._history(),
        {'role': 'user', 'content': 'Long running task'},
        {'role': 'assistant', 'content': 'Server finished answer'},
      ];
      await tester.pump(const Duration(seconds: 4));
      await tester.pump(const Duration(seconds: 4));

      expect(find.text('Server finished answer'), findsOneWidget);
      expect(find.text('Responding…'), findsNothing);
      expect(
        tester.widget<TextField>(find.byType(TextField)).enabled,
        isTrue,
        reason: 'the composer returns once the reply landed',
      );
    },
  );

  testWidgets(
    'a stream that never started still reports the send failure',
    (tester) async {
      final client = _DroppingSseChatHttpClient(_history());
      await _pumpChat(tester, client);

      await tester.enterText(find.byType(TextField), 'Never sent');
      await tester.tap(find.byTooltip('Send'));
      await tester.pump();
      await client.postStarted.future;
      client.dropStream('ClientException: Connection refused');

      await tester.pumpAndSettle();

      expect(find.textContaining('Send failed'), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        '',
        reason: 'the REST path removes the optimistic user message',
      );
    },
  );
}

Future<void> _pumpChat(
  WidgetTester tester,
  _DroppingSseChatHttpClient client,
) async {
  final apiClient = ApiClient(
    baseUrl: 'http://fixture.example',
    apiKey: 'synthetic-key',
    httpClient: client,
  );
  await tester.pumpWidget(
    MaterialApp(
      home: ChatScreen(
        connection: SavedConnection(
          id: 'sse-drop',
          label: 'Fixture',
          host: 'fixture.example',
          port: 8642,
          apiKey: 'synthetic-key',
        ),
        session: Session(
          id: 'sse-drop-session',
          title: 'Fixture chat',
          model: 'fixture-model',
          source: 'test',
          messageCount: client.serverMessages.length,
          isActive: true,
          preview: '',
          startedAt: 1,
        ),
        testApiClient: apiClient,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

ScrollController _chatController(WidgetTester tester) =>
    tester.widget<ListView>(find.byType(ListView).first).controller!;

List<Map<String, dynamic>> _history() => [
  for (var index = 0; index < 24; index++)
    {
      'role': index.isEven ? 'user' : 'assistant',
      'content': 'message $index\n${List.filled(5, 'history line').join('\n')}',
    },
];

class _DroppingSseChatHttpClient extends http.BaseClient {
  List<Map<String, dynamic>> serverMessages;
  final Completer<void> postStarted = Completer<void>();
  StreamController<List<int>>? _stream;

  _DroppingSseChatHttpClient(this.serverMessages);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request.method == 'GET' && request.url.path.endsWith('/messages')) {
      return _json({'data': serverMessages});
    }
    if (request.method == 'POST' &&
        request.url.path.endsWith('/v1/chat/completions')) {
      _stream = StreamController<List<int>>();
      if (!postStarted.isCompleted) postStarted.complete();
      return http.StreamedResponse(
        _stream!.stream,
        200,
        headers: {'content-type': 'text/event-stream'},
      );
    }
    return _json({'error': 'unexpected request'}, statusCode: 404);
  }

  void emitToken(String token) {
    _stream!.add(
      utf8.encode(
        'data: ${jsonEncode({
          'choices': [
            {
              'delta': {'content': token},
            },
          ],
        })}\n\n',
      ),
    );
  }

  /// The transport dies without an SSE `[DONE]`: the body stream errors out.
  void dropStream(String message) {
    _stream!
      ..addError(http.ClientException(message))
      ..close();
  }

  http.StreamedResponse _json(Object body, {int statusCode = 200}) =>
      http.StreamedResponse(
        Stream.value(utf8.encode(jsonEncode(body))),
        statusCode,
        headers: {'content-type': 'application/json'},
      );
}
