import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/app_state.dart';
import '../widgets/connection_badge.dart';
import 'chat_screen.dart';
import 'notifications_screen.dart';
import 'settings_screen.dart';

/// App shell: 只保留「对话」与「设置」两个底部标签。
/// 「通知」移到右上角图标；「设备」合并进设置；「文件」并入对话。
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
            const SizedBox(width: 4),
            // 通知：右上角
            IconButton(
              tooltip: '通知',
              onPressed: _openNotifications,
              icon: Badge(
                isLabelVisible: unread > 0,
                label: Text('$unread'),
                child: const Icon(Icons.notifications_outlined),
              ),
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

class _Tab {
  final String label;
  final IconData icon;
  final IconData selectedIcon;
  const _Tab(this.label, this.icon, this.selectedIcon);
}
