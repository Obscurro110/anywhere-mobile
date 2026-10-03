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
class HomeShell extends StatelessWidget {
  const HomeShell({super.key});

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
            itemBuilder: (ctx) => [
              PopupMenuItem(
                value: 'conv',
                child: ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.forum_outlined, size: 20),
                  title: const Text('电脑端对话'),
                  subtitle: state.activeConversationId != null
                      ? const Text('对话中', style: TextStyle(fontSize: 11))
                      : null,
                ),
              ),
              const PopupMenuItem(
                value: 'tasks',
                child: ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.schedule, size: 20),
                  title: Text('定时任务'),
                ),
              ),
              const PopupMenuItem(
                value: 'settings',
                child: ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.settings_outlined, size: 20),
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
              _TargetOpt(null, '所有设备', Icons.campaign_outlined),
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