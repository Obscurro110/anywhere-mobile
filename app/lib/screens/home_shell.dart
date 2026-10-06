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
            // 顶部胶囊：两级入口 —— 先选电脑设备，再选该设备上的会话；
            // 已进入会话时显示会话名，点它仍可换设备 / 换会话 / 退出。
            _SessionPill(
              deviceLabel: state.targetLabel,
              conversationTitle: state.activeConversationTitle,
              inConversation: state.activeConversationId != null,
              onTap: () => _pickDeviceThenSession(context, state),
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
          Expanded(child: ChatScreen()),
        ],
      ),
    );
  }

  /// 点标题栏胶囊：两级 —— 先选电脑设备，再选该设备上的会话。
  ///
  /// 第一级选的是「跟哪台电脑对话」（决定后续请求的 to）；
  /// 选到具体设备后自动进第二级「选会话」。选「所有设备（广播）」
  /// 则只切目标、不进会话选择（广播没有单一会话可言）。
  void _pickDeviceThenSession(BuildContext context, AppState state) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF1B1F2B),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(14),
              child:
                  Text('选择电脑设备', style: TextStyle(fontWeight: FontWeight.bold)),
            ),
            if (state.peers.isEmpty)
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: Text('暂无在线电脑设备',
                    style: TextStyle(fontSize: 12, color: Colors.white38)),
              ),
            for (final opt in <_TargetOpt>[
              const _TargetOpt(null, '所有设备（广播）', Icons.campaign_outlined),
              ...state.peers.map((d) => _TargetOpt(
                    d.deviceId,
                    '${d.deviceName} (${d.platform})',
                    Icons.devices,
                  )),
            ])
              ListTile(
                dense: true,
                leading: Icon(opt.icon,
                    size: 20,
                    color: opt.id == state.targetDeviceId
                        ? Colors.lightBlueAccent
                        : Colors.white38),
                title: Text(opt.label,
                    style: TextStyle(
                      color: opt.id == state.targetDeviceId
                          ? Colors.lightBlueAccent
                          : null,
                    )),
                trailing: opt.id == state.targetDeviceId
                    ? const Icon(Icons.check, size: 18, color: Colors.lightBlueAccent)
                    : null,
                onTap: () {
                  state.setTargetDevice(opt.id);
                  Navigator.pop(ctx);
                  // 第二级：只有选定具体设备才进会话选择
                  if (opt.id != null) _pickSession(context, state);
                },
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  /// 第二级：列出该设备上的电脑端会话，选中即切换。
  void _pickSession(BuildContext context, AppState state) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF1B1F2B),
      isScrollControlled: true,
      builder: (ctx) => const _SessionSheet(),
    );
  }
}

/// 标题栏里的两级入口胶囊：显示「设备」或「当前会话名」。
/// 进入电脑端会话时用链接图标 + 蓝色，一眼能看出"正在电脑端会话里"。
class _SessionPill extends StatelessWidget {
  final String deviceLabel;
  final String conversationTitle;
  final bool inConversation;
  final VoidCallback onTap;

  const _SessionPill({
    required this.deviceLabel,
    required this.conversationTitle,
    required this.inConversation,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final label = (inConversation && conversationTitle.isNotEmpty)
        ? conversationTitle
        : deviceLabel;
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

class _TargetOpt {
  final String? id;
  final String label;
  final IconData icon;
  const _TargetOpt(this.id, this.label, this.icon);
}

/// 第二级面板：列出当前设备上的电脑端会话，点一条即切到该会话。
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

  /// 第二级会话列表：按「项目」分组（复用电脑端 projects 顺序，其余归「未归类」），
  /// 与「电脑端对话」列表页（ConversationsPage）一致，避免项目层级在两级胶囊里丢失。
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

    return ListView(shrinkWrap: true, children: rows);
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
    return ListTile(
      dense: true,
      leading: Icon(
        isActive ? Icons.chat_bubble : Icons.chat_bubble_outline,
        size: 20,
        color: isActive ? Colors.lightBlueAccent : Colors.white38,
      ),
      title: Text(
        c.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: c.assistantName.isNotEmpty
          ? Text('助手：${c.assistantName}',
              style: const TextStyle(fontSize: 11, color: Colors.amberAccent))
          : null,
      trailing: isActive
          ? const Icon(Icons.check, size: 18, color: Colors.lightBlueAccent)
          : null,
      onTap: () => _open(context, state, c),
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