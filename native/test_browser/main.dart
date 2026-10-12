import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'package:flutter/semantics.dart';
import 'package:high_tension_tic_tac_toe/controller.dart';
import 'package:high_tension_tic_tac_toe/game.dart';
import 'package:high_tension_tic_tac_toe/main.dart' as app;
import 'package:high_tension_tic_tac_toe/peerjs.dart';

// This entry point is built only for CI, never published. It uses the real
// Flutter screen, controller and WebRTC implementation against a local broker.
NativePeer? _peer;

Future<void> main() => app.startGame(
  peerFactory: () => _peer = NativePeer(
    host: '127.0.0.1',
    port: 9000,
    path: '/peerjs',
    secure: false,
    iceServers: const [],
  ),
  onReady: (game) {
    SemanticsBinding.instance.ensureSemantics();
    globalContext.setProperty(
      'gameTest'.toJS,
      createJSInteropWrapper(Probe(game)),
    );
  },
);

@JSExport()
class Probe {
  Probe(this._game);
  final GameController _game;
  String get state => jsonEncode({
    ..._game.state.toJson(),
    'ready': _game.room?.ready ?? false,
    'spectator': _game.spectator,
    'playing': _game.room?.playing ?? false,
    'canMove': _game.canInteract,
    'role': _game.localRole,
    'hostRole': _game.room?.hostRole ?? 0,
    'roomCode': _game.room?.roomCode ?? '',
    'invite': _game.room?.invite ?? '',
    'target': _game.room?.target ?? '',
    'status': _game.roomStatus,
    'localVote': _game.room?.localVote ?? false,
    'remoteVote': _game.room?.remoteVote ?? false,
  });
  void host() {
    unawaited(_game.startOnline());
  }

  void join(String target) {
    unawaited(
      _game.startOnline(invitation: (target: target, spectator: false)),
    );
  }

  void cpu() {
    unawaited(_game.startCpu());
  }

  bool move(String action) => _game.move(Move.parse(jsonDecode(action))!);
  void rematch() => _game.rematch();
  void retry() {
    unawaited(_game.retry());
  }

  void disconnect() {
    unawaited(_peer?.dispose());
  }
}
