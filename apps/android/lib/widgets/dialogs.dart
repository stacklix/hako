import 'package:flutter/material.dart';

import '../models/app_models.dart';

class TrustedNumberDialog extends StatefulWidget {
  const TrustedNumberDialog({super.key, this.initialValue});

  final TrustedNumber? initialValue;

  @override
  State<TrustedNumberDialog> createState() => _TrustedNumberDialogState();
}

class _TrustedNumberDialogState extends State<TrustedNumberDialog> {
  final TextEditingController _controller = TextEditingController();

  @override
  void initState() {
    super.initState();
    final initialValue = widget.initialValue;
    _controller.text = initialValue?.number ?? '';
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.initialValue == null ? '添加可信号码' : '编辑可信号码'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _controller,
            autofocus: true,
            keyboardType: TextInputType.phone,
            decoration: const InputDecoration(
              labelText: '手机号',
              hintText: '+86 13800138000',
            ),
          ),
        ],
      ),
      actions: [
        if (widget.initialValue != null)
          TextButton(
            onPressed: () => Navigator.of(
              context,
            ).pop(const TrustedNumberDialogResult.delete()),
            child: const Text('删除'),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () {
            Navigator.of(context).pop(
              TrustedNumberDialogResult.save(
                TrustedNumber(number: _controller.text.trim()),
              ),
            );
          },
          child: const Text('保存'),
        ),
      ],
    );
  }
}

class TextValueDialog extends StatefulWidget {
  const TextValueDialog({
    super.key,
    required this.title,
    required this.label,
    required this.hint,
  });

  final String title;
  final String label;
  final String hint;

  @override
  State<TextValueDialog> createState() => _TextValueDialogState();
}

class _TextValueDialogState extends State<TextValueDialog> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _controller,
        autofocus: true,
        decoration: InputDecoration(
          labelText: widget.label,
          hintText: widget.hint,
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_controller.text.trim()),
          child: const Text('保存'),
        ),
      ],
    );
  }
}

class SmtpSettingsDialog extends StatefulWidget {
  const SmtpSettingsDialog({super.key, this.initialValue});

  final SmtpSettings? initialValue;

  @override
  State<SmtpSettingsDialog> createState() => _SmtpSettingsDialogState();
}

class _SmtpSettingsDialogState extends State<SmtpSettingsDialog> {
  final TextEditingController _hostController = TextEditingController();
  final TextEditingController _portController = TextEditingController();
  final TextEditingController _fromEmailController = TextEditingController();
  final TextEditingController _usernameController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  bool _showPassword = false;

  @override
  void initState() {
    super.initState();
    final initialValue = widget.initialValue;
    if (initialValue == null) {
      _portController.text = '465';
      return;
    }

    _hostController.text = initialValue.host;
    _portController.text = initialValue.effectivePort;
    _fromEmailController.text = initialValue.fromEmail;
    _usernameController.text = initialValue.username;
    _passwordController.text = initialValue.password;
  }

  @override
  void dispose() {
    _hostController.dispose();
    _portController.dispose();
    _fromEmailController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('配置发件人'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _hostController,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'SMTP Host',
                hintText: 'smtp.example.com',
              ),
            ),
            TextField(
              controller: _portController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: '端口',
                hintText: '465，留空默认 SSL',
              ),
            ),
            TextField(
              controller: _fromEmailController,
              keyboardType: TextInputType.emailAddress,
              decoration: const InputDecoration(
                labelText: '发件邮箱',
                hintText: 'sender@example.com',
              ),
            ),
            TextField(
              controller: _usernameController,
              decoration: const InputDecoration(
                labelText: '账号',
                hintText: 'sender@example.com',
              ),
            ),
            TextField(
              controller: _passwordController,
              obscureText: !_showPassword,
              decoration: InputDecoration(
                labelText: '密码/授权码',
                hintText: '应用专用密码',
                suffixIcon: IconButton(
                  tooltip: _showPassword ? '隐藏密码' : '显示密码',
                  icon: Icon(
                    _showPassword
                        ? Icons.visibility_off_outlined
                        : Icons.visibility_outlined,
                  ),
                  onPressed: () {
                    setState(() {
                      _showPassword = !_showPassword;
                    });
                  },
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () {
            Navigator.of(context).pop(
              SmtpSettings(
                host: _hostController.text.trim(),
                port: _portController.text.trim(),
                fromEmail: _fromEmailController.text.trim(),
                username: _usernameController.text.trim(),
                password: _passwordController.text,
              ),
            );
          },
          child: const Text('保存'),
        ),
      ],
    );
  }
}
