import 'dart:async';

import 'package:flutter/material.dart';
import 'package:ordi_audio/ordi_audio.dart' show OrdiState;

import '../main.dart';
import '../models/conversation_log.dart';
import '../ordi/ordi_controller.dart';
import '../ui/surface.dart';
import '../ui/time_format.dart';
import '../ui/tokens.dart';

/// A conversation as a chat: what was said, and a box to carry on typing.
///
/// Opened from History on a past conversation (its exchanges are shown and
/// anything typed goes back into it), or from Conversate as a new chat. What
/// is typed is answered like speech — the reply streams in as text and is
/// spoken, unless replies are switched off here — and is recorded in History
/// like any other exchange.
class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key, this.session});

  /// The conversation to continue, or null to start a new one.
  final ConversationSession? session;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final TextEditingController _field = TextEditingController();
  final ScrollController _scroll = ScrollController();

  OrdiController? _controller;
  ConversationLog? _log;

  /// The conversation being typed into. Null until a new chat's first answer
  /// has been recorded.
  ConversationSession? _session;

  /// The question just sent and not yet answered, and when it was sent.
  String? _awaiting;
  DateTime _sentAt = DateTime.now();

  /// When this screen opened: anything recorded after it, in a chat that has
  /// no conversation yet, is the answer to something typed here.
  final DateTime _openedAt = DateTime.now();
  bool _sawBusy = false;
  Timer? _silent;

  /// A line under the thread: why a question was not answered.
  String? _note;

  /// Whether the earlier words of an opened conversation have gone to
  /// Ordinary yet. A fresh session knows none of them.
  bool _contextSent = false;

  @override
  void initState() {
    super.initState();
    _session = widget.session;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_controller != null) return;
    _controller = OrdiScope.maybeOf(context);
    _log = OrdiScope.maybeLogOf(context);
    _log?.addListener(_onLog);
    _controller?.reading.addListener(_onReading);
  }

  @override
  void dispose() {
    _silent?.cancel();
    _log?.removeListener(_onLog);
    _controller?.reading.removeListener(_onReading);
    // Leaving the chat must not leave the next spoken answer muted.
    _controller?.setRepliesMuted(false);
    _field.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// A new exchange was recorded: if it is the one being waited for, it is
  /// an answer now rather than a pending bubble.
  void _onLog() {
    final log = _log;
    if (log == null || log.sessions.isEmpty) return;
    // The conversation a typed question lands in is the latest one.
    final latest = log.sessions.first;
    if (latest.entries.isEmpty) return;
    final last = latest.entries.last;

    // A new chat has no conversation until its first answer is recorded —
    // which can come after a "no answer" note was shown, if the reply was
    // slow. Pick it up either way.
    if (_session == null && !last.at.isBefore(_openedAt)) {
      _silent?.cancel();
      setState(() {
        _session = latest;
        _awaiting = null;
        _note = null;
      });
      _toBottom();
      return;
    }

    final waiting = _awaiting;
    if (waiting == null) return;
    if (last.question != waiting || last.at.isBefore(_sentAt)) return;
    _silent?.cancel();
    setState(() {
      _awaiting = null;
      _note = null;
    });
    _toBottom();
  }

  /// Ordinary went quiet without an answer being recorded — it chose not to
  /// reply, or the reply never came. Say so rather than leave a bubble
  /// waiting for ever.
  void _onReading() {
    final state = _controller?.reading.value.state;
    if (state == OrdiState.thinking || state == OrdiState.speaking) {
      _sawBusy = true;
      // It is answering after all: the engine goes idle for a moment while a
      // session finishes opening, before the reply starts.
      _silent?.cancel();
      return;
    }
    if (state != OrdiState.idle || !_sawBusy || _awaiting == null) return;
    _silent?.cancel();
    // Long enough for a reply that was waiting on a tool, or on a session
    // that was still opening, to begin.
    _silent = Timer(const Duration(seconds: 8), () {
      if (!mounted || _awaiting == null) return;
      setState(() {
        _awaiting = null;
        _note = "Ordinary didn't answer that. Try asking it another way.";
      });
    });
  }

  void _toBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    });
  }

  /// A few words of what was said last, for a session that has not heard it.
  String? _earlierWords() {
    final session = _session;
    if (session == null || session.entries.isEmpty || _contextSent) return null;
    String clip(String text) {
      final t = text.trim();
      return t.length <= 140 ? t : '${t.substring(0, 140).trimRight()}…';
    }

    final recent = session.entries.length <= 2
        ? session.entries
        : session.entries.sublist(session.entries.length - 2);
    final said = recent
        .map((e) => 'they asked "${clip(e.question)}" and you said '
            '"${clip(e.answer)}"')
        .join('; ');
    return 'earlier in this conversation: $said';
  }

  Future<void> _send() async {
    final text = _field.text.trim();
    final controller = _controller;
    if (text.isEmpty || controller == null || _awaiting != null) return;
    final context = _earlierWords();
    _field.clear();
    setState(() {
      _awaiting = text;
      _sentAt = DateTime.now();
      _sawBusy = false;
      _note = null;
    });
    _toBottom();
    final ok = await controller.askText(text, into: _session, context: context);
    if (!mounted) return;
    if (ok) {
      _contextSent = true;
    } else {
      // Nothing was sent: give the words back so they are not lost.
      setState(() {
        _awaiting = null;
        _field.text = text;
        _field.selection = TextSelection.collapsed(offset: text.length);
        _note = controller.problem ??
            "Ordinary isn't available right now. Check your connection and "
                'try again.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    final entries = _session?.entries ?? const <ConversationEntry>[];
    return Backdrop(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        resizeToAvoidBottomInset: true,
        appBar: screenBar(
          context,
          text: _session?.displayTitle ?? 'New chat',
          actions: [
            if (controller != null)
              AnimatedBuilder(
                animation: controller,
                builder: (context, _) => IconButton(
                  tooltip: controller.repliesMuted
                      ? 'Spoken replies are off'
                      : 'Spoken replies are on',
                  icon: Icon(
                    controller.repliesMuted
                        ? Icons.volume_off_rounded
                        : Icons.volume_up_rounded,
                    color: Tokens.text,
                    size: 24,
                  ),
                  onPressed: () =>
                      controller.setRepliesMuted(!controller.repliesMuted),
                ),
              ),
            const SizedBox(width: Tokens.x2),
          ],
        ),
        body: SafeArea(
          top: false,
          child: Column(
            children: [
              Expanded(child: _thread(entries)),
              _composer(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _thread(List<ConversationEntry> entries) {
    final summary = _session?.summary;
    final controller = _controller;
    final empty = entries.isEmpty && _awaiting == null;
    return ListView(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(
          Tokens.gutter, Tokens.x2, Tokens.gutter, Tokens.x4),
      children: [
        if (summary != null && summary.trim().isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: Tokens.x4),
            child: Surface(
              radius: 20,
              padding: const EdgeInsets.all(Tokens.x4),
              child: Text(summary,
                  style: Tokens.body.copyWith(fontSize: 14.5, height: 1.55)),
            ),
          ),
        if (empty)
          Padding(
            padding: const EdgeInsets.only(top: Tokens.x10),
            child: Text(
              'Type a message to Ordinary. It answers here, and out loud '
              'unless you turn the speaker off.',
              textAlign: TextAlign.center,
              style: Tokens.body.copyWith(color: Tokens.textFaint),
            ),
          ),
        for (final entry in entries) ...[
          _Bubble(text: entry.question, mine: true, at: entry.at),
          _Bubble(text: entry.answer, mine: false),
        ],
        if (_awaiting != null) ...[
          _Bubble(text: _awaiting!, mine: true),
          if (controller != null)
            ValueListenableBuilder<String>(
              valueListenable: controller.transcript,
              builder: (context, live, _) =>
                  _Bubble(text: live.trim().isEmpty ? '…' : live, mine: false),
            )
          else
            const _Bubble(text: '…', mine: false),
        ],
        if (_note != null)
          Padding(
            padding: const EdgeInsets.only(top: Tokens.x2),
            child: Text(
              _note!,
              textAlign: TextAlign.center,
              style: Tokens.caption.copyWith(color: Tokens.danger),
            ),
          ),
      ],
    );
  }

  Widget _composer() {
    final busy = _awaiting != null;
    return Container(
      padding: const EdgeInsets.fromLTRB(
          Tokens.gutter, Tokens.x2, Tokens.gutter, Tokens.x3),
      decoration: const BoxDecoration(
        color: Tokens.paper,
        border: Border(top: BorderSide(color: Tokens.ruleSoft)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: TextField(
              controller: _field,
              minLines: 1,
              maxLines: 4,
              textCapitalization: TextCapitalization.sentences,
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => _send(),
              style: Tokens.body.copyWith(fontSize: 16, color: Tokens.text),
              decoration: InputDecoration(
                hintText: 'Message Ordinary',
                hintStyle: Tokens.body
                    .copyWith(fontSize: 16, color: Tokens.textFaint),
                filled: true,
                fillColor: Tokens.paper2,
                contentPadding: const EdgeInsets.symmetric(
                    horizontal: Tokens.x4, vertical: Tokens.x3),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(Tokens.rLarge),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          const SizedBox(width: Tokens.x2),
          Semantics(
            button: true,
            label: 'Send',
            child: GestureDetector(
              onTap: busy ? null : _send,
              child: Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: busy ? Tokens.rule : Tokens.text,
                ),
                child: const Icon(Icons.arrow_upward_rounded,
                    color: Tokens.accentInk, size: 24),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// One message: what the person said on the right, Ordinary's reply on the
/// left.
class _Bubble extends StatelessWidget {
  const _Bubble({required this.text, required this.mine, this.at});

  final String text;
  final bool mine;
  final DateTime? at;

  @override
  Widget build(BuildContext context) {
    final maxWidth = MediaQuery.sizeOf(context).width * 0.8;
    return Padding(
      padding: const EdgeInsets.only(bottom: Tokens.x2),
      child: Column(
        crossAxisAlignment:
            mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          if (at != null)
            Padding(
              padding: const EdgeInsets.only(top: Tokens.x2, bottom: 4),
              child: Text(dayTimeLabel(at!), style: Tokens.caption),
            ),
          Container(
            constraints: BoxConstraints(maxWidth: maxWidth),
            padding: const EdgeInsets.symmetric(
                horizontal: Tokens.x4, vertical: Tokens.x3),
            decoration: BoxDecoration(
              color: mine ? Tokens.text : Tokens.paper2,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              text,
              style: Tokens.body.copyWith(
                fontSize: 15,
                height: 1.45,
                color: mine ? Tokens.accentInk : Tokens.text,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
