import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../core/app_config.dart';
import '../core/protocol.dart';
import '../models/models.dart';
import 'notification_service.dart';
import 'relay_client.dart';
import 'update_service.dart';

const _uuid = Uuid();

/// Central application state. Owns the [RelayClient], chat history, peer list,
/// transferred files, delivered notifications and the desktop capability list.
class AppState extends ChangeNotifier {
  AppState(this.config) {
    _client = RelayClient(config);
    _bind();
  }

  AppConfig config;
  late RelayClient _client;
  final notifications = NotificationService();

  RelayStatus status = RelayStatus.disconnected;
  final List<ChatMessage> messages = [];
  final List<PeerDevice> peers = [];
  final List<FileMeta> receivedFiles = [];
  final List<Map<String, dynamic>> inbox = []; // notifications

  /// Models / MCP / skills / prompts reported by the desktop.
  Capabilities capabilities = Capabilities();

  /// 电脑端定时任务（单独请求，避免每次能力刷新都拉）
  List<TaskOption> tasks = const [];

  /// 最近一次「立即运行」的结果
  Map<String, dynamic>? lastTaskRun;

  /// 是否正在拉取任务列表
  bool loadingTasks = false;

  /// Currently selected run options (sent with every message).
  ChatOptions options = const ChatOptions();

  /// Which desktop to talk to. null = broadcast.
  String? targetDeviceId;

  String? _activeConversationId;

  /// True while we're waiting for the desktop's reply (drives the UI spinner).
  bool get awaitingReply => messages.isNotEmpty && messages.last.pending;

  RelayClient get client => _client;
  String get deviceId => config.deviceId;
  String? get activeConversationId => _activeConversationId;

  void _bind() {
    _client.statusStream.listen((s) {
      status = s;
      if (s == RelayStatus.connected) {
        // Ask the desktop for its model / MCP / skill list on (re)connect.
        Future.delayed(const Duration(milliseconds: 600), requestCapabilities);
      }
      notifyListeners();
    });
    _client.messages.listen(_onEnvelope);
  }

  Future<void> init() async {
    await notifications.init();
    await _loadHistory();
    _client.connect();
  }

  // ---- config changes ----
  Future<void> updateConfig(AppConfig next) async {
    config = next;
    await config.save();
    _client.dispose();
    _client = RelayClient(config);
    _bind();
    _client.connect();
    notifyListeners();
  }

  // ---- capabilities ----
  void requestCapabilities() {
    if (!_client.isConnected) return;
    _client.send(Envelope(
      type: MsgType.chat,
      from: config.deviceId,
      to: targetDeviceId ?? '*',
      payload: ChatPayload(
        role: ChatRole.capabilitiesRequest,
        text: '',
      ).toJson(),
    ));
  }

  void setOptions(ChatOptions next) {
    options = next;
    notifyListeners();
  }

  /// 拉取电脑端定时任务列表。
  Future<void> requestTasks() async {
    if (!_client.isConnected) return;
    loadingTasks = true;
    notifyListeners();
    _client.send(Envelope(
      type: MsgType.chat,
      from: config.deviceId,
      to: targetDeviceId ?? '*',
      payload: ChatPayload(role: ChatRole.tasksRequest, text: '').toJson(),
    ));
    // 给电脑端一点时间回传；超时后关掉 loading，避免一直转圈
    await Future.delayed(const Duration(seconds: 6));
    if (loadingTasks) {
      loadingTasks = false;
      notifyListeners();
    }
  }

  /// 让电脑端「立即运行」某个定时任务。
  bool runTask(String taskId, {String? toDeviceId}) {
    if (!_client.isConnected) return false;
    lastTaskRun = null;
    notifyListeners();
    return _client.send(Envelope(
      type: MsgType.chat,
      from: config.deviceId,
      to: toDeviceId ?? targetDeviceId ?? '*',
      payload: {
        'role': ChatRole.taskRun,
        'text': '',
        'taskId': taskId,
      },
    ));
  }

  /// 清掉「立即运行」的结果提示。
  void clearTaskRun() {
    lastTaskRun = null;
    notifyListeners();
  }

  /// 断开后用当前配置重新连接（设置页「重新连接」按钮用）。
  void reconnect() {
    _client.dispose();
    _client = RelayClient(config);
    _bind();
    _client.connect();
    notifyListeners();
  }

  /// 本机 App 版本号（「v1.3.2」这种），设置页状态卡展示用。
  String appVersion = '?';
  Future<void> loadAppVersion() async {
    try {
      final v = await AppVersion.current();
      appVersion = v.versionName;
      notifyListeners();
    } catch (_) {
      // 读不到就保持 '?'
    }
  }

  void setTargetDevice(String? id) {
    targetDeviceId = id;
    notifyListeners();
  }

  /// 标题栏胶囊上显示的当前发送目标。
  String get targetLabel {
    if (targetDeviceId == null) {
      // 只有一台对端设备时，直接显示它的名字，省得用户还要点开看
      final others = peers.where((d) => d.deviceId != config.deviceId).toList();
      if (others.length == 1) return others.first.deviceName;
      return others.isEmpty ? '所有设备' : '所有设备 (${others.length})';
    }
    final hit = peers.where((d) => d.deviceId == targetDeviceId);
    return hit.isNotEmpty ? hit.first.deviceName : '已选设备';
  }

  // ---- incoming envelopes ----
  Future<void> _onEnvelope(Envelope env) async {
    switch (env.type) {
      case MsgType.presence:
        _handlePresence(env);
        break;
      case MsgType.chat:
        _handleChat(env);
        break;
      case MsgType.notification:
        await _handleNotification(env);
        break;
      case MsgType.fileShare:
        _handleFileShare(env);
        break;
      case MsgType.fileStored:
        break;
      case MsgType.deliveryStatus:
        _handleDeliveryStatus(env);
        break;
    }
    notifyListeners();
  }

  void _handlePresence(Envelope env) {
    final list = (env.payload?['devices'] as List? ?? [])
        .map((e) => PeerDevice.fromJson(e as Map<String, dynamic>))
        .where((d) => d.deviceId != config.deviceId)
        .toList();
    peers
      ..clear()
      ..addAll(list);
    // Auto-target the first desktop if the user hasn't chosen one.
    if (targetDeviceId == null) {
      final desktop = list.where((d) => d.isDesktop);
      if (desktop.isNotEmpty) targetDeviceId = desktop.first.deviceId;
    } else if (!list.any((d) => d.deviceId == targetDeviceId)) {
      targetDeviceId = null;
    }
  }

  void _handleChat(Envelope env) {
    final p = ChatPayload.fromJson((env.payload as Map).cast<String, dynamic>());

    // Desktop capability list
    if (p.role == ChatRole.capabilities) {
      try {
        final decoded = jsonDecode(p.text) as Map<String, dynamic>;
        final raw = decoded['__relayCapabilities'] ?? decoded;
        capabilities = Capabilities.fromJson((raw as Map).cast<String, dynamic>());
        notifyListeners();
      } catch (e) {
        debugPrint('[AppState] capabilities decode failed: $e');
      }
      return;
    }

    if (p.role == ChatRole.system) {
      // internal message, don't show
      return;
    }

    // 电脑端回传定时任务列表
    if (p.role == ChatRole.tasks) {
      try {
        final decoded = jsonDecode(p.text) as Map<String, dynamic>;
        final raw = (decoded['__relayTasks'] as List?) ?? const [];
        tasks = raw
            .map((e) => TaskOption.fromJson((e as Map).cast<String, dynamic>()))
            .where((t) => t.id.isNotEmpty)
            .toList();
        loadingTasks = false;
        notifyListeners();
      } catch (e) {
        debugPrint('[AppState] tasks decode failed: $e');
      }
      return;
    }

    // 电脑端回传「立即运行」结果
    if (p.role == ChatRole.taskRunResult) {
      try {
        final decoded = jsonDecode(p.text) as Map<String, dynamic>;
        final r = (decoded['__relayTaskRun'] as Map?)?.cast<String, dynamic>() ?? {};
        final ok = r['ok'] == true;
        lastTaskRun = {
          'ok': ok,
          'taskId': r['taskId']?.toString() ?? '',
          'reason': r['reason']?.toString() ?? '',
          'at': DateTime.now().millisecondsSinceEpoch,
        };
        notifications.show(
          ok ? '任务已触发' : '任务未能运行',
          ok ? '电脑端已开始执行该定时任务' : (r['reason']?.toString() ?? '未知原因'),
          id: DateTime.now().millisecondsSinceEpoch.remainder(100000),
        );
        notifyListeners();
      } catch (e) {
        debugPrint('[AppState] task-run-result decode failed: $e');
      }
      return;
    }

    final isAssistant = p.role == ChatRole.assistant;

    // Merge into the pending assistant bubble if we were waiting for one.
    if (isAssistant && messages.isNotEmpty && messages.last.pending) {
      messages[messages.length - 1] = ChatMessage(
        id: env.id,
        role: p.role,
        text: p.text,
        time: DateTime.fromMillisecondsSinceEpoch(env.ts),
        outgoing: false,
        conversationId: p.conversationId,
        attachments: (p.attachments ?? []).map((e) => FileMeta.fromJson(e)).toList(),
      );
    } else {
      messages.add(ChatMessage(
        id: env.id,
        role: p.role,
        text: p.text,
        time: DateTime.fromMillisecondsSinceEpoch(env.ts),
        outgoing: false,
        conversationId: p.conversationId,
        attachments: (p.attachments ?? []).map((e) => FileMeta.fromJson(e)).toList(),
      ));
    }
    _persistHistory();

    // if it came from desktop while app in background, surface a notification
    if (isAssistant) {
      notifications.show('Anywhere', p.text, id: env.ts.remainder(100000));
    }
  }

  Future<void> _handleNotification(Envelope env) async {
    final payload = (env.payload as Map?)?.cast<String, dynamic>() ?? {};
    final title = payload['title'] as String? ?? 'Anywhere';
    final body = payload['body'] as String? ?? '';
    final item = {
      'id': env.id,
      'title': title,
      'body': body,
      'time': env.ts,
      'read': false,
    };
    inbox.insert(0, item);
    await _persistInbox();
    await notifications.show(title, body, id: env.ts.remainder(100000));
    notifyListeners();
  }

  void _handleFileShare(Envelope env) {
    final fileJson = (env.payload as Map?)?['file'];
    if (fileJson == null) return;
    final meta = FileMeta.fromJson((fileJson as Map).cast<String, dynamic>());
    receivedFiles.insert(0, meta);
    messages.add(ChatMessage(
      id: env.id,
      role: ChatRole.system,
      text: '',
      time: DateTime.fromMillisecondsSinceEpoch(env.ts),
      outgoing: false,
      attachments: [meta],
    ));
    _persistHistory();
    notifications.show('收到文件', meta.name, id: env.ts.remainder(100000));
  }

  void _handleDeliveryStatus(Envelope env) {
    final st = env.payload?['status'];
    if (st == 'undelivered') {
      debugPrint('[AppState] message ${env.id} undelivered');
      // Mark the pending bubble as failed so the UI stops spinning.
      if (messages.isNotEmpty && messages.last.pending) {
        messages[messages.length - 1] = messages.last
            .copyWith(text: '⚠️ 电脑端未收到（可能未启动或未连接）', pending: false);
        _persistHistory();
      }
    }
  }

  // ---- outgoing ----
  bool sendChat(String text, {String? toDeviceId}) {
    final text2 = text.trim();
    if (text2.isEmpty) return false;

    final env = Envelope(
      type: MsgType.chat,
      from: config.deviceId,
      to: toDeviceId ?? targetDeviceId ?? '*',
      payload: ChatPayload(
        role: ChatRole.user,
        text: text2,
        conversationId: _activeConversationId,
        options: options.isEmpty ? null : options,
      ).toJson(),
    );

    messages.add(ChatMessage(
      id: env.id,
      role: ChatRole.user,
      text: text2,
      time: DateTime.now(),
      outgoing: true,
      conversationId: _activeConversationId,
    ));

    // Optimistic "thinking" bubble — replaced when the desktop answers.
    messages.add(ChatMessage(
      id: 'pending-${_uuid.v4()}',
      role: ChatRole.assistant,
      text: '',
      time: DateTime.now(),
      outgoing: false,
      pending: true,
    ));

    _persistHistory();
    notifyListeners();

    final ok = _client.send(env);
    if (!ok) {
      if (messages.isNotEmpty && messages.last.pending) {
        messages.removeLast();
        notifyListeners();
      }
    }
    return ok;
  }

  /// Upload a local file and share it with the desktop (or all devices).
  Future<void> shareFile(File file, {String? toDeviceId}) async {
    final meta = await _client.uploadFile(file);
    final env = Envelope(
      type: MsgType.fileShare,
      from: config.deviceId,
      to: toDeviceId ?? targetDeviceId ?? '*',
      payload: {'file': meta.toJson()},
    );
    _client.send(env);
    receivedFiles.insert(0, meta);
    messages.add(ChatMessage(
      id: env.id,
      role: ChatRole.user,
      text: '',
      time: DateTime.now(),
      outgoing: true,
      attachments: [meta],
    ));
    _persistHistory();
    notifyListeners();
  }

  Future<File> downloadToDevice(FileMeta meta) async {
    final dir = await getApplicationDocumentsDirectory();
    final saveDir = Directory('${dir.path}/AnywhereDownloads');
    if (!await saveDir.exists()) await saveDir.create(recursive: true);
    final path = '${saveDir.path}/${meta.name}';
    final f = await _client.downloadFile(meta.id, path);
    notifyListeners();
    return f;
  }

  // ---- persistence ----
  Future<void> _loadHistory() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString('chat_history');
    if (raw != null) {
      try {
        final list = jsonDecode(raw) as List;
        messages
          ..clear()
          ..addAll(list
              .map((e) => ChatMessage.fromJson(e as Map<String, dynamic>))
              .where((m) => !m.pending));
      } catch (_) {}
    }
    final rawInbox = p.getString('inbox');
    if (rawInbox != null) {
      try {
        final list = jsonDecode(rawInbox) as List;
        inbox
          ..clear()
          ..addAll(list.cast<Map<String, dynamic>>());
      } catch (_) {}
    }
  }

  Future<void> _persistHistory() async {
    final p = await SharedPreferences.getInstance();
    final keep = messages.where((m) => !m.pending).toList();
    final trimmed = keep.length > 500 ? keep.sublist(keep.length - 500) : keep;
    await p.setString('chat_history', jsonEncode(trimmed.map((e) => e.toJson()).toList()));
  }

  Future<void> _persistInbox() async {
    final p = await SharedPreferences.getInstance();
    await p.setString('inbox', jsonEncode(inbox.take(200).toList()));
  }

  Future<void> clearHistory() async {
    messages.clear();
    await _persistHistory();
    notifyListeners();
  }

  void markInboxRead() {
    for (final i in inbox) {
      i['read'] = true;
    }
    _persistInbox();
    notifyListeners();
  }

  @override
  void dispose() {
    _client.dispose();
    super.dispose();
  }
}
