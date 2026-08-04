import 'package:flutter/material.dart';

import '../../services/ha_credentials.dart';
import '../../state/home_controller.dart';
import '../../theme/tokens.dart';
import '../widgets/atoms.dart';

/// Home Assistant の接続設定。
///
/// **これが無いとアプリが起動しても何もできない**ので、home 側の第一歩。
/// 長期アクセストークンは HA の全権限を持つ本物の secret なので、ビルドには
/// 埋めず、ここで入力して Keychain に置く（`docs/…` §7）。
class HaSetupScreen extends StatefulWidget {
  const HaSetupScreen({
    super.key,
    required this.controller,
    required this.onOpenMenu,
    this.isRoot = true,
  });

  final HomeController controller;
  final VoidCallback onOpenMenu;

  /// home の入口として出しているか。Drawer から開き直したときは false にして、
  /// 見出しの記号を「戻る」に変える（☰ のままだと現在地が分からなくなる）。
  final bool isRoot;

  @override
  State<HaSetupScreen> createState() => _HaSetupScreenState();
}

class _HaSetupScreenState extends State<HaSetupScreen> {
  late final _url = TextEditingController(
    text: widget.controller.connection?.baseUrl.toString() ?? '',
  );
  final _token = TextEditingController();

  String? _localError;
  bool _busy = false;

  @override
  void dispose() {
    _url.dispose();
    _token.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final base = HaConnection.parseBaseUrl(_url.text);
    if (base == null) {
      setState(() => _localError = 'アドレスを確認してください（例: 192.168.1.10:8123）');
      return;
    }
    final token = _token.text.trim();
    if (token.isEmpty) {
      setState(() => _localError = '長期アクセストークンを入力してください');
      return;
    }
    setState(() {
      _localError = null;
      _busy = true;
    });
    await widget.controller.save(HaConnection(baseUrl: base, token: token));
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final error = _localError ?? widget.controller.errorBanner;
    return Scaffold(
      backgroundColor: AppColors.frameBg,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 8, 20, 0),
              child: Row(
                children: [
                  if (widget.isRoot)
                    MenuButton(onPressed: widget.onOpenMenu)
                  else
                    IconButton(
                      onPressed: widget.onOpenMenu,
                      tooltip: '戻る',
                      icon: Icon(
                        Icons.arrow_back,
                        color: AppColors.white(0.5),
                        size: 22,
                      ),
                    ),
                  const SizedBox(width: 2),
                  const CapsLabel('HOME'),
                ],
              ),
            ),
            Expanded(
              child: Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 28,
                    vertical: 20,
                  ),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 460),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'Home Assistant に接続',
                          style: AppText.body(24, weight: FontWeight.w900),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'HA のプロフィール画面いちばん下で「長期アクセストークン」を'
                          '発行して貼り付けてください。表示は一度きりです。',
                          style: AppText.body(
                            13,
                            color: AppColors.white(0.6),
                            height: 1.7,
                          ),
                        ),
                        const SizedBox(height: 24),
                        _Field(
                          label: 'アドレス',
                          hint: '192.168.1.10:8123',
                          controller: _url,
                          keyboardType: TextInputType.url,
                        ),
                        const SizedBox(height: 16),
                        _Field(
                          label: '長期アクセストークン',
                          hint: 'eyJhbGciOi…',
                          controller: _token,
                          obscure: true,
                          maxLines: 1,
                        ),
                        if (error != null) ...[
                          const SizedBox(height: 16),
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Icon(
                                Icons.error_outline,
                                color: AppColors.danger,
                                size: 16,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  error,
                                  style: AppText.body(
                                    13,
                                    color: AppColors.white(0.8),
                                    height: 1.6,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                        const SizedBox(height: 24),
                        Row(
                          children: [
                            WhiteButton(
                              label: _busy ? '接続中…' : '接続',
                              onPressed: _busy ? null : _submit,
                            ),
                            if (widget.controller.isConfigured) ...[
                              const SizedBox(width: 12),
                              OutlineButton(
                                label: '保存済みを消す',
                                onPressed: _busy
                                    ? null
                                    : widget.controller.forget,
                              ),
                            ],
                          ],
                        ),
                        const SizedBox(height: 20),
                        Text(
                          'アプリと HA と機器は同じネットワークに置いてください。'
                          'ゲスト SSID や IoT 用 VLAN に分けると mDNS が届かず繋がりません。',
                          style: AppText.body(
                            12,
                            color: AppColors.white(0.4),
                            height: 1.7,
                          ),
                        ),
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

class _Field extends StatelessWidget {
  const _Field({
    required this.label,
    required this.hint,
    required this.controller,
    this.obscure = false,
    this.keyboardType,
    this.maxLines,
  });

  final String label;
  final String hint;
  final TextEditingController controller;
  final bool obscure;
  final TextInputType? keyboardType;
  final int? maxLines;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        CapsLabel(label),
        const SizedBox(height: 8),
        TextField(
          controller: controller,
          obscureText: obscure,
          keyboardType: keyboardType,
          maxLines: maxLines ?? 1,
          autocorrect: false,
          enableSuggestions: false,
          style: AppText.body(15, color: Colors.white),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: AppText.body(15, color: AppColors.white(0.28)),
            filled: true,
            fillColor: AppColors.white(0.06),
            // 面の塗りだけで箱にする（枠線を引かない）。
            border: const OutlineInputBorder(
              borderRadius: AppRadius.row,
              borderSide: BorderSide.none,
            ),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 14,
            ),
          ),
        ),
      ],
    );
  }
}
