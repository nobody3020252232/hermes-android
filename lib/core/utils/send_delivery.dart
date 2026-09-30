import '../services/gateway_turn_coordinator.dart';
import '../services/ws_client.dart';

/// What a failed submit proved about the prompt it carried.
enum SendDelivery {
  /// The server, or the transport itself, proved the prompt never became a
  /// turn. Handing the draft back for an explicit retry is honest and useful.
  rejected,

  /// The request left the device but no authoritative answer came back — the
  /// transport died mid-flight. The server may already own the turn, so the
  /// surface must not claim a failed send, must not refill the composer (the
  /// reader would resend work that is already running), and must reconcile
  /// instead.
  uncertain,
}

/// Classify a submit failure.
///
/// [responseStarted] is true once the turn streamed any content: content proves
/// the server accepted the prompt and is running it, whatever happens to the
/// socket afterwards.
///
/// [deliveryStarted] says whether the prompt actually reached the wire (the
/// transport's own `onSent` signal). It is the only way to tell a socket that
/// died before the frame went out — nothing was submitted, so restoring the
/// draft is right — from one that died after it: null means the transport
/// cannot say, which is treated as "may have been delivered".
SendDelivery classifySendDelivery(
  Object error, {
  required bool responseStarted,
  bool? deliveryStarted,
}) {
  if (responseStarted) return SendDelivery.uncertain;
  if (error is JsonRpcError) {
    // The gateway's own classifier distinguishes an authoritative rejection
    // from a dropped/undecided transport (`Timeout`, closed socket).
    if (gatewayTurnSubmissionWasDefinitelyRejected(error)) {
      return SendDelivery.rejected;
    }
    return deliveryStarted == false
        ? SendDelivery.rejected
        : SendDelivery.uncertain;
  }
  final text = error.toString().toLowerCase();
  // Ordered: a request that never reached the server is a rejection even if
  // the failure text also mentions the connection.
  if (_neverDelivered.any(text.contains)) return SendDelivery.rejected;
  if (_droppedMidFlight.any(text.contains)) {
    return deliveryStarted == false
        ? SendDelivery.rejected
        : SendDelivery.uncertain;
  }
  // An HTTP error body, an argument validation failure, a rejected request:
  // the prompt did not become a turn.
  return SendDelivery.rejected;
}

/// The request never reached the server.
const _neverDelivered = <String>[
  'connection refused',
  'failed host lookup',
  'no route to host',
  'network is unreachable',
  'nodename nor servname',
];

/// The prompt left the device and the transport died before the answer.
const _droppedMidFlight = <String>[
  'connection closed',
  'connection reset',
  'connection terminated',
  'connection lost',
  'broken pipe',
  'socketexception',
  'websocket',
  'timed out',
  'timeout',
];
