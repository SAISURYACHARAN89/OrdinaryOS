import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/account.dart';
import '../ui/surface.dart';
import '../ui/tokens.dart';

/// Where to buy, and who to write to. Plain links out of the app.
const _storeUrl = 'https://ordinarywearables.com';
const _supportEmail = 'support@ordinarywearables.com';

enum _Step { email, code, devices }

/// Signing in with the email an Ordinary was bought with: the email, then the
/// six-digit code sent to it. A third phone is asked which of the two already
/// signed in should be signed out.
class SignInFlow extends StatefulWidget {
  const SignInFlow({super.key, required this.account});

  final Account account;

  @override
  State<SignInFlow> createState() => _SignInFlowState();
}

class _SignInFlowState extends State<SignInFlow> {
  final _email = TextEditingController();
  final _code = TextEditingController();
  _Step _step = _Step.email;
  bool _busy = false;
  String? _error;

  /// The refusal that listed the phones already signed in.
  AccountFailure? _limit;

  /// Seconds until another code may be asked for.
  int _cooldown = 0;
  Timer? _tick;

  @override
  void dispose() {
    _tick?.cancel();
    _email.dispose();
    _code.dispose();
    super.dispose();
  }

  void _startCooldown() {
    _tick?.cancel();
    setState(() => _cooldown = 60);
    _tick = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) return timer.cancel();
      setState(() => _cooldown -= 1);
      if (_cooldown <= 0) timer.cancel();
    });
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } on AccountFailure catch (failure) {
      if (!mounted) return;
      if (failure.code == 'device_limit') {
        setState(() {
          _limit = failure;
          _step = _Step.devices;
        });
      } else {
        final left = failure.attemptsLeft;
        setState(() => _error = left != null && left > 0
            ? '${failure.message} $left ${left == 1 ? 'try' : 'tries'} left.'
            : failure.message);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _sendCode() => _run(() async {
        final email = _email.text.trim();
        if (!email.contains('@') || !email.contains('.')) {
          throw AccountFailure('bad_email', 'Enter a valid email address.');
        }
        await widget.account.start(email);
        if (!mounted) return;
        _code.clear();
        setState(() => _step = _Step.code);
        _startCooldown();
      });

  Future<void> _verify() => _run(() async {
        if (_code.text.trim().length != 6) {
          throw AccountFailure('bad_code', 'Enter the 6-digit code.');
        }
        await widget.account
            .verify(emailAddress: _email.text, code: _code.text);
      });

  Future<void> _replace(AccountDevice device) => _run(() async {
        await widget.account
            .verify(ticket: _limit?.ticket, replaceDeviceId: device.id);
      });

  @override
  Widget build(BuildContext context) {
    return Backdrop(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: SafeArea(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 240),
            child: ListView(
              key: ValueKey(_step),
              padding: const EdgeInsets.fromLTRB(
                  Tokens.gutter, Tokens.x4, Tokens.gutter, Tokens.x6),
              children: switch (_step) {
                _Step.email => _emailStep(),
                _Step.code => _codeStep(),
                _Step.devices => _devicesStep(),
              },
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _header(String title, String body) => [
        const SizedBox(height: 40 + Tokens.x6),
        Text(title, style: Tokens.display),
        const SizedBox(height: Tokens.x3),
        Text(body, style: Tokens.body.copyWith(fontSize: 15)),
        const SizedBox(height: Tokens.x6),
      ];

  Widget _errorLine() => _error == null
      ? const SizedBox(height: Tokens.x4)
      : Padding(
          padding: const EdgeInsets.symmetric(vertical: Tokens.x3),
          child: Text(
            _error!,
            style: Tokens.body.copyWith(fontSize: 14, color: Tokens.danger),
          ),
        );

  InputDecoration _field(String hint) => InputDecoration(
        hintText: hint,
        hintStyle: Tokens.body.copyWith(color: Tokens.textFaint),
        filled: true,
        fillColor: Tokens.paper2,
        counterText: '',
        contentPadding: const EdgeInsets.symmetric(
            horizontal: Tokens.x4, vertical: Tokens.x4),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(Tokens.rSmall),
          borderSide: BorderSide.none,
        ),
      );

  List<Widget> _emailStep() => [
        ..._header(
          'Sign in',
          'Ordinary is for people who own an Ordinary. Enter the email you '
              'used when you ordered.',
        ),
        TextField(
          controller: _email,
          autofocus: true,
          keyboardType: TextInputType.emailAddress,
          textInputAction: TextInputAction.done,
          autocorrect: false,
          enableSuggestions: false,
          autofillHints: const [AutofillHints.email],
          style: Tokens.bodyStrong.copyWith(fontSize: 16),
          decoration: _field('you@example.com'),
          onSubmitted: (_) => _sendCode(),
        ),
        _errorLine(),
        InkButton(
          label: _busy ? 'Sending…' : 'Send code',
          onPressed: _busy ? null : _sendCode,
        ),
      ];

  List<Widget> _codeStep() => [
        ..._header(
          'Check your email',
          'If ${_email.text.trim()} has an Ordinary order, a 6-digit code is on '
              'its way. If it does not, the email will say so.',
        ),
        TextField(
          controller: _code,
          autofocus: true,
          keyboardType: TextInputType.number,
          textInputAction: TextInputAction.done,
          autofillHints: const [AutofillHints.oneTimeCode],
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          maxLength: 6,
          style: Tokens.numeral.copyWith(fontSize: 26, letterSpacing: 8),
          decoration: _field('000000'),
          onChanged: (value) {
            if (value.length == 6) _verify();
          },
          onSubmitted: (_) => _verify(),
        ),
        _errorLine(),
        InkButton(
          label: _busy ? 'Checking…' : 'Sign in',
          onPressed: _busy ? null : _verify,
        ),
        const SizedBox(height: Tokens.x2),
        TextButton(
          onPressed: _busy || _cooldown > 0 ? null : _sendCode,
          child: Text(
            _cooldown > 0 ? 'Send again in ${_cooldown}s' : 'Send again',
            style: Tokens.bodyStrong.copyWith(
              color: _cooldown > 0 ? Tokens.textFaint : Tokens.textSoft,
            ),
          ),
        ),
        TextButton(
          onPressed: _busy
              ? null
              : () => setState(() {
                    _step = _Step.email;
                    _error = null;
                  }),
          child: Text(
            'Use a different email',
            style: Tokens.bodyStrong.copyWith(color: Tokens.textSoft),
          ),
        ),
      ];

  List<Widget> _devicesStep() {
    final devices = _limit?.devices ?? const <AccountDevice>[];
    return [
      ..._header(
        'Already on ${devices.length} phones',
        'Ordinary can be signed in on two phones at a time. Choose one to '
            'sign out, and this phone takes its place.',
      ),
      for (final device in devices)
        Padding(
          padding: const EdgeInsets.only(bottom: Tokens.x2),
          child: Surface(
            radius: 18,
            onTap: _busy ? null : () => _replace(device),
            padding: const EdgeInsets.symmetric(
                horizontal: Tokens.x4, vertical: Tokens.x4),
            child: Row(
              children: [
                const Icon(Icons.smartphone_rounded, size: 22, color: Tokens.text),
                const SizedBox(width: Tokens.x3),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(device.name, style: Tokens.bodyStrong),
                      if (device.lastSeenAt != null)
                        Text(
                          'Last used ${_date(device.lastSeenAt!)}',
                          style: Tokens.caption.copyWith(fontSize: 13),
                        ),
                    ],
                  ),
                ),
                Text(
                  'Sign out',
                  style: Tokens.bodyStrong.copyWith(color: Tokens.danger),
                ),
              ],
            ),
          ),
        ),
      _errorLine(),
      TextButton(
        onPressed: _busy
            ? null
            : () => setState(() {
                  _step = _Step.email;
                  _limit = null;
                  _error = null;
                }),
        child: Text(
          'Cancel',
          style: Tokens.bodyStrong.copyWith(color: Tokens.textSoft),
        ),
      ),
    ];
  }

  static const _months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];

  static String _date(DateTime when) => '${when.day} ${_months[when.month - 1]}';
}

/// Signed in, but this email has no Ordinary — or access was taken away.
class NoAccessScreen extends StatefulWidget {
  const NoAccessScreen({super.key, required this.account});

  final Account account;

  @override
  State<NoAccessScreen> createState() => _NoAccessScreenState();
}

class _NoAccessScreenState extends State<NoAccessScreen> {
  bool _busy = false;

  Future<void> _checkAgain() async {
    setState(() => _busy = true);
    try {
      await widget.account.accessToken(force: true);
    } catch (_) {
      // Offline: nothing changed, and the screen says the same thing.
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _open(String url) async {
    try {
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final email = widget.account.email ?? 'this email';
    final body = switch (widget.account.reason) {
      'revoked' || 'blocked' =>
        'Access for $email has been removed. If that looks wrong, write to '
            '$_supportEmail.',
      _ => "We couldn't find an Ordinary order for $email. If you ordered with "
          'another email, sign in with that one.',
    };
    return Backdrop(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(
                Tokens.gutter, Tokens.x4, Tokens.gutter, Tokens.x6),
            children: [
              const SizedBox(height: 40 + Tokens.x6),
              Text('Ordinary is for owners', style: Tokens.display),
              const SizedBox(height: Tokens.x3),
              Text(body, style: Tokens.body.copyWith(fontSize: 15)),
              const SizedBox(height: Tokens.x8),
              InkButton(
                label: 'Get an Ordinary',
                onPressed: () => _open(_storeUrl),
              ),
              const SizedBox(height: Tokens.x2),
              TextButton(
                onPressed: _busy ? null : _checkAgain,
                child: Text(
                  _busy ? 'Checking…' : 'I have ordered — check again',
                  style: Tokens.bodyStrong.copyWith(color: Tokens.textSoft),
                ),
              ),
              TextButton(
                onPressed: _busy ? null : widget.account.signOut,
                child: Text(
                  'Use a different email',
                  style: Tokens.bodyStrong.copyWith(color: Tokens.textSoft),
                ),
              ),
              TextButton(
                onPressed: () => _open('mailto:$_supportEmail'),
                child: Text(
                  'Contact support',
                  style: Tokens.bodyStrong.copyWith(color: Tokens.textSoft),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
