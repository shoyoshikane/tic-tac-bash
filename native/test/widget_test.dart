import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:high_tension_tic_tac_toe/controller.dart';
import 'package:high_tension_tic_tac_toe/game.dart';
import 'package:high_tension_tic_tac_toe/main.dart';

import 'fakes.dart';

void main() {
  testWidgets(
    'choosing second lets the CPU open and undo keeps the human white turn',
    (tester) async {
      final game = GameController();
      addTearDown(game.dispose);
      await tester.pumpWidget(GameApp(game: game));
      await tester.tap(find.byKey(const Key('role-selector')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byType(SimpleDialog),
          matching: find.text('後攻'),
        ),
      );
      await tester.pump();
      expect(game.cpuRole, 2);
      expect(game.canInteract, isFalse);
      expect(find.text('CPUの番'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 600));
      await tester.runAsync(() async {
        for (var i = 0; i < 100 && game.thinking; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      });
      await tester.pumpAndSettle();
      expect(game.state.moves, 1);
      expect(game.state.log.single.player, 1);
      expect(game.state.turn, 2);
      expect(game.canInteract, isTrue);
      expect(find.text('あなたの番'), findsOneWidget);
      expect(game.move(actions(game.state).first), isTrue);
      game.undo();
      await tester.pump();
      expect(game.state.moves, 1);
      expect(game.state.turn, 2);
      expect(game.canInteract, isTrue);
    },
  );
  testWidgets(
    'all online flicks animate without traces and history shows every move',
    (tester) async {
      final hub = FakeHub();
      final host = GameController(peerFactory: () => hub.create());
      final guest = GameController(peerFactory: () => hub.create());
      addTearDown(() {
        host.dispose();
        guest.dispose();
      });
      await host.startOnline();
      await guest.startOnline(
        invitation: (
          target: host.room!.invite.split('room=').last,
          spectator: false,
        ),
      );
      await tester.pumpWidget(GameApp(game: guest));
      expect(host.move(const Move.place(0)), isTrue);
      expect(host.presenting, isTrue);
      expect(host.lastTurn!.duration, const Duration(milliseconds: 300));
      await tester.pump();
      expect(find.byKey(const Key('last-turn')), findsNothing);
      expect(guest.canInteract, isFalse);
      await tester.pump(const Duration(milliseconds: 350));
      expect(guest.canInteract, isTrue);
      final viewer = GameController(peerFactory: () => hub.create());
      addTearDown(viewer.dispose);
      await viewer.startOnline(
        invitation: (
          target: host.room!.invite.split('room=').last,
          spectator: true,
        ),
      );
      expect(viewer.state.moves, 1);
      expect(viewer.lastTurn, isNull);
      await viewer.room!.close();
      expect(guest.move(const Move.place(2)), isTrue);
      await tester.pump();
      final placement = find.descendant(
        of: find.byKey(const Key('cell-2')),
        matching: find.byType(Transform),
      );
      expect(placement, findsOneWidget);
      expect(tester.widget<Transform>(placement).transform.storage[0], 0);
      await tester.pump(const Duration(milliseconds: 150));
      expect(
        tester.widget<Transform>(placement).transform.storage[0],
        greaterThan(0),
      );
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.byKey(const Key('last-turn')), findsNothing);
      expect(host.move(const Move.flick(0, 0, 1)), isTrue);
      expect(host.lastTurn!.duration, const Duration(milliseconds: 450));
      await tester.pump();
      expect(host.presenting, isTrue);
      expect(find.byKey(const Key('moving-stone')), findsOneWidget);
      expect(guest.canInteract, isFalse);
      final first = tester.getCenter(find.byKey(const Key('moving-stone')));
      await tester.pump(const Duration(milliseconds: 150));
      expect(
        tester.getCenter(find.byKey(const Key('moving-stone'))).dx,
        greaterThan(first.dx),
      );
      await tester.pump(const Duration(milliseconds: 200));
      expect(
        tester.getCenter(find.byKey(const Key('moving-stone'))).dx,
        greaterThan(tester.getCenter(find.byKey(const Key('cell-2'))).dx),
      );
      await tester.pump(const Duration(milliseconds: 110));
      expect(find.byKey(const Key('moving-stone')), findsNothing);
      expect(find.byKey(const Key('move-origin-0')), findsNothing);
      expect(find.byKey(const Key('move-origin-2')), findsNothing);
      expect(
        tester.widget<Container>(find.byKey(const Key('cell-1'))).decoration,
        isA<BoxDecoration>().having((d) => d.border, 'border', isNull),
      );
      expect(guest.canInteract, isTrue);
      final trace = guest.lastTurn;
      await hub.peers['peer-1']!.connections.single.send({'type': 'sync'});
      await tester.pump();
      expect(guest.lastTurn, same(trace));
      expect(guest.move(const Move.flick(4, 1, 0)), isTrue);
      await tester.pump();
      expect(find.byKey(const Key('moving-stone')), findsOneWidget);
      expect(guest.canInteract, isFalse);
      expect(find.byKey(const Key('last-turn')), findsNothing);
      expect(find.byKey(const Key('move-origin-0')), findsNothing);
      await tester.pump(const Duration(milliseconds: 650));
      await tester.ensureVisible(find.byTooltip('履歴'));
      await tester.tap(find.byTooltip('履歴'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.byKey(const Key('moving-stone')), findsOneWidget);
      await tester.pumpAndSettle();
      expect(find.text('開始'), findsNothing);
      expect(find.byKey(const Key('history-step-0')), findsNothing);
      expect(find.byTooltip('この手を再生'), findsNothing);
      expect(find.text('4 / 4 手'), findsOneWidget);
      final replay = tester
          .widget<GameBoard>(find.byKey(const Key('history-board')))
          .game;
      expect(replay.state.board, guest.state.board);
      expect(replay.canInteract, isFalse);
      await tester.tap(find.byTooltip('前の手'));
      await tester.pump();
      expect(find.byKey(const Key('moving-stone')), findsOneWidget);
      await tester.pumpAndSettle();
      expect(find.text('3 / 4 手'), findsOneWidget);
      expect(replay.state.board[4], 2);
      expect(replay.state.board[24], 0);
      await tester.tap(find.byTooltip('最初へ'));
      await tester.pumpAndSettle();
      expect(replay.state.board, [1, ...List.filled(24, 0)]);
      await tester.tap(find.byKey(const Key('history-step-2')));
      await tester.pumpAndSettle();
      expect(replay.state.board[0], 1);
      expect(replay.state.board[2], 2);
      await tester.tap(find.byTooltip('次の手'));
      await tester.pump();
      expect(find.byKey(const Key('moving-stone')), findsOneWidget);
      await tester.pumpAndSettle();
      expect(replay.state.board[1], 1);
      expect(replay.state.board[4], 2);
      expect(guest.state.moves, 4);
      expect(guest.state.board[24], 2);
      await tester.tap(find.text('閉じる'));
      await tester.pumpAndSettle();
      await guest.room!.close();
      await host.room!.close();
      await tester.pump();
    },
  );

  testWidgets(
    'empty visual history shows the initial board with playback disabled',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: GameHistory(entries: [])),
        ),
      );
      expect(find.text('0 / 0 手'), findsOneWidget);
      expect(find.byIcon(Icons.replay), findsNothing);
      expect(
        tester
            .widget<IconButton>(
              find.widgetWithIcon(IconButton, Icons.chevron_right),
            )
            .onPressed,
        isNull,
      );
    },
  );

  testWidgets('CPU moves animate and undo updates the separate history', (
    tester,
  ) async {
    final game = GameController();
    addTearDown(game.dispose);
    await tester.pumpWidget(GameApp(game: game));
    game.move(const Move.place(0));
    await tester.pump();
    expect(game.presenting, isTrue);
    expect(
      find.descendant(
        of: find.byKey(const Key('cell-0')),
        matching: find.byType(Transform),
      ),
      findsOneWidget,
    );
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.runAsync(() async {
      for (var i = 0; i < 100 && game.thinking; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    await tester.pump();
    expect(game.lastTurn, isNotNull);
    await tester.pumpAndSettle();
    expect(game.moveHistory.length, 2);
    expect(find.byKey(const Key('last-turn')), findsNothing);
    await tester.pump(const Duration(milliseconds: 350));
    expect(game.canInteract, isTrue);
    game.undo();
    await tester.pump();
    expect(game.lastTurn, isNull);
    expect(game.moveHistory, isEmpty);
    expect(find.byKey(const Key('last-turn')), findsNothing);
  });
  testWidgets(
    'reach badges identify both colors and disappear when the threat ends',
    (tester) async {
      final game = GameController();
      addTearDown(game.dispose);
      final b = List.filled(25, 0);
      for (final i in [0, 1, 7]) {
        b[i] = 1;
      }
      for (final i in [17, 20, 21]) {
        b[i] = 2;
      }
      game.state = GameState(board: b);
      await tester.pumpWidget(GameApp(game: game));
      expect(find.text('先攻 リーチ'), findsOneWidget);
      expect(find.text('後攻 リーチ'), findsOneWidget);
      game.state = GameState();
      game.changed();
      await tester.pump();
      expect(find.byKey(const Key('reach-1')), findsNothing);
      expect(find.byKey(const Key('reach-2')), findsNothing);
    },
  );
  testWidgets('placement, drag preview, cancellation, commit and undo', (
    tester,
  ) async {
    final game = GameController();
    addTearDown(game.dispose);
    game.state = play(
      play(GameState(), const Move.place(0))!.state,
      const Move.place(2),
    )!.state;
    await tester.pumpWidget(GameApp(game: game));
    expect(find.text('CPU対戦'), findsOneWidget);
    expect(find.text('オンライン対戦'), findsOneWidget);
    final start = tester.getCenter(find.byKey(const Key('cell-0')));
    final gesture = await tester.startGesture(start);
    await gesture.moveTo(start + const Offset(60, 0));
    await tester.pump();
    expect(game.state.moves, 2);
    await gesture.cancel();
    await tester.pump();
    expect(game.state.moves, 2);
    final next = await tester.startGesture(start);
    await next.moveTo(start + const Offset(60, 0));
    await tester.pump();
    await next.up();
    await tester.pump();
    expect(game.state.moves, 3);
    expect(game.state.board[1], 1);
    expect(game.state.board[4], 2);
    expect(find.byKey(const Key('moving-stone')), findsOneWidget);
    expect(game.canInteract, isFalse);
    game.undo();
    await tester.pump();
    expect(game.state.moves, 2);
  });
  testWidgets(
    'spectators use the normal palette, keep their badge, and cannot play',
    (tester) async {
      final hub = FakeHub(),
          host = GameController(peerFactory: () => hub.create()),
          guest = GameController(peerFactory: () => hub.create()),
          viewer = GameController(peerFactory: () => hub.create());
      addTearDown(() {
        host.dispose();
        guest.dispose();
        viewer.dispose();
      });
      await host.startOnline();
      final target = host.room!.invite.split('room=').last;
      await guest.startOnline(invitation: (target: target, spectator: false));
      await viewer.startOnline(invitation: (target: target, spectator: false));
      await tester.pumpWidget(GameApp(game: viewer));
      await tester.pump();
      expect(viewer.spectator, isTrue);
      expect(find.text('観戦モード'), findsOneWidget);
      expect(find.text('もう一局'), findsNothing);
      final scaffold = tester.widget<Scaffold>(find.byType(Scaffold));
      expect(scaffold.backgroundColor, const Color(0xffeff0ed));
      final badge = tester.widget<Container>(
        find.byKey(const Key('spectator-badge')),
      );
      expect(
        (badge.decoration as BoxDecoration).color,
        const Color(0xffd6e0d7),
      );
      final cell = tester.widget<Container>(find.byKey(const Key('cell-12')));
      expect((cell.decoration as BoxDecoration).color, const Color(0xffe8ece5));
      await tester.tap(find.byKey(const Key('cell-12')));
      await tester.pump();
      expect(host.state.moves, 0);
      await viewer.room!.close();
      await guest.room!.close();
      await host.room!.close();
      await tester.pump();
    },
  );
}
