import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../core/app_config.dart';
import '../models/models.dart';
import 'notification_service.dart';
import 'relay_client.dart';
import 'update_service.dart';

const _uuid = Uuid();

/// Central application state. Owns the [RelayClient], chat history, peer list,
/// transferred files, delivered notifications and the desktop capability list.
class AppState extends ChangeNotifier {
  AppState(this.config, {RelayClient? relayClient}) {
    _client = relayClient ?? RelayClient(config);
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

  /// 电脑端已有会话（「电脑端对话」列表）
  List<ConversationOption> conversations = const [];
  bool loadingConversations = false;
  bool conversationsOk = true;
  String? conversationsError;

  /// 电脑端项目的名字列表（用于列表分组）
  List<String> conversationProjects = const [];

  /// 某个会话的消息（会话详情页看）
  /// 每个会话各自一份消息列表，按 conversationId 隔离。
  ///
  /// 以前是一个全局单例 `conversationMessages`：打开会话 A 再打开 B 时，
  /// 谁先请求谁后到达都会互相覆盖 —— 表现就是「多个会话内容重合」，
  /// 甚至看到的是另一个会话的内容（比如只显示 AI 回复的那个）。
  final Map<String, List<ConvMessage>> _convMessagesByConv = {};

  /// 正在加载中的会话 id 集合（每个会话各自的 loading）
  final Set<String> _convMessagesLoading = {};

  /// 每个会话各自的错误信息
  final Map<String, String> _convMessagesError = {};

  /// 当前「正在查看」的会话 id。详情页进来时设置它。
  ///
  /// 这样列表 / loading / error 都跟着当前会话走，
  /// 而不需要一个全局字段被所有会话抢着写。
  String? _viewingConversationId;

  /// 当前正在查看的会话 id
  String? get viewingConversationId => _viewingConversationId;

  /// 当前查看会话的消息列表（没有就空列表）
  List<ConvMessage> get conversationMessages =>
      _viewingConversationId == null
          ? const []
          : (_convMessagesByConv[_viewingConversationId!] ?? const []);

  /// 当前查看会话是否在加载
  bool get loadingConversationMessages =>
      _viewingConversationId != null &&
      _convMessagesLoading.contains(_viewingConversationId);

  /// 当前查看会话的错误（没有就 null）
  String? get conversationMessagesError =>
      _viewingConversationId == null ? null : _convMessagesError[_viewingConversationId];

  /// 某个会话的消息（详情页可显式按 id 取，避免依赖「当前查看」的时序）
  List<ConvMessage> messagesOf(String conversationId) =>
      _convMessagesByConv[conversationId] ?? const [];

  /// 最近一次「打开电脑端会话」的结果
  Map<String, dynamic>? lastConversationOpen;

  /// 最近一次会话管理操作（删除/重命名/删消息）的结果
  Map<String, dynamic>? lastConversationAction;

  /// 最近一次「消息操作」（重新回答 / 删除这条）的结果
  Map<String, dynamic>? lastMessageAction;

  /// 最近一次「自动压缩」开关的结果
  Map<String, dynamic>? lastAutoCompactAction;

  /// 最近一次定时任务管理操作的结果
  Map<String, dynamic>? lastTaskAction;

  /// 正在等待电脑端回能力清单（给「电脑端能力」页的刷新按钮转圈用）
  bool loadingCapabilities = false;

  /// 电脑端提示「消息已排队」的提示信息（null = 没在排队）
  Map<String, dynamic>? bufferNotice;

  /// 正在等待电脑端回结果的「重新回答」目标（本地消息 id）。
  /// 用来让那颗刷新图标转圈，而不是弹一个没必要的弹窗。
  String? reaskingLocalId;

  /// 正在等待电脑端回结果的「删除这条」目标（本地消息 id）。
  String? deletingLocalId;

  /// 手动压缩是否已发起（电脑端跑完会刷新能力清单）
  bool compactRunning = false;

  /// 最近一次删消息的条数（给 UI 提示用）
  int _lastDeletedCount = 0;
  int get lastDeletedCount => _lastDeletedCount;

  /// Currently selected run options (sent with every message).
  ChatOptions options = const ChatOptions();

  /// Which desktop to talk to. null = broadcast.
  String? targetDeviceId;

  /// 当前手机正在对话的电脑端会话（null = 手机自建的临时会话）。
  /// 读取用 public getter `activeConversationId`（见下），写入用
  /// `leaveDesktopConversation()` / `_setActiveConversation()`。
  String? _activeConversationId;
  String _activeConversationTitle = '';

  /// True while we're waiting for the desktop's reply (drives the UI spinner).
  bool get awaitingReply => hasPendingReply;

  /// 最早那条「等待电脑端回复」的气泡下标；没有就 -1。
  ///
  /// 为什么是**最早**而不是最后：连续发多条时会有多个 pending 气泡排队。
  /// 电脑端是按顺序回复的，所以第一个回复该落在第一个 pending 上。
  /// 以前只认 `messages.last.pending`，于是：
  ///   · 第 1 条回复把第 2 个 pending 覆盖掉（内容错位）
  ///   · 第 1 个 pending 再也没人认领 → 一直显示「电脑端处理中」
  int _firstPendingIndex() {
    for (var i = 0; i < messages.length; i++) {
      if (messages[i].pending) return i;
    }
    return -1;
  }

  /// 是否还有气泡在等电脑端回复
  bool get hasPendingReply => _firstPendingIndex() >= 0;

  RelayClient get client => _client;
  String get deviceId => config.deviceId;

  /// 当前对接着的电脑端会话 id（null = 手机自建会话）
  String? get activeConversationId => _activeConversationId;

  /// 当前对接着的电脑端会话标题
  String get activeConversationTitle => _activeConversationTitle;

  int _conversationSwitchGeneration = 0;
  @visibleForTesting
  Duration historyWriteDelay = Duration.zero;
  final Set<String> _detachedConversationIds = {};
  final Map<String, Future<void>> _historyWrites = {};

  /// 切换「当前对话的电脑端会话」。
  ///
  /// **必须同时换掉 messages** —— 每个会话的聊天记录是分开存的，
  /// 不换就会出现「切了会话但还显示上一个会话内容」的重合问题。
  void _setActiveConversation(String? id, String title) {
    final changed = (id ?? '') != (_activeConversationId ?? '');
    if (!changed) {
      _activeConversationTitle = title;
      unawaited(_persistActiveConversation());
      notifyListeners();
      return;
    }

    // ⚠️ 关键：**同步**切换状态，不能等 await 之后再改。
    //
    // 以前是 `await _persistHistory()` 之后才改 _activeConversationId，
    // 这段异步窗口期里：
    //   · 新到的回复仍被算到**旧会话**头上；
    //   · 别处触发的 _persistHistory() 会把内容写进**旧 key**；
    //   · 用户快速连点两个会话时，两个异步闭包交错执行，
    //     最终可能「id 是 A、内容却是 B」——就是"多个对话内容重合"。
    // 现在先把旧会话内容快照下来，立刻切 id 并清空 messages，
    // 落盘和加载都基于快照/新 id，天然不会串。
    final oldId = _activeConversationId;
    final snapshot = messages.where((m) => !m.pending).toList();
    final switchGeneration = ++_conversationSwitchGeneration;

    _activeConversationId = id;
    _activeConversationTitle = title;
    messages.clear(); // 立刻清空，避免旧会话内容残留在界面上
    unawaited(_persistActiveConversation());
    notifyListeners();

    unawaited(() async {
      // 旧会话的记录用**快照 + 旧 key** 落盘（此时 _activeConversationId 已变）
      await _persistMessagesTo(oldId, snapshot);
      if (switchGeneration != _conversationSwitchGeneration || _activeConversationId != id) return;
      await _switchHistoryTo(id, switchGeneration);
      // 切会话时正在等待的回复属于旧会话，别把它的 pending 带过来
      notifyListeners();
    }());
  }

  /// 把指定的一份消息写到**指定会话**的 key（不依赖当前 _activeConversationId）。
  Future<void> _persistMessagesTo(String? conversationId, List<ChatMessage> msgs) {
    final key = _historyKey(conversationId);
    final delay = historyWriteDelay;
    final previous = _historyWrites[key] ?? Future<void>.value();
    final current = previous.catchError((_) {}).then((_) async {
      if (delay > Duration.zero) await Future<void>.delayed(delay);
      try {
        final p = await SharedPreferences.getInstance();
        final existing = _decodeHistory(p.getString(key));
        final merged = _mergeHistory(existing, msgs);
        final trimmed = merged.length > 500 ? merged.sublist(merged.length - 500) : merged;
        await p.setString(
          key,
          jsonEncode(trimmed.map((e) => e.toJson()).toList()),
        );
      } catch (e) {
        debugPrint('[AppState] _persistMessagesTo failed: $e');
      }
    });
    _historyWrites[key] = current;
    return current.whenComplete(() {
      if (identical(_historyWrites[key], current)) _historyWrites.remove(key);
    });
  }

  List<ChatMessage> _decodeHistory(String? raw) {
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = jsonDecode(raw) as List;
      return list
          .map((e) => ChatMessage.fromJson(e as Map<String, dynamic>))
          .where((m) => !m.pending)
          .toList();
    } catch (_) {
      return [];
    }
  }

  /// 同一会话的多次保存可能乱序完成。按消息 ID 合并，不能让较旧快照覆盖新快照。
  Future<void> _updateStoredMessage(
    String? conversationId,
    String messageId,
    ChatMessage Function(ChatMessage old) update,
  ) async {
    if (messageId.isEmpty) return;
    final key = _historyKey(conversationId);
    await (_historyWrites[key] ?? Future<void>.value());
    final stored = _decodeHistory((await SharedPreferences.getInstance()).getString(key));
    final index = stored.indexWhere((message) => message.id == messageId);
    if (index < 0) return;
    stored[index] = update(stored[index]);
    await _persistMessagesTo(conversationId, stored);
  }

  List<ChatMessage> _mergeHistory(List<ChatMessage> stored, List<ChatMessage> incoming) {
    final byId = <String, ChatMessage>{
      for (final message in stored.where((m) => !m.pending)) message.id: message,
    };
    final order = stored.map((m) => m.id).toList();
    for (final message in incoming.where((m) => !m.pending)) {
      if (!byId.containsKey(message.id)) order.add(message.id);
      byId[message.id] = message;
    }
    return [
      for (final id in order)
        if (byId.containsKey(id)) byId[id]!,
    ];
  }

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
    await _loadSubmittedChoices();
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

  /// 刷新在线设备列表（向中继发 presence 广播，收到后更新 peers）。
  void refreshPeers() {
    if (!_client.isConnected) return;
    _client.send(Envelope(type: MsgType.presence));
  }

  // ---- capabilities ----
  void requestCapabilities() {
    if (!_client.isConnected) return;
    loadingCapabilities = true;
    notifyListeners();
    // 兜底：10 秒还没回就别一直转圈
    Future.delayed(const Duration(seconds: 10), () {
      if (loadingCapabilities) {
        loadingCapabilities = false;
        notifyListeners();
      }
    });
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

  // ---- 电脑端能力编辑 ----

  /// 最近一次能力编辑的结果（给 UI 弹提示用）
  Map<String, dynamic>? lastCapsEdit;

  /// 正在等待电脑端回执的编辑 op（给按钮转圈用）
  String? editingCapsOp;

  /// 给电脑端发一条能力编辑指令。
  ///
  /// [op] 见桌面端 caps-edit 分支：prompt-save / prompt-delete /
  /// provider-save / provider-delete / mcp-save / mcp-delete /
  /// skill-toggle / skill-delete。
  /// 回执（caps-edit-result）会带上**最新的能力清单**，直接替换本地缓存。
  bool editDesktopCapability(String op, Map<String, dynamic> body) {
    if (!_client.isConnected) return false;
    lastCapsEdit = null;
    editingCapsOp = op;
    notifyListeners();
    final ok = _client.send(Envelope(
      type: MsgType.chat,
      from: config.deviceId,
      to: targetDeviceId ?? '*',
      payload: {
        'role': ChatRole.capsEdit,
        'text': '',
        'op': op,
        'body': body,
      },
    ));
    if (!ok) {
      editingCapsOp = null;
      notifyListeners();
    }
    return ok;
  }

  void setOptions(ChatOptions next) {
    options = next;
    notifyListeners();
  }

  /// 选中某个「快捷助手」，并把它自带的预设（模型 / 思考预算 / MCP / Skill）
  /// 同步进会话参数。
  ///
  /// 电脑端在建立会话时会应用 `prompt.defaultMcpServers` / `defaultSkills`，
  /// 但手机端如果不显式带上，后续一旦手动改过参数就可能把助手预设覆盖掉，
  /// 所以这里一次性套用，用户之后仍可单独微调。
  ///
  /// 传 null 表示回到「默认助手」（清空助手相关预设，保留其他手动设置）。
  /// 用户是否**手动**选过助手。
  /// 手动选过之后，就不再被电脑端上报的默认助手覆盖。
  bool _promptTouchedByUser = false;

  /// 换助手后，下一条消息必须创建新电脑端会话；成功发送一次后清除。
  bool _forceNewConversationOnNextMessage = false;

  /// 用户是不是主动退出了电脑端会话。
  bool _leftConversationManually = false;

  void applyPrompt(String? key, {bool fromUser = true}) {
    if (fromUser) {
      _promptTouchedByUser = true;
      if ((key ?? '') != (options.promptKey ?? '')) {
        _forceNewConversationOnNextMessage = true;
      }
    }

    // ⚠️⚠️ 关键规则：**助手属于「会话」，不属于「参数」**。
    //
    // 在已经绑定某个电脑端会话的情况下换助手，必须**先解绑**（回到
    // 「新会话」状态）—— 否则下一条消息仍然带着旧 conversationId，
    // 电脑端会把新助手的预设（模型 / MCP / Skill）灌进**旧会话**，
    // 而旧会话自己的助手并不会变 —— 于是出现
    // 「这个会话的助手是 A，参数却是 B 的」这种不伦不类的状态，
    // 也就是用户说的「会话和助手绑定不严格 / 会错乱」。
    //
    // 正确语义：**换助手 = 开新会话**。
    if (fromUser && _activeConversationId != null) {
      final changed = (key ?? '') != (options.promptKey ?? '');
      if (changed) {
        // ⚠️ 这里只解绑，**不能**设 _leftConversationManually：
        // 发出去的消息会在电脑端开一个新会话，回传的 user-message-meta
        // 需要能把手机绑到**新会话**上；一旦标记"用户主动退出"，
        // _bindActiveConversationSilently 会拒绝绑定 → 每轮都开新会话，
        // 新助手必须开启新的电脑端会话，而不是复用旧手机窗口。
        _forceNewConversationOnNextMessage = true;
        _detachedConversationIds.add(_activeConversationId!);
        _setActiveConversation(null, '');
      }
    }

    if (key == null || key.isEmpty) {
      options = options.copyWith(clearPromptKey: true);
      if (_activeConversationId != null) unawaited(_persistActiveConversation());
      notifyListeners();
      return;
    }

    final hit = capabilities.prompts.where((p) => p.key == key);
    final p = hit.isNotEmpty ? hit.first : null;

    options = ChatOptions(
      promptKey: key,
      // 助手没配就用用户当前的选择，不要清空
      model: (p != null && p.model.isNotEmpty) ? p.model : options.model,
      reasoningEffort: (p != null && p.reasoningEffort.isNotEmpty)
          ? p.reasoningEffort
          : options.reasoningEffort,
      mcp: (p != null && p.mcp.isNotEmpty) ? p.mcp : options.mcp,
      skills: (p != null && p.skills.isNotEmpty) ? p.skills : options.skills,
    );
    // 打开会话时是「先 setActiveConversation，再 applyPrompt(会话自带助手)」，
    // 所以这里要补一次持久化，否则存进磁盘的还是切换前的助手。
    if (_activeConversationId != null) {
      unawaited(_persistActiveConversation());
    }
    notifyListeners();
  }

  /// 当前选中的助手（没选返回 null）。
  PromptOption? get activePrompt {
    final key = options.promptKey;
    if (key == null || key.isEmpty) return null;
    final hit = capabilities.prompts.where((p) => p.key == key);
    return hit.isNotEmpty ? hit.first : null;
  }

  /// 拿到电脑端能力清单后，把「手机当前助手」对齐到电脑端正在用的那个。
  ///
  /// 只在**用户没手动选过助手**、且手机没绑定某个电脑端会话时才对齐 ——
  /// 否则会把用户的选择/会话自带的助手覆盖掉。
  void _adoptDesktopPrompt(Capabilities caps) {
    final key = caps.desktopPromptKey;
    if (key.isEmpty) return;
    if (_promptTouchedByUser) return;
    if (_activeConversationId != null) return;
    if (options.promptKey == key) return;
    applyPrompt(key, fromUser: false);
  }

  /// 静默把手机当前聊天绑定到电脑端真实会话。
  ///
  /// 场景：手机在「主聊天」里发消息，电脑端其实把它路由进了某个具体会话
  /// （比如复用的「手机」会话）。以前手机不知道这件事，于是下一条消息
  /// 又可能被路由到别处 —— 表现就是「对话和助手没有对应」。
  /// 这里只改绑定，不切历史（当前这些消息本来就属于那个会话）。
  void _bindActiveConversationSilently(String convId, {String title = ''}) {
    if (convId.isEmpty) return;
    // 用户主动退出过 → 尊重这个选择，不要再自动绑回去
    if (_leftConversationManually) return;
    if (_activeConversationId == convId) return;
    if (_activeConversationId != null) return; // 已绑定别的会话，不要抢
    ++_conversationSwitchGeneration;
    _activeConversationId = convId;
    if (title.isNotEmpty) _activeConversationTitle = title;
    unawaited(_persistActiveConversation());
    unawaited(_persistHistory());
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

  /// 拉取电脑端已有会话列表。
  Future<void> requestConversations() async {
    if (!_client.isConnected) {
      conversationsError = '未连接到中继服务器';
      notifyListeners();
      return;
    }
    loadingConversations = true;
    conversationsError = null;
    notifyListeners();
    _client.send(Envelope(
      type: MsgType.chat,
      from: config.deviceId,
      to: targetDeviceId ?? '*',
      payload: ChatPayload(role: ChatRole.conversationsRequest, text: '').toJson(),
    ));
    await Future.delayed(const Duration(seconds: 8));
    if (loadingConversations) {
      loadingConversations = false;
      conversationsError ??= '电脑端没有响应（确认电脑端在线，且已设置本地会话目录）';
      notifyListeners();
    }
  }

  /// 在电脑端打开某个已有会话，并把回复回传到这里。
  bool openConversationOnDesktop(String conversationId) {
    if (!_client.isConnected) return false;
    lastConversationOpen = null;
    _detachedConversationIds.remove(conversationId);
    notifyListeners();
    return _client.send(Envelope(
      type: MsgType.chat,
      from: config.deviceId,
      to: targetDeviceId ?? '*',
      payload: {
        'role': ChatRole.conversationOpen,
        'text': '',
        'conversationId': conversationId,
      },
    ));
  }

  /// 回到「手机自建会话」（不再对接着电脑端的某个会话）。
  void leaveDesktopConversation() {
    lastConversationOpen = null;
    // 记住"是我主动退出的"：之后电脑端回传 conversationId 也不会自动绑回去
    _leftConversationManually = true;
    if (_activeConversationId != null) _detachedConversationIds.add(_activeConversationId!);
    _forceNewConversationOnNextMessage = true;
    _setActiveConversation(null, '');
  }

  // ---- 电脑端会话管理 ----

  /// 拉取某个会话的消息内容（会话详情页）。
  ///
  /// 只动**这个会话自己**的那份缓存，不影响别的会话 ——
  /// 以前直接清空全局列表，导致并发/乱序响应时内容互相串。
  bool requestConversationMessages(String conversationId) {
    final cid = conversationId.trim();
    if (cid.isEmpty) return false;

    // 切到「正在查看这个会话」
    _viewingConversationId = cid;

    if (!_client.isConnected) {
      _convMessagesError[cid] = '未连接中继';
      notifyListeners();
      return false;
    }

    // 只清这个会话的缓存与错误，不复用旧数据（避免显示过期内容）
    _convMessagesByConv.remove(cid);
    _convMessagesError.remove(cid);
    _convMessagesLoading.add(cid);
    notifyListeners();

    return _client.send(Envelope(
      type: MsgType.chat,
      from: config.deviceId,
      to: targetDeviceId ?? '*',
      payload: {
        'role': ChatRole.conversationMessagesRequest,
        'text': '',
        'conversationId': cid,
      },
    ));
  }

  /// 详情页退出时调用，避免它退出后还影响别的页面
  void stopViewingConversation(String conversationId) {
    if (_viewingConversationId == conversationId) {
      _viewingConversationId = null;
    }
  }

  /// 删除电脑端某个会话（会话文件一起删除）。
  bool deleteConversationOnDesktop(String conversationId) {
    if (!_client.isConnected) return false;
    lastConversationAction = null;
    notifyListeners();
    return _client.send(Envelope(
      type: MsgType.chat,
      from: config.deviceId,
      to: targetDeviceId ?? '*',
      payload: {
        'role': ChatRole.conversationDelete,
        'text': '',
        'conversationId': conversationId,
      },
    ));
  }

  /// 重命名电脑端某个会话。
  bool renameConversationOnDesktop(String conversationId, String title) {
    if (!_client.isConnected) return false;
    final t = title.trim();
    if (t.isEmpty) return false;
    lastConversationAction = null;
    notifyListeners();
    return _client.send(Envelope(
      type: MsgType.chat,
      from: config.deviceId,
      to: targetDeviceId ?? '*',
      payload: {
        'role': ChatRole.conversationRename,
        'text': '',
        'conversationId': conversationId,
        'title': t,
      },
    ));
  }

  /// 让电脑端「重新回答」某条 assistant 消息（会真的再跑一次 AI）。
  ///
  /// 要求该会话**已经在电脑端打开**（列表里点过「在电脑端打开」），
  /// 否则电脑端没有承载窗口可执行，会回 conversation_not_open。
  bool reaskMessageOnDesktop(String conversationId, String messageId) {
    if (!_client.isConnected) return false;
    if (messageId.isEmpty) return false;
    lastMessageAction = null;
    notifyListeners();
    return _client.send(Envelope(
      type: MsgType.chat,
      from: config.deviceId,
      to: targetDeviceId ?? '*',
      payload: {
        'role': ChatRole.messageAction,
        'text': '',
        'action': 'reask',
        'conversationId': conversationId,
        'messageId': messageId,
      },
    ));
  }

  /// 让电脑端删除会话里的某一条消息。
  ///
  /// 同时把 messageId 发过去 —— 电脑端会**优先用它现查本窗口的下标**，
  /// 因为手机拿到的 index 来自数据库分页读取，和窗口内存里的下标可能不一致。
  /// index 只作为查不到 id 时的回退。
  bool deleteMessageOnDesktop(String conversationId, int index,
      {String messageId = ''}) {
    if (!_client.isConnected) return false;
    if (index < 0 && messageId.isEmpty) return false;
    lastMessageAction = null;
    notifyListeners();
    return _client.send(Envelope(
      type: MsgType.chat,
      from: config.deviceId,
      to: targetDeviceId ?? '*',
      payload: {
        'role': ChatRole.messageAction,
        'text': '',
        'action': 'deleteMessage',
        'conversationId': conversationId,
        'index': index,
        if (messageId.isNotEmpty) 'messageId': messageId,
      },
    ));
  }

  /// 手机上已提交的选择结果：本地消息 id -> 用户选了哪个（给气泡显示"已选择"）。
  final Map<String, String> _submittedChoices = {};

  /// 同样的结果，另按 toolCallId 存一份。
  ///
  /// 为什么需要第二份：`msg.id` 只是**本地**消息 id，电脑端在工具状态更新/
  /// 重新回答时回传的消息可能被换成新的本地 id（见 _onEnvelope 的「情况 A」），
  /// 那时按 id 查就查不到，面板会退回「未选择」——就是「提交完回头看又没选」。
  /// toolCallId 是电脑端那次提问的稳定标识，不会随重建消息而变。
  final Map<String, String> _submittedChoicesByTool = {};

  String? submittedChoiceFor(String messageId) => _submittedChoices[messageId];

  /// 按电脑端 toolCallId 查已提交结果（本地 id 对不上时的兜底）。
  String? submittedChoiceForTool(String toolCallId) =>
      toolCallId.isEmpty ? null : _submittedChoicesByTool[toolCallId];

  static const _submittedChoicesKey = 'submitted_choices_v1';

  /// 把「已提交的选择」也落盘 —— 以前只在内存里，
  /// 重启 App 后所有回答过的选择区都会退回去让用户重选。
  Future<void> _persistSubmittedChoices() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(
        _submittedChoicesKey,
        jsonEncode({
          'byId': _submittedChoices,
          'byTool': _submittedChoicesByTool,
        }),
      );
    } catch (e) {
      debugPrint('[AppState] _persistSubmittedChoices failed: $e');
    }
  }

  Future<void> _loadSubmittedChoices() async {
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString(_submittedChoicesKey);
      if (raw == null || raw.isEmpty) return;
      final j = jsonDecode(raw) as Map<String, dynamic>;
      final byId = (j['byId'] as Map?)?.cast<String, dynamic>() ?? {};
      final byTool = (j['byTool'] as Map?)?.cast<String, dynamic>() ?? {};
      _submittedChoices
        ..clear()
        ..addAll(byId.map((k, v) => MapEntry(k, v.toString())));
      _submittedChoicesByTool
        ..clear()
        ..addAll(byTool.map((k, v) => MapEntry(k, v.toString())));
    } catch (e) {
      debugPrint('[AppState] _loadSubmittedChoices failed: $e');
    }
  }

  /// 在手机上回答电脑端 ask_user_choice 的提问。
  ///
  /// 电脑端窗口里那个工具正 await 等着答案；提交后 AI 会基于选择继续生成，
  /// 新回复会像普通回复一样回传到手机（电脑端已绑回传目标）。
  /// [answer] 的结构见电脑端 buildChoiceResultText：
  /// { responses: [{ questionIndex, type: 'select'|'custom'|'discuss', selected, customText }] }
  ///
  /// [messageId] / [displayText] 用于乐观更新：提交后本地立刻记下"已选择 xxx"，
  /// 气泡里的选项区隐藏，避免重复点选；即使电脑端回执慢也不影响观感。
  bool submitChoiceOnDesktop(
      String conversationId, String toolCallId, Map<String, dynamic> answer,
      {String? messageId, String displayText = ''}) {
    if (!_client.isConnected) return false;
    if (toolCallId.isEmpty) return false;
    lastMessageAction = null;
    if (messageId != null && messageId.isNotEmpty && displayText.isNotEmpty) {
      _submittedChoices[messageId] = displayText;
    }
    // 按 toolCallId 也记一份（稳定标识，本地消息 id 变化后也能对上），
    // 并落盘，避免重启后「已选择」又退回成没选。
    if (displayText.isNotEmpty) {
      _submittedChoicesByTool[toolCallId] = displayText;
    }
    unawaited(_persistSubmittedChoices());
    notifyListeners();
    return _client.send(Envelope(
      type: MsgType.chat,
      from: config.deviceId,
      to: targetDeviceId ?? '*',
      payload: {
        'role': ChatRole.messageAction,
        'text': '',
        'action': 'choiceSubmit',
        'conversationId': conversationId,
        'toolCallId': toolCallId,
        'answer': answer,
      },
    ));
  }

  // ---- 会话压缩（真实功能，不再是摆设）----

  /// 让电脑端**手动压缩一次**当前会话。
  ///
  /// 要求该会话已经在电脑端打开（压缩是窗口内的动作，要重写 chat_show）。
  bool runCompactOnDesktop(String? conversationId) {
    if (!_client.isConnected) return false;
    compactRunning = true;
    lastMessageAction = null;
    notifyListeners();
    return _client.send(Envelope(
      type: MsgType.chat,
      from: config.deviceId,
      to: targetDeviceId ?? '*',
      payload: {
        'role': ChatRole.messageAction,
        'text': '',
        'action': 'runCompact',
        'conversationId': conversationId ?? activeConversationId ?? '',
      },
    ));
  }

  /// 开关「自动压缩」（按模型的配置，写到电脑端）。
  bool setAutoCompact(bool enabled, {String? model}) {
    if (!_client.isConnected) return false;
    lastAutoCompactAction = null;
    notifyListeners();
    return _client.send(Envelope(
      type: MsgType.chat,
      from: config.deviceId,
      to: targetDeviceId ?? '*',
      payload: {
        'role': ChatRole.setAutoCompact,
        'text': '',
        'enabled': enabled,
        if (model != null && model.isNotEmpty) 'model': model,
      },
    ));
  }

  /// 清掉「已排队」提示（用户看到后调）
  void clearBufferNotice() {
    if (bufferNotice == null) return;
    bufferNotice = null;
    notifyListeners();
  }

  /// 清掉上一次任务管理操作的结果提示
  void clearTaskAction() {
    if (lastTaskAction == null) return;
    lastTaskAction = null;
    notifyListeners();
  }

  // ---- 主聊天界面：气泡操作（对应电脑端气泡下方那排按钮）----

  /// 复制不需要电脑端，UI 直接做。

  /// 让电脑端重新回答这一条（气泡上的 ↻）。
  ///
  /// 会记下本地这条消息的 id（reaskingLocalId），让图标转圈直到电脑端回结果；
  /// 同时记下它是「要覆盖的那一条」，新回复回来时替换它而不是追加一条。
  bool reaskChatMessage(ChatMessage m) {
    final meta = m.desktopMeta;
    if (meta == null || !meta.isValid) return false;
    final convId = meta.conversationId.isNotEmpty
        ? meta.conversationId
        : (m.conversationId ?? _activeConversationId ?? '');
    lastMessageAction = null;
    reaskingLocalId = m.id;
    _reaskOverwriteLocalId = m.id;
    notifyListeners();
    final ok = reaskMessageOnDesktop(convId, meta.messageId);
    if (!ok) {
      reaskingLocalId = null;
      _reaskOverwriteLocalId = null;
      notifyListeners();
    }
    return ok;
  }

  /// 让电脑端删掉这一条（气泡上的 🗑）。
  /// 顺带把本地这条从列表里去掉，避免刷新前后不一致。
  bool deleteChatMessage(ChatMessage m) {
    final meta = m.desktopMeta;
    if (meta == null || meta.index < 0) return false;
    final convId = meta.conversationId.isNotEmpty
        ? meta.conversationId
        : (m.conversationId ?? _activeConversationId ?? '');
    // 带上 messageId：电脑端优先按 id 在自己窗口里查下标，避免分页错位删错行
    final ok = deleteMessageOnDesktop(convId, meta.index,
        messageId: meta.messageId);
    if (ok) {
      messages.removeWhere((x) => x.id == m.id);
      _persistHistory();
      notifyListeners();
    }
    return ok;
  }

  /// 点了「重新回答」还没等到结果时，这条消息应该显示转圈图标。
  bool isReasking(String localMessageId) => reaskingLocalId == localMessageId;

  /// 内部：本次重新回答要覆盖掉哪条本地旧回复（收到新回复后替换它）
  String? _reaskOverwriteLocalId;

  // ---- 定时任务管理 ----

  /// 新建任务。名称不能含 \ / : * ? " < > |
  bool createTask(String name) {
    if (!_client.isConnected) return false;
    final n = name.trim();
    if (n.isEmpty || RegExp(r'[\\/:*?"<>|]').hasMatch(n)) return false;
    lastTaskAction = null;
    return _sendTaskManage({'op': 'create', 'name': n});
  }

  /// 删除任务
  bool deleteTask(String taskId) {
    if (!_client.isConnected) return false;
    lastTaskAction = null;
    return _sendTaskManage({'op': 'delete', 'taskId': taskId});
  }

  /// 重命名任务
  bool renameTask(String taskId, String name) {
    if (!_client.isConnected) return false;
    final n = name.trim();
    if (n.isEmpty || RegExp(r'[\\/:*?"<>|]').hasMatch(n)) return false;
    lastTaskAction = null;
    return _sendTaskManage({
      'op': 'update',
      'taskId': taskId,
      'patch': {'name': n},
    });
  }

  /// 改任务的调度配置（触发方式 / 时间等）
  bool updateTaskSchedule(String taskId, Map<String, dynamic> patch) {
    if (!_client.isConnected) return false;
    if (patch.isEmpty) return false;
    lastTaskAction = null;
    return _sendTaskManage({'op': 'update', 'taskId': taskId, 'patch': patch});
  }

  /// 启用 / 停用任务
  bool setTaskEnabled(String taskId, bool enabled) {
    if (!_client.isConnected) return false;
    lastTaskAction = null;
    return _sendTaskManage({
      'op': 'setEnabled',
      'taskId': taskId,
      'enabled': enabled,
    });
  }

  /// 清空任务的历史记录
  bool clearTaskHistory(String taskId) {
    if (!_client.isConnected) return false;
    lastTaskAction = null;
    return _sendTaskManage({'op': 'clearHistory', 'taskId': taskId});
  }

  bool _sendTaskManage(Map<String, dynamic> body) {
    return _client.send(Envelope(
      type: MsgType.chat,
      from: config.deviceId,
      to: targetDeviceId ?? '*',
      payload: {'role': ChatRole.taskManage, 'text': '', ...body},
    ));
  }

  /// 删除会话里的若干条消息。
  bool deleteConversationMessages(String conversationId, List<String> storageIds) {
    if (!_client.isConnected) return false;
    final ids = storageIds.where((e) => e.isNotEmpty).toList();
    if (ids.isEmpty) return false;
    lastConversationAction = null;
    notifyListeners();
    return _client.send(Envelope(
      type: MsgType.chat,
      from: config.deviceId,
      to: targetDeviceId ?? '*',
      payload: {
        'role': ChatRole.conversationMessagesDelete,
        'text': '',
        'conversationId': conversationId,
        'storageIds': ids,
      },
    ));
  }

  static String _conversationOpenReason(String reason) {
    switch (reason) {
      case 'chat_dir_not_configured':
        return '电脑端还没设置「本地会话目录」';
      case 'conversation_not_found':
        return '电脑端找不到这个会话（可能已被删除或移动）';
      case 'open_window_failed':
        return '电脑端打开窗口失败';
      case 'openWindow_unavailable':
        return '电脑端版本过旧，请更新桌面端';
      default:
        return reason.isEmpty ? '未知原因' : reason;
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

  /// 改本机显示名（默认自动取手机型号，用户想改才调）。
  /// 存盘后重连，这样电脑端设备列表里立刻能看到新名字。
  void setDeviceName(String name) {
    final n = name.trim();
    if (n.isEmpty || n == config.deviceName) return;
    config.deviceName = n;
    config.save();
    reconnect();
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
      loadingCapabilities = false;
      try {
        final decoded = jsonDecode(p.text) as Map<String, dynamic>;
        final raw = decoded['__relayCapabilities'] ?? decoded;
        capabilities = Capabilities.fromJson((raw as Map).cast<String, dynamic>());
        // 压缩跑完后电脑端会重新上报，这时候把"压缩中"标记清掉
        compactRunning = false;
        _adoptDesktopPrompt(capabilities);
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

    // 电脑端回传「已有会话」列表
    if (p.role == ChatRole.conversations) {
      try {
        final decoded = jsonDecode(p.text) as Map<String, dynamic>;
        final raw = (decoded['__relayConversations'] as List?) ?? const [];
        conversations = raw
            .map((e) => ConversationOption.fromJson((e as Map).cast<String, dynamic>()))
            .where((c) => c.id.isNotEmpty)
            .toList();
        // 项目名列表（去重，保留电脑端顺序）
        final projs = (decoded['projects'] as List?) ?? const [];
        conversationProjects = projs
            .map((e) => ((e as Map)['name'] ?? '').toString())
            .where((n) => n.isNotEmpty)
            .toList();
        conversationsOk = decoded['ok'] != false;
        final reason = decoded['reason']?.toString() ?? '';
        if (!conversationsOk) {
          conversationsError = reason == 'chat_dir_not_configured'
              ? '电脑端还没设置「本地会话目录」，请到电脑端 设置 → 对话存储 里选一个目录'
              : (reason.isEmpty ? '读取失败' : reason);
        } else {
          conversationsError = null;
        }
        loadingConversations = false;
        notifyListeners();
      } catch (e) {
        debugPrint('[AppState] conversations decode failed: $e');
        loadingConversations = false;
        conversationsError = '解析会话列表失败';
        notifyListeners();
      }
      return;
    }

    // 电脑端主动通知：会话列表发生变化（增/删/改名）→ 重新拉列表
    if (p.role == ChatRole.conversationsChanged) {
      unawaited(requestConversations());
      return;
    }

    // 电脑端主动通知：某个会话的消息被删除 → 刷新那个会话的消息
    if (p.role == ChatRole.messagesChanged) {
      try {
        final decoded = jsonDecode(p.text) as Map<String, dynamic>;
        final r = (decoded['__relayMessagesChanged'] as Map?)
                ?.cast<String, dynamic>() ??
            {};
        final cid = (r['conversationId']?.toString() ?? '').trim();
        if (cid.isNotEmpty) requestConversationMessages(cid);
      } catch (e) {
        debugPrint('[AppState] messages-changed decode failed: $e');
      }
      return;
    }

    // 电脑端回传某个会话的消息内容
    if (p.role == ChatRole.conversationMessages) {
      try {
        final decoded = jsonDecode(p.text) as Map<String, dynamic>;
        final r =
            (decoded['__relayConversationMessages'] as Map?)?.cast<String, dynamic>() ?? {};

        // **关键**：这份数据是哪个会话的？按它自己的 id 存。
        // 以前不看 conversationId，谁后到就覆盖全局列表 ——
        // 于是打开 A 再打开 B，A 的响应晚到就会把 B 的页面刷成 A 的内容。
        final cid = (r['conversationId']?.toString() ?? '').trim();
        if (cid.isEmpty) {
          debugPrint('[AppState] conversation-messages 缺少 conversationId，已忽略');
          return;
        }

        final raw = (r['messages'] as List?) ?? const [];
        _convMessagesByConv[cid] = raw
            .map((e) => ConvMessage.fromJson((e as Map).cast<String, dynamic>()))
            .toList();

        final ok = r['ok'] != false;
        if (ok) {
          _convMessagesError.remove(cid);
        } else {
          _convMessagesError[cid] =
              _conversationOpenReason(r['reason']?.toString() ?? '读取消息失败');
        }
        _convMessagesLoading.remove(cid);
        notifyListeners();
      } catch (e) {
        debugPrint('[AppState] conversation-messages decode failed: $e');
        // 解不出来时至少把「正在查看的那个」的 loading 停掉，
        // 否则详情页会一直转圈
        final cid = _viewingConversationId;
        if (cid != null) {
          _convMessagesLoading.remove(cid);
          _convMessagesError[cid] = '解析会话消息失败';
        }
        notifyListeners();
      }
      return;
    }

    // 电脑端回传会话管理操作（删除 / 重命名 / 删消息）结果
    if (p.role == ChatRole.conversationActionResult) {
      try {
        final decoded = jsonDecode(p.text) as Map<String, dynamic>;
        final r = (decoded['__relayConversationActionResult'] as Map?)
                ?.cast<String, dynamic>() ??
            {};
        final action = r['action']?.toString() ?? '';
        final ok = r['ok'] == true;
        final cid = r['conversationId']?.toString() ?? '';
        lastConversationAction = {
          'action': action,
          'ok': ok,
          'conversationId': cid,
          'removed': r['removed'] == true,
          'deleted': (r['deleted'] as num?)?.toInt() ?? 0,
          'title': r['title']?.toString() ?? '',
          'reason': r['reason']?.toString() ?? '',
        };

        if (ok) {
          switch (action) {
            case 'delete':
              conversations = conversations.where((c) => c.id != cid).toList();
              if (activeConversationId == cid) {
                _setActiveConversation(null, '');
              }
              break;
            case 'rename':
              final t = r['title']?.toString() ?? '';
              conversations = conversations
                  .map((c) => c.id == cid ? c.copyWith(title: t) : c)
                  .toList();
              if (activeConversationId == cid) {
                _activeConversationTitle = t;
                unawaited(_persistActiveConversation());
              }
              break;
            case 'deleteMessages':
              final n = (r['deleted'] as num?)?.toInt() ?? 0;
              // 删完刷新那个会话的消息（只动它自己那份缓存）。
              // 以前这里给 getter 赋值 —— 那是编译不过的，而且逻辑也没意义。
              final cid = (r['conversationId']?.toString() ?? '').trim();
              if (cid.isNotEmpty) {
                // 注意：requestConversationMessages 返回 bool（发送是否成功），
                // 不是 Future，所以不能套 unawaited。
                requestConversationMessages(cid);
              }
              _lastDeletedCount = n;
              break;
          }
          // 会话/消息被改过，顺手重新拉一遍电脑端列表，保证手机端跟电脑端一致
          unawaited(requestConversations());
        }
        notifyListeners();
      } catch (e) {
        debugPrint('[AppState] conversation-action-result decode failed: $e');
      }
      return;
    }

    // 电脑端提示「你的消息已排队」（它正在生成上一轮）
    if (p.role == ChatRole.buffered) {
      try {
        final decoded = jsonDecode(p.text) as Map<String, dynamic>;
        final b = (decoded['__relayBuffered'] as Map?)?.cast<String, dynamic>() ?? {};
        bufferNotice = {
          'text': b['text']?.toString() ?? '',
          'reason': b['reason']?.toString() ?? '',
          'at': DateTime.now().millisecondsSinceEpoch,
        };
        notifyListeners();
      } catch (e) {
        debugPrint('[AppState] buffered decode failed: $e');
      }
      return;
    }

    // 电脑端回传「自动压缩」开关结果
    if (p.role == ChatRole.setAutoCompactResult) {
      try {
        final decoded = jsonDecode(p.text) as Map<String, dynamic>;
        final r = (decoded['__relayAutoCompact'] as Map?)?.cast<String, dynamic>() ?? {};
        lastAutoCompactAction = {
          'ok': r['ok'] == true,
          'enabled': r['enabled'] == true,
          'model': r['model']?.toString() ?? '',
          'reason': r['reason']?.toString() ?? '',
        };
        // 立刻把本地展示同步成新状态，不用等下一次拉能力
        final c = capabilities.compact;
        if (c != null && r['ok'] == true) {
          capabilities = Capabilities(
            models: capabilities.models,
            providers: capabilities.providers,
            mcp: capabilities.mcp,
            skills: capabilities.skills,
            prompts: capabilities.prompts,
            tasks: capabilities.tasks,
            desktopPromptKey: capabilities.desktopPromptKey,
            compact: CompactConfig(
              model: c.model,
              autoCompactEnabled: r['enabled'] == true,
              hideCompactedMessages: c.hideCompactedMessages,
              contextLength: c.contextLength,
              contextLengthSource: c.contextLengthSource,
              compactPrompt: c.compactPrompt,
            ),
            reasoningEffortOptions: capabilities.reasoningEffortOptions,
            current: capabilities.current,
            desktopVersion: capabilities.desktopVersion,
            desktopVersionCode: capabilities.desktopVersionCode,
            upstreamVersion: capabilities.upstreamVersion,
            fetchedAt: capabilities.fetchedAt,
          );
        }
        notifyListeners();
      } catch (e) {
        debugPrint('[AppState] set-auto-compact-result decode failed: $e');
      }
      return;
    }

    // 电脑端回传定时任务管理结果（同时带上最新任务列表）
    if (p.role == ChatRole.taskManageResult) {
      try {
        final decoded = jsonDecode(p.text) as Map<String, dynamic>;
        final r = (decoded['__relayTaskManageResult'] as Map?)?.cast<String, dynamic>() ?? {};
        lastTaskAction = {
          'op': r['op']?.toString() ?? '',
          'ok': r['ok'] == true,
          'taskId': r['taskId']?.toString() ?? '',
          'removed': r['removed'] == true,
          'cleared': (r['cleared'] as num?)?.toInt() ?? 0,
          'reason': r['reason']?.toString() ?? '',
        };
        final raw = (decoded['__relayTasks'] as List?) ?? const [];
        final next = raw
            .map((e) => TaskOption.fromJson((e as Map).cast<String, dynamic>()))
            .where((t) => t.id.isNotEmpty)
            .toList();
        tasks = next;
        capabilities = capabilities.withTasks(next);
        loadingTasks = false;
        notifyListeners();
      } catch (e) {
        debugPrint('[AppState] task-manage-result decode failed: $e');
        loadingTasks = false;
        notifyListeners();
      }
      return;
    }

    // 电脑端回传消息操作（重新回答 / 删除这条）结果
    if (p.role == ChatRole.messageActionResult) {
      try {
        final decoded = jsonDecode(p.text) as Map<String, dynamic>;
        final r = (decoded['__relayMessageAction'] as Map?)?.cast<String, dynamic>() ?? {};
        lastMessageAction = {
          'action': r['action']?.toString() ?? '',
          'ok': r['ok'] == true,
          'reason': r['reason']?.toString() ?? '',
        };
        // 电脑端已回结果 —— 不管成功失败，转圈都要停。
        // 成功的话随后到达的新回复会覆盖旧气泡；
        // 失败的话保持原样，由 HomeShell 弹出原因。
        if (r['action'] == 'reask') {
          reaskingLocalId = null;
          if (r['ok'] != true) _reaskOverwriteLocalId = null;
        }
        notifyListeners();
      } catch (e) {
        debugPrint('[AppState] message-action-result decode failed: $e');
      }
      return;
    }

    // 电脑端回传「打开会话」结果
    if (p.role == ChatRole.conversationOpenResult) {
      try {
        final decoded = jsonDecode(p.text) as Map<String, dynamic>;
        final r = (decoded['__relayConversationOpen'] as Map?)?.cast<String, dynamic>() ?? {};
        final ok = r['ok'] == true;
        if (_detachedConversationIds.contains(r['conversationId']?.toString())) return;
        // 统一走 _setActiveConversation：它会落盘旧会话的记录、
        // 再加载新会话的记录。直接改 _activeConversationId 会让
        // messages 留在上一个会话，造成「多个对话内容重合」。
        final openPromptKey = r['promptKey']?.toString() ?? '';
        if (ok) {
          _leftConversationManually = false;
          _forceNewConversationOnNextMessage = false;
        }
        _setActiveConversation(
          ok ? r['conversationId']?.toString() : null,
          ok ? (r['title']?.toString() ?? '') : '',
        );
        // 会话和助手对应：电脑端会话里的 promptKey 同步成手机当前助手。
        // 这样在手机里继续对话时，用的还是这个会话原来的助手预设。
        if (ok) {
          applyPrompt(openPromptKey.isEmpty ? null : openPromptKey, fromUser: false);
        }
        lastConversationOpen = {
          'ok': ok,
          'conversationId': r['conversationId']?.toString() ?? '',
          'title': r['title']?.toString() ?? '',
          'promptKey': openPromptKey,
          'assistantName': r['assistantName']?.toString() ?? '',
          'reason': r['reason']?.toString() ?? '',
        };
        notifications.show(
          ok ? '已打开电脑端会话' : '打开会话失败',
          ok
              ? ((r['title']?.toString() ?? '').isEmpty
                  ? '电脑端已切换到该会话，可直接对话'
                  : '「${r['title']}」，可直接对话')
              : _conversationOpenReason(r['reason']?.toString() ?? ''),
          id: DateTime.now().millisecondsSinceEpoch.remainder(100000),
        );
        notifyListeners();
      } catch (e) {
        debugPrint('[AppState] conversation-open-result decode failed: $e');
      }
      return;
    }

    // 电脑端回执：能力编辑结果（带最新能力清单）
    if (p.role == ChatRole.capsEditResult) {
      try {
        final decoded = jsonDecode(p.text) as Map<String, dynamic>;
        final r = (decoded['__relayCapsEditResult'] as Map?)?.cast<String, dynamic>() ?? {};
        final ok = r['ok'] == true;
        final capsJson = r['capabilities'];
        if (ok && capsJson is Map) {
          capabilities = Capabilities.fromJson(capsJson.cast<String, dynamic>());
          loadingCapabilities = false;
          _adoptDesktopPrompt(capabilities);
        }
        lastCapsEdit = {
          'op': r['op']?.toString() ?? '',
          'ok': ok,
          'reason': r['reason']?.toString() ?? '',
        };
        editingCapsOp = null;
        notifyListeners();
      } catch (e) {
        debugPrint('[AppState] caps-edit-result decode failed: $e');
        editingCapsOp = null;
        notifyListeners();
      }
      return;
    }

    // 电脑端回传「你刚发的那条消息在电脑端的位置」
    // —— 补上之后，自己发的消息也能显示「删除这条」（以前只有 AI 回复才有）
    if (p.role == ChatRole.userMessageMeta) {
      await () async {
      try {
        final decoded = jsonDecode(p.text) as Map<String, dynamic>;
        final m = (decoded['__relayUserMessageMeta'] as Map?)?.cast<String, dynamic>() ?? {};
        final clientId = m['clientMsgId']?.toString() ?? '';
        final desktopId = m['messageId']?.toString() ?? '';
        final index = (m['index'] as num?)?.toInt() ?? -1;
        final convId = m['conversationId']?.toString() ?? '';
        if (_detachedConversationIds.contains(convId)) return;
        if (desktopId.isEmpty || index < 0) return;
        final targetId = convId.isEmpty ? _activeConversationId : convId;
        if (_activeConversationId == null && convId.isNotEmpty) {
          _bindActiveConversationSilently(convId);
        }
        if (targetId == null || targetId != _activeConversationId) {
          await _updateStoredMessage(targetId, clientId, (old) => ChatMessage(
            id: old.id,
            role: old.role,
            text: old.text,
            time: old.time,
            outgoing: old.outgoing,
            conversationId: convId.isNotEmpty ? convId : old.conversationId,
            attachments: old.attachments,
            pending: old.pending,
            modelTag: old.modelTag,
            desktopMeta: AssistantMeta(
              messageId: desktopId,
              index: index,
              conversationId: convId,
            ),
          ));
          return;
        }
        // 优先按手机本地消息 id 精确匹配；拿不到就退回「最后一条自己发的」
        var at = -1;
        if (clientId.isNotEmpty) {
          at = messages.indexWhere((x) => x.id == clientId);
        }
        if (at < 0 && clientId.isEmpty) {
          at = messages.lastIndexWhere((x) => x.outgoing);
        }
        // 先确认回执对应当前列表里的消息，再允许自动绑定。
        if (at < 0) return;
        if (convId.isNotEmpty) {
          _bindActiveConversationSilently(convId);
        }
        if (desktopId.isNotEmpty && index >= 0) {
          final old = messages[at];
          messages[at] = ChatMessage(
            id: old.id,
            role: old.role,
            text: old.text,
            time: old.time,
            outgoing: old.outgoing,
            conversationId: convId.isNotEmpty ? convId : old.conversationId,
            attachments: old.attachments,
            pending: old.pending,
            modelTag: old.modelTag,
            desktopMeta: AssistantMeta(
              messageId: desktopId,
              index: index,
              conversationId: convId,
            ),
          );
          _persistHistory();
          notifyListeners();
        }
      } catch (e) {
        debugPrint('[AppState] user-message-meta decode failed: $e');
      }
      }();
      return;
    }

    final isAssistant = p.role == ChatRole.assistant;

    // 会话归属校验：电脑端回的是**哪个**会话的消息？
    //
    // 只在手机已绑定电脑端会话时校验（p.conversationId 有值）。
    // 否则会出现：从 A 切到 B 之后，A 迟到的回复被追加进 B 的聊天列表，
    // 两个会话的内容又混在一起。
    if (isAssistant && p.conversationId != null && p.conversationId!.isNotEmpty) {
      if (_detachedConversationIds.contains(p.conversationId)) return;
      final mine = _activeConversationId;
      if (mine != null && mine.isNotEmpty && p.conversationId != mine) {
        debugPrint('[AppState] 丢弃不属于当前会话的回复: '
            'got=${p.conversationId} current=$mine');
        return;
      }
    }

    // 情况 A：这条是「重新回答」的产物
    //   电脑端那边是「删掉旧的 assistant 气泡 → 重新生成」，
    //   所以手机这边也必须**覆盖**原来那条，不能再追加一条（否则会出现两条回复）。
    final overwriteId = _reaskOverwriteLocalId;
    if (isAssistant && overwriteId != null) {
      final idx = messages.indexWhere((m) => m.id == overwriteId);
      final fresh = ChatMessage(
        id: env.id,
        role: p.role,
        text: p.text,
        time: DateTime.fromMillisecondsSinceEpoch(env.ts),
        outgoing: false,
        conversationId: p.conversationId,
        attachments: (p.attachments ?? []).map((e) => FileMeta.fromJson(e)).toList(),
        desktopMeta: p.assistantMeta,
        modelTag: p.assistantMeta?.modelTag ?? '',
        choice: p.choice ?? p.assistantMeta?.choice,
      );
      if (idx >= 0) {
        messages[idx] = fresh;
      } else {
        messages.add(fresh);
      }
      _reaskOverwriteLocalId = null;
      reaskingLocalId = null;
      _persistHistory();
      notifyListeners();
      notifications.show('Anywhere', p.text, id: env.ts.remainder(100000));
      return;
    }

    // 情况 A2：这条消息之前已经到过（电脑端工具状态/内容实时更新）→ 就地更新，
    // 不新增气泡（否则同一条回复会出现两个气泡）。
    if (isAssistant && (p.assistantMeta?.messageId.isNotEmpty ?? false)) {
      final mid = p.assistantMeta!.messageId;
      final idx = messages.indexWhere((m) => m.desktopMeta?.messageId == mid);
      if (idx >= 0) {
        final prev = messages[idx];
        messages[idx] = ChatMessage(
          id: prev.id,
          role: p.role,
          text: p.text,
          time: prev.time,
          outgoing: false,
          conversationId: p.conversationId,
          attachments:
              (p.attachments ?? []).map((e) => FileMeta.fromJson(e)).toList(),
          desktopMeta: p.assistantMeta,
          modelTag: p.assistantMeta?.modelTag ?? prev.modelTag,
          choice: p.choice ?? p.assistantMeta?.choice ?? prev.choice,
        );
        _persistHistory();
        notifyListeners();
        return;
      }
    }

    // 情况 B：正常回复 —— 合并进**最早**那个 pending 气泡
    // （电脑端按顺序回复，所以每个回复认领最早的一条；
    //   以前只认最后一条，连续发消息时会留下永远转圈的 pending）
    final pendingIdx = isAssistant ? _firstPendingIndex() : -1;
    if (isAssistant && pendingIdx >= 0) {
      messages[pendingIdx] = ChatMessage(
        id: env.id,
        role: p.role,
        text: p.text,
        time: DateTime.fromMillisecondsSinceEpoch(env.ts),
        outgoing: false,
        conversationId: p.conversationId,
        attachments: (p.attachments ?? []).map((e) => FileMeta.fromJson(e)).toList(),
        desktopMeta: p.assistantMeta,
        modelTag: p.assistantMeta?.modelTag ?? '',
        choice: p.choice ?? p.assistantMeta?.choice,
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
        desktopMeta: p.assistantMeta,
        modelTag: p.assistantMeta?.modelTag ?? '',
        choice: p.choice ?? p.assistantMeta?.choice,
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
    if (st != 'undelivered') return;

    // 中继可能把"哪条没送到"放在不同字段里，逐个试；
    // 都没有就退回用 envelope 自己的 id。
    final pl = env.payload ?? const {};
    final candidates = <String>[
      for (final k in ['messageId', 'id', 'originalId', 'clientMsgId', '__relayClientMsgId'])
        if (pl[k] != null) pl[k].toString(),
      env.id,
    ].where((x) => x.isNotEmpty).toList();

    // 1) 先按 id 精确找到对应的 pending 气泡
    var pi = -1;
    for (final cid in candidates) {
      final idx = messages.indexWhere((m) => m.id == 'pending-$cid');
      if (idx >= 0) {
        pi = idx;
        break;
      }
    }
    // 2) 找不到就退回「最早那个 pending」——总比一直转圈好
    if (pi < 0) pi = _firstPendingIndex();

    debugPrint('[AppState] undelivered; candidates=$candidates hit=$pi');
    if (pi >= 0) {
      messages[pi] = messages[pi]
          .copyWith(text: '⚠️ 电脑端未收到（可能未启动或未连接）', pending: false);
      _persistHistory();
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

    // 换助手后的第一条消息不携带旧会话 id，并要求 relay 强制新建会话。
    if (_forceNewConversationOnNextMessage) {
      env.payload['__relayNewConversation'] = true;
    }

    // 把本条消息在手机本地的 id 也带上（放在 __relayClientMsgId）。
    // 电脑端 append 后会回传「这条在电脑端的位置」，手机靠这个 id
    // 就能精确给对应气泡挂上「删除这条」。
    env.payload['__relayClientMsgId'] = env.id;

    messages.add(ChatMessage(
      id: env.id,
      role: ChatRole.user,
      text: text2,
      time: DateTime.now(),
      outgoing: true,
      conversationId: _activeConversationId,
    ));

    // Optimistic "thinking" bubble — replaced when the desktop answers.
    //
    // id 用 'pending-<envelope id>' 而不是随机 uuid：这样中继回
    // delivery_status(undelivered) 时，能**精确**找到是哪一个气泡失败，
    // 而不是随便挑一个（连发多条时会认错）。
    messages.add(ChatMessage(
      id: 'pending-${env.id}',
      role: ChatRole.assistant,
      text: '',
      time: DateTime.now(),
      outgoing: false,
      pending: true,
    ));

    _persistHistory();
    notifyListeners();

    final ok = _client.send(env);
    if (ok && _forceNewConversationOnNextMessage) {
      _forceNewConversationOnNextMessage = false;
      _leftConversationManually = false;
    }
    if (!ok) {
      // 没发出去：把刚加的 pending 和**用户气泡**一起撤掉。
      // 以前只摘 pending，用户气泡留在列表里看起来像"已发送"，
      // 但其实根本没出去（输入框文字仍在，用户可以直接重发）。
      messages.removeWhere((m) => m.id == 'pending-${env.id}' || m.id == env.id);
      _persistHistory();
      notifyListeners();
    }
    return ok;
  }

  /// Upload a local file and share it with the desktop (or all devices).
  Future<void> shareFile(File file, {String? toDeviceId}) async {
    if (!_client.isConnected) throw StateError('未连接到中继服务器，文件未发送');
    final recipient = toDeviceId ?? targetDeviceId ?? '*';
    final conversationId = _activeConversationId;
    final meta = await _client.uploadFile(file);
    final env = Envelope(
      type: MsgType.fileShare,
      from: config.deviceId,
      to: recipient,
      payload: {'file': meta.toJson()},
    );
    if (!_client.send(env)) throw StateError('连接已断开，文件未发送');
    receivedFiles.insert(0, meta);
    final message = ChatMessage(
      id: env.id,
      role: ChatRole.user,
      text: '',
      time: DateTime.now(),
      outgoing: true,
      conversationId: conversationId,
      attachments: [meta],
    );
    if (_activeConversationId == conversationId) {
      messages.add(message);
      await _persistHistory();
    } else {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString(_historyKey(conversationId));
      var history = <ChatMessage>[];
      if (raw != null) {
        try {
          history = (jsonDecode(raw) as List)
              .map((e) => ChatMessage.fromJson((e as Map).cast<String, dynamic>()))
              .toList();
        } catch (e) {
          debugPrint('[AppState] shareFile history decode failed: $e');
        }
      }
      await _persistMessagesTo(conversationId, [...history, message]);
    }
    notifyListeners();
  }

  Future<File> downloadToDevice(FileMeta meta) async {
    final dir = await getApplicationDocumentsDirectory();
    final saveDir = Directory('${dir.path}/AnywhereDownloads');
    if (!await saveDir.exists()) await saveDir.create(recursive: true);
    // ⚠️ 文件名来自电脑端，绝不能直接拼进路径：
    //   · `../..` 之类可以写到 AnywhereDownloads 之外（路径穿越）；
    //   · 含 `/` `\` `:` 等字符在 Windows 上会直接抛异常；
    //   · 同名文件直接覆盖会悄悄丢掉上一次下载的内容。
    final safeName = _sanitizeFileName(meta.name);
    final path = _uniqueFilePath(saveDir.path, safeName);
    final f = await _client.downloadFile(meta.id, path);
    notifyListeners();
    return f;
  }

  /// 把来自外部的文件名收敛成一个安全的单层文件名。
  static String _sanitizeFileName(String? raw) {
    var name = (raw ?? '').trim();
    // 只取最后一段，砍掉任何目录部分
    name = name.split(RegExp(r'[\\/]+')).last;
    // 去掉 Windows 非法字符与控制字符
    name = name.replaceAll(RegExp(r'[<>:"|?*\x00-\x1f]'), '_');
    // '.' / '..' 之类无意义名字兜底
    if (name.isEmpty || name == '.' || name == '..') name = 'download';
    // 过长的文件名（含扩展名）做截断，避免超出文件系统上限
    if (name.length > 120) {
      final dot = name.lastIndexOf('.');
      final ext = (dot > 0 && name.length - dot <= 10) ? name.substring(dot) : '';
      name = '${name.substring(0, 120 - ext.length)}$ext';
    }
    return name;
  }

  /// 在 [dirPath] 下找一个不冲突的路径：同名时追加 ` (1)`、` (2)`…
  static String _uniqueFilePath(String dirPath, String fileName) {
    var candidate = '$dirPath${Platform.pathSeparator}$fileName';
    if (!File(candidate).existsSync()) return candidate;
    final dot = fileName.lastIndexOf('.');
    final stem = dot > 0 ? fileName.substring(0, dot) : fileName;
    final ext = dot > 0 ? fileName.substring(dot) : '';
    for (var i = 1; i < 1000; i++) {
      candidate = '$dirPath${Platform.pathSeparator}$stem ($i)$ext';
      if (!File(candidate).existsSync()) return candidate;
    }
    return '$dirPath${Platform.pathSeparator}${DateTime.now().millisecondsSinceEpoch}_$fileName';
  }

  // ---- persistence ----
  /// 聊天记录的存储 key —— **按会话分开**。
  ///
  /// 以前所有会话共用一个 'chat_history'：切到别的电脑端会话时，messages
  /// 不清空、新消息也写回同一个 key，于是几个会话的内容永远混在一起，
  /// 看起来就是「多个对话互相重合」。现在每个会话各有各的 key。
  String _historyKey(String? conversationId) {
    final id = (conversationId ?? '').trim();
    // 没绑定任何电脑端会话时（本机随便聊）用一个固定 key
    return id.isEmpty ? 'chat_history' : 'chat_history:$id';
  }

  /// 把当前 messages 写回**当前会话自己**的 key
  Future<void> _persistHistory() async {
    final id = _activeConversationId;
    final snapshot = messages.toList();
    await _persistMessagesTo(id, snapshot);
  }

  /// 切换到某个会话时，把 messages 换成**那个会话自己**的记录
  Future<void> _switchHistoryTo(String? conversationId, [int? expectedGeneration]) async {
    // 加载代次失效时不再写界面；保留切换后已经收到的所有消息。
    final generation = expectedGeneration ?? _conversationSwitchGeneration;
    final p = await SharedPreferences.getInstance();
    if (generation != _conversationSwitchGeneration ||
        _activeConversationId != conversationId) {
      return;
    }
    await (_historyWrites[_historyKey(conversationId)] ?? Future<void>.value());
    if (generation != _conversationSwitchGeneration ||
        _activeConversationId != conversationId) {
      return;
    }
    final raw = p.getString(_historyKey(conversationId));

    // await 期间新到的消息，稍后补回去（按 id 去重，避免和磁盘里的重复）
    final arrived = messages.toList();

    messages.clear();
    messages.addAll(_decodeHistory(raw));
    if (arrived.isNotEmpty) {
      final have = messages.map((m) => m.id).toSet();
      messages.addAll(arrived.where((m) => !have.contains(m.id)));
    }
  }

  Future<void> _loadHistory() async {
    final p = await SharedPreferences.getInstance();

    // 先恢复「上次接的是哪个电脑端会话」，再按它的 key 加载记录
    final convId = p.getString('active_conversation_id');
    if (convId != null && convId.isNotEmpty) {
      _activeConversationId = convId;
      _activeConversationTitle = p.getString('active_conversation_title') ?? '';
      // ⚠️ 助手跟着会话一起恢复：会话的助手是这个会话自己的属性，
      // 不恢复的话重启后手机显示的助手会空掉或被电脑端默认助手顶掉 ——
      // 用户看到的就是「会话和助手对不上」。
      final pk = p.getString('active_conversation_prompt');
      if (pk != null && pk.isNotEmpty) {
        options = options.copyWith(promptKey: pk);
        // 视为「用户已选定」，避免 _adoptDesktopPrompt 用电脑端默认助手覆盖它
        _promptTouchedByUser = true;
      }
    }

    await _switchHistoryTo(_activeConversationId);

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

  Future<void> _persistActiveConversation() async {
    final id = _activeConversationId;
    final title = _activeConversationTitle;
    final pk = options.promptKey;
    final p = await SharedPreferences.getInstance();
    if (id == null || id.isEmpty) {
      await p.remove('active_conversation_id');
      await p.remove('active_conversation_title');
      await p.remove('active_conversation_prompt');
    } else {
      await p.setString('active_conversation_id', id);
      await p.setString('active_conversation_title', title);
      // ⚠️ 助手必须跟着会话一起存：以前只存 id/title，重启后手机不知道
      // 当前会话用的是哪个助手 —— 要么显示空助手、要么被电脑端默认助手
      // 顶掉，看起来就是「会话和助手对不上」。
      if (pk == null || pk.isEmpty) {
        await p.remove('active_conversation_prompt');
      } else {
        await p.setString('active_conversation_prompt', pk);
      }
    }
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
