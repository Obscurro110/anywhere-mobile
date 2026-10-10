import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../services/app_state.dart';
import '../widgets/connection_badge.dart';
import 'chat_screen.dart';
import 'conversations_screen.dart';
import 'notifications_screen.dart';
import 'settings_screen.dart';
import 'tasks_screen.dart';

/// App 外壳：只有「对话」一个主界面。
///
/// 设置、通知、定时任务都是**二级页面**（右侧图标/菜单进入），
/// 不再用底部 Tab 把「对话」和「设置」并列 —— 那会让配置页显得和主功能同等地位。
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  AppState? _state;
  Map<String, dynamic>? _seenMessageAction;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final s = context.read<AppState>();
    if (s != _state) {
      _state?.removeListener(_onStateChanged);
      _state = s;
      s.addListener(_onStateChanged);
    }
  }

  @override
  void dispose() {
    _state?.removeListener(_onStateChanged);
    super.dispose();
  }

  /// 手机对某条消息的操作（重新回答 / 删除）如果失败，
  /// 以前只是存进 AppState 没人显示 —— 表现就是「点了没反应」。
  /// 这里统一弹出来，让失败原因可见。
  void _onStateChanged() {
    final s = _state;
    if (s == null || !mounted) return;
    final r = s.lastMessageAction;
    if (r == null || identical(r, _seenMessageAction)) return;
    _seenMessageAction = r;
    if (r['ok'] == true) return;

    final reason = r['reason']?.toString() ?? '';
    const map = {
      'conversation_not_open': '电脑端还没打开这个会话，请先在列表里点「在电脑端打开」',
      'not_last_message': '只能重新回答最后一条消息',
      'nothing_to_reask': '没有可以重新回答的消息',
      'message_not_found': '电脑端找不到这条消息（可能已变动）',
      'messageId_required': '缺少消息标识',
      'index_required': '缺少消息位置',
      'busy': '电脑端正忙，请稍后再试',
      'target_not_found': '电脑端窗口已关闭',
      'unknown_action': '电脑端不认识这个操作（可能版本较旧）',
    };
    final msg = map[reason] ?? (reason.isEmpty ? '操作失败' : '操作失败：$reason');
    // notifyListeners 可能在 build/布局过程中被调用，
    // 直接 showSnackBar 会报 "setState during build"，所以挪到下一帧。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(msg),
        duration: const Duration(seconds: 4),
      ));
    });
  }

  void _push(BuildContext context, Widget page) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));
  }

  @override
  Widget build(BuildContext context) {
    final unread = context.select<AppState, int>(
      (s) => s.inbox.where((n) => n['read'] != true).length,
    );
    final state = context.watch<AppState>();

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 12,
        title: Row(
          children: [
            // 与电脑端对话
            const Text('对话', style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(width: 8),
            // 顶部胶囊：直接选电脑上的会话。已进入会话时显示会话名。
            _SessionPill(
              conversationTitle: state.activeConversationTitle,
              inConversation: state.activeConversationId != null,
              onTap: () => _pickSession(context, state),
            ),
          ],
        ),
        actions: [
          const ConnectionBadge(),
          IconButton(
            tooltip: '通知',
            onPressed: () => _push(context, const NotificationsPage()),
            icon: Badge(
              isLabelVisible: unread > 0,
              label: Text('$unread'),
              child: const Icon(Icons.notifications_outlined),
            ),
          ),
          PopupMenuButton<String>(
            tooltip: '更多',
            icon: const Icon(Icons.more_vert),
            color: const Color(0xFF1F2330),
            onSelected: (v) {
              switch (v) {
                case 'conv':
                  _push(context, const ConversationsPage());
                case 'tasks':
                  _push(context, const TasksPage());
                case 'settings':
                  _push(context, const SettingsPage());
              }
            },
            // 右上角菜单：带汉字 + 图标（设置/定时任务这类层级菜单，
            // 还是汉字更清楚）。「对话中/任务数」用圆点/角标补充。
            itemBuilder: (ctx) => [
              PopupMenuItem(
                value: 'conv',
                height: 48,
                child: ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      const Icon(Icons.forum_outlined, size: 22),
                      if (state.activeConversationId != null)
                        const Positioned(
                          right: -2,
                          top: -2,
                          child: CircleAvatar(
                            radius: 3.5,
                            backgroundColor: Colors.greenAccent,
                          ),
                        ),
                    ],
                  ),
                  title: const Text('电脑端对话'),
                ),
              ),
              PopupMenuItem(
                value: 'tasks',
                height: 48,
                child: ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Badge(
                    isLabelVisible: state.tasks.isNotEmpty,
                    label: Text('${state.tasks.length}'),
                    child: const Icon(Icons.schedule, size: 22),
                  ),
                  title: const Text('定时任务'),
                ),
              ),
              PopupMenuItem(
                value: 'settings',
                height: 48,
                child: const ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.settings_outlined, size: 22),
                  title: Text('设置'),
                ),
              ),
            ],
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: const Column(
        children: [
          // 电脑端正在生成时发的消息会进「缓冲区」，这里明确告诉用户没丢
          _BufferBanner(),
          // 「当前会话 + 助手」绑定条：让「我在哪个会话、用的哪个助手」一眼可见
          _ConversationBindingBar(),
          Expanded(child: ChatScreen()),
        ],
      ),
    );
  }

  /// 点标题栏胶囊：直接列出电脑上的会话，选中即切换。
  ///
  /// 只有一台电脑在线、又还没指定目标时，自动对上它，
  /// 免得会话列表和后面的消息广播到所有设备。
  void _pickSession(BuildContext context, AppState state) {
    if (state.targetDeviceId == null) {
      final others =
          state.peers.where((d) => d.deviceId != state.config.deviceId).toList();
      if (others.length == 1) state.setTargetDevice(others.first.deviceId);
    }
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF1B1F2B),
      isScrollControlled: true,
      builder: (ctx) => const _SessionSheet(),
    );
  }
}

/// 标题栏入口胶囊：未进会话时显示「选择会话」，进入后显示会话名。
class _SessionPill extends StatelessWidget {
  final String conversationTitle;
  final bool inConversation;
  final VoidCallback onTap;

  const _SessionPill({
    required this.conversationTitle,
    required this.inConversation,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final label = (inConversation && conversationTitle.isNotEmpty)
        ? conversationTitle
        : '选择会话';
    return Material(
      color: inConversation ? const Color(0xFF1D2A3A) : const Color(0xFF232838),
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                inConversation ? Icons.link : Icons.north_east,
                size: 12,
                color: inConversation ? Colors.lightBlueAccent : Colors.white54,
              ),
              const SizedBox(width: 4),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 120),
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12, color: Colors.white70),
                ),
              ),
              const Icon(Icons.expand_more, size: 14, color: Colors.white38),
            ],
          ),
        ),
      ),
    );
  }
}

/// 会话面板：列出电脑端会话，点一条即切到该会话。
///
/// 切换成功后底部「助手/模型/思考」会跟随该会话的助手
/// （由 AppState 处理 conversationOpenResult 时 applyPrompt 完成）。
class _SessionSheet extends StatefulWidget {
  const _SessionSheet();

  @override
  State<_SessionSheet> createState() => _SessionSheetState();
}

class _SessionSheetState extends State<_SessionSheet> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<AppState>().requestConversations();
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.6,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 14, 6, 6),
              child: Row(
                children: [
                  const Text('选择会话',
                      style: TextStyle(fontWeight: FontWeight.bold)),
                  const Spacer(),
                  IconButton(
                    tooltip: '刷新',
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.refresh, size: 18),
                    onPressed: state.requestConversations,
                  ),
                ],
              ),
            ),
            if (state.activeConversationId != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                child: Row(
                  children: [
                    const Icon(Icons.link,
                        size: 14, color: Colors.lightBlueAccent),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        state.activeConversationTitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 12, color: Colors.white70),
                      ),
                    ),
                    TextButton(
                      onPressed: () {
                        state.leaveDesktopConversation();
                        Navigator.of(context).pop();
                      },
                      child: const Text('退出'),
                    ),
                  ],
                ),
              ),
            Flexible(
              child: (state.loadingConversations && state.conversations.isEmpty)
                  ? const Padding(
                      padding: EdgeInsets.all(24),
                      child: Center(child: CircularProgressIndicator()),
                    )
                  : state.conversations.isEmpty
                      ? const Padding(
                          padding: EdgeInsets.all(24),
                          child: Text('该电脑暂无会话',
                              style: TextStyle(
                                  fontSize: 12, color: Colors.white38)),
                        )
                      : _buildGroupedList(context, state),
            ),
          ],
        ),
      ),
    );
  }

  /// 会话列表按「项目」分组（复用电脑端 projects 顺序，其余归「未归类」），
  /// 与「电脑端对话」列表页一致。
  Widget _buildGroupedList(BuildContext context, AppState state) {
    final grouped = <String, List<ConversationOption>>{};
    for (final p in state.conversationProjects) {
      grouped[p] = [];
    }
    final ungrouped = <ConversationOption>[];
    for (final c in state.conversations) {
      if (c.projectName.isNotEmpty && grouped.containsKey(c.projectName)) {
        grouped[c.projectName]!.add(c);
      } else if (c.projectName.isNotEmpty) {
        grouped.putIfAbsent(c.projectName, () => []).add(c);
      } else {
        ungrouped.add(c);
      }
    }
    grouped.removeWhere((_, v) => v.isEmpty);

    final rows = <Widget>[];
    for (final entry in grouped.entries) {
      rows.add(_projectHeader(entry.key, entry.value.length));
      for (final c in entry.value) {
        rows.add(_tile(context, state, c));
      }
    }
    if (ungrouped.isNotEmpty) {
      rows.add(_projectHeader('未归类', ungrouped.length, muted: true));
      for (final c in ungrouped) {
        rows.add(_tile(context, state, c));
      }
    }
    rows.add(const SizedBox(height: 8));

    return ListView(
      shrinkWrap: true,
      // 会话现在是卡片，左右要留白，否则卡片会贴边显得像一条条色块
      padding: const EdgeInsets.symmetric(horizontal: 10),
      children: rows,
    );
  }

  Widget _projectHeader(String name, int count, {bool muted = false}) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 14, 6, 6),
      child: Row(
        children: [
          Icon(Icons.folder_outlined,
              size: 14, color: muted ? Colors.white24 : Colors.amberAccent),
          const SizedBox(width: 6),
          Text(
            name,
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              color: muted ? Colors.white38 : Colors.white70,
            ),
          ),
          const SizedBox(width: 6),
          Text('$count',
              style: const TextStyle(fontSize: 11, color: Colors.white24)),
        ],
      ),
    );
  }

  Widget _tile(BuildContext context, AppState state, ConversationOption c) {
    final isActive = c.id == state.activeConversationId;
    // ⚠️ 以前是 dense ListTile 直接摞在一起，没有外边距也没有分隔线：
    // 相邻会话挨得太近，看起来像一坨，分不清「哪一行属于哪个会话」，
    // 助手/时间这些小字又挤在一起。现在每个会话一张卡片 + 明确间隔。
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: isActive ? const Color(0xFF1D2A3A) : const Color(0xFF1B1F2B),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: isActive ? Colors.lightBlueAccent.withAlpha(140) : const Color(0xFF2A3040),
        ),
      ),
      child: ListTile(
        dense: true,
        contentPadding: const EdgeInsets.fromLTRB(12, 2, 8, 2),
        leading: Icon(
          isActive ? Icons.chat_bubble : Icons.chat_bubble_outline,
          size: 20,
          color: isActive ? Colors.lightBlueAccent : Colors.white38,
        ),
        title: Text(
          c.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 3),
          child: Wrap(
            spacing: 8,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (c.updatedLabel.isNotEmpty)
                Text(c.updatedLabel,
                    style: const TextStyle(fontSize: 10.5, color: Colors.white38)),
              // 助手：会话的核心属性，用醒目的标签单独标出来
              if (c.assistantName.isNotEmpty)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: const Color(0xFF262C3D),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    '助手 · ${c.assistantName}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 10.5, color: Colors.amberAccent),
                  ),
                )
              else if (c.promptKey.isNotEmpty)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: const Color(0xFF262C3D),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    '助手 · ${c.promptKey}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 10.5, color: Colors.white54),
                  ),
                ),
              if (isActive)
                const Text('对话中',
                    style: TextStyle(fontSize: 10.5, color: Colors.lightBlueAccent)),
            ],
          ),
        ),
        trailing: isActive
            ? const Icon(Icons.check_circle, size: 18, color: Colors.lightBlueAccent)
            : null,
        onTap: () => _open(context, state, c),
      ),
    );
  }

  Future<void> _open(
      BuildContext context, AppState state, ConversationOption c) async {
    // 先抓 messenger：pop 之后本 sheet 的 context 会失效，再 `of(context)` 会崩。
    final messenger = ScaffoldMessenger.of(context);
    final nav = Navigator.of(context);
    if (!state.client.isConnected) {
      messenger.showSnackBar(
        const SnackBar(content: Text('未连接到中继服务器')),
      );
      return;
    }
    final sent = state.openConversationOnDesktop(c.id);
    if (!sent) {
      messenger.showSnackBar(
        const SnackBar(content: Text('发送失败')),
      );
      return;
    }
    nav.pop();
    // 等电脑端确认切到该会话；助手会随 conversationOpenResult 自动跟随。
    for (var i = 0; i < 12; i++) {
      await Future.delayed(const Duration(milliseconds: 500));
      if (!mounted) return;
      if (state.activeConversationId == c.id) return;
      final res = state.lastConversationOpen;
      if (res != null && res['ok'] != true) {
        messenger.showSnackBar(
          SnackBar(content: Text('打开失败：${res['reason']}')),
        );
        return;
      }
    }
  }
}

/// 顶部横幅：电脑端正在生成时，你发的消息会进它的「缓冲区」排队。
/// 以前手机端完全不知道这件事，气泡一直转圈，用户以为卡死了。
class _BufferBanner extends StatelessWidget {
  const _BufferBanner();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final notice = state.bufferNotice;
    if (notice == null) return const SizedBox.shrink();

    final text = (notice['text'] as String?) ?? '';
    return Material(
      color: const Color(0xFF2A2418),
      child: InkWell(
        onTap: () => state.clearBufferNotice(),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              const Icon(Icons.hourglass_bottom,
                  size: 16, color: Colors.orangeAccent),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '已排队：电脑端正在生成，本轮结束后会自动发送',
                      style: TextStyle(fontSize: 12, color: Colors.orangeAccent),
                    ),
                    if (text.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          text,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 11, color: Colors.white54),
                        ),
                      ),
                  ],
                ),
              ),
              const Icon(Icons.close, size: 16, color: Colors.white38),
            ],
          ),
        ),
      ),
    );
  }
}

/// 「当前会话 ↔ 助手」绑定条。
///
/// 用户反馈「会话和助手绑定不严格」—— 根子之一是**看不出来**：
/// 聊天页只有消息列表，没有地方告诉你「现在挂在哪个会话上、
/// 这个会话用的是哪个助手」。这里把绑定关系显式画出来；
/// 没绑定时明确写「下一条消息会创建新会话」。
class _ConversationBindingBar extends StatelessWidget {
  const _ConversationBindingBar();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final convId = state.activeConversationId;
    final inConv = convId != null && convId.isNotEmpty;
    final title = state.activeConversationTitle;
    final prompt = state.activePrompt;
    final key = state.options.promptKey ?? '';
    final promptLabel = prompt != null
        ? prompt.label
        : (key.isEmpty ? '默认（跟随电脑端）' : key);

    // 没进会话时这行只写「新会话」。换助手本身就会开新会话，这行没有信息量。
    if (!inConv) return const SizedBox.shrink();

    return Material(
      color: const Color(0xFF141821),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
        child: Row(
          children: [
            Icon(inConv ? Icons.link : Icons.add_circle_outline,
                size: 15,
                color: inConv ? Colors.lightBlueAccent : Colors.white38),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                inConv ? '会话：${title.isEmpty ? convId : title}' : '新会话（下一条消息创建）',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 11.5,
                    color: inConv ? Colors.lightBlueAccent : Colors.white54),
              ),
            ),
            // 助手标签：当前生效的助手
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: const Color(0xFF262C3D),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.auto_awesome,
                      size: 11, color: Colors.amberAccent),
                  const SizedBox(width: 4),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 110),
                    child: Text(promptLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 10.5, color: Colors.amberAccent)),
                  ),
                ],
              ),
            ),
            if (inConv)
              IconButton(
                tooltip: '退出会话（回到新会话）',
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
                icon: const Icon(Icons.link_off, size: 15, color: Colors.white38),
                onPressed: () =>
                    context.read<AppState>().leaveDesktopConversation(),
              ),
          ],
        ),
      ),
    );
  }
}
