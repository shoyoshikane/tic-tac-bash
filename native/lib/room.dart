import 'dart:async';
import 'dart:math';

import 'package:uuid/uuid.dart';

import 'game.dart';
import 'transport.dart';

const protocolVersion = 1;
const webGameUrl = String.fromEnvironment(
  'WEB_GAME_URL',
  defaultValue: 'https://shoyoshikane.github.io/tic-tac-bash/',
);
typedef Invitation = ({String target, bool spectator});
String generateRoomCode() {
  const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  final random = Random.secure();
  return List.generate(
    6,
    (_) => alphabet[random.nextInt(alphabet.length)],
  ).join();
}

Invitation? parseInvitation(String text) {
  final trimmed = text.trim();
  if (RegExp(r'^[a-zA-Z0-9]{4,6}$').hasMatch(trimmed)) {
    return (target: trimmed.toUpperCase(), spectator: false);
  }
  final link = RegExp(
    r'(?:https?://|hightension://)[^\s]+',
  ).firstMatch(trimmed)?.group(0);
  final uri = Uri.tryParse(link ?? trimmed);
  if (uri == null) return null;
  Map<String, String> params;
  try {
    params = uri.hasFragment
        ? Uri.splitQueryString(uri.fragment)
        : uri.queryParameters;
  } catch (_) {
    return null;
  }
  final target = params['room'] ?? (link == null ? trimmed : '');
  if (!RegExp(r'^[a-zA-Z0-9_-]{1,100}$').hasMatch(target)) return null;
  return (target: target, spectator: params['watch'] == '1');
}

class OnlineRoom {
  OnlineRoom({
    required this.peerFactory,
    required this.onState,
    required this.onStatus,
    String Function()? codeFactory,
  }) : codeFactory = codeFactory ?? generateRoomCode;
  final String Function() codeFactory;
  final RoomPeer Function() peerFactory;
  final void Function(GameState, List<Slide>) onState;
  final void Function(String) onStatus;
  GameState state = GameState();
  String match = const Uuid().v4(),
      identity = const Uuid().v4(),
      target = '',
      invite = '';
  String? guestToken;
  String roomCode = '';
  int _codeRetries = 0;
  int role = 0, rev = -1;
  int hostRole = 1;
  bool host = false,
      ready = false,
      pending = false,
      spectator = false,
      playing = false;
  bool localVote = false, remoteVote = false, _closed = false;
  RoomPeer? _peer;
  RoomConnection? _opponent;
  final Set<RoomConnection> _watchers = {};
  final Map<RoomConnection, List<StreamSubscription<dynamic>>> _subscriptions =
      {};
  final Map<RoomConnection, Timer> _heartbeats = {}, _rejectionTimers = {};
  final Map<RoomConnection, DateTime> _lastSeen = {};
  Timer? _timeout;
  int _attempt = 0;
  bool get canMove =>
      ready &&
      !pending &&
      !spectator &&
      state.turn == role &&
      state.result == null;
  bool get canChooseRole =>
      host && !_closed && (state.moves == 0 || state.result != null);
  bool chooseRole(int player) {
    if (!canChooseRole || (player != 1 && player != 2)) return false;
    if (hostRole == player) return true;
    hostRole = role = player;
    localVote = remoteVote = false;
    _broadcast();
    onState(state, []);
    if (ready) _voteStatus();
    return true;
  }

  void status(String text) {
    if (!_closed) onStatus(text);
  }

  Future<void> start({String target = '', bool spectator = false}) async {
    this.target = target;
    host = target.isEmpty;
    if (host && invite.isEmpty) roomCode = codeFactory();
    if (!host)
      roomCode =
          RegExp(
            r'^(?:vidro-)?([A-Z0-9]{4,6})$',
          ).firstMatch(target)?.group(1) ??
          '';
    this.spectator = !host && spectator;
    role = host
        ? hostRole
        : this.spectator
        ? 0
        : 2;
    status('接続を準備しています…');
    final attempt = ++_attempt, peer = _peer = peerFactory();
    _armTimeout('接続できませんでした。回線を確認して再接続してください。');
    try {
      await peer.start(
        peerId: host ? roomCode : null,
        onOpen: (id) {
          if (_closed || attempt != _attempt) return;
          if (host) {
            _timeout?.cancel();
            invite = '$webGameUrl#room=$id';
            status(ready ? '友達と接続しました。' : '');
          } else if (_opponent == null)
            unawaited(_connect(peer));
        },
        onConnection: (conn) {
          if (_closed || attempt != _attempt || !host) {
            unawaited(conn.close());
            return;
          }
          _admit(conn);
        },
        onError: (text) {
          if (_closed || attempt != _attempt) return;
          if (host && invite.isEmpty && text == peerIdTaken) {
            unawaited(_replaceCode(peer));
            return;
          }
          if (!ready) status(text);
        },
      );
    } catch (_) {
      if (!_closed && attempt == _attempt) status('接続できませんでした。再接続してください。');
    }
  }

  Future<void> _replaceCode(RoomPeer peer) async {
    final attempt = ++_attempt;
    _timeout?.cancel();
    await peer.dispose();
    if (_closed || attempt != _attempt) return;
    if (++_codeRetries >= 5) {
      status('部屋を作れませんでした。再接続してください。');
      return;
    }
    await start();
  }

  void _armTimeout(String message) {
    _timeout?.cancel();
    _timeout = Timer(const Duration(seconds: 20), () {
      if (_closed || ready) return;
      final conn = _opponent;
      _opponent = null;
      pending = false;
      if (conn != null) unawaited(conn.close());
      status(message);
    });
  }

  Future<void> _connect(RoomPeer peer) async {
    status('友達の部屋に接続しています…');
    try {
      final conn = await peer.connect(target, {
        'version': protocolVersion,
        'token': identity,
        'watch': spectator,
      });
      if (_closed || _peer != peer) {
        await conn.close();
        return;
      }
      _attach(conn, watcher: false);
    } catch (_) {
      if (!_closed) status('部屋につながりません。作成者の画面を確認してください。');
    }
  }

  void _admit(RoomConnection conn) {
    final meta = conn.metadata;
    if (meta['version'] == protocolVersion && meta['watch'] == true) {
      _attach(conn, watcher: true);
      return;
    }
    final token = meta['token'];
    if (meta['version'] != protocolVersion ||
        token is! String ||
        token.length > 100) {
      _reject(conn);
      return;
    }
    if ((guestToken != null && guestToken != token) || _opponent != null) {
      _attach(conn, watcher: true);
      return;
    }
    _attach(conn, watcher: false);
  }

  void _reject(RoomConnection conn) {
    void reject() {
      _send(conn, {'type': 'rejected'});
    }

    _subscriptions[conn] = [
      conn.opened.listen((_) {
        reject();
        _rejectionTimers[conn] = Timer(
          const Duration(seconds: 20),
          () => unawaited(conn.close()),
        );
      }),
      conn.messages.listen((m) {
        if (m['version'] != protocolVersion) return;
        if (m['type'] == 'sync') reject();
        if (m['type'] == 'rejected-ack') unawaited(conn.close());
      }),
      conn.closed.listen((_) => _cleanup(conn)),
    ];
    if (conn.open) {
      reject();
      _rejectionTimers[conn] = Timer(
        const Duration(seconds: 20),
        () => unawaited(conn.close()),
      );
    }
  }

  void _attach(RoomConnection conn, {required bool watcher}) {
    if (watcher)
      _watchers.add(conn);
    else
      _opponent = conn;
    void opened() {
      if (_closed || (!watcher && _opponent != conn)) return;
      _lastSeen[conn] = DateTime.now();
      _heartbeats[conn]?.cancel();
      _heartbeats[conn] = Timer.periodic(const Duration(seconds: 1), (_) {
        if (_closed) return;
        if (DateTime.now()
                .difference(_lastSeen[conn] ?? DateTime.now())
                .inSeconds >
            6) {
          _lost(conn);
          unawaited(conn.close());
          return;
        }
        _send(conn, {'type': 'ping'});
      });
      if (watcher) {
        _send(conn, {...snapshot(), 'spectator': true});
      } else if (host) {
        guestToken = conn.metadata['token'] as String;
        ready = true;
        _timeout?.cancel();
        _broadcast();
        _voteStatus();
      } else {
        _send(conn, {'type': 'sync'});
      }
    }

    _subscriptions[conn] = [
      conn.opened.listen((_) => opened()),
      conn.closed.listen((_) => _lost(conn)),
      conn.messages.listen((message) {
        if (_closed || message['version'] != protocolVersion) return;
        _lastSeen[conn] = DateTime.now();
        if (message['type'] == 'ping') {
          _send(conn, {'type': 'pong'});
          return;
        }
        if (message['type'] == 'pong') return;
        if (watcher) {
          if (message['type'] == 'sync')
            _send(conn, {...snapshot(), 'spectator': true});
          return;
        }
        if (_opponent == conn) _receive(message);
      }),
    ];
    if (conn.open) opened();
  }

  void _cleanup(RoomConnection conn) {
    _heartbeats.remove(conn)?.cancel();
    _rejectionTimers.remove(conn)?.cancel();
    _lastSeen.remove(conn);
    for (final subscription
        in _subscriptions.remove(conn) ?? <StreamSubscription<dynamic>>[]) {
      unawaited(subscription.cancel());
    }
    _watchers.remove(conn);
  }

  void _lost(RoomConnection conn) {
    final opponent = _opponent == conn;
    _cleanup(conn);
    if (_closed || !opponent) return;
    _opponent = null;
    ready = false;
    pending = false;
    localVote = false;
    remoteVote = false;
    _timeout?.cancel();
    if (host) _broadcast();
    status(spectator ? '観戦の接続が切れました。再接続してください。' : '友達との接続が切れました。再接続してください。');
  }

  void _send(RoomConnection conn, Map<String, dynamic> message) {
    if (_closed || !conn.open) return;
    unawaited(
      conn.send({...message, 'version': protocolVersion}).catchError((
        Object error,
      ) {
        _lost(conn);
        unawaited(conn.close());
      }),
    );
  }

  Map<String, dynamic> snapshot() => {
    'type': 'state',
    'version': protocolVersion,
    'match': match,
    'rev': state.moves,
    'log': state.log.map((m) => m.toJson()).toList(),
    'votes': [localVote, remoteVote],
    'playing': ready,
    'hostRole': hostRole,
  };
  void _broadcast() {
    final message = snapshot();
    if (_opponent != null) _send(_opponent!, message);
    for (final conn in List<RoomConnection>.of(_watchers)) {
      _send(conn, {...message, 'spectator': true});
    }
  }

  void _receive(Map<String, dynamic> message) {
    if (message['type'] == 'rejected') {
      if (_opponent != null) _send(_opponent!, {'type': 'rejected-ack'});
      final conn = _opponent;
      _opponent = null;
      ready = false;
      pending = false;
      _timeout?.cancel();
      if (conn != null) {
        _cleanup(conn);
        unawaited(conn.close());
      }
      status('このリンクでは接続できません。招待リンクを確認してください。');
      return;
    }
    if (host) {
      if (message['type'] == 'sync') {
        _broadcast();
        return;
      }
      if (message['type'] == 'move' && ready) {
        final move = Move.parse(message['action']);
        final out =
            move != null &&
                state.turn == 3 - hostRole &&
                message['match'] == match &&
                message['rev'] == state.moves
            ? play(state, move)
            : null;
        if (out != null) {
          state = out.state;
          localVote = false;
          remoteVote = false;
          _broadcast();
          onState(state, out.steps);
        } else {
          _broadcast();
        }
      }
      if (message['type'] == 'rematch' && ready && message['match'] == match) {
        remoteVote = true;
        _maybeRematch();
      }
    } else if (message['type'] == 'state') {
      final nextMatch = message['match'], nextRev = message['rev'];
      if (nextMatch is! String ||
          nextMatch.length >= 100 ||
          nextRev is! int ||
          (nextMatch == match && nextRev < rev))
        return;
      final next = restore(message['log']);
      if (next == null || next.moves != nextRev) return;
      final chosenRole = message['hostRole'] ?? 1;
      if (chosenRole != 1 && chosenRole != 2) return;
      hostRole = chosenRole as int;
      if (message['spectator'] == true) {
        spectator = true;
        role = 0;
      }
      if (!spectator) role = 3 - hostRole;
      final steps = match == nextMatch && next.moves == state.moves + 1
          ? play(state, next.log.last)?.steps ?? <Slide>[]
          : <Slide>[];
      match = nextMatch;
      rev = nextRev;
      state = next;
      ready = true;
      pending = false;
      playing = message['playing'] == true;
      _timeout?.cancel();
      final votes = message['votes'];
      localVote =
          !spectator && votes is List && votes.length == 2 && votes[1] == true;
      remoteVote =
          !spectator && votes is List && votes.length == 2 && votes[0] == true;
      onState(state, steps);
      _voteStatus();
    }
  }

  bool move(Move move) {
    if (!canMove) return false;
    final out = play(state, move);
    if (out == null) return false;
    if (host) {
      state = out.state;
      localVote = false;
      remoteVote = false;
      _broadcast();
      onState(state, out.steps);
    } else {
      pending = true;
      _send(_opponent!, {
        'type': 'move',
        'match': match,
        'rev': state.moves,
        'action': move.toJson(),
      });
      status('手を送信しています…');
    }
    return true;
  }

  void rematch() {
    if (!ready || spectator) return;
    localVote = true;
    if (host)
      _maybeRematch();
    else {
      _send(_opponent!, {'type': 'rematch', 'match': match});
      _voteStatus();
    }
  }

  void _maybeRematch() {
    if (localVote && remoteVote) {
      match = const Uuid().v4();
      state = GameState();
      localVote = false;
      remoteVote = false;
      _broadcast();
      onState(state, []);
    } else {
      _broadcast();
    }
    _voteStatus();
  }

  void _voteStatus() {
    status(
      spectator
          ? playing
                ? '観戦中です。'
                : '対戦相手の接続を待っています。'
          : localVote
          ? 'もう一局を希望しました。返事を待っています。'
          : remoteVote
          ? '相手がもう一局を希望しています。'
          : '友達と接続しました。あなたは${role == 1 ? '先攻' : '後攻'}です。',
    );
  }

  Future<void> retry() async {
    if (_closed || ready) return;
    _codeRetries = 0;
    if (host && invite.isNotEmpty) {
      status('友達の接続を待っています。');
      return;
    }
    final old = _peer;
    _peer = null;
    final conn = _opponent;
    _opponent = null;
    if (conn != null) _cleanup(conn);
    await old?.dispose();
    if (!_closed) await start(target: target, spectator: spectator);
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _attempt++;
    _timeout?.cancel();
    ready = false;
    final conns = List<RoomConnection>.of(_subscriptions.keys);
    for (final conn in conns) {
      _cleanup(conn);
      await conn.close();
    }
    await _peer?.dispose();
  }
}
