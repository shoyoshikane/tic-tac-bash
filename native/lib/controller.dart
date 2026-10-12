import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'game.dart';
import 'peerjs.dart';
import 'room.dart';
import 'transport.dart';
import 'browser.dart';

GameState? _cpuReply(GameState state) {
  final move = choose(state);
  return move == null ? null : play(state, move)?.state;
}

class TurnPresentation {
  TurnPresentation(this.before, this.after, this.move, this.steps);
  final GameState before, after;
  final Move move;
  final List<Slide> steps;
  Duration get duration => Duration(milliseconds: steps.isEmpty ? 300 : 350);
}

class GameController extends ChangeNotifier {
  GameController({RoomPeer Function()? peerFactory, this.readOnly = false})
    : peerFactory = peerFactory ?? (() => NativePeer());
  final bool readOnly;
  final RoomPeer Function() peerFactory;
  GameState state = GameState();
  int cpuRole = 1;
  int get localRole => online ? room?.role ?? 0 : cpuRole;
  OnlineRoom? room;
  bool online = false, thinking = false, _disposed = false;
  String roomStatus = '';
  Timer? _cpuTimer;
  Timer? _presentationTimer;
  TurnPresentation? lastTurn;
  bool presenting = false;
  String? _onlineMatch;
  int _epoch = 0;
  final List<GameState> _undo = [];
  SharedPreferences? _preferences;
  bool get spectator => online && (room?.spectator ?? false);
  bool get canInteract =>
      !readOnly &&
      !_disposed &&
      state.result == null &&
      !thinking &&
      !presenting &&
      (online ? room?.canMove == true : state.turn == cpuRole);
  bool get canUndo => !online && !thinking && _undo.isNotEmpty;

  void _clearPresentation() {
    _presentationTimer?.cancel();
    lastTurn = null;
    presenting = false;
  }

  void _accept(GameState next, {bool animate = true}) {
    final before = state;
    if (next.moves == before.moves &&
        jsonEncode(next.log.map((m) => m.toJson()).toList()) ==
            jsonEncode(before.log.map((m) => m.toJson()).toList())) {
      state = next;
      return;
    }
    _clearPresentation();
    final contiguous =
        next.moves == before.moves + 1 &&
        next.log.length == before.log.length + 1 &&
        jsonEncode(
              next.log.take(before.log.length).map((m) => m.toJson()).toList(),
            ) ==
            jsonEncode(before.log.map((m) => m.toJson()).toList());
    if (animate && contiguous) {
      final move = next.log.last;
      final out = play(before, move);
      if (out != null) {
        lastTurn = TurnPresentation(before, next, move, out.steps);
        presenting = true;
        _presentationTimer = Timer(lastTurn!.duration, () {
          if (_disposed) return;
          presenting = false;
          _schedule();
          changed();
        });
      }
    }
    state = next;
  }

  List<TurnPresentation> get moveHistory {
    var position = GameState();
    final entries = <TurnPresentation>[];
    for (final move in state.log) {
      final out = play(position, move);
      if (out == null) break;
      entries.add(TurnPresentation(position, out.state, move, out.steps));
      position = out.state;
    }
    return entries;
  }

  GameState? _reachState;
  List<int> _reachPlayers = const [];
  List<int> get reachPlayers {
    if (!identical(_reachState, state)) {
      _reachState = state;
      _reachPlayers = playersInReach(state);
    }
    return _reachPlayers;
  }

  void changed() {
    if (!_disposed) {
      if (online && room != null && room!.target.isNotEmpty) {
        setInvitation(room!.target, room!.spectator);
      }
      notifyListeners();
    }
  }

  Future<void> load() async {
    try {
      _preferences = await SharedPreferences.getInstance();
      final text = _preferences!.getString('high-tension-native-v1');
      final saved = text == null ? null : restore(jsonDecode(text));
      cpuRole = _preferences!.getInt('high-tension-cpu-role') == 2 ? 2 : 1;
      if (saved != null) state = saved;
    } catch (_) {
      /* Start a new game when saved data cannot be restored. */
    }
    if (_disposed) return;
    _schedule();
    changed();
  }

  void _save() {
    if (!online)
      unawaited(
        _preferences?.setInt('high-tension-cpu-role', cpuRole) ??
            Future.value(false),
      );
    if (!online)
      unawaited(
        _preferences?.setString(
              'high-tension-native-v1',
              jsonEncode(state.log.map((m) => m.toJson()).toList()),
            ) ??
            Future.value(false),
      );
  }

  void _schedule() {
    _cpuTimer?.cancel();
    if (presenting || readOnly) return;
    if (!online && state.turn != cpuRole && state.result == null) {
      final epoch = _epoch;
      _cpuTimer = Timer(const Duration(milliseconds: 600), () async {
        if (_disposed || online || epoch != _epoch) return;
        thinking = true;
        changed();
        final next = await compute(_cpuReply, state);
        if (_disposed || epoch != _epoch || online) return;
        if (next != null) _accept(next);
        thinking = false;
        _save();
        changed();
      });
    }
  }

  bool move(Move move) {
    if (!canInteract) return false;
    if (online) return room!.move(move);
    final out = play(state, move);
    if (out == null) return false;
    _undo.add(state);
    _accept(out.state);
    _save();
    _schedule();
    changed();
    return true;
  }

  void undo() {
    if (!canUndo) return;
    _epoch++;
    _cpuTimer?.cancel();
    _clearPresentation();
    state = _undo.removeLast();
    thinking = false;
    _save();
    changed();
  }

  Future<void> startCpu({int? role}) async {
    _clearPresentation();
    setInvitation('', false);
    _epoch++;
    _cpuTimer?.cancel();
    thinking = false;
    online = false;
    final old = room;
    room = null;
    await old?.close();
    if (_disposed) return;
    if (role == 1 || role == 2) cpuRole = role!;
    state = GameState();
    _undo.clear();
    _save();
    _schedule();
    changed();
  }

  Future<void> startOnline({Invitation? invitation}) async {
    _clearPresentation();
    setInvitation(invitation?.target ?? '', invitation?.spectator ?? false);
    _epoch++;
    _cpuTimer?.cancel();
    thinking = false;
    online = true;
    final old = room;
    room = null;
    await old?.close();
    if (_disposed) return;
    state = GameState();
    _undo.clear();
    roomStatus = '接続を準備しています…';
    final next = OnlineRoom(
      peerFactory: peerFactory,
      onState: (next, steps) {
        if (_disposed) return;
        final match = room?.match;
        final ownMove =
            next.moves == state.moves + 1 &&
            next.log.isNotEmpty &&
            next.log.last.player == room?.role;
        final live = match != null && (match == _onlineMatch || ownMove);
        if (!live) _clearPresentation();
        _onlineMatch = match;
        _accept(next, animate: live);
        changed();
      },
      onStatus: (text) {
        if (room?.ready != true) _onlineMatch = null;
        roomStatus = text;
        changed();
      },
    );
    room = next;
    _onlineMatch = next.match;
    changed();
    await next.start(
      target: invitation?.target ?? '',
      spectator: invitation?.spectator ?? false,
    );
  }

  void rematch() {
    if (online) room?.rematch();
  }

  Future<void> retry() async {
    await room?.retry();
  }

  String get turnLabel {
    if (presenting) return '';
    if (state.result != null) {
      if (state.result == 0) return '引き分け';
      if (spectator || readOnly) return '${state.result == 1 ? '先攻' : '後攻'}の勝ち';
      return state.result == localRole
          ? 'あなたの勝ち！'
          : online
          ? '相手の勝ち'
          : 'CPUの勝ち';
    }
    if (online) {
      if (room?.ready != true) return '接続待ち';
      if (spectator)
        return room!.playing ? '${state.turn == 1 ? '先攻' : '後攻'}の番' : '接続待ち';
      return room!.role == state.turn ? 'あなたの番' : '相手の番';
    }
    return state.turn == cpuRole ? 'あなたの番' : 'CPUの番';
  }

  String get hint {
    if (presenting) return '';
    if (spectator)
      return room?.ready == true && room?.playing == true
          ? '観戦中'
          : '対戦の再接続を待っています';
    if (state.result != null) return state.result == 0 ? 'もう一局、どうぞ。' : '';
    if (!canInteract) return online ? '相手の手を待っています' : '考えています…';
    return 'タップで置く・ドラッグで弾く';
  }

  @override
  void dispose() {
    _disposed = true;
    _epoch++;
    _cpuTimer?.cancel();
    _presentationTimer?.cancel();
    if (room != null) unawaited(room!.close());
    super.dispose();
  }
}
