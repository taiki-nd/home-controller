import 'package:flutter/material.dart';

import '../../services/ma_credentials.dart';
import '../../state/ma_controller.dart';
import '../../theme/tokens.dart';
import '../widgets/atoms.dart';

/// Music Assistant の接続設定。
///
/// 立て付けは `HaSetupScreen` と同じ。トークンは MA の全操作が通る secret
/// なのでビルドに埋めず、ここで入力して Keychain に置く
/// （`docs/music-assistant-integration.md` §3・§7.4）。
class MaSetupScreen extends StatefulWidget {
  const MaSetupScreen({
    super.key,
    required this.controller,
    required this.onOpenMenu,
    this.isRoot = true,
  });

  final MaController controller;
  final VoidCallback onOpenMenu;

  /// 入口として出しているか。Drawer から開き直したときは false にして、
  /// 見出しの記号を「戻る」に変える。
  final bool isRoot;

  @override
  State<MaSetupScreen> createState() => _MaSetupScreenState();
}

class _MaSetupScreenState extends State<MaSetupScreen> {
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
    final base = MaConnection.parseBaseUrl(_url.text);
    if (base == null) {
      setState(() => _localError = 'アドレスを確認してください（例: 192.168.1.10:8095）');
      return;
    }
    setState(() {
      _localError = null;
      _busy = true;
    });
    // トークンは空でもよい（MA 2.8 未満は認証が無い）。要る世代なら
    // 握手で弾かれて authFailed になり、この画面に戻ってくる。
    await widget.controller.save(
      MaConnection(baseUrl: base, token: _token.text.trim()),
    );
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
                  const CapsLabel('HI-RES'),
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
                          'Music Assistant に接続',
                          style: AppText.body(24, weight: FontWeight.w900),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'MA の Settings → Users → 自分のユーザーで「Create token」'
                          'を押して貼り付けてください。表示は一度きりです。',
                          style: AppText.body(
                            13,
                            color: AppColors.white(0.6),
                            height: 1.7,
                          ),
                        ),
                        const SizedBox(height: 24),
                        _Field(
                          label: 'アドレス',
                          hint: '192.168.1.10:8095',
                          controller: _url,
                          keyboardType: TextInputType.url,
                        ),
                        const SizedBox(height: 16),
                        _Field(
                          label: 'アクセストークン',
                          hint: 'MA 2.8 未満なら空のまま',
                          controller: _token,
                          obscure: true,
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
                          'Qobuz と WiiM は MA 側で足しておいてください'
                          '（Settings → Music Providers / Player Providers）。'
                          'HA アドオンとして動かしている場合、アドレスは HA と'
                          '同じホストのポート 8095 になります。',
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
  });

  final String label;
  final String hint;
  final TextEditingController controller;
  final bool obscure;
  final TextInputType? keyboardType;

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
          maxLines: 1,
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
