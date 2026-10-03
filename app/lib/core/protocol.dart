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

  /// Desktop -> phone: capability list (models / MCP / skills / prompts) as JSON.
  static const capabilities = 'capabilities';

  /// Phone -> desktop: please send me your capability list.
  static const capabilitiesRequest = 'capabilities-request';

  /// Desktop -> phone: scheduled task list.
  static const tasks = 'tasks';

  /// Phone -> desktop: please send me your scheduled task list.
  static const tasksRequest = 'tasks-request';

  /// Phone -> desktop: run this scheduled task now.
  static const taskRun = 'task-run';

  /// Desktop -> phone: result of a task-run request.
  static const taskRunResult = 'task-run-result';

  /// Desktop -> phone: list of existing desktop conversations.
  static const conversations = 'conversations';

  /// Phone -> desktop: please send me your conversation list.
  static const conversationsRequest = 'conversations-request';

  /// Phone -> desktop: open this conversation on the desktop and let me chat in it.
  static const conversationOpen = 'conversation-open';

  /// Desktop -> phone: result of a conversation-open request.
  static const conversationOpenResult = 'conversation-open-result';

  /// Phone -> desktop: please send me the messages of this conversation.
  static const conversationMessagesRequest = 'conversation-messages-request';

  /// Desktop -> phone: messages of a conversation.
  static const conversationMessages = 'conversation-messages';

  /// Phone -> desktop: delete this conversation.
  static const conversationDelete = 'conversation-delete';

  /// Phone -> desktop: rename this conversation.
  static const conversationRename = 'conversation-rename';

  /// Phone -> desktop: delete these messages inside a conversation.
  static const conversationMessagesDelete = 'conversation-messages-delete';

  /// Desktop -> phone: result of delete / rename / deleteMessages.
  static const conversationActionResult = 'conversation-action-result';

  /// Phone -> desktop: act on one message (re-ask / delete this).
  static const messageAction = 'message-action';

  /// Desktop -> phone: result of a message action.
  static const messageActionResult = 'message-action-result';

  /// Phone -> desktop: create / delete / rename / enable / edit a scheduled task.
  static const taskManage = 'task-manage';

  /// Desktop -> phone: result of a task management op (carries fresh task list).
  static const taskManageResult = 'task-manage-result';

  /// Phone -> desktop: turn auto-compaction on/off (per-model config).
  static const setAutoCompact = 'set-auto-compact';

  /// Desktop -> phone: result of toggling auto-compaction.
  static const setAutoCompactResult = 'set-auto-compact-result';

  /// Desktop -> phone: your message is queued (desktop is mid-generation).
  static const buffered = 'buffered';
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

  /// Which desktop 「快捷助手」(prompt config key) should host this conversation,
  /// e.g. `AI`. Changing it makes the desktop start a fresh conversation.
  final String? promptKey;

  const ChatOptions({
    this.model,
    this.reasoningEffort,
    this.mcp,
    this.skills,
    this.compress,
    this.promptKey,
  });

  bool get isEmpty =>
      model == null &&
      reasoningEffort == null &&
      (mcp == null || mcp!.isEmpty) &&
      (skills == null || skills!.isEmpty) &&
      compress == null &&
      promptKey == null;

  Map<String, dynamic> toJson() => {
        if (model != null) 'model': model,
        if (reasoningEffort != null) 'reasoningEffort': reasoningEffort,
        if (mcp != null) 'mcp': mcp,
        if (skills != null) 'skills': skills,
        if (compress != null) 'compress': compress,
        if (promptKey != null) 'promptKey': promptKey,
      };

  factory ChatOptions.fromJson(Map<String, dynamic> j) => ChatOptions(
        model: j['model'] as String?,
        reasoningEffort: j['reasoningEffort'] as String?,
        mcp: (j['mcp'] as List?)?.map((e) => e.toString()).toList(),
        skills: (j['skills'] as List?)?.map((e) => e.toString()).toList(),
        compress: j['compress'] as bool?,
        promptKey: j['promptKey'] as String?,
      );

  ChatOptions copyWith({
    String? model,
    String? reasoningEffort,
    List<String>? mcp,
    List<String>? skills,
    bool? compress,
    String? promptKey,
    /// 置为 true 时把 promptKey 清空（`promptKey: null` 无法区分"不改"和"改成空"）
    bool clearPromptKey = false,
  }) =>
      ChatOptions(
        model: model ?? this.model,
        reasoningEffort: reasoningEffort ?? this.reasoningEffort,
        mcp: mcp ?? this.mcp,
        skills: skills ?? this.skills,
        compress: compress ?? this.compress,
        promptKey: clearPromptKey ? null : (promptKey ?? this.promptKey),
      );
}

/// Convenience builders for the payloads.
class ChatPayload {
  final String role; // 'user' | 'assistant' | 'system' | 'capabilities' | ...
  final String text;
  final String? conversationId;
  final List<Map<String, dynamic>>? attachments;
  final ChatOptions? options;

  /// 电脑端那条 assistant 消息的元信息（气泡上的「重新回答 / 删除这条」
  /// 要靠它定位到电脑端 chat_show 里的正确位置）。
  final AssistantMeta? assistantMeta;

  ChatPayload({
    required this.role,
    required this.text,
    this.conversationId,
    this.attachments,
    this.options,
    this.assistantMeta,
  });

  Map<String, dynamic> toJson() => {
        'role': role,
        'text': text,
        if (conversationId != null) 'conversationId': conversationId,
        if (attachments != null) 'attachments': attachments,
        if (options != null && !options!.isEmpty) 'options': options!.toJson(),
        if (assistantMeta != null) '__relayAssistantMeta': assistantMeta!.toJson(),
      };

  factory ChatPayload.fromJson(Map<String, dynamic> j) => ChatPayload(
        role: j['role'] as String? ?? 'user',
        text: j['text'] as String? ?? '',
        conversationId: j['conversationId'] as String?,
        attachments: (j['attachments'] as List?)?.cast<Map<String, dynamic>>(),
        options: j['options'] is Map
            ? ChatOptions.fromJson((j['options'] as Map).cast<String, dynamic>())
            : null,
        assistantMeta: j['__relayAssistantMeta'] is Map
            ? AssistantMeta.fromJson(
                (j['__relayAssistantMeta'] as Map).cast<String, dynamic>())
            : null,
      );
}

/// 电脑端某条 assistant 消息的定位信息。
class AssistantMeta {
  /// 电脑端 chat_show 里这条气泡的 id（「重新回答」要回传它）
  final String messageId;
  /// 在 chat_show 里的下标（「删除这条」要回传它）
  final int index;
  final String conversationId;

  AssistantMeta({
    this.messageId = '',
    this.index = -1,
    this.conversationId = '',
  });

  bool get isValid => messageId.isNotEmpty && index >= 0;

  Map<String, dynamic> toJson() => {
        'messageId': messageId,
        'index': index,
        'conversationId': conversationId,
      };

  factory AssistantMeta.fromJson(Map<String, dynamic> j) => AssistantMeta(
        messageId: j['messageId'] as String? ?? '',
        index: (j['index'] as num?)?.toInt() ?? -1,
        conversationId: j['conversationId'] as String? ?? '',
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
  /// 电脑端配的说明文字（可能为空）
  final String description;
  /// stdio / sse / builtin
  final String type;
  final String command;
  final String url;
  final int argsCount;
  final int toolCount;
  final bool builtin;

  McpOption({
    required this.id,
    required this.label,
    this.enabled = true,
    this.description = '',
    this.type = '',
    this.command = '',
    this.url = '',
    this.argsCount = 0,
    this.toolCount = 0,
    this.builtin = false,
  });

  /// 一句话说明，优先用电脑端的描述，没有就按类型兜底
  String get summary {
    if (description.isNotEmpty) return description;
    if (builtin) return '内置工具';
    if (type == 'sse' || url.isNotEmpty) return '远程服务（${url.isEmpty ? "SSE" : url}）';
    if (command.isNotEmpty) return '本地命令：$command';
    return '未填写说明';
  }

  factory McpOption.fromJson(Map<String, dynamic> j) => McpOption(
        id: j['id'] as String? ?? '',
        label: j['label'] as String? ?? j['id'] as String? ?? '',
        enabled: j['enabled'] as bool? ?? true,
        description: j['description'] as String? ?? '',
        type: j['type'] as String? ?? '',
        command: j['command'] as String? ?? '',
        url: j['url'] as String? ?? '',
        argsCount: (j['argsCount'] as num?)?.toInt() ?? 0,
        toolCount: (j['toolCount'] as num?)?.toInt() ?? 0,
        builtin: j['builtin'] as bool? ?? false,
      );
}

class SkillOption {
  final String id;
  final String label;
  final String description;
  final bool userInvocable;
  final bool disabled;
  final String context;
  final List<String> allowedTools;

  SkillOption({
    required this.id,
    required this.label,
    this.description = '',
    this.userInvocable = true,
    this.disabled = false,
    this.context = 'normal',
    this.allowedTools = const [],
  });

  /// 一句话说明（电脑端 SKILL.md 的 description）
  String get summary =>
      description.isNotEmpty ? description : '这个 Skill 没有写说明';

  factory SkillOption.fromJson(Map<String, dynamic> j) => SkillOption(
        id: j['id'] as String? ?? '',
        label: j['label'] as String? ?? j['id'] as String? ?? '',
        description: j['description'] as String? ?? '',
        userInvocable: j['userInvocable'] as bool? ?? true,
        disabled: j['disabled'] as bool? ?? false,
        context: j['context'] as String? ?? 'normal',
        allowedTools: ((j['allowedTools'] as List?) ?? const [])
            .map((e) => e.toString())
            .where((e) => e.isNotEmpty)
            .toList(),
      );
}

/// 电脑端「快捷助手」（prompt 配置）。
///
/// 每个助手自带一套预设（模型 / 思考预算 / MCP / Skill）。选中助手时
/// 要把这些预设一并应用到会话参数里，否则助手配好的 MCP、Skill 不会生效。
class PromptOption {
  final String key;
  final String label;
  final String icon;
  final String model;
  final String type;

  /// 助手预设的思考预算
  final String reasoningEffort;

  /// 助手预设的 MCP 工具 id 列表
  final List<String> mcp;

  /// 助手预设的 Skill 名称列表
  final List<String> skills;

  PromptOption({
    required this.key,
    required this.label,
    this.icon = '',
    this.model = '',
    this.type = 'over',
    this.reasoningEffort = '',
    this.mcp = const [],
    this.skills = const [],
  });

  /// 这个助手是否带了任何预设（用于 UI 上提示"已套用助手预设"）
  bool get hasPreset =>
      model.isNotEmpty ||
      reasoningEffort.isNotEmpty ||
      mcp.isNotEmpty ||
      skills.isNotEmpty;

  /// 预设摘要，例如「5 个 MCP · 3 个 Skill」
  String get presetSummary {
    final bits = <String>[];
    if (model.isNotEmpty) bits.add('模型');
    if (reasoningEffort.isNotEmpty) bits.add('思考');
    if (mcp.isNotEmpty) bits.add('${mcp.length} 个 MCP');
    if (skills.isNotEmpty) bits.add('${skills.length} 个 Skill');
    return bits.join(' · ');
  }

  factory PromptOption.fromJson(Map<String, dynamic> j) => PromptOption(
        key: j['key'] as String? ?? '',
        label: j['label'] as String? ?? j['key'] as String? ?? '',
        icon: j['icon'] as String? ?? '',
        model: j['model'] as String? ?? '',
        type: j['type'] as String? ?? 'over',
        reasoningEffort: j['reasoningEffort'] as String? ?? '',
        mcp: ((j['mcp'] as List?) ?? const [])
            .map((e) => e.toString().trim())
            .where((e) => e.isNotEmpty)
            .toList(),
        skills: ((j['skills'] as List?) ?? const [])
            .map((e) => e.toString().trim())
            .where((e) => e.isNotEmpty)
            .toList(),
      );
}

/// 电脑端已有会话（手机「电脑端对话」列表用）。
class ConversationOption {
  final String id;
  final String title;
  final String updatedAt;
  final String createdAt;
  final int size;
  final String format;
  /// 所属项目（电脑端用 projects.yml 组织会话；未归类时为空）
  final String projectId;
  final String projectName;

  ConversationOption({
    required this.id,
    required this.title,
    this.updatedAt = '',
    this.createdAt = '',
    this.size = 0,
    this.format = 'sqlite',
    this.projectId = '',
    this.projectName = '',
  });

  /// 相对时间，例如「3 分钟前」「昨天」
  String get updatedLabel {
    final dt = DateTime.tryParse(updatedAt);
    if (dt == null) return '';
    final local = dt.toLocal();
    final diff = DateTime.now().difference(local);
    if (diff.inMinutes < 1) return '刚刚';
    if (diff.inMinutes < 60) return '${diff.inMinutes} 分钟前';
    if (diff.inHours < 24) return '${diff.inHours} 小时前';
    if (diff.inDays == 1) return '昨天';
    if (diff.inDays < 30) return '${diff.inDays} 天前';
    return '${local.year}-${_two(local.month)}-${_two(local.day)}';
  }

  static String _two(int n) => n < 10 ? '0$n' : '$n';

  factory ConversationOption.fromJson(Map<String, dynamic> j) => ConversationOption(
        id: j['id'] as String? ?? '',
        title: j['title'] as String? ?? '未命名会话',
        updatedAt: j['updatedAt'] as String? ?? '',
        createdAt: j['createdAt'] as String? ?? '',
        size: (j['size'] as num?)?.toInt() ?? 0,
        format: j['format'] as String? ?? 'sqlite',
        projectId: j['projectId'] as String? ?? '',
        projectName: j['projectName'] as String? ?? '',
      );

  ConversationOption copyWith({String? title, String? projectId, String? projectName}) =>
      ConversationOption(
        id: id,
        title: title ?? this.title,
        updatedAt: updatedAt,
        createdAt: createdAt,
        size: size,
        format: format,
        projectId: projectId ?? this.projectId,
        projectName: projectName ?? this.projectName,
      );
}

/// 会话里的一条消息（只带展示所需的字段）。
class ConvMessage {
  final String id;
  /// 在电脑端 chat_show 里的下标 —— 「删除这条」要回传它
  final int index;
  final String role;
  final String text;
  final String time;

  ConvMessage({
    required this.id,
    this.index = -1,
    required this.role,
    required this.text,
    this.time = '',
  });

  bool get isUser => role == 'user';
  bool get isSystem => role == 'system';
  /// 系统提示词在电脑端不允许删
  bool get canDelete => !isSystem && index >= 0;
  /// 只有 assistant 消息能「重新回答」
  bool get canReask => role == 'assistant' && id.isNotEmpty;

  factory ConvMessage.fromJson(Map<String, dynamic> j) => ConvMessage(
        id: j['id'] as String? ?? '',
        index: (j['index'] as num?)?.toInt() ?? -1,
        role: j['role'] as String? ?? '',
        text: j['text'] as String? ?? '',
        time: j['time'] as String? ?? '',
      );
}

/// 电脑端定时任务。
class TaskOption {
  final String id;
  final String label;
  final String description;
  final bool enabled;
  final String schedule;
  final String promptKey;
  final String modelRoute;
  final String lastRunTime;

  // ---- 下面是「编辑任务」要回填的完整配置 ----
  final String triggerType;
  final int intervalMinutes;
  final String intervalStartTime;
  final String dailyTime;
  final List<int> weeklyDays;
  final String weeklyTime;
  final List<int> monthlyDays;
  final String monthlyTime;
  final String singleDate;
  final String singleTime;
  final int historyCount;

  TaskOption({
    required this.id,
    required this.label,
    this.description = '',
    this.enabled = false,
    this.schedule = '',
    this.promptKey = '',
    this.modelRoute = '',
    this.lastRunTime = '',
    this.triggerType = 'interval',
    this.intervalMinutes = 60,
    this.intervalStartTime = '00:00',
    this.dailyTime = '12:00',
    this.weeklyDays = const [1, 2, 3, 4, 5],
    this.weeklyTime = '12:00',
    this.monthlyDays = const [1],
    this.monthlyTime = '12:00',
    this.singleDate = '',
    this.singleTime = '12:00',
    this.historyCount = 0,
  });

  static List<int> _intList(dynamic v) {
    if (v is! List) return const [];
    final out = <int>[];
    for (final e in v) {
      // 不能直接 as num?，脏数据（字符串）会抛类型错误
      final n = e is num ? e.toInt() : int.tryParse(e?.toString() ?? '');
      if (n != null && n > 0) out.add(n);
    }
    return out;
  }

  factory TaskOption.fromJson(Map<String, dynamic> j) => TaskOption(
        id: j['id'] as String? ?? '',
        label: j['label'] as String? ?? j['id'] as String? ?? '',
        description: j['description'] as String? ?? '',
        enabled: j['enabled'] as bool? ?? false,
        schedule: j['schedule'] as String? ?? '',
        promptKey: j['promptKey'] as String? ?? '',
        modelRoute: j['modelRoute'] as String? ?? '',
        lastRunTime: j['lastRunTime'] as String? ?? '',
        triggerType: j['triggerType'] as String? ?? 'interval',
        intervalMinutes: (j['intervalMinutes'] as num?)?.toInt() ?? 60,
        intervalStartTime: j['intervalStartTime'] as String? ?? '00:00',
        dailyTime: j['dailyTime'] as String? ?? '12:00',
        weeklyDays: _intList(j['weeklyDays']),
        weeklyTime: j['weeklyTime'] as String? ?? '12:00',
        monthlyDays: _intList(j['monthlyDays']),
        monthlyTime: j['monthlyTime'] as String? ?? '12:00',
        singleDate: j['singleDate'] as String? ?? '',
        singleTime: j['singleTime'] as String? ?? '12:00',
        historyCount: (j['historyCount'] as num?)?.toInt() ?? 0,
      );
}

/// 电脑端的会话压缩配置（按模型存）。
///
/// 说明：电脑端的压缩是「上下文快满时自动把前面的对话摘要掉」，
/// 由 `autoCompactEnabled` 控制；也可以手动压一次。
/// 手机端以前那个「压缩」chip 只改了自己的局部变量，电脑端根本不读，
/// 属于假功能——现在改成真正读这份配置。
class CompactConfig {
  /// 这份配置对应的模型（value 形式 "provider|model"）
  final String model;
  final bool autoCompactEnabled;
  final bool hideCompactedMessages;
  /// 上下文窗口大小（token），0 表示未设置
  final int contextLength;
  /// 'manual' | 'auto' | 'api' | ''
  final String contextLengthSource;
  final String compactPrompt;

  CompactConfig({
    this.model = '',
    this.autoCompactEnabled = true,
    this.hideCompactedMessages = true,
    this.contextLength = 0,
    this.contextLengthSource = '',
    this.compactPrompt = '',
  });

  factory CompactConfig.fromJson(Map<String, dynamic> j) => CompactConfig(
        model: j['model'] as String? ?? '',
        autoCompactEnabled: j['autoCompactEnabled'] as bool? ?? true,
        hideCompactedMessages: j['hideCompactedMessages'] as bool? ?? true,
        contextLength: (j['contextLength'] as num?)?.toInt() ?? 0,
        contextLengthSource: j['contextLengthSource'] as String? ?? '',
        compactPrompt: j['compactPrompt'] as String? ?? '',
      );

  String get contextLabel {
    if (contextLength <= 0) return '未设置';
    if (contextLength >= 1000) {
      final k = contextLength / 1000;
      return '${k == k.roundToDouble() ? k.toInt() : k.toStringAsFixed(0)}K';
    }
    return '$contextLength';
  }
}

class Capabilities {
  final List<ModelOption> models;
  final List<McpOption> mcp;
  final List<SkillOption> skills;

  /// 电脑端「快捷助手」列表
  final List<PromptOption> prompts;

  /// 电脑端定时任务列表
  final List<TaskOption> tasks;

  /// 电脑端的会话压缩配置（null = 电脑端版本太旧，不支持）
  final CompactConfig? compact;

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
    this.prompts = const [],
    this.tasks = const [],
    this.compact,
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

  /// 本次是否带来了任务列表（任务单独请求，用于判断"刷新过了"）
  bool get hasTasks => tasks.isNotEmpty;

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
        prompts: ((j['prompts'] as List?) ?? [])
            .map((e) => PromptOption.fromJson((e as Map).cast<String, dynamic>()))
            .where((p) => p.key.isNotEmpty)
            .toList(),
        tasks: ((j['tasks'] as List?) ?? [])
            .map((e) => TaskOption.fromJson((e as Map).cast<String, dynamic>()))
            .where((t) => t.id.isNotEmpty)
            .toList(),
        compact: j['compact'] is Map
            ? CompactConfig.fromJson((j['compact'] as Map).cast<String, dynamic>())
            : null,
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

  Capabilities withTasks(List<TaskOption> next) => Capabilities(
        models: models,
        mcp: mcp,
        skills: skills,
        prompts: prompts,
        tasks: next,
        compact: compact,
        reasoningEffortOptions: reasoningEffortOptions,
        current: current,
        desktopVersion: desktopVersion,
        desktopVersionCode: desktopVersionCode,
        upstreamVersion: upstreamVersion,
        fetchedAt: fetchedAt,
      );
}
