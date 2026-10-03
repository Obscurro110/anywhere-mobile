import 'dart:io';

import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:open_filex/open_filex.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../services/app_state.dart';
import '../widgets/conversation_options_bar.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _controller = TextEditingController();
  final _scroll = ScrollController();
  bool _uploading = false;

  @override
  void dispose() {
    _controller.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _send() {
    final state = context.read<AppState>();
    final text = _controller.text;
    if (text.trim().isEmpty) return;
    final ok = state.sendChat(text);
    if (ok) _controller.clear();
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('未连接到中继服务器，消息未发送')),
      );
    }
    _scrollToBottom();
  }

  Future<void> _pickAndSendFile() async {
    final state = context.read<AppState>();
    final result = await FilePicker.platform.pickFiles(withData: false);
    final path = result?.files.single.path;
    if (path == null) return;
    setState(() => _uploading = true);
    try {
      await state.shareFile(File(path));
      _scrollToBottom();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('文件已发送')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('发送失败: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  Future<void> _openFile(FileMeta meta) async {
    final state = context.read<AppState>();
    try {
      final f = await state.downloadToDevice(meta);
      await OpenFilex.open(f.path);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('下载失败: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    _scrollToBottom();

    return Column(
      children: [
        Expanded(
          child: state.messages.isEmpty
              ? const _EmptyChat()
              : ListView.builder(
                  controller: _scroll,
                  padding: const EdgeInsets.all(12),
                  itemCount: state.messages.length,
                  itemBuilder: (context, i) => _Bubble(
                    msg: state.messages[i],
                    onOpenFile: _openFile,
                  ),
                ),
        ),
        // 会话参数：紧贴输入框上方（参考电脑端 ChatInput 的布局）
        const ConversationOptionsBar(),
        _Composer(
          controller: _controller,
          onSend: _send,
          onAttach: _uploading ? null : _pickAndSendFile,
          uploading: _uploading,
          awaiting: state.awaitingReply,
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// 消息气泡
// ---------------------------------------------------------------------------
class _EmptyChat extends StatelessWidget {
  const _EmptyChat();
  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.forum_outlined, size: 56, color: Colors.white24),
          SizedBox(height: 12),
          Text('还没有消息', style: TextStyle(color: Colors.white54)),
          SizedBox(height: 4),
          Text('连接后即可与电脑端 Anywhere Desktop 对话',
              style: TextStyle(color: Colors.white38, fontSize: 12)),
        ],
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  final ChatMessage msg;
  final Future<void> Function(FileMeta) onOpenFile;

  const _Bubble({required this.msg, required this.onOpenFile});

  @override
  Widget build(BuildContext context) {
    final outgoing = msg.outgoing;
    final atts = msg.attachments ?? const <FileMeta>[];

    return Align(
      alignment: outgoing ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.78),
        decoration: BoxDecoration(
          color: outgoing ? const Color(0xFF3A46C9) : const Color(0xFF232838),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!outgoing && msg.role == ChatRole.assistant)
              const Padding(
                padding: EdgeInsets.only(bottom: 4),
                child: Text('Anywhere Desktop',
                    style: TextStyle(fontSize: 10, color: Colors.white38)),
              ),
            if (msg.pending)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: 13,
                      height: 13,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    SizedBox(width: 8),
                    Text('电脑端正在处理…',
                        style: TextStyle(fontSize: 13, color: Colors.white70)),
                  ],
                ),
              )
            else if (msg.text.isNotEmpty)
              SelectableText(msg.text, style: const TextStyle(fontSize: 15)),
            for (final f in atts)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Material(
                  color: Colors.black26,
                  borderRadius: BorderRadius.circular(8),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(8),
                    onTap: outgoing ? null : () => onOpenFile(f),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.insert_drive_file,
                              size: 18, color: Colors.amberAccent),
                          const SizedBox(width: 8),
                          Flexible(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(f.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(fontSize: 13)),
                                Text(f.humanSize,
                                    style: const TextStyle(
                                        fontSize: 11, color: Colors.white54)),
                              ],
                            ),
                          ),
                          if (!outgoing) ...[
                            const SizedBox(width: 8),
                            const Icon(Icons.download, size: 16, color: Colors.white54),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _Composer extends StatelessWidget {
  final TextEditingController controller;
  final VoidCallback onSend;
  final VoidCallback? onAttach;
  final bool uploading;
  final bool awaiting;

  const _Composer({
    required this.controller,
    required this.onSend,
    required this.onAttach,
    required this.uploading,
    required this.awaiting,
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
        color: const Color(0xFF12151E),
        child: Row(
          children: [
            IconButton(
              tooltip: '发送文件',
              onPressed: onAttach,
              icon: uploading
                  ? const SizedBox(
                      width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.attach_file),
            ),
            Expanded(
              child: TextField(
                controller: controller,
                minLines: 1,
                maxLines: 5,
                textInputAction: TextInputAction.newline,
                decoration: InputDecoration(
                  hintText: awaiting ? '电脑端正在处理，可继续输入…' : '输入消息…',
                  filled: true,
                  fillColor: const Color(0xFF1B1F2B),
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(22),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 6),
            IconButton.filled(
              onPressed: onSend,
              icon: const Icon(Icons.send),
            ),
          ],
        ),
      ),
    );
  }
}
