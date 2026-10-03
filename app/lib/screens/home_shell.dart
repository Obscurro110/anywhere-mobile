import 'package:flutter/material.dart';

import '../widgets/connection_badge.dart';
import 'chat_screen.dart';
import 'devices_screen.dart';
import 'files_screen.dart';
import 'notifications_screen.dart';
import 'settings_screen.dart';

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;

  static const _tabs = [
    _Tab('对话', Icons.chat_bubble_outline, Icons.chat_bubble),
    _Tab('设备', Icons.devices_outlined, Icons.devices),
    _Tab('文件', Icons.folder_outlined, Icons.folder),
    _Tab('通知', Icons.notifications_outlined, Icons.notifications),
    _Tab('设置', Icons.settings_outlined, Icons.settings),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Text(_tabs[_index].label),
            const Spacer(),
            const ConnectionBadge(),
            IconButton(
              icon: const Icon(Icons.settings_outlined),
              onPressed: () => setState(() => _index = 4),
            ),
          ],
        ),
      ),
      body: IndexedStack(
        index: _index,
        children: const [
          ChatScreen(),
          DevicesScreen(),
          FilesScreen(),
          NotificationsScreen(),
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
