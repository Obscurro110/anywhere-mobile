import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../services/app_state.dart';

/// 会话详情：查看某个电脑端会话里的全部消息，可批量选择并删除。
///
/// 说明：这里是只读展示 + 删除，**不在这里发消息**。
/// 想接着聊请用列表里的「在电脑端打开」——那样 AI 才会带上完整上下文。
class ConversationDetailPage extends StatefulWidget {
  final ConversationOption conversation;

  const ConversationDetailPage({super.key, required this.conversation});

  @override
  State<ConversationDetailPage> createState() => _ConversationDetailPageState();
}

class _ConversationDetailPageState extends State<ConversationDetailPage> {
  /// 选择模式下已勾选的消息 id
  final _selected = <String>{};
  bool _selecting = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        context.read<AppState>().requestConversationMessages(widget.conversation.id);
      }
    });
  }

  @override
  void dispose() {
    // 告诉 AppState 不再查看这个会话，避免它退出后还把
    // 「当前查看会话」指向这里（会影响到别的页面读到的列表/loading）。
    _state?.stopViewingConversation(widget.conversation.id);
    super.dispose();
  }

  AppState? _state;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    _state = state;
    // AppBar 里也要用（是否显示「选择消息」按钮），所以这里再取一份
    final messages = state.messagesOf(widget.conversation.id);

    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.conversation.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        leading: _selecting
            ? IconButton(
                icon: const Icon(Icons.close),
                onPressed: () => setState(() {
                  _selecting = false;
                  _selected.clear();
                }),
              )
            : null,
        actions: [
          if (messages.isNotEmpty)
            _selecting
                ? IconButton(
                    tooltip: '删除选中',
                    icon: Badge(
                      isLabelVisible: _selected.isNotEmpty,
                      label: Text('${_selected.length}'),
                      child: const Icon(Icons.delete_outline),
                    ),
                    onPressed: _selected.isEmpty ? null : _deleteSelected,
                  )
                : IconButton(
                    tooltip: '选择消息',
                    icon: const Icon(Icons.checklist),
                    onPressed: () => setState(() => _selecting = true),
                  ),
          IconButton(
            tooltip: '刷新',
            icon: const Icon(Icons.refresh),
            onPressed: () =>
                state.requestConversationMessages(widget.conversation.id),
          ),
        ],
      ),
      body: _body(context, state),
    );
  }

  Widget _body(BuildContext context, AppState state) {
    // 只用**这个会话自己**的消息，不依赖全局「当前查看」的时序
    final messages = state.messagesOf(widget.conversation.id);

    if (state.loadingConversationMessages) {
      return const Center(child: CircularProgressIndicator());
    }
    if (state.conversationMessagesError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            state.conversationMessagesError!,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white70, height: 1.6),
          ),
        ),
      );
    }
    if (messages.isEmpty) {
      return const Center(
        child: Text('这个会话没有可显示的文字消息',
            style: TextStyle(color: Colors.white38)),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
      itemCount: messages.length + 1,
      itemBuilder: (context, i) {
        if (i == 0) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(6, 0, 6, 12),
            child: Text(
              '共 ${messages.length} 条消息'
              '${_selecting ? " · 勾选后可删除" : ""}',
              style: const TextStyle(fontSize: 12, color: Colors.white38),
            ),
          );
        }
        final m = messages[i - 1];
        return _messageTile(m);
      },
    );
  }

  Widget _messageTile(ConvMessage m) {
    final isUser = m.isUser;
    final isSys = m.isSystem;
    final checked = _selected.contains(m.id);

    return InkWell(
      onTap: () {
        if (!_selecting || m.id.isEmpty) return;
        setState(() {
          if (checked) {
            _selected.remove(m.id);
          } else {
            _selected.add(m.id);
          }
        });
      },
      onLongPress: () => _messageMenu(m),
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
        decoration: BoxDecoration(
          color: isSys
              ? const Color(0xFF191C24)
              : (isUser ? const Color(0xFF1E2A22) : const Color(0xFF1B1F2B)),
          borderRadius: BorderRadius.circular(10),
          border: checked
              ? Border.all(color: Colors.lightBlueAccent, width: 1.5)
              : Border.all(color: Colors.transparent),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_selecting) ...[
              Icon(
                checked ? Icons.check_circle : Icons.circle_outlined,
                size: 18,
                color: checked ? Colors.lightBlueAccent : Colors.white24,
              ),
              const SizedBox(width: 10),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        isSys ? '系统' : (isUser ? '你' : 'AI'),
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          color: isSys
                              ? Colors.white38
                              : (isUser ? Colors.greenAccent : Colors.lightBlueAccent),
                        ),
                      ),
                      const Spacer(),
                      if (m.time.isNotEmpty)
                        Text(
                          m.time.length > 16 ? m.time.substring(0, 16) : m.time,
                          style: const TextStyle(
                              fontSize: 10, color: Colors.white24),
                        ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  SelectableText(
                    m.text,
                    style: const TextStyle(
                        fontSize: 13.5, height: 1.5, color: Colors.white),
                  ),
                ],
              ),
            ),
            // 单条操作入口（选择模式下隐藏，避免误触）
            if (!_selecting)
              IconButton(
                tooltip: '操作',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.more_vert, size: 18, color: Colors.white38),
                onPressed: () => _messageMenu(m),
              ),
          ],
        ),
      ),
    );
  }

  /// 单条消息的操作菜单：重新回答 / 删除这条 / 复制
  Future<void> _messageMenu(ConvMessage m) async {
    // 菜单项只显示图标（不显示汉字），长按有提示
    final items = <PopupMenuEntry<String>>[
      PopupMenuItem(
        value: 'copy',
        height: 44,
        child: Tooltip(
          message: '复制',
          child: const Icon(Icons.copy, size: 20),
        ),
      ),
      if (m.canReask)
        PopupMenuItem(
          value: 'reask',
          height: 44,
          child: Tooltip(
            message: '重新回答',
            child: const Icon(Icons.refresh, size: 20),
          ),
        ),
      if (m.canDelete)
        PopupMenuItem(
          value: 'delete',
          height: 44,
          child: Tooltip(
            message: '删除这条',
            child: const Icon(Icons.delete_outline,
                size: 20, color: Colors.redAccent),
          ),
        ),
    ];

    final box = context.findRenderObject() as RenderBox?;
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (box == null || overlay == null) return;

    final choice = await showMenu<String>(
      context: context,
      color: const Color(0xFF232733),
      position: RelativeRect.fromRect(
        Rect.fromPoints(
          box.localToGlobal(Offset.zero, ancestor: overlay),
          box.localToGlobal(box.size.bottomRight(Offset.zero), ancestor: overlay),
        ),
        Offset.zero & overlay.size,
      ),
      items: items,
    );
    if (choice == null || !mounted) return;

    final state = context.read<AppState>();
    switch (choice) {
      case 'copy':
        await Clipboard.setData(ClipboardData(text: m.text));
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('已复制'), duration: Duration(seconds: 1)),
        );
      case 'reask':
        _doReask(state, m);
      case 'delete':
        _doDeleteOne(state, m);
    }
  }

  Future<void> _doReask(AppState state, ConvMessage m) async {
    // 「重新回答」必须在电脑端那个会话窗口里跑
    if (state.activeConversationId != widget.conversation.id) {
      _warnNotOpen();
      return;
    }
    final sent = state.reaskMessageOnDesktop(widget.conversation.id, m.id);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(sent ? '已让电脑端重新回答…' : '发送失败'),
        duration: const Duration(seconds: 2),
      ),
    );
    if (!sent) return;
    // 等电脑端跑完再刷新
    await Future.delayed(const Duration(seconds: 3));
    if (mounted) {
      state.requestConversationMessages(widget.conversation.id);
    }
  }

  Future<void> _doDeleteOne(AppState state, ConvMessage m) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除这条消息'),
        content: const Text('将从电脑端这个会话里永久删除这条消息。此操作不可撤销。'),
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
    if (ok != true || !mounted) return;

    // 优先走「让电脑端窗口删」——和你在电脑上点删除是同一个逻辑，
    // 不会因为索引/压缩导致删错行。没开窗口才退回直接改数据。
    if (state.activeConversationId == widget.conversation.id) {
      final sent = state.deleteMessageOnDesktop(widget.conversation.id, m.index,
          messageId: m.id);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(sent ? '已让电脑端删除…' : '发送失败'),
          duration: const Duration(seconds: 2),
        ),
      );
      if (sent) {
        await Future.delayed(const Duration(milliseconds: 1500));
        if (mounted) {
          state.requestConversationMessages(widget.conversation.id);
        }
      }
      return;
    }

    _warnNotOpen();
  }

  void _warnNotOpen() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('请先在列表里点「在电脑端打开」，再操作这条消息'),
        duration: Duration(seconds: 3),
      ),
    );
  }

  Future<void> _deleteSelected() async {
    final n = _selected.length;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除消息'),
        content: Text('将从电脑端这个会话里永久删除选中的 $n 条消息。\n\n此操作不可撤销。'),
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
    if (ok != true || !mounted) return;
    final state = context.read<AppState>();
    final sent = state.deleteConversationMessages(
      widget.conversation.id,
      _selected.toList(),
    );
    if (!mounted) return;
    setState(() {
      _selecting = false;
      _selected.clear();
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(sent ? '已请求删除 $n 条消息' : '发送失败')),
    );
    // 稍后刷新一次，拿到电脑端删除后的真实列表
    await Future.delayed(const Duration(milliseconds: 1200));
    if (mounted) {
      state.requestConversationMessages(widget.conversation.id);
    }
  }
}
