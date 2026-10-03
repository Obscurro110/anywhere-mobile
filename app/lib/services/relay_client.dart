import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/io.dart';

import '../core/app_config.dart';
import '../core/protocol.dart';

enum RelayStatus { disconnected, connecting, connected }

/// Low-level WebSocket client to the public relay server.
///
/// Responsibilities: connect/reconnect, keepalive, encode/decode envelopes,
/// and expose a broadcast stream of incoming [Envelope]s.
class RelayClient {
  RelayClient(this.config);

  final AppConfig config;

  WebSocketChannel? _channel;
  StreamSubscription? _sub;
  Timer? _pingTimer;
  Timer? _reconnectTimer;
  int _retry = 0;
  bool _manuallyClosed = false;

  final _controller = StreamController<Envelope>.broadcast();
  final _statusController = StreamController<RelayStatus>.broadcast();
  RelayStatus _status = RelayStatus.disconnected;

  Stream<Envelope> get messages => _controller.stream;
  Stream<RelayStatus> get statusStream => _statusController.stream;
  RelayStatus get status => _status;
  bool get isConnected => _status == RelayStatus.connected;

  void _setStatus(RelayStatus s) {
    _status = s;
    if (!_statusController.isClosed) _statusController.add(s);
  }

  void connect() {
    _manuallyClosed = false;
    _open();
  }

  void _open() {
    _cleanupSocket();
    _setStatus(RelayStatus.connecting);

    final uri = Uri.parse(
      '${config.serverUrl}'
      '?token=${Uri.encodeComponent(config.token)}'
      '&deviceId=${Uri.encodeComponent(config.deviceId)}'
      '&deviceName=${Uri.encodeComponent(config.deviceName)}'
      '&platform=${Uri.encodeComponent(config.platform)}',
    );

    try {
      final channel = IOWebSocketChannel.connect(
        uri,
        pingInterval: const Duration(seconds: 20),
        connectTimeout: const Duration(seconds: 10),
      );
      _channel = channel;
      _sub = channel.stream.listen(
        _onData,
        onError: (e) => _onClosed('error: $e'),
        onDone: () => _onClosed('closed'),
        cancelOnError: true,
      );
      // wait for the socket to be ready
      channel.ready.then((_) {
        _retry = 0;
        _setStatus(RelayStatus.connected);
        _startPing();
      }).catchError((e) {
        _onClosed('ready failed: $e');
      });
    } catch (e) {
      _onClosed('connect failed: $e');
    }
  }

  void _onData(dynamic raw) {
    final env = Envelope.tryDecode(raw is String ? raw : utf8.decode(raw as List<int>));
    if (env == null) return;
    if (env.type == MsgType.pong) return;
    if (!_controller.isClosed) _controller.add(env);
  }

  void _onClosed(String reason) {
    debugPrint('[RelayClient] closed: $reason');
    _stopPing();
    _setStatus(RelayStatus.disconnected);
    if (!_manuallyClosed) _scheduleReconnect();
  }

  void _scheduleReconnect() {
    _reconnectTimer?.cancel();
    final delay = Duration(seconds: min(30, 2 + _retry * 2));
    _retry++;
    _reconnectTimer = Timer(delay, () {
      if (!_manuallyClosed) _open();
    });
  }

  void _startPing() {
    _pingTimer?.cancel();
    _pingTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      send(Envelope(type: MsgType.ping));
    });
  }

  void _stopPing() {
    _pingTimer?.cancel();
    _pingTimer = null;
  }

  void _cleanupSocket() {
    _sub?.cancel();
    _sub = null;
    try {
      _channel?.sink.close();
    } catch (_) {}
    _channel = null;
  }

  bool send(Envelope env) {
    if (_channel == null || !isConnected) return false;
    try {
      final out = env.toJson();
      out['from'] = config.deviceId;
      _channel!.sink.add(jsonEncode(out));
      return true;
    } catch (e) {
      debugPrint('[RelayClient] send failed: $e');
      return false;
    }
  }

  /// Upload a local file to the relay and return its [FileMeta].
  Future<FileMeta> uploadFile(File file, {String? name}) async {
    final fileName = name ?? file.path.split(Platform.pathSeparator).last;
    final uri = Uri.parse(
      '${config.httpBase}/upload?token=${Uri.encodeComponent(config.token)}&name=${Uri.encodeComponent(fileName)}',
    );
    // The relay accepts a raw byte stream as the request body.
    final bytes = await file.readAsBytes();
    final resp = await http.post(
      uri,
      headers: {'content-type': 'application/octet-stream'},
      body: bytes,
    );
    if (resp.statusCode != 200) {
      throw Exception('upload failed ${resp.statusCode}: ${resp.body}');
    }
    final j = jsonDecode(resp.body) as Map<String, dynamic>;
    if (j['ok'] != true) throw Exception('upload rejected: ${resp.body}');
    return FileMeta.fromJson(j['file'] as Map<String, dynamic>);
  }

  /// Download a relayed file to [savePath].
  Future<File> downloadFile(String fileId, String savePath) async {
    final uri = Uri.parse(
      '${config.httpBase}/file/$fileId?token=${Uri.encodeComponent(config.token)}',
    );
    final resp = await http.get(uri);
    if (resp.statusCode != 200) {
      throw Exception('download failed ${resp.statusCode}');
    }
    final f = File(savePath);
    await f.writeAsBytes(resp.bodyBytes);
    return f;
  }

  void dispose() {
    _manuallyClosed = true;
    _stopPing();
    _reconnectTimer?.cancel();
    _cleanupSocket();
    _controller.close();
    _statusController.close();
  }
}
