// Server→client request contract: the Android client must advertise
// `server_requests` once per socket and answer `srq-…` request frames
// (clarify) instead of dropping them — otherwise every clarify prompt is
// withdrawn before the phone can render it (Hermes #112548 fail-fast).
// Lives outside the widget suites: real local WS traffic cannot share a
// suite with TestWidgetsFlutterBinding (see ws_keepalive_test.dart).
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/connection.dart';
import 'package:hermes_android/core/services/desktop_gateway_client.dart';
import 'package:hermes_android/core/services/ws_client.dart';

const _fixtureKey = 'fixture-key';

void main() {
  test('WsClient advertises server_requests after gateway.ready', () async {
    final gateway = await _ServerRequestFakeGateway.start();
    addTearDown(gateway.stop);
    final client = WsClient(
      'http://127.0.0.1:${gateway.port}',
      token: _fixtureKey,
      advertiseServerRequests: true,
    );
    addTearDown(client.close);
    await client.connect().timeout(const Duration(seconds: 5));

    await _waitFor(
      () => gateway.framesOfMethod('client.capabilities').isNotEmpty,
      timeout: const Duration(seconds: 5),
    );
    final request = gateway.framesOfMethod('client.capabilities').single;
    expect(request['params'], isA<Map>());
    expect((request['params'] as Map)['server_requests'], isTrue);
  });

  test('WsClient routes server requests to the handler; normal RPCs survive',
      () async {
    final gateway = await _ServerRequestFakeGateway.start();
    addTearDown(gateway.stop);
    final client = WsClient(
      'http://127.0.0.1:${gateway.port}',
      token: _fixtureKey,
    );
    addTearDown(client.close);
    final received = <ServerRequestEvent>[];
    client.onServerRequest = received.add;
    await client.connect().timeout(const Duration(seconds: 5));

    gateway.sendServerRequest('srq-test-1', 'clarify', {
      'session_id': 'gw-runtime-1',
      'question': 'Proceed?',
      'choices': ['Yes', 'No'],
    });
    await _waitFor(
      () => received.isNotEmpty,
      timeout: const Duration(seconds: 3),
    );
    expect(received.single.id, 'srq-test-1');
    expect(received.single.method, 'clarify');
    expect(received.single.params['question'], 'Proceed?');

    // The answer goes back as a raw response frame with the same id.
    client.sendServerRequestResponse('srq-test-1', result: {'answer': 'Yes'});
    await _waitFor(
      () => gateway.responseFrames.any((f) => f['id'] == 'srq-test-1'),
      timeout: const Duration(seconds: 3),
    );
    final response = gateway.responseFrames
        .firstWhere((f) => f['id'] == 'srq-test-1');
    expect(response['result'], {'answer': 'Yes'});

    // The request frame never leaked into the pending map: a normal RPC works.
    final rpc = await client
        .send('session.resume', {'session_id': 'x'})
        .timeout(const Duration(seconds: 3));
    expect(rpc['error'], isNull);
  });

  test('WsClient declines server requests with no handler (-32601)', () async {
    final gateway = await _ServerRequestFakeGateway.start();
    addTearDown(gateway.stop);
    final client = WsClient(
      'http://127.0.0.1:${gateway.port}',
      token: _fixtureKey,
    );
    addTearDown(client.close);
    await client.connect().timeout(const Duration(seconds: 5));

    gateway.sendServerRequest('srq-test-2', 'approval', {
      'session_id': 'gw-runtime-1',
    });
    await _waitFor(
      () => gateway.responseFrames.any((f) => f['id'] == 'srq-test-2'),
      timeout: const Duration(seconds: 3),
    );
    final response = gateway.responseFrames
        .firstWhere((f) => f['id'] == 'srq-test-2');
    expect((response['error'] as Map)['code'], -32601);
  });

  test(
      'DesktopGatewayClient answers prompts and replays open requests on resume',
      () async {
    final gateway = await _ServerRequestFakeGateway.start();
    addTearDown(gateway.stop);
    final client = DesktopGatewayClient.fromConnection(
      SavedConnection(
        id: 'conn-requests',
        label: 'Local fake',
        host: 'localhost',
        port: gateway.port,
        apiKey: _fixtureKey,
        useHttps: false,
        desktopGatewayUrl: 'http://127.0.0.1:${gateway.port}',
        dashboardUsername: 'u',
        dashboardPassword: 'p',
      ),
    );
    addTearDown(client.close);

    final prompts = <(String, ServerRequestEvent)>[];
    client.setServerRequestListener(
      (mobile, request) => prompts.add((mobile, request)),
    );

    await client.ensureSession('mob-sr');
    // Fresh chat: 4007 → session.create mints runtime + stored ids.
    expect(gateway.resumedStoredIds, contains('mob-sr'));

    // Live prompt on the bound session routes to the mobile id.
    gateway.sendServerRequest('srq-live-1', 'clarify', {
      'session_id': 'gw-runtime-1',
      'question': 'Pick one',
      'choices': ['a', 'b'],
    });
    await _waitFor(
      () => prompts.isNotEmpty,
      timeout: const Duration(seconds: 3),
    );
    expect(prompts.single.$1, 'mob-sr');
    expect(prompts.single.$2.id, 'srq-live-1');
    expect(prompts.single.$2.params['question'], 'Pick one');

    // Single-question answer: response frame with the same id.
    await client.respondToServerRequest('srq-live-1', {'answer': 'a'});
    await _waitFor(
      () => gateway.responseFrames.any((f) => f['id'] == 'srq-live-1'),
      timeout: const Duration(seconds: 3),
    );

    // Batch lock: clarify.lock RPC carries the same request id.
    await client.lockClarifyAnswer(
      requestId: 'srq-live-1',
      questionId: 'q0',
      answer: 'a',
    );
    await _waitFor(
      () => gateway.framesOfMethod('clarify.lock').isNotEmpty,
      timeout: const Duration(seconds: 3),
    );
    final lock = gateway.framesOfMethod('clarify.lock').single;
    expect((lock['params'] as Map)['request_id'], 'srq-live-1');
    expect((lock['params'] as Map)['question_id'], 'q0');
    expect((lock['params'] as Map)['answer'], 'a');

    // Reconnect: the stored key re-resumes and the gateway's still-open
    // requests are re-delivered to the listener.
    gateway.openRequestsOnResume = [
      {
        'id': 'srq-replay-1',
        'method': 'clarify',
        'params': {
          'session_id': 'gw-runtime-1',
          'question': 'Still waiting?',
        },
      },
    ];
    await gateway.dropSocket();
    await _waitFor(
      () => gateway.connectionCount >= 2,
      timeout: const Duration(seconds: 10),
    );
    await _waitFor(
      () => prompts.any((p) => p.$2.id == 'srq-replay-1'),
      timeout: const Duration(seconds: 8),
    );
  });
}

Future<void> _waitFor(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw StateError('condition not met within $timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

class _ServerRequestFakeGateway {
  _ServerRequestFakeGateway(this._server);

  final HttpServer _server;
  final List<WebSocket> _sockets = [];
  final List<Map<String, dynamic>> frames = [];
  final List<Map<String, dynamic>> responseFrames = [];
  final List<String> resumedStoredIds = [];
  List<Map<String, dynamic>> openRequestsOnResume = [];
  int connectionCount = 0;

  int get port => _server.port;

  static Future<_ServerRequestFakeGateway> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final gw = _ServerRequestFakeGateway(server);
    server.listen((httpReq) async {
      if (httpReq.method == 'POST' &&
          httpReq.uri.path == '/auth/password-login') {
        httpReq.response
          ..statusCode = 200
          ..headers.set('set-cookie', 'hermes_session_at=TOK123; Path=/')
          ..write('{"ok":true}');
        await httpReq.response.close();
        return;
      }
      if (httpReq.method == 'POST' &&
          httpReq.uri.path == '/api/auth/ws-ticket') {
        httpReq.response
          ..statusCode = 200
          ..headers.contentType = ContentType.json
          ..write('{"ticket":"TICKET-1"}');
        await httpReq.response.close();
        return;
      }
      if (httpReq.uri.path == '/api/ws') {
        final socket = await WebSocketTransformer.upgrade(httpReq);
        gw._sockets.add(socket);
        gw.connectionCount++;
        socket.add(
          jsonEncode({
            'jsonrpc': '2.0',
            'method': 'event',
            'params': {'type': 'gateway.ready', 'payload': {}},
          }),
        );
        socket.listen((raw) {
          final frame = jsonDecode(raw as String) as Map<String, dynamic>;
          if (frame['method'] != null) {
            gw.frames.add(frame);
          } else if (frame.containsKey('result') ||
              frame.containsKey('error')) {
            gw.responseFrames.add(frame);
          }
          final id = frame['id'];
          final method = frame['method'];
          void reply(Map<String, dynamic> body) {
            socket.add(jsonEncode({'jsonrpc': '2.0', 'id': id, ...body}));
          }

          switch (method) {
            case 'gateway.ping':
              reply({
                'result': {'ok': true},
              });
            case 'client.capabilities':
              reply({
                'result': {'server_requests': <String>[]},
              });
            case 'clarify.lock':
              reply({
                'result': {'status': 'locked'},
              });
            case 'session.resume':
              final requested =
                  (frame['params']?['session_id'] ?? '').toString();
              gw.resumedStoredIds.add(requested);
              if (requested.startsWith('mob')) {
                reply({
                  'error': {'code': 4007, 'message': 'session not found'},
                });
              } else {
                reply({
                  'result': {
                    'session_id': 'gw-runtime-1',
                    if (gw.openRequestsOnResume.isNotEmpty)
                      'open_requests': gw.openRequestsOnResume,
                  },
                });
              }
            case 'session.create':
              reply({
                'result': {
                  'session_id': 'gw-runtime-1',
                  'stored_session_id': 'stored-sr-1',
                },
              });
            default:
              if (id != null) {
                reply({
                  'error': {'code': 1, 'message': 'not needed for this test'},
                });
              }
          }
        });
        return;
      }
      httpReq.response.statusCode = 404;
      await httpReq.response.close();
    });
    return gw;
  }

  List<Map<String, dynamic>> framesOfMethod(String method) =>
      frames.where((f) => f['method'] == method).toList();

  void sendServerRequest(String id, String method, Map<String, dynamic> params) {
    final frame = jsonEncode({
      'jsonrpc': '2.0',
      'id': id,
      'method': method,
      'params': params,
    });
    for (final socket in _sockets) {
      socket.add(frame);
    }
  }

  Future<void> dropSocket() async {
    final sockets = List<WebSocket>.from(_sockets);
    _sockets.clear();
    for (final ws in sockets) {
      await ws.close(WebSocketStatus.goingAway, 'fixture drop');
    }
  }

  Future<void> stop() async {
    for (final ws in _sockets) {
      await ws.close();
    }
    _sockets.clear();
    await _server.close(force: true);
  }
}
