import '../core/protocol.dart';

// Re-export protocol types so importers of models.dart (e.g. screens) can use
// FileMeta / ChatPayload / Envelope without a separate import.
export '../core/protocol.dart'
    show
        FileMeta,
        ChatPayload,
        ChatOptions,
        ChatRole,
        Capabilities,
        ModelOption,
        McpOption,
        SkillOption,
        PromptOption,
        TaskOption,
        ConversationOption,
        ConvMessage,
        CompactConfig,
        AssistantMeta,
        ChoiceMeta,
        ChoiceQuestion,
        ChoiceOption,
        TokenUsage,
        Envelope,
        MsgType,
        kProtocolVersion;

/// A chat message shown in the conversation list.
class ChatMessage {
  final String id;
  final String role; // 'user' | 'assistant' | 'system'
  final String text;
  final DateTime time;
  final bool outgoing; // true = sent from this device
  final String? conversationId;
  final List<FileMeta>? attachments;

  /// True while we're waiting for the desktop to produce this assistant reply.
  final bool pending;

  /// 电脑端那条消息的定位信息（气泡操作栏用）。
  /// 只有「电脑端回传的 assistant 回复」才有，本地消息为 null。
  final AssistantMeta? desktopMeta;

  /// 这条回复是哪个模型答的，形如「服务商|模型名」（电脑端回传）。
  /// 空字符串表示电脑端没报（旧版本），UI 会退回默认文案。
  final String modelTag;

  /// 电脑端 ask_user_choice 正在等用户选择（气泡下渲染可点选的选项）。
  /// 用户提交后此消息的 choice 应被置空（避免重复提交）。
  final ChoiceMeta? choice;

  ChatMessage({
    required this.id,
    required this.role,
    required this.text,
    required this.time,
    required this.outgoing,
    this.conversationId,
    this.attachments,
    this.pending = false,
    this.desktopMeta,
    this.modelTag = '',
    this.choice,
  });

  /// 是电脑端 AI 的回复（能重新回答 / 删除）
  bool get isDesktopAssistant =>
      !outgoing && role == 'assistant' && (desktopMeta?.isValid ?? false);

  Map<String, dynamic> toJson() => {
        'id': id,
        'role': role,
        'text': text,
        'time': time.millisecondsSinceEpoch,
        'outgoing': outgoing,
        'conversationId': conversationId,
        'attachments': attachments?.map((e) => e.toJson()).toList(),
        if (desktopMeta != null) 'desktopMeta': desktopMeta!.toJson(),
        if (modelTag.isNotEmpty) 'modelTag': modelTag,
        if (choice != null) 'choice': choice!.toJson(),
      };

  factory ChatMessage.fromJson(Map<String, dynamic> j) => ChatMessage(
        id: j['id'] as String,
        role: j['role'] as String? ?? 'user',
        text: j['text'] as String? ?? '',
        time: DateTime.fromMillisecondsSinceEpoch((j['time'] as num?)?.toInt() ?? 0),
        outgoing: j['outgoing'] as bool? ?? false,
        conversationId: j['conversationId'] as String?,
        attachments: (j['attachments'] as List?)
            ?.map((e) => FileMeta.fromJson(e as Map<String, dynamic>))
            .toList(),
        desktopMeta: j['desktopMeta'] is Map
            ? AssistantMeta.fromJson(
                (j['desktopMeta'] as Map).cast<String, dynamic>())
            : null,
        modelTag: j['modelTag'] as String? ?? '',
        choice: j['choice'] is Map
            ? ChoiceMeta.fromJson((j['choice'] as Map).cast<String, dynamic>())
            : null,
      );

  ChatMessage copyWith({String? text, bool? pending, ChoiceMeta? choice}) =>
      ChatMessage(
        id: id,
        role: role,
        text: text ?? this.text,
        time: time,
        outgoing: outgoing,
        conversationId: conversationId,
        attachments: attachments,
        pending: pending ?? this.pending,
        desktopMeta: desktopMeta,
        modelTag: modelTag,
        choice: choice ?? this.choice,
      );
}

/// A peer device currently visible on the relay for this user.
class PeerDevice {
  final String deviceId;
  final String deviceName;
  final String platform;
  final DateTime connectedAt;
  final bool online;

  PeerDevice({
    required this.deviceId,
    required this.deviceName,
    required this.platform,
    required this.connectedAt,
    this.online = true,
  });

  factory PeerDevice.fromJson(Map<String, dynamic> j) => PeerDevice(
        deviceId: j['deviceId'] as String,
        deviceName: j['deviceName'] as String? ?? 'Device',
        platform: j['platform'] as String? ?? 'unknown',
        connectedAt: DateTime.fromMillisecondsSinceEpoch(
            (j['connectedAt'] as num?)?.toInt() ?? 0),
        online: j['online'] as bool? ?? true,
      );

  Map<String, dynamic> toJson() =>
      {'deviceId': deviceId, 'deviceName': deviceName, 'platform': platform};

  bool get isDesktop => platform == 'desktop';
}
