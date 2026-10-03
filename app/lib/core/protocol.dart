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

/// Chat `role` values used as lightweight "channels" over the chat envelope.
class ChatRole {
  static const user = 'user';
  static const assistant = 'assistant';
  static const system = 'system';

  /// Desktop -> phone: capability list (models / MCP / skills) as JSON text.
  static const capabilities = 'capabilities';

  /// Phone -> desktop: please send me your capability list.
  static const capabilitiesRequest = 'capabilities-request';
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

/// Per-message run options the phone can send along with a chat message.
/// These are applied by the desktop before it runs the AI turn.
class ChatOptions {
  /// `"<providerId>|<modelName>"`, e.g. `0|gpt-4o`. null = use desktop default.
  final String? model;

  /// `default | none | low | medium | high | xhigh | max`
  final String? reasoningEffort;

  /// Enabled MCP server ids.
  final List<String>? mcp;

  /// Enabled skill ids.
  final List<String>? skills;

  /// Ask the desktop to compress the conversation before this turn.
  final bool? compress;

  const ChatOptions({
    this.model,
    this.reasoningEffort,
    this.mcp,
    this.skills,
    this.compress,
  });

  bool get isEmpty =>
      model == null &&
      reasoningEffort == null &&
      (mcp == null || mcp!.isEmpty) &&
      (skills == null || skills!.isEmpty) &&
      compress == null;

  Map<String, dynamic> toJson() => {
        if (model != null) 'model': model,
        if (reasoningEffort != null) 'reasoningEffort': reasoningEffort,
        if (mcp != null) 'mcp': mcp,
        if (skills != null) 'skills': skills,
        if (compress != null) 'compress': compress,
      };

  factory ChatOptions.fromJson(Map<String, dynamic> j) => ChatOptions(
        model: j['model'] as String?,
        reasoningEffort: j['reasoningEffort'] as String?,
        mcp: (j['mcp'] as List?)?.map((e) => e.toString()).toList(),
        skills: (j['skills'] as List?)?.map((e) => e.toString()).toList(),
        compress: j['compress'] as bool?,
      );

  ChatOptions copyWith({
    String? model,
    String? reasoningEffort,
    List<String>? mcp,
    List<String>? skills,
    bool? compress,
  }) =>
      ChatOptions(
        model: model ?? this.model,
        reasoningEffort: reasoningEffort ?? this.reasoningEffort,
        mcp: mcp ?? this.mcp,
        skills: skills ?? this.skills,
        compress: compress ?? this.compress,
      );
}

/// Convenience builders for the payloads.
class ChatPayload {
  final String role; // 'user' | 'assistant' | 'system' | 'capabilities' | ...
  final String text;
  final String? conversationId;
  final List<Map<String, dynamic>>? attachments;
  final ChatOptions? options;

  ChatPayload({
    required this.role,
    required this.text,
    this.conversationId,
    this.attachments,
    this.options,
  });

  Map<String, dynamic> toJson() => {
        'role': role,
        'text': text,
        if (conversationId != null) 'conversationId': conversationId,
        if (attachments != null) 'attachments': attachments,
        if (options != null && !options!.isEmpty) 'options': options!.toJson(),
      };

  factory ChatPayload.fromJson(Map<String, dynamic> j) => ChatPayload(
        role: j['role'] as String? ?? 'user',
        text: j['text'] as String? ?? '',
        conversationId: j['conversationId'] as String?,
        attachments: (j['attachments'] as List?)?.cast<Map<String, dynamic>>(),
        options: j['options'] is Map
            ? ChatOptions.fromJson((j['options'] as Map).cast<String, dynamic>())
            : null,
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

  String get humanSize {
    if (size < 1024) return '$size B';
    if (size < 1024 * 1024) return '${(size / 1024).toStringAsFixed(1)} KB';
    if (size < 1024 * 1024 * 1024) {
      return '${(size / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    return '${(size / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  }
}

// ---------------------------------------------------------------------------
// Capabilities (desktop -> phone)
// ---------------------------------------------------------------------------

class ModelOption {
  final String value; // "<providerId>|<modelName>"
  final String label;
  final String provider;

  ModelOption({required this.value, required this.label, this.provider = ''});

  factory ModelOption.fromJson(Map<String, dynamic> j) => ModelOption(
        value: j['value'] as String? ?? '',
        label: j['label'] as String? ?? j['value'] as String? ?? '',
        provider: j['provider'] as String? ?? '',
      );
}

class McpOption {
  final String id;
  final String label;
  final bool enabled;

  McpOption({required this.id, required this.label, this.enabled = true});

  factory McpOption.fromJson(Map<String, dynamic> j) => McpOption(
        id: j['id'] as String? ?? '',
        label: j['label'] as String? ?? j['id'] as String? ?? '',
        enabled: j['enabled'] as bool? ?? true,
      );
}

class SkillOption {
  final String id;
  final String label;

  SkillOption({required this.id, required this.label});

  factory SkillOption.fromJson(Map<String, dynamic> j) => SkillOption(
        id: j['id'] as String? ?? '',
        label: j['label'] as String? ?? j['id'] as String? ?? '',
      );
}

/// Everything the phone needs to render the same pickers as the desktop.
class Capabilities {
  final List<ModelOption> models;
  final List<McpOption> mcp;
  final List<SkillOption> skills;
  final List<String> reasoningEffortOptions;
  final ChatOptions current;
  final int fetchedAt;

  /// 电脑端「手机互通」版本号
  final String desktopVersion;
  final int desktopVersionCode;
  final String upstreamVersion;

  Capabilities({
    this.models = const [],
    this.mcp = const [],
    this.skills = const [],
    this.reasoningEffortOptions = const [
      'default',
      'none',
      'low',
      'medium',
      'high',
      'xhigh',
      'max',
    ],
    this.current = const ChatOptions(),
    this.desktopVersion = '',
    this.desktopVersionCode = 0,
    this.upstreamVersion = '',
    int? fetchedAt,
  }) : fetchedAt = fetchedAt ?? DateTime.now().millisecondsSinceEpoch;

  bool get isEmpty => models.isEmpty && mcp.isEmpty && skills.isEmpty;

  factory Capabilities.fromJson(Map<String, dynamic> j) => Capabilities(
        models: ((j['models'] as List?) ?? [])
            .map((e) => ModelOption.fromJson((e as Map).cast<String, dynamic>()))
            .where((m) => m.value.isNotEmpty)
            .toList(),
        mcp: ((j['mcp'] as List?) ?? [])
            .map((e) => McpOption.fromJson((e as Map).cast<String, dynamic>()))
            .where((m) => m.id.isNotEmpty)
            .toList(),
        skills: ((j['skills'] as List?) ?? [])
            .map((e) => SkillOption.fromJson((e as Map).cast<String, dynamic>()))
            .where((s) => s.id.isNotEmpty)
            .toList(),
        reasoningEffortOptions:
            ((j['reasoningEffortOptions'] as List?) ?? const ['default'])
                .map((e) => e.toString())
                .toList(),
        current: j['current'] is Map
            ? ChatOptions.fromJson((j['current'] as Map).cast<String, dynamic>())
            : const ChatOptions(),
        desktopVersion: j['desktopVersion'] as String? ?? '',
        desktopVersionCode: (j['desktopVersionCode'] as num?)?.toInt() ?? 0,
        upstreamVersion: j['upstreamVersion'] as String? ?? '',
      );
}
