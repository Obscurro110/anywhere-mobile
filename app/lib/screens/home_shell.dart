import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

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
            // 当前接的是哪个电脑端会话（点击可切换/退出）
            if (state.activeConversationId != null)
              _ConvPill(
                title: state.activeConversationTitle.isEmpty
                    ? '电脑端会话'
                    : state.activeConversationTitle,
                onTap: () => _push(context, const ConversationsPage()),
              )
            else
              _TargetPill(
                label: state.targetLabel,
                onTap: () => _pickTarget(context, state),
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
            // 只显示图标（不显示汉字）；「对话中」用小圆点表示，
            // 定时任务有数量时用角标数字表示。
            itemBuilder: (ctx) => [
              PopupMenuItem(
                value: 'conv',
                height: 48,
                child: Tooltip(
                  message: '电脑端对话',
                  child: Badge(
                    isLabelVisible: state.activeConversationId != null,
                    smallSize: 7,
                    child: const Icon(Icons.forum_outlined, size: 22),
                  ),
                ),
              ),
              PopupMenuItem(
                value: 'tasks',
                height: 48,
                child: Tooltip(
                  message: '定时任务',
                  child: Badge(
                    isLabelVisible: state.tasks.isNotEmpty,
                    label: Text('${state.tasks.length}'),
                    child: const Icon(Icons.schedule, size: 22),
                  ),
                ),
              ),
              PopupMenuItem(
                value: 'settings',
                height: 48,
                child: Tooltip(
                  message: '设置',
                  child: const Icon(Icons.settings_outlined, size: 22),
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

  /// 点标题栏的设备胶囊 = 切换发送目标
  void _pickTarget(BuildContext context, AppState state) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF1B1F2B),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(14),
              child: Text('发送到', style: TextStyle(fontWeight: FontWeight.bold)),
            ),
            if (state.peers.isEmpty)
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: Text('暂无其他在线设备，将发送给所有设备',
                    style: TextStyle(fontSize: 12, color: Colors.white38)),
              ),
            for (final opt in <_TargetOpt>[
              const _TargetOpt(null, '所有设备', Icons.campaign_outlined),
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
                },
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

/// 标题栏里的「发送到」胶囊 —— 把原先占一整行的设备条压成一个小标签。
class _TargetPill extends StatelessWidget {
  final String label;
  final VoidCallback onTap;

  const _TargetPill({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFF232838),
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.north_east, size: 12, color: Colors.white54),
              const SizedBox(width: 4),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 110),
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

/// 标题栏里显示「当前接的是电脑端哪个会话」。
/// 与 _TargetPill 区分开：这个用的是链接图标 + 蓝色，一眼能看出"正在电脑端会话里"。
class _ConvPill extends StatelessWidget {
  final String title;
  final VoidCallback onTap;

  const _ConvPill({required this.title, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFF1D2A3A),
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.link, size: 12, color: Colors.lightBlueAccent),
              const SizedBox(width: 4),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 120),
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12, color: Colors.white),
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