abstract class RoomConnection {
  Map<String, dynamic> get metadata;
  bool get open;
  Stream<void> get opened;
  Stream<void> get closed;
  Stream<Map<String, dynamic>> get messages;
  Future<void> send(Map<String, dynamic> message);
  Future<void> close();
}

abstract class RoomPeer {
  Future<void> start({
    String? peerId,
    required void Function(String) onOpen,
    required void Function(RoomConnection) onConnection,
    required void Function(String) onError,
  });
  Future<RoomConnection> connect(String target, Map<String, dynamic> metadata);
  Future<void> dispose();
}

const peerIdTaken = 'peer-id-taken';
