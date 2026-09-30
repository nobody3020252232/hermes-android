import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/attachment_draft.dart';
import 'package:hermes_android/core/screens/chat_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/ws_client.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_voice_composer_adapter.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({'verbose_mode': false});
  });

  testWidgets(
    'a Remote submit that reached the wire keeps the turn instead of '
    'refilling the prompt',
    (tester) async {
      final drafts = [
        _attachedDraft('first', '@file:first-ref'),
        _attachedDraft('second', '@file:second-ref'),
        _attachedDraft('third', '@file:third-ref'),
      ];
      var submitCount = 0;
      String? submittedText;
      await _pumpChat(
        tester,
        drafts: drafts,
        remoteSubmit:
            ({
              required sessionId,
              required text,
              required onEvent,
              required onSent,
            }) async {
              onSent();
              submitCount += 1;
              submittedText = text;
              throw JsonRpcError(
                'prompt.submit',
                'Desktop gateway connection closed',
              );
            },
      );

      await tester.enterText(find.byType(TextField), 'Retry this prompt');
      await tester.tap(find.byTooltip('Send'));
      await tester.pump();
      await tester.pump();

      expect(submitCount, 1);
      expect(
        submittedText,
        'Retry this prompt\n\n'
        '@file:first-ref\n@file:second-ref\n@file:third-ref',
      );
      // The prompt reached the wire: claiming a failed send here would invite
      // a duplicate of work the server may already be doing.
      expect(find.textContaining('Send failed'), findsNothing);
      expect(find.text('Responding…'), findsOneWidget);
      expect(find.byTooltip('Stop response'), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        '',
        reason: 'the draft must not come back',
      );
      expect(
        tester.widget<TextField>(find.byType(TextField)).enabled,
        isFalse,
        reason: 'the composer blocks a duplicate submit while reattaching',
      );
      // The attachments went with the prompt, so they are not offered again.
      expect(find.bySemanticsLabel('Attachment 1 of 3'), findsNothing);
      expect(find.bySemanticsLabel('Attachment 2 of 3'), findsNothing);
      expect(find.bySemanticsLabel('Attachment 3 of 3'), findsNothing);
      expect(
        drafts.map((draft) => draft.status),
        everyElement(AttachmentDraftStatus.attached),
      );
      expect(drafts.map((draft) => draft.refText), [
        '@file:first-ref',
        '@file:second-ref',
        '@file:third-ref',
      ]);

      // Nothing is resubmitted while the reader waits for the reply.
      await tester.pump(const Duration(seconds: 10));
      expect(submitCount, 1);
    },
  );

  testWidgets(
    'an authoritative rejection still hands the prompt and drafts back',
    (tester) async {
      final drafts = [
        _attachedDraft('first', '@file:first-ref'),
        _attachedDraft('second', '@file:second-ref'),
        _attachedDraft('third', '@file:third-ref'),
      ];
      var submitCount = 0;
      String? submittedText;
      await _pumpChat(
        tester,
        drafts: drafts,
        remoteSubmit:
            ({
              required sessionId,
              required text,
              required onEvent,
              required onSent,
            }) async {
              submitCount += 1;
              submittedText = text;
              // No onSent: the prompt never reached the wire, and the gateway
              // rejected it outright (no transport marker in the message).
              throw JsonRpcError('prompt.submit', 'Session is not available');
            },
      );

      await tester.enterText(find.byType(TextField), 'Retry this prompt');
      await tester.tap(find.byTooltip('Send'));
      await tester.pump();
      await tester.pumpAndSettle();

      expect(submitCount, 1);
      expect(submittedText, contains('Retry this prompt'));
      expect(
        find.text(
          'Send failed: JsonRpcError(prompt.submit): Session is not available',
        ),
        findsOneWidget,
      );
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'Retry this prompt',
        reason: 'nothing was submitted, so the draft comes back',
      );
      expect(find.bySemanticsLabel('Attachment 1 of 3'), findsOneWidget);
      expect(find.bySemanticsLabel('Attachment 2 of 3'), findsOneWidget);
      expect(find.bySemanticsLabel('Attachment 3 of 3'), findsOneWidget);
      expect(
        tester.getSemantics(find.bySemanticsLabel('Attachment 1 of 3')).value,
        'Uploaded',
      );
      expect(
        tester.getSemantics(find.bySemanticsLabel('Attachment 2 of 3')).value,
        'Uploaded',
      );
      expect(
        tester.getSemantics(find.bySemanticsLabel('Attachment 3 of 3')).value,
        'Uploaded',
      );
      expect(find.text('first.txt'), findsOneWidget);
      expect(find.text('second.txt'), findsOneWidget);
      expect(find.text('third.txt'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('first.txt')).dy,
        lessThan(tester.getTopLeft(find.text('second.txt')).dy),
      );
      expect(
        tester.getTopLeft(find.text('second.txt')).dy,
        lessThan(tester.getTopLeft(find.text('third.txt')).dy),
      );
      expect(
        drafts.map((draft) => draft.status),
        everyElement(AttachmentDraftStatus.attached),
      );
      expect(drafts.map((draft) => draft.refText), [
        '@file:first-ref',
        '@file:second-ref',
        '@file:third-ref',
      ]);
      expect(
        tester
            .widget<IconButton>(find.widgetWithIcon(IconButton, Icons.send))
            .onPressed,
        isNotNull,
        reason: 'the composer is usable for an explicit retry',
      );

      await tester.pump(const Duration(seconds: 10));
      expect(submitCount, 1);
    },
  );
}

AttachmentDraft _attachedDraft(String id, String refText) {
  return AttachmentDraft(
    id: id,
    cachedPath: 'C:/synthetic/$id.txt',
    name: '$id.txt',
    byteLength: 4,
    mediaType: 'text/plain',
    kind: AttachmentDraftKind.genericFile,
    status: AttachmentDraftStatus.attached,
    refText: refText,
  );
}

Future<void> _pumpChat(
  WidgetTester tester, {
  required List<AttachmentDraft> drafts,
  required TestRemotePromptSubmit remoteSubmit,
}) async {
  final apiClient = ApiClient(
    baseUrl: 'http://failure.fixture',
    apiKey: 'synthetic-key',
    httpClient: _EmptyChatHttpClient(),
  );
  await tester.pumpWidget(
    MaterialApp(
      home: ChatScreen(
        connection: SavedConnection(
          id: 'failure-fixture',
          label: 'Failure fixture',
          host: 'failure.fixture',
          port: 8642,
          apiKey: 'synthetic-key',
        ),
        session: const Session(
          id: 'failure-session',
          title: 'Failure chat',
          model: 'fixture-model',
          source: 'test',
          messageCount: 0,
          isActive: true,
          preview: '',
          startedAt: 1,
        ),
        testApiClient: apiClient,
        testRemotePromptSubmit: remoteSubmit,
        testInitialAttachmentDrafts: drafts,
        testVoiceComposerAdapter: FakeVoiceComposerAdapter(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

class _EmptyChatHttpClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request.method == 'GET' && request.url.path.endsWith('/messages')) {
      return http.StreamedResponse(
        Stream.value(utf8.encode(jsonEncode({'data': <Object>[]}))),
        200,
        headers: {'content-type': 'application/json'},
      );
    }
    return http.StreamedResponse(
      Stream.value(utf8.encode(jsonEncode({'error': 'unexpected request'}))),
      404,
      headers: {'content-type': 'application/json'},
    );
  }
}
