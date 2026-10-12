import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:uuid/uuid.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'transport.dart';

// PeerJS 1.5.5 signaling and JSON data-channel wire format. JSON frames are
// UTF-8 binary frames, matching PeerJS's BufferedConnection/Json serializer.
class NativePeer implements RoomPeer {
  NativePeer({
    this.host = '0.peerjs.com',
    this.port = 443,
    this.path = '/',
    this.secure = true,
    this.iceServers = const [
      {'urls': 'stun:stun.l.google.com:19302'},
    ],
  });
  final String host, path;
  final int port;
  final bool secure;
  final List<Map<String, dynamic>> iceServers;
  String id = const Uuid().v4();
  final String token = const Uuid().v4();
  WebSocketChannel? _socket;
  StreamSubscription<dynamic>? _subscription;
  Timer? _heartbeat, _reconnect;
  bool _disposed = false, _ready = false;
  final Map<String, _NativeConnection> _connections = {};
  final Map<String, List<Map<String, dynamic>>> _earlyCandidates = {};
  final List<Map<String, dynamic>> _outbox = [];
  Future<void> _queue = Future.value();
  late void Function(String) _onOpen, _onError;
  late void Function(RoomConnection) _onConnection;

  @override
  Future<void> start({
    String? peerId,
    required void Function(String) onOpen,
    required void Function(RoomConnection) onConnection,
    required void Function(String) onError,
  }) async {
    if (peerId != null) id = peerId;
    _onOpen = onOpen;
    _onConnection = onConnection;
    _onError = onError;
    await _openSocket();
  }

  Future<void> _openSocket() async {
    if (_disposed) return;
    final normalized = path.endsWith('/') ? path : '$path/';
    final uri = Uri(
      scheme: secure ? 'wss' : 'ws',
      host: host,
      port: port,
      path: '${normalized}peerjs',
      queryParameters: {
        'key': 'peerjs',
        'id': id,
        'token': token,
        'version': '1.5.5',
      },
    );
    try {
      final socket = _socket = WebSocketChannel.connect(uri);
      await socket.ready;
      if (_disposed || _socket != socket) {
        await socket.sink.close();
        return;
      }
      _subscription = socket.stream.listen(
        (data) {
          _queue = _queue.then((_) => _handle(data)).catchError((Object error) {
            if (!_disposed) _onError('接続処理に失敗しました。再接続してください。');
          });
        },
        onError: (Object error) => _socketLost(socket),
        onDone: () => _socketLost(socket),
      );
      _heartbeat?.cancel();
      _heartbeat = Timer.periodic(const Duration(seconds: 5), (_) {
        if (!_disposed && _ready)
          socket.sink.add(jsonEncode({'type': 'HEARTBEAT'}));
      });
    } catch (_) {
      if (!_disposed) {
        _onError('接続サービスにつながりません。回線を確認してください。');
        _scheduleReconnect();
      }
    }
  }

  void _socketLost(WebSocketChannel socket) {
    if (_disposed || _socket != socket) return;
    _ready = false;
    _socket = null;
    _heartbeat?.cancel();
    _onError('接続サービスとの通信が切れました。再接続しています…');
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    _reconnect?.cancel();
    _reconnect = Timer(const Duration(seconds: 2), () {
      if (!_disposed) unawaited(_openSocket());
    });
  }

  void _signal(Map<String, dynamic> message) {
    if (_disposed) return;
    if (!_ready) {
      _outbox.add(message);
      return;
    }
    _socket?.sink.add(jsonEncode(message));
  }

  Future<void> _handle(dynamic raw) async {
    if (_disposed) return;
    dynamic decoded;
    try {
      decoded = jsonDecode(raw is String ? raw : utf8.decode(raw as List<int>));
    } catch (_) {
      return;
    }
    if (decoded is! Map) return;
    final message = Map<String, dynamic>.from(decoded);
    if (message['type'] == 'OPEN') {
      _ready = true;
      final pending = List<Map<String, dynamic>>.of(_outbox);
      _outbox.clear();
      for (final m in pending) {
        _signal(m);
      }
      _onOpen(id);
      return;
    }
    if ([
      'ERROR',
      'ID-TAKEN',
      'INVALID-KEY',
      'EXPIRE',
    ].contains(message['type'])) {
      _onError(
        message['type'] == 'ID-TAKEN'
            ? peerIdTaken
            : message['type'] == 'EXPIRE'
            ? '部屋が見つかりません。作成者の画面を確認してください。'
            : '接続サービスに接続できませんでした。',
      );
      return;
    }
    final payload = message['payload'], source = message['src'];
    if (payload is! Map ||
        source is! String ||
        payload['connectionId'] is! String)
      return;
    final connectionId = payload['connectionId'] as String,
        key = '$source/$connectionId';
    if (message['type'] == 'OFFER') {
      if (payload['type'] != 'data' ||
          payload['serialization'] != 'json' ||
          _connections.containsKey(key))
        return;
      final metadata = payload['metadata'] is Map
          ? Map<String, dynamic>.from(payload['metadata'] as Map)
          : <String, dynamic>{};
      final conn = _newConnection(source, connectionId, metadata);
      await conn.initialize();
      for (final candidate
          in _earlyCandidates.remove(key) ?? <Map<String, dynamic>>[]) {
        await conn.candidate(candidate);
      }
      if (_disposed) {
        await conn.close();
        return;
      }
      _onConnection(conn);
      await conn.answer(Map<String, dynamic>.from(payload['sdp'] as Map));
    } else {
      final conn = _connections[key];
      if (conn == null) {
        if (message['type'] == 'CANDIDATE' &&
            payload['candidate'] is Map &&
            _earlyCandidates.length < 64) {
          final list = _earlyCandidates.putIfAbsent(key, () => []);
          if (list.length < 64)
            list.add(Map<String, dynamic>.from(payload['candidate'] as Map));
        }
        return;
      }
      if (message['type'] == 'ANSWER' && payload['sdp'] is Map)
        await conn.remoteDescription(
          Map<String, dynamic>.from(payload['sdp'] as Map),
        );
      if (message['type'] == 'CANDIDATE' && payload['candidate'] is Map)
        await conn.candidate(
          Map<String, dynamic>.from(payload['candidate'] as Map),
        );
      if (message['type'] == 'LEAVE') await conn.close();
    }
  }

  _NativeConnection _newConnection(
    String target,
    String connectionId,
    Map<String, dynamic> metadata,
  ) {
    final conn = _NativeConnection(
      target,
      connectionId,
      metadata,
      iceServers,
      _signal,
    );
    _connections['$target/$connectionId'] = conn;
    conn.closed.listen((_) {
      _connections.remove('$target/$connectionId');
    });
    return conn;
  }

  @override
  Future<RoomConnection> connect(
    String target,
    Map<String, dynamic> metadata,
  ) async {
    final conn = _newConnection(target, 'dc_${const Uuid().v4()}', metadata);
    await conn.initialize();
    unawaited(
      conn.offer().catchError((Object error) {
        _onError('対戦相手につながりませんでした。');
        return conn.close();
      }),
    );
    return conn;
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    _reconnect?.cancel();
    _heartbeat?.cancel();
    _ready = false;
    _outbox.clear();
    await _subscription?.cancel();
    await _socket?.sink.close();
    for (final conn in List<_NativeConnection>.of(_connections.values)) {
      await conn.close();
    }
    _connections.clear();
    _earlyCandidates.clear();
  }
}

class _NativeConnection implements RoomConnection {
  _NativeConnection(
    this.target,
    this.id,
    this.metadata,
    this.iceServers,
    this.signal,
  );
  final String target, id;
  @override
  final Map<String, dynamic> metadata;
  final List<Map<String, dynamic>> iceServers;
  final void Function(Map<String, dynamic>) signal;
  RTCPeerConnection? _pc;
  RTCDataChannel? _channel;
  final _opened = StreamController<void>.broadcast(sync: true),
      _closed = StreamController<void>.broadcast(sync: true);
  final _messages = StreamController<Map<String, dynamic>>.broadcast(
    sync: true,
  );
  bool _isOpen = false, _disposed = false, _remoteSet = false;
  final List<RTCIceCandidate> _pending = [];
  @override
  bool get open => _isOpen && !_disposed;
  @override
  Stream<void> get opened => _opened.stream;
  @override
  Stream<void> get closed => _closed.stream;
  @override
  Stream<Map<String, dynamic>> get messages => _messages.stream;
  Future<void> initialize() async {
    final pc = _pc = await createPeerConnection({
      'iceServers': iceServers,
      'sdpSemantics': 'unified-plan',
    });
    pc.onIceCandidate = (candidate) {
      if (!_disposed && candidate.candidate?.isNotEmpty == true)
        signal({
          'type': 'CANDIDATE',
          'dst': target,
          'payload': {
            'type': 'data',
            'connectionId': id,
            'candidate': candidate.toMap(),
          },
        });
    };
    pc.onDataChannel = _attach;
    pc.onConnectionState = (state) {
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
          state == RTCPeerConnectionState.RTCPeerConnectionStateClosed)
        unawaited(close());
    };
  }

  void _attach(RTCDataChannel channel) {
    if (_disposed) {
      unawaited(channel.close());
      return;
    }
    _channel = channel;
    void stateChanged(RTCDataChannelState state) {
      if (_disposed) return;
      if (state == RTCDataChannelState.RTCDataChannelOpen && !_isOpen) {
        _isOpen = true;
        _opened.add(null);
      }
      if (state == RTCDataChannelState.RTCDataChannelClosed) unawaited(close());
    }

    channel.onDataChannelState = stateChanged;
    channel.onMessage = (message) {
      if (_disposed) return;
      try {
        final value = jsonDecode(
          message.isBinary ? utf8.decode(message.binary) : message.text,
        );
        if (value is Map) {
          if (value['__peerData'] is Map &&
              value['__peerData']['type'] == 'close') {
            unawaited(close());
            return;
          }
          _messages.add(Map<String, dynamic>.from(value));
        }
      } catch (_) {
        /* Ignore malformed channel frames. */
      }
    };
    if (channel.state != null) stateChanged(channel.state!);
  }

  Future<void> offer() async {
    if (_disposed) return;
    _attach(
      await _pc!.createDataChannel(id, RTCDataChannelInit()..ordered = true),
    );
    final sdp = await _pc!.createOffer();
    await _pc!.setLocalDescription(sdp);
    if (!_disposed)
      signal({
        'type': 'OFFER',
        'dst': target,
        'payload': {
          'type': 'data',
          'connectionId': id,
          'label': id,
          'serialization': 'json',
          'reliable': true,
          'metadata': metadata,
          'sdp': sdp.toMap(),
        },
      });
  }

  Future<void> remoteDescription(Map<String, dynamic> sdp) async {
    if (_disposed) return;
    await _pc!.setRemoteDescription(
      RTCSessionDescription(sdp['sdp'] as String?, sdp['type'] as String?),
    );
    _remoteSet = true;
    for (final c in _pending) {
      await _pc!.addCandidate(c);
    }
    _pending.clear();
  }

  Future<void> answer(Map<String, dynamic> offer) async {
    await remoteDescription(offer);
    if (_disposed) return;
    final sdp = await _pc!.createAnswer();
    await _pc!.setLocalDescription(sdp);
    if (!_disposed)
      signal({
        'type': 'ANSWER',
        'dst': target,
        'payload': {'type': 'data', 'connectionId': id, 'sdp': sdp.toMap()},
      });
  }

  Future<void> candidate(Map<String, dynamic> value) async {
    if (_disposed) return;
    final c = RTCIceCandidate(
      value['candidate'] as String?,
      value['sdpMid'] as String?,
      value['sdpMLineIndex'] as int?,
    );
    if (_remoteSet)
      await _pc!.addCandidate(c);
    else
      _pending.add(c);
  }

  @override
  Future<void> send(Map<String, dynamic> message) async {
    if (!open) throw StateError('Connection is not open');
    await _channel!.send(
      RTCDataChannelMessage.fromBinary(
        Uint8List.fromList(utf8.encode(jsonEncode(message))),
      ),
    );
  }

  @override
  Future<void> close() async {
    if (_disposed) return;
    _disposed = true;
    _isOpen = false;
    _closed.add(null);
    await _channel?.close();
    await _pc?.close();
    await _pc?.dispose();
    await _opened.close();
    await _messages.close();
    await _closed.close();
  }
}
