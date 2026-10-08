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
    await Future<void>.delayed(const Duration(milliseconds: 180));
    final preferences = await SharedPreferences.getInstance();
    final raw = preferences.getString('chat_history:conversation-A') ?? '';
    expect(raw, contains(firstId));
    expect(raw, contains('desktop-message'));
  });

  test('disconnect during upload does not create a sent attachment', () async {
    await expectLater(state.shareFile(File('unused-test-file')), throwsStateError);
    expect(state.messages, isEmpty);
    expect(state.receivedFiles, isEmpty);
  });
}
