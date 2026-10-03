import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/app_state.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _controller = TextEditingController();
  final _scroll = ScrollController();
  String? _targetDeviceId; // null => broadcast to all devices

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
    final ok = state.sendChat(text, toDeviceId: _targetDeviceId);
    _controller.clear();
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('未连接到中继服务器，消息未发送')),
      );
    }
    _scrollToBottom();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    _scrollToBottom();

    final peers = state.peers;

    return Column(
      children: [
        // target selector
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          color: const Color(0xFF161923),
          child: Row(
            children: [
              const Icon(Icons.send_to_mobile, size: 16, color: Colors.white54),
              const SizedBox(width: 8),
              const Text('发送到：', style: TextStyle(fontSize: 12, color: Colors.white54)),
              const SizedBox(width: 4),
              Expanded(
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<String?>(
                    value: _targetDeviceId,
                    isDense: true,
                    dropdownColor: const Color(0xFF1F2330),
                    items: [
                      const DropdownMenuItem(value: null, child: Text('所有设备（广播）')),
                      ...peers.map((d) => DropdownMenuItem(
                            value: d.deviceId,
                            child: Text('${d.deviceName} (${d.platform})'),
                          )),
                    ],
                    onChanged: (v) => setState(() => _targetDeviceId = v),
                  ),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: state.messages.isEmpty
              ? const _EmptyChat()
              : ListView.builder(
                  controller: _scroll,
                  padding: const EdgeInsets.all(12),
                  itemCount: state.messages.length,
                  itemBuilder: (context, i) => _Bubble(msg: state.messages[i]),
                ),
        ),
        _Composer(controller: _controller, onSend: _send),
      ],
    );
  }
}

class _EmptyChat extends StatelessWidget {
  const _EmptyChat();
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: const [
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
  final dynamic msg;
  const _Bubble({required this.msg});

  @override
  Widget build(BuildContext context) {
    final outgoing = msg.outgoing == true;
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
            if (!outgoing)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text('${msg.role}',
                    style: const TextStyle(fontSize: 10, color: Colors.white38)),
              ),
            SelectableText(msg.text as String, style: const TextStyle(fontSize: 15)),
          ],
        ),
      ),
    );
  }
}

class _Composer extends StatelessWidget {
  final TextEditingController controller;
  final VoidCallback onSend;
  const _Composer({required this.controller, required this.onSend});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 6, 8, 8),
        color: const Color(0xFF12151E),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: controller,
                minLines: 1,
                maxLines: 5,
                textInputAction: TextInputAction.newline,
                decoration: InputDecoration(
                  hintText: '输入消息…',
                  filled: true,
                  fillColor: const Color(0xFF1B1F2B),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
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
