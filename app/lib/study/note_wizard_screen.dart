import 'package:flutter/material.dart';
import 'package:speech_to_text/speech_to_text.dart';

import '../ui/glass.dart';
import '../ui/tokens.dart';

/// Naming a note and writing its content as two separate steps, rather than
/// one crowded form — and the content step can be dictated instead of typed,
/// since an app built around talking to Ordi shouldn't make writing notes
/// the one place you're stuck with a keyboard.
class NoteWizardScreen extends StatefulWidget {
  const NoteWizardScreen({
    super.key,
    this.initialName = '',
    this.initialContent = '',
    this.startOnContent = false,
  });

  final String initialName;
  final String initialContent;

  /// Editing an existing note jumps straight to its content — the name is
  /// already set, and it's rarely what someone's come back to fix.
  final bool startOnContent;

  @override
  State<NoteWizardScreen> createState() => _NoteWizardScreenState();
}

class _NoteWizardScreenState extends State<NoteWizardScreen> {
  late int _step = widget.startOnContent ? 1 : 0;
  late final TextEditingController _name =
      TextEditingController(text: widget.initialName);
  late final TextEditingController _content =
      TextEditingController(text: widget.initialContent);

  final SpeechToText _speech = SpeechToText();
  bool _speechReady = false;
  bool _listening = false;
  String _contentBeforeListening = '';

  @override
  void dispose() {
    _speech.stop();
    _name.dispose();
    _content.dispose();
    super.dispose();
  }

  void _goToContent() {
    if (_name.text.trim().isEmpty) return;
    setState(() => _step = 1);
  }

  void _goBackToName() {
    if (_listening) _stopListening();
    setState(() => _step = 0);
  }

  void _save() {
    final name = _name.text.trim();
    final content = _content.text.trim();
    if (name.isEmpty || content.isEmpty) return;
    Navigator.of(context).pop((name, _content.text));
  }

  Future<void> _toggleDictation() async {
    if (_listening) {
      await _stopListening();
      return;
    }
    if (!_speechReady) {
      _speechReady = await _speech.initialize(
        onStatus: (status) {
          if ((status == 'done' || status == 'notListening') && mounted) {
            setState(() => _listening = false);
          }
        },
      );
      if (!_speechReady) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content:
                Text("Dictation isn't available on this device right now."),
          ),
        );
        return;
      }
    }
    _contentBeforeListening = _content.text;
    setState(() => _listening = true);
    await _speech.listen(
      onResult: (result) {
        final joiner = _contentBeforeListening.isEmpty ||
                _contentBeforeListening.endsWith(' ')
            ? ''
            : ' ';
        final updated =
            '$_contentBeforeListening$joiner${result.recognizedWords}';
        _content.value = TextEditingValue(
          text: updated,
          selection: TextSelection.collapsed(offset: updated.length),
        );
      },
      listenOptions: SpeechListenOptions(
        partialResults: true,
        listenMode: ListenMode.dictation,
      ),
    );
  }

  Future<void> _stopListening() async {
    await _speech.stop();
    if (mounted) setState(() => _listening = false);
  }

  @override
  Widget build(BuildContext context) {
    return Backdrop(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          leading: IconButton(
            icon: const Icon(Icons.chevron_left_rounded,
                color: Tokens.text, size: 30),
            onPressed: () => _step == 1 && !widget.startOnContent
                ? _goBackToName()
                : Navigator.of(context).maybePop(),
          ),
          title: _StepDots(step: _step),
          centerTitle: true,
        ),
        body: SafeArea(
          top: false,
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 260),
            transitionBuilder: (child, animation) => FadeTransition(
              opacity: animation,
              child: SlideTransition(
                position: Tween<Offset>(
                  begin: const Offset(0, 0.04),
                  end: Offset.zero,
                ).animate(animation),
                child: child,
              ),
            ),
            child: _step == 0
                ? _NameStep(
                    key: const ValueKey('name'),
                    controller: _name,
                    onNext: _goToContent,
                  )
                : _ContentStep(
                    key: const ValueKey('content'),
                    name: _name.text,
                    controller: _content,
                    listening: _listening,
                    onToggleDictation: _toggleDictation,
                    onSave: _save,
                  ),
          ),
        ),
      ),
    );
  }
}

/// A small pill-and-dot progress indicator — the active step reads as a
/// pill, the other as a plain dot, rather than spelling out "Step 1 of 2".
class _StepDots extends StatelessWidget {
  const _StepDots({required this.step});

  final int step;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < 2; i++)
          AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            margin: const EdgeInsets.symmetric(horizontal: 3),
            width: i == step ? 18 : 6,
            height: 6,
            decoration: BoxDecoration(
              color: i == step ? Tokens.text : Tokens.edgeLit,
              borderRadius: BorderRadius.circular(3),
            ),
          ),
      ],
    );
  }
}

class _NameStep extends StatelessWidget {
  const _NameStep({super.key, required this.controller, required this.onNext});

  final TextEditingController controller;
  final VoidCallback onNext;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding:
          const EdgeInsets.fromLTRB(Tokens.gutter, Tokens.x8, Tokens.gutter, Tokens.x6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Name this note', style: Tokens.label),
          const SizedBox(height: Tokens.x2),
          TextField(
            controller: controller,
            autofocus: true,
            style: Tokens.display,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              hintText: 'Untitled',
              hintStyle: TextStyle(color: Tokens.textFaint),
              border: InputBorder.none,
            ),
            onSubmitted: (_) => onNext(),
          ),
          const SizedBox(height: Tokens.x3),
          const Divider(color: Tokens.edgeLit, height: 1),
          const Spacer(),
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: controller,
            builder: (context, value, _) => SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: value.text.trim().isEmpty ? null : onNext,
                style: FilledButton.styleFrom(
                  backgroundColor: Tokens.text,
                  padding: const EdgeInsets.symmetric(vertical: Tokens.x3),
                ),
                child: const Text('Next'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ContentStep extends StatelessWidget {
  const _ContentStep({
    super.key,
    required this.name,
    required this.controller,
    required this.listening,
    required this.onToggleDictation,
    required this.onSave,
  });

  final String name;
  final TextEditingController controller;
  final bool listening;
  final VoidCallback onToggleDictation;
  final VoidCallback onSave;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding:
          const EdgeInsets.fromLTRB(Tokens.gutter, Tokens.x4, Tokens.gutter, Tokens.x6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(name,
              style: Tokens.heading, maxLines: 1, overflow: TextOverflow.ellipsis),
          const SizedBox(height: Tokens.x4),
          Expanded(
            child: TextField(
              controller: controller,
              autofocus: true,
              maxLines: null,
              expands: true,
              textAlignVertical: TextAlignVertical.top,
              style: Tokens.body.copyWith(
                color: Tokens.text,
                fontSize: 17,
                height: 1.5,
              ),
              decoration: const InputDecoration(
                hintText: 'Type or paste — or tap the mic to dictate',
                hintStyle: TextStyle(color: Tokens.textFaint),
                border: InputBorder.none,
              ),
            ),
          ),
          const SizedBox(height: Tokens.x4),
          if (listening)
            Padding(
              padding: const EdgeInsets.only(bottom: Tokens.x2),
              child: Text('Listening…',
                  style: Tokens.label.copyWith(color: Tokens.danger)),
            ),
          Row(
            children: [
              _DictateButton(listening: listening, onTap: onToggleDictation),
              const SizedBox(width: Tokens.x3),
              Expanded(
                child: ValueListenableBuilder<TextEditingValue>(
                  valueListenable: controller,
                  builder: (context, value, _) => FilledButton(
                    onPressed: value.text.trim().isEmpty ? null : onSave,
                    style: FilledButton.styleFrom(
                      backgroundColor: Tokens.text,
                      padding: const EdgeInsets.symmetric(vertical: Tokens.x3),
                    ),
                    child: const Text('Save'),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Glows and pulses while listening rather than just swapping an icon — the
/// one place in this screen worth a bit of life, since it's the whole reason
/// this wizard has two steps and not one.
class _DictateButton extends StatefulWidget {
  const _DictateButton({required this.listening, required this.onTap});

  final bool listening;
  final VoidCallback onTap;

  @override
  State<_DictateButton> createState() => _DictateButtonState();
}

class _DictateButtonState extends State<_DictateButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );

  @override
  void initState() {
    super.initState();
    if (widget.listening) _pulse.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(covariant _DictateButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Only ever animating while actually listening — looping unconditionally
    // from the moment this widget exists is exactly the kind of endless
    // animation that never lets a test (or, for that matter, the battery)
    // settle down.
    if (widget.listening && !oldWidget.listening) {
      _pulse.repeat(reverse: true);
    } else if (!widget.listening && oldWidget.listening) {
      _pulse
        ..stop()
        ..value = 0;
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onTap,
      child: AnimatedBuilder(
        animation: _pulse,
        builder: (context, _) {
          final t = widget.listening ? _pulse.value : 0.0;
          return Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: widget.listening ? Tokens.danger : Tokens.inkRaised,
              border: widget.listening
                  ? null
                  : Border.all(color: Tokens.edgeLit, width: 1),
              boxShadow: widget.listening
                  ? [
                      BoxShadow(
                        color: Tokens.danger.withValues(alpha: 0.35),
                        blurRadius: 10 + t * 10,
                        spreadRadius: 1 + t * 2,
                      ),
                    ]
                  : null,
            ),
            alignment: Alignment.center,
            child: Icon(
              widget.listening ? Icons.stop_rounded : Icons.mic_none_rounded,
              color: widget.listening ? Colors.white : Tokens.text,
              size: 24,
            ),
          );
        },
      ),
    );
  }
}
