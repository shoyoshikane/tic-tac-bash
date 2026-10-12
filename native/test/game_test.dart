import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:high_tension_tic_tac_toe/game.dart';

void main() {
  test(
    'reach requires a legal winning flick and excludes reversal, draws and finished games',
    () {
      final b = List.filled(25, 0);
      b[0] = b[1] = 1;
      expect(playersInReach(GameState(board: b)), isEmpty);
      b[7] = 1;
      final state = GameState(board: b, turn: 2);
      expect(playersInReach(state), [1]);
      final winning = play(
        GameState(board: b),
        const Move.flick(7, -1, 0),
      )!.state;
      expect(playersInReach(winning), isEmpty);
      expect(
        playersInReach(GameState(board: b, previous: boardKey(winning.board))),
        isEmpty,
      );
      final simultaneous = List.filled(25, 0);
      for (final i in [2, 10, 11]) {
        simultaneous[i] = 1;
      }
      for (final i in [17, 20, 21]) {
        simultaneous[i] = 2;
      }
      final drawPosition = GameState(board: simultaneous);
      expect(play(drawPosition, const Move.flick(2, 1, 0))!.state.result, 0);
      expect(playersInReach(drawPosition), isNot(contains(1)));
      for (final i in [17, 20, 21]) {
        b[i] = 2;
      }
      expect(playersInReach(GameState(board: b)), [1, 2]);
    },
  );
  test(
    'Dart matches expected states and playable moves from recorded games',
    () {
      final corpus =
          jsonDecode(File('test/fixtures/web-games.json').readAsStringSync())
              as List;
      for (final game in corpus) {
        var state = GameState();
        for (final frame in game as List) {
          expect(state.toJson(), frame['before']);
          expect(
            actions(state).map((m) => m.toJson()).toList(),
            frame['actions'],
          );
          final old = state.toJson();
          final out = play(state, Move.parse(frame['move'])!);
          expect(out, isNotNull);
          expect(out!.state.toJson(), frame['after']);
          expect(state.toJson(), old);
          expect(
            restore(out.state.toJson()['log'])!.toJson(),
            out.state.toJson(),
          );
          state = out.state;
        }
      }
    },
  );
  test('chain, diagonal, immobile and reversal rules', () {
    final b = List.filled(25, 0);
    b[10] = 1;
    b[12] = 2;
    b[13] = 1;
    final out = flick(b, 10, 0, 1);
    expect(out.board.sublist(10, 15), [0, 1, 2, 0, 1]);
    expect(out.steps.length, 2);
    expect(b[10], 1);
    final single = List.filled(25, 0)..[0] = 1;
    expect(flick(single, 0, 1, 1).board[24], 1);
    expect(
      preview(GameState(board: single), const Move.flick(0, -1, 0)),
      isNull,
    );
    final next = play(
      GameState(board: single),
      const Move.flick(0, 0, 1),
    )!.state;
    expect(
      preview(
        GameState(board: next.board, turn: 1, previous: next.previous),
        const Move.flick(4, 0, -1),
      ),
      isNull,
    );
  });
  test('bad network logs are rejected and the CPU takes a win', () {
    for (final entry in [
      null,
      {},
      {'type': 'place', 'i': -1},
      {'type': 'flick', 'i': 0, 'dr': 9, 'dc': 0},
      {'type': 'place', 'i': 0.5},
    ]) {
      expect(Move.parse(entry), isNull);
    }
    expect(
      restore([
        {'type': 'place', 'i': 0, 'player': 2},
      ]),
      isNull,
    );
    final b = List.filled(25, 0);
    b[0] = 1;
    b[1] = 1;
    b[7] = 1;
    final state = GameState(board: b);
    expect(play(state, choose(state)!)!.state.result, 1);
  });
}
