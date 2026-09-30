import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/ws_client.dart';
import 'package:hermes_android/core/utils/send_delivery.dart';

void main() {
  group('classifySendDelivery', () {
    test('streamed content proves the server ran the turn', () {
      expect(
        classifySendDelivery(
          JsonRpcError('prompt.submit', 'Session is not available'),
          responseStarted: true,
          deliveryStarted: false,
        ),
        SendDelivery.uncertain,
      );
    });

    test('a closed socket is not an authoritative rejection', () {
      // The shape the gateway actually raises when the socket dies mid-submit.
      final error = JsonRpcError(
        'prompt.submit',
        'Desktop gateway connection closed',
        reason: 'connection_closed',
      );
      expect(
        classifySendDelivery(
          error,
          responseStarted: false,
          deliveryStarted: true,
        ),
        SendDelivery.uncertain,
      );
    });

    test('a message-only connection drop is still ambiguous', () {
      expect(
        classifySendDelivery(
          JsonRpcError('prompt.submit', 'Desktop gateway connection closed'),
          responseStarted: false,
          deliveryStarted: true,
        ),
        SendDelivery.uncertain,
      );
    });

    test('a socket that died before the frame went out is a rejection', () {
      final error = JsonRpcError(
        'prompt.submit',
        'Desktop gateway connection closed',
        reason: 'connection_closed',
      );
      expect(
        classifySendDelivery(
          error,
          responseStarted: false,
          deliveryStarted: false,
        ),
        SendDelivery.rejected,
      );
    });

    test('an authoritative gateway rejection keeps the draft', () {
      expect(
        classifySendDelivery(
          JsonRpcError('prompt.submit', 'Session is not available', code: -32602),
          responseStarted: false,
          deliveryStarted: true,
        ),
        SendDelivery.rejected,
      );
    });

    test('a REST stream that died mid-answer is ambiguous', () {
      expect(
        classifySendDelivery(
          'ClientException: Connection closed while receiving data, '
          'uri=http://100.86.93.23:8642/v1/chat/completions',
          responseStarted: false,
        ),
        SendDelivery.uncertain,
      );
      expect(
        classifySendDelivery(
          'ClientException: Connection reset by peer (OS Error)',
          responseStarted: false,
        ),
        SendDelivery.uncertain,
      );
      expect(
        classifySendDelivery(
          'SocketException: Connection closed before full header was received',
          responseStarted: false,
        ),
        SendDelivery.uncertain,
      );
    });

    test('a request that never reached the server keeps the draft', () {
      for (final message in const [
        'ClientException: Connection refused',
        'SocketException: Failed host lookup: "fixture.example"',
        'HTTP 503',
        'HTTP 400: model is required',
      ]) {
        expect(
          classifySendDelivery(message, responseStarted: false),
          SendDelivery.rejected,
          reason: message,
        );
      }
    });
  });
}
