import 'package:flutter_test/flutter_test.dart';
import 'package:high_tension_tic_tac_toe/game.dart';
import 'package:high_tension_tic_tac_toe/room.dart';

import 'fakes.dart';

Future<void> settle() async {
  for (var i = 0; i < 8; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  test('room codes accept mixed case and preserve existing invite links', () {
    expect(parseInvitation(' abC234 '), (target: 'ABC234', spectator: false));
    expect(parseInvitation('AB23'), (target: 'AB23', spectator: false));
    expect(
      parseInvitation('${webGameUrl}#room=ABC234'),
      parseInvitation('abc234'),
    );
    expect(parseInvitation('${webGameUrl}#room=legacy-id&watch=1'), (
      target: 'legacy-id',
      spectator: true,
    ));
    expect(parseInvitation('ABC!23'), isNull);
    expect(generateRoomCode(), matches(RegExp(r'^[A-Z2-9]{6}$')));
  });

  test(
    'colliding room codes are reissued without replacing the existing room',
    () async {
      final hub = FakeHub();
      OnlineRoom make(String Function() codes) => OnlineRoom(
        peerFactory: hub.create,
        onState: (_, _) {},
        onStatus: (_) {},
        codeFactory: codes,
      );
      final first = make(() => 'ABC234');
      var attempt = 0;
      final second = make(() => attempt++ == 0 ? 'ABC234' : 'DEF567');
      final guest = make(() => 'GHI789');
      try {
        await first.start();
        await second.start();
        await settle();
        expect(first.roomCode, 'ABC234');
        expect(second.roomCode, 'DEF567');
        expect(hub.peers.containsKey('ABC234'), isTrue);
        await guest.start(target: parseInvitation('def567')!.target);
        await settle();
        expect(second.ready, isTrue);
        expect(first.ready, isFalse);
        expect(guest.move(const Move.place(0)), isFalse);
        expect(second.move(const Move.place(0)), isTrue);
        await settle();
        expect(guest.state.board[0], 1);
      } finally {
        await first.close();
        await second.close();
        await guest.close();
      }
    },
  );
  test(
    'only the host chooses roles, including guest-first games and reconnects',
    () async {
      final hub = FakeHub();
      OnlineRoom make() => OnlineRoom(
        peerFactory: hub.create,
        onState: (_, _) {},
        onStatus: (_) {},
      );
      final host = make(), guest = make(), viewer = make();
      try {
        await host.start();
        expect(host.chooseRole(2), isTrue);
        final target = parseInvitation(host.invite)!.target;
        await guest.start(target: target);
        await viewer.start(target: target);
        await settle();
        expect(host.role, 2);
        expect(guest.role, 1);
        expect(guest.canMove, isTrue);
        expect(host.canMove, isFalse);
        expect(viewer.role, 0);
        expect(viewer.hostRole, 2);
        expect(guest.chooseRole(2), isFalse);
        expect(viewer.chooseRole(1), isFalse);
        final guestPeer = hub.peers.values.firstWhere(
          (p) => p != hub.peers[target] && p != hub.peers.values.last,
        );
        await guestPeer.connections.first.send({
          'type': 'state',
          'version': 1,
          'hostRole': 1,
        });
        expect(host.role, 2);
        expect(guest.move(const Move.place(0)), isTrue);
        await settle();
        expect(host.state.board[0], 1);
        expect(host.chooseRole(1), isFalse);
        expect(host.move(const Move.place(2)), isTrue);
        await settle();
        expect(viewer.state.board[2], 2);
        await guestPeer.connections.first.close();
        await guest.retry();
        await settle();
        expect(guest.role, 1);
        expect(viewer.hostRole, 2);
        host.rematch();
        guest.rematch();
        await settle();
        expect(host.state.moves, 0);
        expect(guest.role, 1);
        expect(guest.canMove, isTrue);
        expect(host.chooseRole(1), isTrue);
        await settle();
        expect(guest.role, 2);
        expect(viewer.hostRole, 1);
        expect(host.canMove, isTrue);
      } finally {
        await host.close();
        await guest.close();
        await viewer.close();
      }
    },
  );
  test('invite parsing accepts shared Web text and custom native links', () {
    expect(parseInvitation('遊ぼう！\n${webGameUrl}#room=friend&watch=1'), (
      target: 'friend',
      spectator: true,
    ));
    expect(parseInvitation('hightension://join?room=friend'), (
      target: 'friend',
      spectator: false,
    ));
    expect(parseInvitation('https://example.com/no-room'), isNull);
  });
  test(
    'host-authoritative moves, automatic spectators, forged moves, rematches and reconnection',
    () async {
      final hub = FakeHub();
      OnlineRoom make() => OnlineRoom(
        peerFactory: hub.create,
        onState: (_, _) {},
        onStatus: (_) {},
      );
      final host = make(), guest = make(), viewer = make();
      try {
        await host.start();
        final target = parseInvitation(host.invite)!.target;
        await guest.start(target: target);
        await settle();
        expect(host.ready, isTrue);
        expect(guest.ready, isTrue);
        expect(host.move(const Move.place(0)), isTrue);
        await settle();
        expect(guest.state.board[0], 1);
        await viewer.start(target: target);
        await settle();
        expect(viewer.spectator, isTrue);
        expect(viewer.role, 0);
        expect(viewer.state.moves, 1);
        expect(viewer.move(const Move.place(2)), isFalse);
        viewer.rematch();
        expect(viewer.localVote, isFalse);
        final viewerPeer = hub.peers.values.last;
        await viewerPeer.connections.first.send({
          'type': 'move',
          'version': 1,
          'match': host.match,
          'rev': 1,
          'action': const Move.place(2).toJson(),
        });
        await settle();
        expect(host.state.moves, 1);
        expect(guest.move(const Move.place(2)), isTrue);
        await settle();
        expect(viewer.state.moves, 2);
        expect(host.move(const Move.flick(0, 0, 1)), isTrue);
        await settle();
        expect(viewer.state.board[1], 1);
        expect(viewer.state.board[4], 2);
        host.rematch();
        await settle();
        expect(viewer.localVote, isFalse);
        guest.rematch();
        await settle();
        expect(host.state.moves, 0);
        expect(viewer.state.moves, 0);
        final guestPeer = hub.peers.values.firstWhere(
          (p) => p != hub.peers[target] && p != viewerPeer,
        );
        await guestPeer.connections.first.close();
        await settle();
        expect(host.ready, isFalse);
        expect(viewer.playing, isFalse);
        await guest.retry();
        await settle();
        expect(guest.role, 2);
        expect(guest.spectator, isFalse);
        expect(host.ready, isTrue);
        expect(viewer.playing, isTrue);
      } finally {
        await host.close();
        await guest.close();
        await viewer.close();
      }
    },
  );
}
