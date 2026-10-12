import 'dart:async';

import 'package:high_tension_tic_tac_toe/transport.dart';

class FakeHub {
  final Map<String, FakePeer> peers = {};
  int nextId = 0;
  FakePeer create() => FakePeer(this, 'peer-${nextId++}');
}

class FakePeer implements RoomPeer {
  FakePeer(this.hub, this.id);
  final FakeHub hub;
  String id;
  final List<FakeConnection> connections = [];
  late void Function(RoomConnection) onConnection;
  @override
  Future<void> start({
    String? peerId,
    required void Function(String) onOpen,
    required void Function(RoomConnection) onConnection,
    required void Function(String) onError,
  }) async {
    if (peerId != null) id = peerId;
    if (hub.peers.containsKey(id)) {
      onError(peerIdTaken);
      return;
    }
    this.onConnection = onConnection;
    hub.peers[id] = this;
    onOpen(id);
  }

  @override
  Future<RoomConnection> connect(
    String target,
    Map<String, dynamic> metadata,
  ) async {
    final remote = hub.peers[target];
    if (remote == null) throw StateError('Missing peer');
    final local = FakeConnection({}), other = FakeConnection(metadata);
    local.partner = other;
    other.partner = local;
    connections.add(local);
    remote.connections.add(other);
    remote.onConnection(other);
    scheduleMicrotask(() {
      other.activate();
      local.activate();
    });
    return local;
  }

  @override
  Future<void> dispose() async {
    if (identical(hub.peers[id], this)) hub.peers.remove(id);
    for (final conn in List<FakeConnection>.of(connections)) {
      await conn.close();
    }
  }
}

class FakeConnection implements RoomConnection {
  FakeConnection(this.metadata);
  @override
  final Map<String, dynamic> metadata;
  late FakeConnection partner;
  bool _open = false, _disposed = false;
  final _opened = StreamController<void>.broadcast(sync: true),
      _closed = StreamController<void>.broadcast(sync: true);
  final _messages = StreamController<Map<String, dynamic>>.broadcast(
    sync: true,
  );
  @override
  bool get open => _open && !_disposed;
  @override
  Stream<void> get opened => _opened.stream;
  @override
  Stream<void> get closed => _closed.stream;
  @override
  Stream<Map<String, dynamic>> get messages => _messages.stream;
  void activate() {
    if (!_disposed) {
      _open = true;
      _opened.add(null);
    }
  }

  @override
  Future<void> send(Map<String, dynamic> message) async {
    if (!_disposed && !partner._disposed) partner._messages.add(message);
  }

  @override
  Future<void> close() async {
    if (_disposed) return;
    _disposed = true;
    _open = false;
    _closed.add(null);
    await partner.close();
    await _opened.close();
    await _messages.close();
    await _closed.close();
  }
}
