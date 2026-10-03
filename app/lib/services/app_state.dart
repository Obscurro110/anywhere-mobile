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

const _uuid = Uuid();

/// Central application state. Owns the [RelayClient], chat history, peer list,
/// transferred files and delivered notifications.
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

  String? _activeConversationId;

  RelayClient get client => _client;
  String get deviceId => config.deviceId;
  String? get activeConversationId => _activeConversationId;

  void _bind() {
    _client.statusStream.listen((s) {
      status = s;
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
  }

  void _handleChat(Envelope env) {
    final p = ChatPayload.fromJson((env.payload as Map).cast<String, dynamic>());
    messages.add(ChatMessage(
      id: env.id,
      role: p.role,
      text: p.text,
      time: DateTime.fromMillisecondsSinceEpoch(env.ts),
      outgoing: false,
      conversationId: p.conversationId,
      attachments: (p.attachments ?? [])
          .map((e) => FileMeta.fromJson(e))
          .toList(),
    ));
    _persistHistory();

    // if it came from desktop while app in background, surface a notification
    if (p.role == 'assistant') {
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
    notifications.show('File received', meta.name, id: env.ts.remainder(100000));
  }

  void _handleDeliveryStatus(Envelope env) {
    final status = env.payload?['status'];
    if (status == 'undelivered') {
      final idx = messages.indexWhere((m) => m.id == env.id);
      if (idx >= 0) {
        // simply annotate it isn't delivered; full queueing handled desktop-side
        debugPrint('[AppState] message ${env.id} undelivered');
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
      to: toDeviceId ?? '*',
      payload: ChatPayload(
        role: 'user',
        text: text2,
        conversationId: _activeConversationId,
      ).toJson(),
    );
    messages.add(ChatMessage(
      id: env.id,
      role: 'user',
      text: text2,
      time: DateTime.now(),
      outgoing: true,
      conversationId: _activeConversationId,
    ));
    _persistHistory();
    notifyListeners();
    return _client.send(env);
  }

  /// Upload a local file and share it with the desktop (or all devices).
  Future<void> shareFile(File file, {String? toDeviceId}) async {
    final meta = await _client.uploadFile(file);
    final env = Envelope(
      type: MsgType.fileShare,
      from: config.deviceId,
      to: toDeviceId ?? '*',
      payload: {'file': meta.toJson()},
    );
    _client.send(env);
    receivedFiles.insert(0, meta); // show our own sent file too
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
          ..addAll(list.map((e) => ChatMessage.fromJson(e as Map<String, dynamic>)));
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
    final trimmed = messages.length > 500 ? messages.sublist(messages.length - 500) : messages;
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
