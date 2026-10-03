import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../services/app_state.dart';

/// 独立页面（从右上角通知图标进入）。
class NotificationsPage extends StatelessWidget {
  const NotificationsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    return Scaffold(
      appBar: AppBar(
        title: const Text('通知'),
        actions: [
          if (state.inbox.isNotEmpty)
            TextButton.icon(
              onPressed: state.markInboxRead,
              icon: const Icon(Icons.done_all, size: 18),
              label: const Text('全部已读'),
            ),
        ],
      ),
      body: const NotificationsScreen(),
    );
  }
}

/// 通知列表（可单独嵌入）。
class NotificationsScreen extends StatelessWidget {
  const NotificationsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final inbox = state.inbox;

    if (inbox.isEmpty) {
      return const Center(
        child: Text('暂无通知\n电脑端定时任务完成后会推送到这里',
            textAlign: TextAlign.center, style: TextStyle(color: Colors.white54)),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: inbox.length,
      itemBuilder: (context, i) {
        final n = inbox[i];
        final t = DateTime.fromMillisecondsSinceEpoch((n['time'] as num).toInt());
        final read = n['read'] == true;
        return Card(
          color: read ? const Color(0xFF161923) : const Color(0xFF232838),
          child: ListTile(
            leading: Icon(
              read ? Icons.notifications_none : Icons.notifications_active,
              color: read ? Colors.white38 : Colors.amberAccent,
            ),
            title: Text(n['title'] as String? ?? 'Anywhere'),
            subtitle: Text(n['body'] as String? ?? ''),
            trailing: Text(
              DateFormat('MM-dd HH:mm').format(t),
              style: const TextStyle(fontSize: 11, color: Colors.white38),
            ),
          ),
        );
      },
    );
  }
}
