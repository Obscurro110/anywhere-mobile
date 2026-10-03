import '../core/protocol.dart';

// Re-export protocol types so importers of models.dart (e.g. screens) can use
// FileMeta / ChatPayload / Envelope without a separate import.
export '../core/protocol.dart'
    show FileMeta, ChatPayload, Envelope, MsgType, kProtocolVersion;

/// A chat message shown in the conversation list.
class ChatMessage {
  final String id;
  final String role; // 'user' | 'assistant' | 'system'
  final String text;
  final DateTime time;
  final bool outgoing; // true = sent from this device
  final String? conversationId;
  final List<FileMeta>? attachments;

  ChatMessage({
    required this.id,
    required this.role,
    required this.text,
    required this.time,
    required this.outgoing,
    this.conversationId,
    this.attachments,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'role': role,
        'text': text,
        'time': time.millisecondsSinceEpoch,
        'outgoing': outgoing,
        'conversationId': conversationId,
        'attachments': attachments?.map((e) => e.toJson()).toList(),
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
