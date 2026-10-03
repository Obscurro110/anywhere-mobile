import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../services/app_state.dart';

/// 电脑端对话：列出电脑端已有的本地会话，点开即可接着聊。
///
/// 原理：手机点某条会话 → 电脑端用 `conversation:open` 读出该会话并在本机
/// 打开一个窗口（带 relayTo）→ 之后手机的每条消息都进那个会话，AI 的回复
/// 也会回传到手机。会话文件始终留在电脑端，手机只是「远程遥控」。
class ConversationsPage extends StatefulWidget {
  const ConversationsPage({super.key});

  @override
  State<ConversationsPage> createState() => _ConversationsPageState();
}

class _ConversationsPageState extends State<ConversationsPage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<AppState>().requestConversations();
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();

    return Scaffold(
      appBar: AppBar(
        title: const Text('电脑端对话'),
        actions: [
          IconButton(
            tooltip: '刷新',
            icon: const Icon(Icons.refresh),
            onPressed: () => state.requestConversations(),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () => state.requestConversations(),
        child: _body(context, state),
      ),
    );
  }

  Widget _body(BuildContext context, AppState state) {
    if (state.loadingConversations && state.conversations.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    if (state.conversationsError != null && state.conversations.isEmpty) {
      return ListView(
        padding: const EdgeInsets.all(24),
        children: [
          const SizedBox(height: 50),
          const Icon(Icons.error_outline, size: 52, color: Colors.orangeAccent),
          const SizedBox(height: 14),
          Text(
            state.conversationsError!,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white70, height: 1.6),
          ),
          const SizedBox(height: 20),
          Center(
            child: OutlinedButton.icon(
              onPressed: () => state.requestConversations(),
              icon: const Icon(Icons.refresh),
              label: const Text('重试'),
            ),
          ),
        ],
      );
    }

    if (state.conversations.isEmpty) {
      return ListView(
        padding: const EdgeInsets.all(24),
        children: const [
          SizedBox(height: 60),
          Icon(Icons.forum_outlined, size: 56, color: Colors.white24),
          SizedBox(height: 14),
          Text('电脑端还没有会话',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white54)),
          SizedBox(height: 6),
          Text('在电脑端随便聊几句，这里就会出现',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white38, fontSize: 12)),
        ],
      );
    }

    final activeId = state.activeConversationId;

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 20),
      itemCount: state.conversations.length + 1,
      itemBuilder: (context, i) {
        // 顶部：提示当前是否对接着某个电脑端会话
        if (i == 0) {
          if (activeId == null) {
            return const Padding(
              padding: EdgeInsets.fromLTRB(6, 4, 6, 12),
              child: Text(
                '点一条会话即可在电脑端打开它，之后手机的对话就进入该会话',
                style: TextStyle(fontSize: 12, color: Colors.white38),
              ),
            );
          }
          return Container(
            margin: const EdgeInsets.only(bottom: 12),
            padding: const EdgeInsets.fromLTRB(12, 10, 6, 10),
            decoration: BoxDecoration(
              color: const Color(0xFF1D2A3A),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: const Color(0xFF2E5A7A)),
            ),
            child: Row(
              children: [
                const Icon(Icons.link, size: 18, color: Colors.lightBlueAccent),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('正在电脑端会话中对话',
                          style: TextStyle(fontSize: 12, color: Colors.white70)),
                      if (state.activeConversationTitle.isNotEmpty)
                        Text(
                          state.activeConversationTitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 13, fontWeight: FontWeight.bold),
                        ),
                    ],
                  ),
                ),
                TextButton(
                  onPressed: state.leaveDesktopConversation,
                  child: const Text('退出'),
                ),
              ],
            ),
          );
        }

        final c = state.conversations[i - 1];
        final isActive = c.id == activeId;

        return Card(
          color: isActive ? const Color(0xFF1D2A3A) : const Color(0xFF1B1F2B),
          margin: const EdgeInsets.only(bottom: 8),
          child: ListTile(
            contentPadding: const EdgeInsets.fromLTRB(14, 6, 8, 6),
            leading: Icon(
              isActive ? Icons.chat_bubble : Icons.chat_bubble_outline,
              color: isActive ? Colors.lightBlueAccent : Colors.white38,
            ),
            title: Text(
              c.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 14.5),
            ),
            subtitle: Row(
              children: [
                if (c.updatedLabel.isNotEmpty)
                  Text(c.updatedLabel,
                      style: const TextStyle(fontSize: 11, color: Colors.white38)),
                if (isActive) ...[
                  const SizedBox(width: 8),
                  const Text('对话中',
                      style: TextStyle(fontSize: 11, color: Colors.lightBlueAccent)),
                ],
              ],
            ),
            trailing: isActive
                ? null
                : const Icon(Icons.open_in_new, size: 18, color: Colors.white24),
            onTap: isActive ? null : () => _open(context, state, c),
          ),
        );
      },
    );
  }

  Future<void> _open(
      BuildContext context, AppState state, ConversationOption c) async {
    if (!state.client.isConnected) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('未连接到中继服务器')),
      );
      return;
    }
    final sent = state.openConversationOnDesktop(c.id);
    if (!sent) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('发送失败')),
      );
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('正在电脑端打开「${c.title}」…')),
    );
    if (!mounted) return;
    // 等电脑端回执（回执会更新 activeConversationId）
    for (var i = 0; i < 12; i++) {
      await Future.delayed(const Duration(milliseconds: 500));
      if (!mounted) return;
      if (state.activeConversationId == c.id) {
        if (mounted) Navigator.of(context).pop();
        return;
      }
      final res = state.lastConversationOpen;
      if (res != null && res['ok'] != true) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('打开失败：${res['reason']}')),
          );
        }
        return;
      }
    }
  }
}
