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

  /// 文件上传/下载的最长等待时间（大文件走的是中继，给足余量）
  static const Duration _httpTimeout = Duration(minutes: 3);

  WebSocketChannel? _channel;
  StreamSubscription? _sub;
  Timer? _pingTimer;
  Timer? _reconnectTimer;
  int _retry = 0;
  bool _manuallyClosed = false;

  /// 连接「代次」。每次 _open() 自增，异步回调用它判断自己是否已过期。
  ///
  /// 为什么需要：`channel.ready` 是个 Future，_open() 被再次调用（重连/手动
  /// 连接）后，**上一次**的 ready 回调仍会触发。它会去改 _status、启动 ping、
  /// 甚至调 _onClosed 触发再次重连 —— 把一条已经健康的新连接搞成断开，
  /// 表现为「连接状态反复跳 / 一直重连」。dispose() 之后触发还会泄漏定时器。
  int _gen = 0;

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
    // 手动连接时，把排队中的自动重连取消掉，否则会出现两条连接同时建立
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
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

    final myGen = ++_gen;
    try {
      final channel = IOWebSocketChannel.connect(
        uri,
        pingInterval: const Duration(seconds: 20),
        connectTimeout: const Duration(seconds: 10),
      );
      _channel = channel;
      _sub = channel.stream.listen(
        _onData,
        onError: (e) => _onClosed('error: $e', myGen),
        onDone: () => _onClosed('closed', myGen),
        cancelOnError: true,
      );
      // wait for the socket to be ready
      channel.ready.then((_) {
        if (myGen != _gen) return; // 这次连接已被取代，别再去改状态
        _retry = 0;
        _setStatus(RelayStatus.connected);
        _startPing();
      }).catchError((e) {
        if (myGen != _gen) return;
        _onClosed('ready failed: $e', myGen);
      });
    } catch (e) {
      if (myGen != _gen) return;
      _onClosed('connect failed: $e', myGen);
    }
  }

  void _onData(dynamic raw) {
    // raw 可能是 String，也可能是 List<int>；其它类型直接忽略，
    // 以前写死 `raw as List<int>`，遇到意外类型会抛异常打断整个流。
    String text;
    if (raw is String) {
      text = raw;
    } else if (raw is List<int>) {
      try {
        text = utf8.decode(raw);
      } catch (e) {
        debugPrint('[RelayClient] decode failed: $e');
        return;
      }
    } else {
      return;
    }
    final env = Envelope.tryDecode(text);
    if (env == null) return;
    if (env.type == MsgType.pong) return;
    if (!_controller.isClosed) _controller.add(env);
  }

  /// [gen] 是触发这次关闭的连接代次；过期（已被新连接取代）就忽略。
  ///
  /// 同一个 socket 的 onError 和 onDone 可能都会触发这里，
  /// 不加守卫会把 _retry 重复自增、并排两个重连定时器。
  void _onClosed(String reason, [int? gen]) {
    if (gen != null && gen != _gen) return;
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
    // 必须加超时：中继不可达时 http.post 会一直挂着，
    // 界面上的「发送中」永远不结束。
    final resp = await http
        .post(
          uri,
          headers: {'content-type': 'application/octet-stream'},
          body: bytes,
        )
        .timeout(_httpTimeout);
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
    final resp = await http.get(uri).timeout(_httpTimeout);
    if (resp.statusCode != 200) {
      throw Exception('download failed ${resp.statusCode}');
    }
    final f = File(savePath);
    await f.writeAsBytes(resp.bodyBytes);
    return f;
  }

  void dispose() {
    _manuallyClosed = true;
    // 代次自增：任何在途的 ready/onError/onDone 回调都会因过期而被忽略，
    // 否则 dispose 之后仍可能启动一个永远停不下来的 ping 定时器。
    _gen++;
    _stopPing();
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _cleanupSocket();
    if (!_controller.isClosed) _controller.close();
    if (!_statusController.isClosed) _statusController.close();
  }
}
