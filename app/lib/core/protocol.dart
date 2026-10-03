import 'dart:convert';
import 'package:uuid/uuid.dart';

/// Wire protocol version. MUST match `docs/PROTOCOL.md` and the relay server.
const int kProtocolVersion = 1;

const _uuid = Uuid();

/// Envelope message types exchanged between Android / Desktop via the relay.
class MsgType {
  static const welcome = 'welcome';
  static const presence = 'presence';
  static const chat = 'chat';
  static const chatAck = 'ack';
  static const notification = 'notification';
  static const fileShare = 'file_share';
  static const fileStored = 'file_stored';
  static const ping = 'ping';
  static const pong = 'pong';
  static const error = 'error';
  static const deliveryStatus = 'delivery_status';
}

/// A single unit of data flowing over the relay.
class Envelope {
  final int v;
  final String type;
  final String id;
  final String from;
  final String to;
  final int ts;
  final dynamic payload;

  Envelope({
    this.v = kProtocolVersion,
    required this.type,
    String? id,
    this.from = '',
    this.to = '*',
    int? ts,
    this.payload,
  })  : id = id ?? _uuid.v4(),
        ts = ts ?? DateTime.now().millisecondsSinceEpoch;

  Map<String, dynamic> toJson() => {
        'v': v,
        'type': type,
        'id': id,
        'from': from,
        'to': to,
        'ts': ts,
        'payload': payload,
      };

  factory Envelope.fromJson(Map<String, dynamic> j) => Envelope(
        v: (j['v'] as num?)?.toInt() ?? kProtocolVersion,
        type: j['type'] as String? ?? '',
        id: j['id'] as String? ?? _uuid.v4(),
        from: j['from'] as String? ?? '',
        to: j['to'] as String? ?? '*',
        ts: (j['ts'] as num?)?.toInt() ?? 0,
        payload: j['payload'],
      );

  String encode() => jsonEncode(toJson());

  static Envelope? tryDecode(dynamic raw) {
    if (raw is! String) return null;
    try {
      final m = jsonDecode(raw);
      if (m is Map<String, dynamic>) return Envelope.fromJson(m);
    } catch (_) {}
    return null;
  }
}

/// Convenience builders for the payloads.
class ChatPayload {
  final String role; // 'user' | 'assistant' | 'system'
  final String text;
  final String? conversationId;
  final List<Map<String, dynamic>>? attachments;

  ChatPayload({
    required this.role,
    required this.text,
    this.conversationId,
    this.attachments,
  });

  Map<String, dynamic> toJson() => {
        'role': role,
        'text': text,
        if (conversationId != null) 'conversationId': conversationId,
        if (attachments != null) 'attachments': attachments,
      };

  factory ChatPayload.fromJson(Map<String, dynamic> j) => ChatPayload(
        role: j['role'] as String? ?? 'user',
        text: j['text'] as String? ?? '',
        conversationId: j['conversationId'] as String?,
        attachments: (j['attachments'] as List?)?.cast<Map<String, dynamic>>(),
      );
}

class FileMeta {
  final String id;
  final String name;
  final int size;
  final String mime;
  final int createdAt;

  FileMeta({
    required this.id,
    required this.name,
    required this.size,
    required this.mime,
    required this.createdAt,
  });

  factory FileMeta.fromJson(Map<String, dynamic> j) => FileMeta(
        id: j['id'] as String,
        name: j['name'] as String? ?? 'file',
        size: (j['size'] as num?)?.toInt() ?? 0,
        mime: j['mime'] as String? ?? 'application/octet-stream',
        createdAt: (j['createdAt'] as num?)?.toInt() ?? 0,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'size': size,
        'mime': mime,
        'createdAt': createdAt,
      };
}
