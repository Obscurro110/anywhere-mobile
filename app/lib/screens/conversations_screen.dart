import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../services/app_state.dart';
import 'conversation_detail_screen.dart';

/// 电脑端对话：列出电脑端已有的本地会话，按项目分组，可点开接着聊或管理。
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
      // 页面可能在这一帧内就被关掉了，不判 mounted 会拿到失效的 context
      if (mounted) context.read<AppState>().requestConversations();
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

    // 按项目分组：先按电脑端 projects 顺序，再「未归类」
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
    // 去掉空项目
    grouped.removeWhere((_, v) => v.isEmpty);

    final rows = <Widget>[];

    // 顶部：当前接的会话提示
    if (state.activeConversationId != null) {
      rows.add(_activeBanner(context, state));
    }

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

    rows.add(const SizedBox(height: 20));

    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      children: rows,
    );
  }

  Widget _activeBanner(BuildContext context, AppState state) {
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
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

    return Card(
      color: isActive ? const Color(0xFF1D2A3A) : const Color(0xFF1B1F2B),
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        contentPadding: const EdgeInsets.fromLTRB(14, 6, 4, 6),
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
        trailing: PopupMenuButton<String>(
          icon: const Icon(Icons.more_vert, size: 18, color: Colors.white38),
          color: const Color(0xFF232733),
          onSelected: (v) {
            switch (v) {
              case 'open':
                _open(context, state, c);
              case 'view':
                Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => ConversationDetailPage(conversation: c),
                ));
              case 'rename':
                _rename(context, state, c);
              case 'delete':
                _delete(context, state, c);
            }
          },
          itemBuilder: (ctx) => [
            if (!isActive)
              const PopupMenuItem(
                value: 'open',
                child: ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.open_in_new, size: 18),
                  title: Text('在电脑端打开'),
                ),
              ),
            const PopupMenuItem(
              value: 'view',
              child: ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.article_outlined, size: 18),
                title: Text('查看对话'),
              ),
            ),
            const PopupMenuItem(
              value: 'rename',
              child: ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.edit_outlined, size: 18),
                title: Text('重命名'),
              ),
            ),
            const PopupMenuItem(
              value: 'delete',
              child: ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.delete_outline,
                    size: 18, color: Colors.redAccent),
                title: Text('删除会话',
                    style: TextStyle(color: Colors.redAccent)),
              ),
            ),
          ],
        ),
        onTap: isActive
            ? () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => ConversationDetailPage(conversation: c),
                ))
            : () => _open(context, state, c),
      ),
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
          final messenger = ScaffoldMessenger.of(context);
          messenger.showSnackBar(
            SnackBar(content: Text('打开失败：${res['reason']}')),
          );
        }
        return;
      }
    }
  }

  Future<void> _rename(
      BuildContext context, AppState state, ConversationOption c) async {
    final ctrl = TextEditingController(text: c.title);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('重命名会话'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
              child: const Text('确定')),
        ],
      ),
    );
    if (name == null || name.isEmpty || name == c.title) return;
    if (!context.mounted) return;
    final ok = state.renameConversationOnDesktop(c.id, name);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(ok ? '已重命名为「$name」' : '重命名失败')),
      );
    }
  }

  Future<void> _delete(
      BuildContext context, AppState state, ConversationOption c) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除会话'),
        content: Text(
          '将从电脑端永久删除这个会话及其全部对话记录：\n\n「${c.title}」\n\n此操作不可撤销。',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    if (!context.mounted) return;
    final sent = state.deleteConversationOnDesktop(c.id);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(sent ? '已请求删除「${c.title}」' : '发送失败')),
      );
    }
  }
}
