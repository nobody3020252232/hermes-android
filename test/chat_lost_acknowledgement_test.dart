// A submit whose acknowledgement was lost keeps the local turn visible until
// its terminal row lands. The reader must still be able to leave that state by
// hand: the stop control releases the composer instead of parking it behind the
// reattach retry loop.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/chat_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/ws_client.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({'verbose_mode': false});
  });

  testWidgets('stop releases a turn whose acknowledgement was lost', (
    tester,
  ) async {
    await _pumpChat(
      tester,
      remoteSubmit:
          ({
            required sessionId,
            required text,
            required onEvent,
            required onSent,
          }) async {
            onSent();
            throw JsonRpcError(
              'prompt.submit',
              'Desktop gateway connection closed',
              reason: 'connection_closed',
            );
          },
    );

    await tester.enterText(find.byType(TextField), 'Long running task');
    await tester.tap(find.byTooltip('Send'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.textContaining('Send failed'), findsNothing);
    expect(find.text('Responding…'), findsOneWidget);
    expect(find.text('Connection lost — Hermes keeps working; reattaching…'),
        findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).enabled,
      isFalse,
      reason: 'the pending turn blocks a duplicate submit',
    );

    // The stop control is the escape hatch out of the pending-turn state.
    final stopButton = tester.widget<IconButton>(
      find.widgetWithIcon(IconButton, Icons.stop_rounded),
    );
    expect(stopButton.onPressed, isNotNull);
    stopButton.onPressed!();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('Responding…'), findsNothing);
    expect(find.byTooltip('Stop response'), findsNothing);
    expect(
      tester.widget<TextField>(find.byType(TextField)).enabled,
      isTrue,
      reason: 'stopping must hand the composer back',
    );
    expect(
      tester
          .widget<IconButton>(find.widgetWithIcon(IconButton, Icons.send))
          .onPressed,
      isNotNull,
    );
  });
}

Future<void> _pumpChat(
  WidgetTester tester, {
  required TestRemotePromptSubmit remoteSubmit,
}) async {
  final apiClient = ApiClient(
    baseUrl: 'http://lost-ack.fixture',
    apiKey: 'synthetic-key',
    httpClient: _EmptyChatHttpClient(),
  );
  await tester.pumpWidget(
    MaterialApp(
      home: ChatScreen(
        connection: SavedConnection(
          id: 'lost-ack',
          label: 'Fixture',
          host: 'lost-ack.fixture',
          port: 9119,
          apiKey: 'synthetic-key',
        ),
        session: const Session(
          id: 'lost-ack-session',
          title: 'Fixture chat',
          model: 'fixture-model',
          source: 'test',
          messageCount: 0,
          isActive: true,
          preview: '',
          startedAt: 1,
        ),
        testApiClient: apiClient,
        testRemotePromptSubmit: remoteSubmit,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

class _EmptyChatHttpClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    return http.StreamedResponse(
      Stream.value(utf8.encode(jsonEncode({'data': <Object>[]}))),
      200,
      headers: {'content-type': 'application/json'},
    );
  }
}
