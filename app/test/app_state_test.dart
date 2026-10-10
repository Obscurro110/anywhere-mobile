import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:anywhere_mobile/core/app_config.dart';
import 'package:anywhere_mobile/core/protocol.dart';
import 'package:anywhere_mobile/services/app_state.dart';
import 'package:anywhere_mobile/services/relay_client.dart';

class FakeRelay extends RelayClient {
  FakeRelay(super.config);
  final incoming = StreamController<Envelope>.broadcast();
  final sent = <Envelope>[];
  bool online = true;
  @override
  Stream<Envelope> get messages => incoming.stream;
  @override
  bool get isConnected => online;
  @override
  bool send(Envelope envelope) {
    if (!online) return false;
    sent.add(envelope);
    return true;
  }
  @override
  Future<FileMeta> uploadFile(File file, {String? name}) async {
    online = false;
    return FileMeta(id: 'file', name: 'test.txt', size: 1,
        mime: 'text/plain', createdAt: 1);
  }
  void opened(String id, String prompt) => incoming.add(Envelope(
    type: MsgType.chat,
    payload: {'role': ChatRole.conversationOpenResult,
      'text': jsonEncode({'__relayConversationOpen': {
        'ok': true, 'conversationId': id, 'title': id, 'promptKey': prompt,
      }})},
  ));
  void metadata(String id, String clientId) => incoming.add(Envelope(
    type: MsgType.chat,
    payload: {'role': ChatRole.userMessageMeta,
      'text': jsonEncode({'__relayUserMessageMeta': {
        'conversationId': id, 'clientMsgId': clientId,
        'messageId': 'desktop-message', 'index': 1,
      }})},
  ));
  void history(String id, List<Map<String, dynamic>> msgs) => incoming.add(Envelope(
    type: MsgType.chat,
    payload: {'role': ChatRole.conversationMessages,
      'text': jsonEncode({'__relayConversationMessages': {
        'conversationId': id, 'ok': true, 'messages': msgs,
      }})},
  ));
  @override
  void dispose() {
    incoming.close();
    super.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FakeRelay relay;
  late AppState state;
  Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 30));
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    final config = AppConfig(userId: 'test', token: 'test',
      serverUrl: 'ws://localhost/ws', deviceId: 'phone', deviceName: 'test');
    relay = FakeRelay(config);
    state = AppState(config, relayClient: relay);
  });
  tearDown(() => state.dispose());

  test('opening a conversation adopts its assistant without detaching', () async {
    state.applyPrompt('A');
    relay.opened('conversation-B', 'B');
    await settle();
    expect(state.activeConversationId, 'conversation-B');
    expect(state.options.promptKey, 'B');
  });

  test('assistant switch requests fresh session and ignores stale metadata', () async {
    relay.opened('old', 'A');
    await settle();
    state.applyPrompt('B');
    await settle();
    expect(state.activeConversationId, isNull);
    expect(state.sendChat('new turn'), isTrue);
    final envelope = relay.sent.last;
    expect(envelope.payload['conversationId'], isNull);
    expect(envelope.payload['__relayNewConversation'], isTrue);
    relay.metadata('old', 'missing-old-client-id');
    await settle();
    expect(state.activeConversationId, isNull);
    relay.metadata('new', envelope.id);
    await settle();
    expect(state.activeConversationId, 'new');
    expect(state.sendChat('next turn'), isTrue);
    expect(relay.sent.last.payload['conversationId'], 'new');
    expect(relay.sent.last.payload['__relayNewConversation'], isNull);
  });

  test('switching away preserves messages persisted during the switch', () async {
    state.historyWriteDelay = const Duration(milliseconds: 80);
    relay.opened('conversation-A', 'A');
    await settle();
    expect(state.sendChat('first'), isTrue);
    final firstId = relay.sent.last.id;
    relay.opened('conversation-B', 'B');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    relay.metadata('conversation-A', firstId);
    await Future<void>.delayed(const Duration(milliseconds: 400));
    final preferences = await SharedPreferences.getInstance();
    final raw = preferences.getString('chat_history:conversation-A') ?? '';
    expect(raw, contains(firstId));
    expect(raw, contains('desktop-message'));
    expect(state.activeConversationId, 'conversation-B');
  });

  test('disconnect during upload does not create a sent attachment', () async {
    await expectLater(state.shareFile(File('unused-test-file')), throwsStateError);
    expect(state.messages, isEmpty);
    expect(state.receivedFiles, isEmpty);
  });

  test('opening a conversation hydrates its desktop history', () async {
    relay.opened('conversation-A', 'A');
    await settle();
    expect(state.activeConversationId, 'conversation-A');
    // 电脑端返回这个会话已有的历史（手机本地原本是空的）
    relay.history('conversation-A', [
      {'id': '1', 'index': 0, 'role': 'user', 'text': '你觉得亚马逊怎么样?', 'time': ''},
      {'id': '2', 'index': 1, 'role': 'assistant', 'text': '挺好的', 'time': ''},
    ]);
    await settle();
    expect(state.messages.length, 2);
    expect(state.messages.first.text, '你觉得亚马逊怎么样?');
    expect(state.messages.first.outgoing, isTrue);
    expect(state.messages.last.text, '挺好的');
    expect(state.messages.last.desktopMeta?.messageId, '2');
  });

  test('hydrating does not duplicate a message already on the desktop', () async {
    relay.opened('conversation-A', 'A');
    await settle();
    expect(state.sendChat('hi'), isTrue);
    final clientId = relay.sent.last.id;
    // 电脑端回执：这条 user 消息在电脑端的 id 是 'desktop-message'
    relay.metadata('conversation-A', clientId);
    await settle();
    // 随后历史里又带回同一条（同一个 desktop id）—— 合并时不能变成两条
    relay.history('conversation-A', [
      {'id': 'desktop-message', 'index': 1, 'role': 'user', 'text': 'hi', 'time': ''},
    ]);
    await settle();
    expect(state.messages.where((m) => m.role == 'user').length, 1);
  });

  test('desktop system prompt does not enter the chat stream', () async {
    relay.opened('conversation-A', 'A');
    await settle();
    expect(state.activeConversationId, 'conversation-A');
    // 电脑端的历史里带一条系统提示词（role=system）—— 它不该出现在聊天消息流
    relay.history('conversation-A', [
      {'id': 'sys', 'index': 0, 'role': 'system', 'text': '你是一个AI助手', 'time': ''},
      {'id': '1', 'index': 1, 'role': 'user', 'text': '你觉得亚马逊怎么样?', 'time': ''},
    ]);
    await settle();
    expect(state.messages.any((m) => m.role == ChatRole.system), isFalse);
    expect(state.messages.any((m) => m.text == '你是一个AI助手'), isFalse);
    expect(state.messages.any((m) => m.text == '你觉得亚马逊怎么样?'), isTrue);
  });
}
