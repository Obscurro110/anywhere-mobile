import 'dart:io';

import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:open_filex/open_filex.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../services/app_state.dart';

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
    final peers = state.peers;
    _scrollToBottom();

    return Column(
      children: [
        _TargetBar(
          peers: peers,
          value: state.targetDeviceId,
          onChanged: state.setTargetDevice,
        ),
        _CapabilityBar(state: state),
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
// 目标设备选择
// ---------------------------------------------------------------------------
class _TargetBar extends StatelessWidget {
  final List<PeerDevice> peers;
  final String? value;
  final ValueChanged<String?> onChanged;

  const _TargetBar({required this.peers, required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
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
                value: peers.any((d) => d.deviceId == value) ? value : null,
                isDense: true,
                isExpanded: true,
                dropdownColor: const Color(0xFF1F2330),
                items: [
                  const DropdownMenuItem(value: null, child: Text('所有设备（广播）')),
                  ...peers.map((d) => DropdownMenuItem(
                        value: d.deviceId,
                        child: Text('${d.deviceName} (${d.platform})',
                            overflow: TextOverflow.ellipsis),
                      )),
                ],
                onChanged: onChanged,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 能力工具条：模型 / 思考预算 / MCP / Skill / 压缩
// ---------------------------------------------------------------------------
class _CapabilityBar extends StatelessWidget {
  final AppState state;
  const _CapabilityBar({required this.state});

  static const _effortLabels = {
    'default': '默认',
    'none': '关闭',
    'low': '低',
    'medium': '中',
    'high': '高',
    'xhigh': '很高',
    'max': '最大',
  };

  String get _modelLabel {
    final v = state.options.model;
    if (v == null || v.isEmpty) return '默认模型';
    final hit = state.capabilities.models.where((m) => m.value == v);
    if (hit.isNotEmpty) return hit.first.label;
    final parts = v.split('|');
    return parts.length > 1 ? parts[1] : v;
  }

  @override
  Widget build(BuildContext context) {
    final caps = state.capabilities;
    final opts = state.options;

    return Container(
      color: const Color(0xFF141821),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            _chip(
              context,
              icon: Icons.memory,
              label: _modelLabel,
              active: (opts.model ?? '').isNotEmpty,
              onTap: () => _pickModel(context),
            ),
            _chip(
              context,
              icon: Icons.psychology_outlined,
              label:
                  '思考: ${_effortLabels[opts.reasoningEffort ?? 'default'] ?? opts.reasoningEffort}',
              active: opts.reasoningEffort != null && opts.reasoningEffort != 'default',
              onTap: () => _pickEffort(context),
            ),
            _chip(
              context,
              icon: Icons.build_outlined,
              label: 'MCP${(opts.mcp?.isNotEmpty ?? false) ? ' ${opts.mcp!.length}' : ''}',
              active: opts.mcp?.isNotEmpty ?? false,
              onTap: () => _pickMcp(context),
            ),
            _chip(
              context,
              icon: Icons.auto_awesome_outlined,
              label: 'Skill${(opts.skills?.isNotEmpty ?? false) ? ' ${opts.skills!.length}' : ''}',
              active: opts.skills?.isNotEmpty ?? false,
              onTap: () => _pickSkills(context),
            ),
            _chip(
              context,
              icon: Icons.compress,
              label: opts.compress == true ? '压缩: 开' : '压缩',
              active: opts.compress == true,
              onTap: () {
                state.setOptions(
                  ChatOptions(
                    model: opts.model,
                    reasoningEffort: opts.reasoningEffort,
                    mcp: opts.mcp,
                    skills: opts.skills,
                    compress: !(opts.compress ?? false),
                  ),
                );
              },
            ),
            IconButton(
              tooltip: '刷新能力列表',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.refresh, size: 18),
              onPressed: state.requestCapabilities,
            ),
          ],
        ),
      ),
    );
  }

  Widget _chip(
    BuildContext context, {
    required IconData icon,
    required String label,
    required bool active,
    required VoidCallback onTap,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Material(
        color: active ? const Color(0xFF2C3550) : const Color(0xFF1B1F2B),
        borderRadius: BorderRadius.circular(20),
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 14, color: active ? Colors.lightBlueAccent : Colors.white54),
                const SizedBox(width: 5),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 110),
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      color: active ? Colors.white : Colors.white70,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ---- pickers ----
  void _pickModel(BuildContext context) {
    final caps = state.capabilities;
    if (caps.models.isEmpty) {
      _needCapabilities(context);
      return;
    }
    _showSheet<String?>(
      context,
      title: '选择模型',
      items: [
        const _SheetItem<String?>(value: null, label: '默认（跟随电脑端）'),
        ...caps.models.map((m) => _SheetItem<String?>(
              value: m.value,
              label: m.label,
              subtitle: m.provider,
            )),
      ],
      current: state.options.model,
      onPicked: (v) {
        final o = state.options;
        state.setOptions(ChatOptions(
          model: v,
          reasoningEffort: o.reasoningEffort,
          mcp: o.mcp,
          skills: o.skills,
          compress: o.compress,
        ));
      },
    );
  }

  void _pickEffort(BuildContext context) {
    final list = state.capabilities.reasoningEffortOptions.isEmpty
        ? const ['default', 'none', 'low', 'medium', 'high', 'xhigh', 'max']
        : state.capabilities.reasoningEffortOptions;
    _showSheet<String?>(
      context,
      title: '思考预算',
      items: [
        const _SheetItem<String?>(value: null, label: '默认（跟随电脑端）'),
        ...list.map((e) => _SheetItem<String?>(
              value: e,
              label: _effortLabels[e] ?? e,
            )),
      ],
      current: state.options.reasoningEffort,
      onPicked: (v) {
        final o = state.options;
        state.setOptions(ChatOptions(
          model: o.model,
          reasoningEffort: v,
          mcp: o.mcp,
          skills: o.skills,
          compress: o.compress,
        ));
      },
    );
  }

  void _pickMcp(BuildContext context) {
    final caps = state.capabilities;
    if (caps.mcp.isEmpty) {
      _needCapabilities(context);
      return;
    }
    final selected = {...?state.options.mcp};
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF1B1F2B),
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => _MultiSheet(
          title: 'MCP 工具',
          children: caps.mcp
              .map((m) => CheckboxListTile(
                    dense: true,
                    value: selected.contains(m.id),
                    title: Text(m.label),
                    subtitle: m.enabled ? null : const Text('（电脑端已停用）'),
                    onChanged: (v) => setLocal(() {
                      if (v == true) {
                        selected.add(m.id);
                      } else {
                        selected.remove(m.id);
                      }
                    }),
                  ))
              .toList(),
          onConfirm: () {
            final o = state.options;
            state.setOptions(ChatOptions(
              model: o.model,
              reasoningEffort: o.reasoningEffort,
              mcp: selected.toList(),
              skills: o.skills,
              compress: o.compress,
            ));
            Navigator.pop(ctx);
          },
        ),
      ),
    );
  }

  void _pickSkills(BuildContext context) {
    final caps = state.capabilities;
    if (caps.skills.isEmpty) {
      _needCapabilities(context);
      return;
    }
    final selected = {...?state.options.skills};
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF1B1F2B),
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => _MultiSheet(
          title: 'Skill',
          children: caps.skills
              .map((s) => CheckboxListTile(
                    dense: true,
                    value: selected.contains(s.id),
                    title: Text(s.label),
                    onChanged: (v) => setLocal(() {
                      if (v == true) {
                        selected.add(s.id);
                      } else {
                        selected.remove(s.id);
                      }
                    }),
                  ))
              .toList(),
          onConfirm: () {
            final o = state.options;
            state.setOptions(ChatOptions(
              model: o.model,
              reasoningEffort: o.reasoningEffort,
              mcp: o.mcp,
              skills: selected.toList(),
              compress: o.compress,
            ));
            Navigator.pop(ctx);
          },
        ),
      ),
    );
  }

  void _needCapabilities(BuildContext context) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('电脑端还没上报能力列表，请确认电脑端「手机互通」已连接后点刷新'),
      ),
    );
    state.requestCapabilities();
  }

  static void _showSheet<T>(
    BuildContext context, {
    required String title,
    required List<_SheetItem<T>> items,
    required T current,
    required ValueChanged<T> onPicked,
  }) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF1B1F2B),
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(14),
              child: Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: items
                    .map((it) => ListTile(
                          dense: true,
                          title: Text(it.label),
                          subtitle: it.subtitle == null ? null : Text(it.subtitle!),
                          trailing: it.value == current
                              ? const Icon(Icons.check, color: Colors.lightBlueAccent)
                              : null,
                          onTap: () {
                            onPicked(it.value);
                            Navigator.pop(ctx);
                          },
                        ))
                    .toList(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SheetItem<T> {
  final T value;
  final String label;
  final String? subtitle;
  const _SheetItem({required this.value, required this.label, this.subtitle});
}

class _MultiSheet extends StatelessWidget {
  final String title;
  final List<Widget> children;
  final VoidCallback onConfirm;

  const _MultiSheet({
    required this.title,
    required this.children,
    required this.onConfirm,
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.all(14),
            child: Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
          ),
          Flexible(child: ListView(shrinkWrap: true, children: children)),
          Padding(
            padding: const EdgeInsets.all(12),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton(onPressed: onConfirm, child: const Text('确定')),
            ),
          ),
        ],
      ),
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
            // 附件
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
        padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
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
