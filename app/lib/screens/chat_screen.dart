import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;
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
                    // 电脑端的「重新回答」只对最后一条生效，这里同步这个规则
                    isLast: i == state.messages.length - 1,
                  ),
                ),
        ),
        // 会话参数：紧贴输入框上方（参考电脑端 ChatInput 的布局）
        const ConversationOptionsBar(),
        _Composer(
          controller: _controller,
          onSend: _send,
          onStop: state.generating ? () => state.cancelGeneration() : null,
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
  final bool isLast;

  const _Bubble({
    required this.msg,
    required this.onOpenFile,
    this.isLast = false,
  });

  @override
  Widget build(BuildContext context) {
    final outgoing = msg.outgoing;
    final atts = msg.attachments ?? const <FileMeta>[];
    final reasoningText = msg.desktopMeta?.reasoning ?? '';

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
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.smart_toy_outlined,
                            size: 12, color: Colors.white38),
                        const SizedBox(width: 4),
                        Text(
                          // 显示「服务商|模型」，而不是笼统的 Anywhere Desktop：
                          // 一眼能看出这条是哪个模型答的
                          msg.modelTag.isNotEmpty
                              ? msg.modelTag
                              : 'Anywhere Desktop',
                          style: const TextStyle(
                              fontSize: 10.5, color: Colors.white38),
                        ),
                      ],
                    ),
                    // 时间（+耗时）放在模型名下面 —— 与电脑端气泡一致
                    if (_headerTime(msg).isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 1, left: 16),
                        child: Text(
                          _headerTime(msg),
                          style: const TextStyle(
                              fontSize: 10.5, color: Colors.white38),
                        ),
                      ),
                  ],
                ),
              ),
            // 电脑端把「思考内容」放在正文上方（折叠块），手机端保持一致
            if (!outgoing && !msg.pending && reasoningText.trim().isNotEmpty)
              _ThinkingBlock(text: reasoningText),
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
              _MarkdownText(text: msg.text),
            // 电脑端已受理、正在流式生成但这一帧还没出正文：
            // 显示「正在生成…」，而不是干等一个空气泡。
            if (!outgoing &&
                !msg.pending &&
                msg.text.isEmpty &&
                (msg.desktopMeta?.streaming ?? false))
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
                    Text('电脑端正在生成…',
                        style: TextStyle(fontSize: 13, color: Colors.white70)),
                  ],
                ),
              ),
            // 工具调用：折叠块，默认收起（执行中转圈）。
            // 以前是拼成一大段文字直接铺在气泡里，手机上刷屏。
            if (!outgoing &&
                !msg.pending &&
                (msg.desktopMeta?.toolCalls.isNotEmpty ?? false))
              _ToolCallsBlock(calls: msg.desktopMeta!.toolCalls),
            // 电脑端 ask_user_choice 提问：气泡下渲染可点选的选项
            if (msg.choice?.isValid == true && !msg.pending)
              _ChoicePanel(msg: msg),
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
            // 气泡下方的操作栏（对齐电脑端气泡底部的按钮）
            if (!msg.pending)
              _ActionBar(msg: msg, outgoing: outgoing, isLast: isLast),
            // 时间 / 耗时 / token 元信息（和电脑端气泡一致）
            _MetaLine(msg: msg, outgoing: outgoing),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 消息元信息（时间 / 耗时 / token）—— 对齐电脑端气泡的显示
// ---------------------------------------------------------------------------
/// 时间统一成「2026-10-05 10:02」——与电脑端 formatTimestamp 完全一致。
String _fmtClock(int ms) {
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  String two(int n) => n.toString().padLeft(2, '0');
  return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
}

/// 气泡头部的时间行（时间 + 耗时），电脑端与手机端同一套文案。
String _headerTime(ChatMessage msg) {
  final meta = msg.desktopMeta;
  final startMs = (meta != null && meta.startTime > 0)
      ? meta.startTime
      : msg.time.millisecondsSinceEpoch;
  if (startMs <= 0) return '';
  final duration =
      (meta != null && meta.startTime > 0 && meta.endTime > meta.startTime)
          ? _fmtDurationMs(meta.endTime - meta.startTime)
          : '';
  return duration.isNotEmpty
      ? '${_fmtClock(startMs)} ($duration)'
      : _fmtClock(startMs);
}

/// 耗时统一中文口径：0分7秒 / 1分23秒 / 1时2分3秒（电脑端同款）。
String _fmtDurationMs(int ms) {
  if (ms <= 0) return '';
  final total = (ms / 1000).round();
  final h = total ~/ 3600;
  final m = (total % 3600) ~/ 60;
  final sec = total % 60;
  if (h > 0) return '$h时$m分$sec秒';
  return '$m分$sec秒';
}

String _fmtToken(int n) {
  if (n <= 0) return '0';
  if (n >= 1000000) {
    return '${(n / 1000000).toStringAsFixed(n >= 10000000 ? 1 : 2)}M';
  }
  if (n >= 10000) return '${(n / 1000).toStringAsFixed(n >= 100000 ? 0 : 1)}K';
  return '$n';
}

// ---------------------------------------------------------------------------
// Markdown 渲染（表格 / 代码块 / 标题 / 加粗 / 列表 / 引用）——
// 对齐电脑端气泡：之前手机端是 SelectableText 直出原始 Markdown，
// 看到的是 "| 维度 | 现状 |"、"## 一、"、** 这类记号，和电脑端差很多。
// ---------------------------------------------------------------------------
final MarkdownStyleSheet _bubbleMarkdownStyle = MarkdownStyleSheet(
  p: const TextStyle(fontSize: 15, height: 1.45, color: Colors.white),
  a: const TextStyle(
      fontSize: 15,
      height: 1.45,
      color: Color(0xFF8AB4F8),
      decoration: TextDecoration.underline),
  em: const TextStyle(
      fontSize: 15, height: 1.45, color: Colors.white, fontStyle: FontStyle.italic),
  strong: const TextStyle(
      fontSize: 15, height: 1.45, color: Colors.white, fontWeight: FontWeight.w700),
  h1: const TextStyle(fontSize: 21, height: 1.3, color: Colors.white, fontWeight: FontWeight.w700),
  h2: const TextStyle(fontSize: 18.5, height: 1.3, color: Colors.white, fontWeight: FontWeight.w700),
  h3: const TextStyle(fontSize: 16.5, height: 1.3, color: Colors.white, fontWeight: FontWeight.w700),
  h4: const TextStyle(fontSize: 15.5, color: Colors.white, fontWeight: FontWeight.w700),
  h5: const TextStyle(fontSize: 15, color: Colors.white, fontWeight: FontWeight.w700),
  h6: const TextStyle(fontSize: 14.5, color: Colors.white, fontWeight: FontWeight.w700),
  code: const TextStyle(
      fontSize: 12.5, fontFamily: 'monospace', color: Color(0xFFE8E8EC)),
  codeblockDecoration: BoxDecoration(
    color: const Color(0xFF0F1524),
    borderRadius: BorderRadius.circular(8),
    border: Border.all(color: Colors.white24, width: 0.6),
  ),
  codeblockPadding: const EdgeInsets.all(10),
  blockquote: const TextStyle(fontSize: 15, height: 1.45, color: Colors.white70),
  blockquoteDecoration: const BoxDecoration(
    color: Color(0x22FFFFFF),
    border: Border(left: BorderSide(color: Colors.white38, width: 3)),
  ),
  blockquotePadding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
  listBullet: const TextStyle(fontSize: 15, height: 1.45, color: Colors.white),
  listBulletPadding: const EdgeInsets.only(right: 6),
  listIndent: 22,
  tableBorder: TableBorder.all(color: Colors.white24, width: 0.6),
  // 列宽按内容自适应（内容太宽时才回退等分）。以前一律等分，会把
  // 「2029年预计 1.4万亿美元」这种挤成 4~5 行，很难看。
  tableCellsPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
  tableHead: const TextStyle(
      fontSize: 14, color: Colors.white, fontWeight: FontWeight.w700, height: 1.25),
  tableBody: const TextStyle(fontSize: 14, height: 1.3, color: Colors.white),
  tableColumnWidth: const IntrinsicColumnWidth(),
  horizontalRuleDecoration: const BoxDecoration(
    border: Border(top: BorderSide(color: Colors.white24)),
  ),
  blockSpacing: 8,
);

/// 正文里残留的思考标记要清掉：有些模型/中转会把思考包成
/// `<thinking>...</thinking>` 或 ` thinking...` 直接塞进正文，
/// 手机端以前原样渲染，气泡开头就出现一堆 `<thinking></thinking>` 代码。
///
/// 只做「删标记 + 删成对内容」这一步：思考正文本身由电脑端放在
/// 气泡上方的折叠块（desktopMeta.reasoning），不在这里重复展示。
String _stripThinkingTags(String s) {
  if (s.isEmpty) return s;
  var out = s;
  // <thinking>...</thinking> / <reasoning>...</reasoning>（含换行，非贪婪）
  out = out.replaceAll(
      RegExp(r'<(thinking|reasoning|thought)>[\s\S]*?</\1>', caseSensitive: false), '');
  // 未闭合的残留：<thinking> ... 直到结尾；以及单独的孤立标签
  out = out.replaceAll(
      RegExp(r'<(thinking|reasoning|thought)>[\s\S]*$', caseSensitive: false), '');
  out = out.replaceAll(
      RegExp(r'</(thinking|reasoning|thought)>', caseSensitive: false), '');
  out = out.replaceAll(
      RegExp(r'<(thinking|reasoning|thought)\s*/?>', caseSensitive: false), '');
  // 另一种常见写法：思考内容直接包在 <thinking ...> 里但无闭合 —— 上面已覆盖。
  return out.trim();
}

/// 用 Markdown 渲染气泡正文（支持 GFM 表格 / 代码块 / 标题 / 加粗 / 列表）。
class _MarkdownText extends StatelessWidget {
  final String text;
  const _MarkdownText({required this.text});

  @override
  Widget build(BuildContext context) {
    final data = _stripThinkingTags(text);
    if (data.isEmpty) return const SizedBox.shrink();
    return MarkdownBody(
      data: data,
      selectable: true,
      extensionSet: md.ExtensionSet.gitHubFlavored,
      styleSheet: _bubbleMarkdownStyle,
      // ⚠️ 默认会把 ![](http://…) 渲染成 Image.network，也就是**手机直接去
      // 请求任意远端地址** —— 谁给气泡里塞一条图片链接，谁就能拿到你的 IP、
      // 判断你是否在线、做追踪像素。这里改成不联网：只显示一个占位块，
      // 把地址（截断）显示出来，需要看图时用户自己决定。
      imageBuilder: (uri, title, alt) => _blockedImage(context, uri, alt),
    );
  }

  /// 被屏蔽的远端图片占位（不发起任何网络请求）。
  Widget _blockedImage(BuildContext context, Uri uri, String? alt) {
    final shown = uri.toString();
    final brief = shown.length > 60 ? '${shown.substring(0, 60)}…' : shown;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF1B1F2B),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFF2A3040)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.image_not_supported_outlined,
              size: 15, color: Colors.white38),
          const SizedBox(width: 8),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('已屏蔽外部图片（防止链接被用来追踪你的 IP）',
                    style: TextStyle(fontSize: 11.5, color: Colors.white54)),
                if (alt != null && alt.trim().isNotEmpty)
                  Text(alt.trim(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 11, color: Colors.white38)),
                Text(brief,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 10.5, color: Colors.white24)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 工具调用折叠块（默认收起）：
/// 收起时只显示「🔧 工具名 [状态]」，执行中显示转圈；
/// 点一下展开看参数 / 结果（超长可滚动，不会把气泡撑爆）。
class _ToolCallsBlock extends StatefulWidget {
  final List<ToolCallMeta> calls;
  const _ToolCallsBlock({required this.calls});

  @override
  State<_ToolCallsBlock> createState() => _ToolCallsBlockState();
}

class _ToolCallsBlockState extends State<_ToolCallsBlock> {
  final Set<int> _expanded = <int>{};

  @override
  Widget build(BuildContext context) {
    if (widget.calls.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < widget.calls.length; i++)
            _buildOne(i, widget.calls[i]),
        ],
      ),
    );
  }

  Widget _buildOne(int i, ToolCallMeta c) {
    final open = _expanded.contains(i);
    final running = c.isRunning;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Material(
        color: const Color(0x14FFFFFF),
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: c.hasDetail
              ? () => setState(() {
                    if (open) {
                      _expanded.remove(i);
                    } else {
                      _expanded.add(i);
                    }
                  })
              : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.build_outlined,
                        size: 13, color: Colors.amberAccent),
                    const SizedBox(width: 5),
                    Flexible(
                      child: Text(
                        c.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 11.5, color: Colors.white70),
                      ),
                    ),
                    if (c.statusLabel.isNotEmpty) ...[
                      const SizedBox(width: 5),
                      Text(
                        '[${c.statusLabel}]',
                        style: TextStyle(
                            fontSize: 11,
                            color:
                                running ? Colors.amberAccent : Colors.white38),
                      ),
                    ],
                    if (running) ...[
                      const SizedBox(width: 5),
                      const SizedBox(
                        width: 10,
                        height: 10,
                        child: CircularProgressIndicator(strokeWidth: 1.5),
                      ),
                    ],
                    if (c.hasDetail) ...[
                      const SizedBox(width: 3),
                      Icon(open ? Icons.expand_less : Icons.expand_more,
                          size: 14, color: Colors.white38),
                    ],
                  ],
                ),
                if (open && c.hasDetail)
                  Padding(
                    padding: const EdgeInsets.only(top: 5),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 240),
                      child: SingleChildScrollView(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (c.args.isNotEmpty) ...[
                              const Text('参数',
                                  style: TextStyle(
                                      fontSize: 10.5, color: Colors.white38)),
                              SelectableText(
                                c.args,
                                style: const TextStyle(
                                    fontSize: 11,
                                    color: Colors.white60,
                                    height: 1.4),
                              ),
                            ],
                            if (c.result.isNotEmpty) ...[
                              const SizedBox(height: 6),
                              const Text('结果',
                                  style: TextStyle(
                                      fontSize: 10.5, color: Colors.white38)),
                              SelectableText(
                                c.result,
                                style: const TextStyle(
                                    fontSize: 11,
                                    color: Colors.white60,
                                    height: 1.4),
                              ),
                            ],
                          ],
                        ),
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
}

/// 思考内容折叠区（对齐电脑端气泡上方的 Thinking 块）。
/// 默认收起，点标题行展开/收起。
class _ThinkingBlock extends StatefulWidget {
  final String text;
  const _ThinkingBlock({required this.text});

  @override
  State<_ThinkingBlock> createState() => _ThinkingBlockState();
}

class _ThinkingBlockState extends State<_ThinkingBlock> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final t = widget.text.trim();
    if (t.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: const Color(0x1AFFFFFF),
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => setState(() => _expanded = !_expanded),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.psychology_alt_outlined,
                        size: 13, color: Colors.white54),
                    const SizedBox(width: 5),
                    const Text('思考内容',
                        style: TextStyle(fontSize: 11.5, color: Colors.white54)),
                    const SizedBox(width: 2),
                    Icon(_expanded ? Icons.expand_less : Icons.expand_more,
                        size: 14, color: Colors.white38),
                  ],
                ),
                if (_expanded)
                  Padding(
                    padding: const EdgeInsets.only(top: 5),
                    child: SelectableText(
                      t,
                      style: const TextStyle(
                          fontSize: 12, height: 1.45, color: Colors.white60),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// token 用量文案（输入 x · 输出 y，有思考时中间加「思考 z」）。
/// 没有 token 数据返回空串。现在显示在操作按钮同一行（_ActionBar），
/// 所以 _MetaLine 不再输出它。
String _tokenLine(ChatMessage msg) {
  final t = msg.desktopMeta?.tokens;
  if (t == null || t.isEmpty) return '';
  final inT = _fmtToken(t.prompt);
  final outT = _fmtToken(t.completion);
  final reasonT = _fmtToken(t.reasoning);
  return reasonT.isNotEmpty && t.reasoning > 0
      ? '输入 $inT · 思考 $reasonT · 输出 $outT'
      : '输入 $inT · 输出 $outT';
}

/// 气泡底部的元信息：**只给用户自己发的消息**显示时间（+耗时）。
///
/// assistant 的时间已经挪到「模型名下面」、token 已经挪到操作按钮同一行；
/// ⚠️ 这里曾经是 `outgoing || meta == null`：pending 气泡（meta 还没到）会在
/// 头部和底部各显示一次时间 —— 就是「电脑端正在处理」出现两个时间的原因。
class _MetaLine extends StatelessWidget {
  final ChatMessage msg;
  final bool outgoing;
  const _MetaLine({required this.msg, required this.outgoing});

  @override
  Widget build(BuildContext context) {
    final meta = msg.desktopMeta;

    // 时间：AI 消息优先用电脑端 startTime，否则用本地时间
    final startMs = (meta != null && meta.startTime > 0)
        ? meta.startTime
        : msg.time.millisecondsSinceEpoch;

    // 耗时
    final duration = (meta != null && meta.startTime > 0 && meta.endTime > meta.startTime)
        ? _fmtDurationMs(meta.endTime - meta.startTime)
        : '';

    // 只给用户消息输出时间行；assistant 完全交给头部 + 操作栏。
    if (!outgoing) return const SizedBox.shrink();
    if (startMs <= 0) return const SizedBox.shrink();

    final line = duration.isNotEmpty
        ? '${_fmtClock(startMs)} ($duration)'
        : _fmtClock(startMs);

    return Padding(
      padding: const EdgeInsets.only(top: 5),
      child: Text(line,
          style: const TextStyle(fontSize: 10.5, color: Colors.white38)),
    );
  }
}

/// 电脑端 ask_user_choice 提问的选项面板。
///
/// 一题一屏：顶部「问题 X / N」+ 圆点翻页（点圆点直接跳题），只渲染当前题的选项。
/// 点选项只记录选择（高亮），不立即提交；底部「上一题 / 下一题」+ 右侧「提交」。
/// 全部选完点提交才回传电脑端（每题一条 {questionIndex,type:'select',selected:[label]}）；
/// 提交后本地记录"已选择"，选项区隐藏，避免重复点选。
class _ChoicePanel extends StatefulWidget {
  final ChatMessage msg;
  const _ChoicePanel({required this.msg});

  @override
  State<_ChoicePanel> createState() => _ChoicePanelState();
}

class _ChoicePanelState extends State<_ChoicePanel> {
  /// 每题选中的 label（问题下标 -> label）。
  final Map<int, String> _selected = {};

  /// 当前显示第几题。
  int _qi = 0;

  /// 把当前题下标夹到合法范围，避免电脑端数据变化导致越界。
  int _clampedQi(int total) {
    if (total <= 0) return 0;
    if (_qi < 0) return 0;
    if (_qi >= total) return total - 1;
    return _qi;
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final msg = widget.msg;
    final choice = msg.choice;
    if (choice == null || !choice.isValid) return const SizedBox.shrink();

    // 已提交：保持「已选择：xxx」展示。
    // 先按本地消息 id 查；查不到再按电脑端 toolCallId 兜底
    // （消息被电脑端更新/重建后本地 id 会变，toolCallId 不会），
    // 否则会出现「提交完回头看又变回没选」。
    final submitted =
        state.submittedChoiceFor(msg.id) ?? state.submittedChoiceForTool(choice.toolCallId);
    if (submitted != null && submitted.isNotEmpty) {
      return _submittedBox(submitted);
    }

    final questions = choice.questions;
    final total = questions.length;
    if (total == 0) return const SizedBox.shrink();
    final qi = _clampedQi(total);
    final q = questions[qi];

    // 只统计「有选项」的题：无选项的题不阻塞提交。
    var hasAnyOption = false;
    final unanswered = <int>[];
    for (var i = 0; i < total; i++) {
      if (questions[i].options.isEmpty) continue;
      hasAnyOption = true;
      final picked = _selected[i];
      if (picked == null || picked.isEmpty) unanswered.add(i);
    }
    final canSubmit = hasAnyOption && unanswered.isEmpty;

    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
        decoration: BoxDecoration(
          color: const Color(0xFF1D2438),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: const Color(0xFF3A46C9)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 顶部：问题 X / N + 圆点翻页
            Row(
              children: [
                Text('问题 ${qi + 1} / $total',
                    style: const TextStyle(
                        fontSize: 12,
                        color: Colors.white54,
                        fontWeight: FontWeight.w600)),
                const Spacer(),
                if (total > 1)
                  Row(
                    children: [
                      for (var i = 0; i < total; i++)
                        GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => setState(() => _qi = i),
                          child: Container(
                            margin: const EdgeInsets.symmetric(horizontal: 3),
                            width: 8,
                            height: 8,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: i == qi
                                  ? Colors.lightBlueAccent
                                  : Colors.white24,
                            ),
                          ),
                        ),
                    ],
                  ),
              ],
            ),
            // 题干
            if (q.header.isNotEmpty || q.question.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8, bottom: 8),
                child: Text(
                  [
                    if (q.header.isNotEmpty) q.header,
                    if (q.question.isNotEmpty) q.question,
                  ].join('：'),
                  style: const TextStyle(
                      fontSize: 13.5, fontWeight: FontWeight.w600),
                ),
              ),
            // 当前题的选项
            if (q.options.isEmpty)
              const Padding(
                padding: EdgeInsets.only(bottom: 8),
                child: Text('（无可选项）',
                    style: TextStyle(fontSize: 12.5, color: Colors.white38)),
              )
            else
              ...q.options.map((o) => _optionTile(qi, o)),
            // 底部：上一题 / 下一题 + 提交
            Row(
              children: [
                TextButton(
                  onPressed: qi > 0 ? () => setState(() => _qi = qi - 1) : null,
                  child: const Text('上一题'),
                ),
                TextButton(
                  onPressed:
                      qi < total - 1 ? () => setState(() => _qi = qi + 1) : null,
                  child: const Text('下一题'),
                ),
                const Spacer(),
                FilledButton(
                  onPressed: canSubmit ? () => _submit(state, choice) : null,
                  child: Text(canSubmit ? '提交' : '还有 ${unanswered.length} 题未选'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// 已提交后的展示（和旧版一致）。
  Widget _submittedBox(String submitted) {
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: const Color(0xFF1D2438),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: const Color(0xFF3A46C9)),
        ),
        child: Row(
          children: [
            const Icon(Icons.check_circle_outline,
                size: 16, color: Colors.greenAccent),
            const SizedBox(width: 8),
            Expanded(
              child: Text('已选择：$submitted',
                  style: const TextStyle(fontSize: 13.5)),
            ),
          ],
        ),
      ),
    );
  }

  /// 一个选项格子（选中态高亮）。
  Widget _optionTile(int qi, ChoiceOption o) {
    final label = o.label;
    final picked = _selected[qi] == label;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: picked ? const Color(0xFF3A46C9) : const Color(0xFF2A3148),
        borderRadius: BorderRadius.circular(9),
        child: InkWell(
          borderRadius: BorderRadius.circular(9),
          // 点选项只记录选择，不提交
          onTap: () => setState(() => _selected[qi] = label),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  picked
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  size: 16,
                  color: picked ? Colors.white : Colors.lightBlueAccent,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(label, style: const TextStyle(fontSize: 13.5)),
                      if (o.description.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 3),
                          child: Text(o.description,
                              style: const TextStyle(
                                  fontSize: 12, color: Colors.white54)),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 全部选完点提交：每题一条 responses，displayText 用 ' / ' 连接各题 label。
  void _submit(AppState state, ChoiceMeta choice) {
    final msg = widget.msg;
    final cid = msg.conversationId ?? state.activeConversationId ?? '';
    final responses = <Map<String, dynamic>>[];
    final labels = <String>[];
    for (var i = 0; i < choice.questions.length; i++) {
      final picked = _selected[i];
      if (picked == null || picked.isEmpty) continue;
      responses.add({
        'questionIndex': i,
        'type': 'select',
        'selected': [picked],
      });
      labels.add(picked);
    }
    if (responses.isEmpty) return;
    state.submitChoiceOnDesktop(
      cid,
      choice.toolCallId,
      {'responses': responses},
      messageId: msg.id,
      displayText: labels.join(' / '),
    );
  }
}

/// 气泡底部的操作按钮：复制 / 重新回答 / 删除这条。
///
/// 对应电脑端 ChatMessage.vue 的 footer-actions。
/// 「重新回答」「删除这条」需要电脑端那条消息的定位信息（desktopMeta），
/// 只有电脑端回传的 AI 回复才有；普通消息至少能「复制」。
class _ActionBar extends StatelessWidget {
  final ChatMessage msg;
  final bool outgoing;
  final bool isLast;
  const _ActionBar({
    required this.msg,
    required this.outgoing,
    this.isLast = false,
  });

  @override
  Widget build(BuildContext context) {
    // 用 watch 而不是 read：重答/删除的等待状态变了要重建这个按钮（转圈）
    final state = context.watch<AppState>();
    final reasking = state.isReasking(msg.id);

    // 「重新回答」只对电脑端回传的 AI 回复、且是最后一条时显示
    // （电脑端的 reaskAI 内部只允许重答最后一条）
    final canReask = !outgoing &&
        msg.role == ChatRole.assistant &&
        msg.isDesktopAssistant &&
        isLast;
    // 「删除这条」只要拿到电脑端定位就行 —— **自己发的消息也算**
    // （电脑端 append 后会回传位置，手机据此挂上 desktopMeta）
    final canDelete = msg.desktopMeta?.isValid ?? false;

    // token 用量：和操作图标同一行，放在图标**右侧**（用户消息没有 token，返回空串）
    final tokenStr = _tokenLine(msg);

    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _act(context, Icons.copy_rounded, '复制', () async {
            await Clipboard.setData(ClipboardData(text: _stripThinkingTags(msg.text)));
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                content: Text('已复制'),
                duration: Duration(seconds: 1),
              ));
            }
          }),
          if (canReask)
            // 点完就转圈，不弹任何弹窗；转圈持续到电脑端回结果（失败时由
            // HomeShell 统一弹出原因，成功时新回复会覆盖掉这条旧的）。
            _act(
              context,
              Icons.refresh_rounded,
              reasking ? '重新回答中' : '重新回答',
              reasking
                  ? null
                  : () {
                      context.read<AppState>().reaskChatMessage(msg);
                    },
              busy: reasking,
            ),
          if (canDelete)
            _act(context, Icons.delete_outline_rounded, '删除这条', () async {
              final state = context.read<AppState>();
              final yes = await showDialog<bool>(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: const Text('删除这条消息'),
                  content: const Text('将从电脑端这个会话里删除这条消息，不可撤销。'),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(ctx, false),
                        child: const Text('取消')),
                    FilledButton(
                      style:
                          FilledButton.styleFrom(backgroundColor: Colors.redAccent),
                      onPressed: () => Navigator.pop(ctx, true),
                      child: const Text('删除'),
                    ),
                  ],
                ),
              );
              if (yes != true) return;
              final ok = state.deleteChatMessage(msg);
              if (context.mounted && !ok) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                  content: Text('删除失败（电脑端未连接该会话）'),
                ));
              }
            }, danger: true),
          // token 用量放在操作图标**右侧**；用 Flexible 防止长文案把气泡撑破
          if (tokenStr.isNotEmpty)
            Flexible(
              child: Padding(
                padding: const EdgeInsets.only(left: 6),
                child: Text(
                  tokenStr,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 10.5, color: Colors.white38),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// 一个小操作按钮。onTap 为 null 表示不可点（busy 时转圈）。
  Widget _act(BuildContext context, IconData icon, String label,
      VoidCallback? onTap, {bool danger = false, bool busy = false}) {
    final color = busy
        ? Colors.lightBlueAccent
        : (danger ? Colors.redAccent : Colors.white54);
    // 只显示图标（文字放到长按提示里）—— 界面更干净，
    // 也不会因为中文标签把气泡底部撑得很宽。
    return Padding(
      padding: const EdgeInsets.only(right: 2),
      child: Tooltip(
        message: label,
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
            child: busy
                ? SizedBox(
                    width: 15,
                    height: 15,
                    child: CircularProgressIndicator(
                      strokeWidth: 1.8,
                      valueColor: AlwaysStoppedAnimation(color),
                    ),
                  )
                : Icon(icon, size: 16, color: color),
          ),
        ),
      ),
    );
  }
}

class _Composer extends StatelessWidget {
  final TextEditingController controller;
  final VoidCallback onSend;
  final VoidCallback? onStop;
  final VoidCallback? onAttach;
  final bool uploading;
  final bool awaiting;

  const _Composer({
    required this.controller,
    required this.onSend,
    required this.onStop,
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
              tooltip: onStop != null ? '暂停生成' : '发送',
              style: onStop != null
                  ? IconButton.styleFrom(backgroundColor: Colors.redAccent)
                  : null,
              onPressed: onStop ?? onSend,
              icon: Icon(onStop != null ? Icons.stop_rounded : Icons.send),
            ),
          ],
        ),
      ),
    );
  }
}
