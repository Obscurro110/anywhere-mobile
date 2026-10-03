import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../services/app_state.dart';

class NotificationsScreen extends StatelessWidget {
  const NotificationsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final inbox = state.inbox;

    return Column(
      children: [
        if (inbox.isNotEmpty)
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: state.markInboxRead,
              icon: const Icon(Icons.done_all, size: 18),
              label: const Text('全部已读'),
            ),
          ),
        Expanded(
          child: inbox.isEmpty
              ? const Center(
                  child: Text('暂无通知\n电脑端定时任务完成后会推送到这里',
                      textAlign: TextAlign.center, style: TextStyle(color: Colors.white54)),
                )
              : ListView.builder(
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
                ),
        ),
      ],
    );
  }
}
