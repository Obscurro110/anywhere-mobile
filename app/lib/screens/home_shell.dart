import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/app_state.dart';
import '../widgets/connection_badge.dart';
import 'chat_screen.dart';
import 'notifications_screen.dart';
import 'settings_screen.dart';
import 'tasks_screen.dart';

/// App 外壳：
///  - 底部只保留「对话」与「设置」两个标签
///  - 「通知」在右上角图标
///  - 「目标设备 / 定时任务」收进右上角 ⋮ 菜单（不占对话区）
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;

  static const _tabs = [
    _Tab('对话', Icons.chat_bubble_outline, Icons.chat_bubble),
    _Tab('设置', Icons.settings_outlined, Icons.settings),
  ];

  void _openNotifications() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const NotificationsPage()),
    );
  }

  void _openTasks() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const TasksPage()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final unread = context.select<AppState, int>(
      (s) => s.inbox.where((n) => n['read'] != true).length,
    );

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Text(_tabs[_index].label),
            const Spacer(),
            const ConnectionBadge(),
            // 通知
            IconButton(
              tooltip: '通知',
              onPressed: _openNotifications,
              icon: Badge(
                isLabelVisible: unread > 0,
                label: Text('$unread'),
                child: const Icon(Icons.notifications_outlined),
              ),
            ),
            // 更多：目标设备 / 定时任务
            PopupMenuButton<String>(
              tooltip: '更多',
              icon: const Icon(Icons.more_vert),
              color: const Color(0xFF1F2330),
              onSelected: (v) {
                if (v == 'tasks') _openTasks();
              },
              itemBuilder: (ctx) => [
                PopupMenuItem<String>(
                  enabled: false,
                  padding: EdgeInsets.zero,
                  child: const _TargetDeviceMenu(),
                ),
                const PopupMenuDivider(),
                const PopupMenuItem<String>(
                  value: 'tasks',
                  child: ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.schedule, size: 20),
                    title: Text('定时任务'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
      body: IndexedStack(
        index: _index,
        children: const [
          ChatScreen(),
          SettingsScreen(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: [
          for (final t in _tabs)
            NavigationDestination(
              icon: Icon(t.icon),
              selectedIcon: Icon(t.selectedIcon),
              label: t.label,
            ),
        ],
      ),
    );
  }
}

/// 菜单里的「发送到」选择器 —— 不再占用对话区顶部。
class _TargetDeviceMenu extends StatelessWidget {
  const _TargetDeviceMenu();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final peers = state.peers;
    final current = state.targetDeviceId;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 12, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('发送到',
              style: TextStyle(fontSize: 12, color: Colors.white54)),
          const SizedBox(height: 6),
          for (final opt in <_TargetOpt>[
            _TargetOpt(null, '所有设备（广播）'),
            ...peers.map((d) => _TargetOpt(d.deviceId, '${d.deviceName} (${d.platform})')),
          ])
            InkWell(
              onTap: () {
                context.read<AppState>().setTargetDevice(opt.id);
                Navigator.pop(context);
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  children: [
                    Icon(
                      opt.id == null ? Icons.campaign_outlined : Icons.devices,
                      size: 18,
                      color: opt.id == current ? Colors.lightBlueAccent : Colors.white38,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        opt.label,
                        style: TextStyle(
                          fontSize: 14,
                          color: opt.id == current ? Colors.lightBlueAccent : Colors.white,
                        ),
                      ),
                    ),
                    if (opt.id == current)
                      const Icon(Icons.check, size: 16, color: Colors.lightBlueAccent),
                  ],
                ),
              ),
            ),
          if (peers.isEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 4),
              child: Text('（暂无其他在线设备）',
                  style: TextStyle(fontSize: 12, color: Colors.white38)),
            ),
        ],
      ),
    );
  }
}

class _TargetOpt {
  final String? id;
  final String label;
  const _TargetOpt(this.id, this.label);
}

class _Tab {
  final String label;
  final IconData icon;
  final IconData selectedIcon;
  const _Tab(this.label, this.icon, this.selectedIcon);
}
