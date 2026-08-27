import 'package:flutter/material.dart';

import '../../state/qobuz_controller.dart';
import '../../theme/tokens.dart';
import '../widgets/atoms.dart';

/// hi-res（Qobuz 直叩き + WiiM）の設定
/// （`docs/qobuz-wiim-integration.md` §6・§7）。
///
/// 立て付けは `HaSetupScreen` と同じ。入れるものは 3 つ:
///
/// 1. **WiiM の IP。** DHCP 予約で固定しておく（SSDP では探さない、§5.1）
/// 2. **app_id / app_secret。** 非公式の値なのでビルドに埋めず、
///    ここで入れるか bundle.js から取り直す（§3.2）
/// 3. **Qobuz のログイン。** パスワードは MD5 にして送り、平文は保存しない
class QobuzSetupScreen extends StatefulWidget {
  const QobuzSetupScreen({
    super.key,
    required this.controller,
    required this.onOpenMenu,
    this.isRoot = true,
  });

  final QobuzController controller;
  final VoidCallback onOpenMenu;

  /// 入口として出しているか。Drawer から開き直したときは false にして、
  /// 見出しの記号を「戻る」に変える。
  final bool isRoot;

  @override
  State<QobuzSetupScreen> createState() => _QobuzSetupScreenState();
}

class _QobuzSetupScreenState extends State<QobuzSetupScreen> {
  late final _host = TextEditingController(
    text: widget.controller.wiimConnection?.host ?? '',
  );
  late final _appId = TextEditingController(
    text: widget.controller.appConfig?.appId ?? '',
  );
  late final _appSecret = TextEditingController(
    text: widget.controller.appConfig?.appSecret ?? '',
  );
  final _email = TextEditingController();
  final _password = TextEditingController();

  String? _localError;

  @override
  void dispose() {
    _host.dispose();
    _appId.dispose();
    _appSecret.dispose();
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _saveWiim() async {
    setState(() => _localError = null);
    await widget.controller.saveWiim(_host.text);
  }

  Future<void> _saveKeys() async {
    if (_appId.text.trim().isEmpty) {
      setState(() => _localError = 'app_id を入れてください');
      return;
    }
    setState(() => _localError = null);
    await widget.controller.saveAppConfig(_appId.text, _appSecret.text);
  }

  Future<void> _refreshKeys() async {
    setState(() => _localError = null);
    await widget.controller.refreshKeys();
    if (!mounted) return;
    final config = widget.controller.appConfig;
    if (config != null) {
      _appId.text = config.appId;
      _appSecret.text = config.appSecret;
    }
  }

  Future<void> _login() async {
    if (_email.text.trim().isEmpty || _password.text.isEmpty) {
      setState(() => _localError = 'メールアドレスとパスワードを入れてください');
      return;
    }
    setState(() => _localError = null);
    await widget.controller.login(
      email: _email.text.trim(),
      password: _password.text,
    );
    // ログインできてもできてもパスワードは残さない。
    if (mounted) _password.clear();
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final error = _localError ?? controller.errorBanner;
    final busy = controller.busy;
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
                          'Qobuz を WiiM で鳴らす',
                          style: AppText.body(24, weight: FontWeight.w900),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Qobuz のカタログをこのアプリで辿り、再生は同じ LAN の '
                          'WiiM に投げます。サーバーは要りません。',
                          style: AppText.body(
                            13,
                            color: AppColors.white(0.6),
                            height: 1.7,
                          ),
                        ),
                        const SizedBox(height: 24),

                        // ── 1. WiiM ────────────────────────────────
                        const CapsLabel('1. WIIM', size: 10),
                        const SizedBox(height: 12),
                        _Field(
                          label: 'IP アドレス',
                          hint: '192.168.1.42',
                          controller: _host,
                          keyboardType: TextInputType.url,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'WiiM 側は DHCP 予約で固定しておいてください。'
                          '初回は iOS が「ローカルネットワークの許可」を聞いてきます。'
                          '**ここで拒否すると無言で繋がらなくなります。**',
                          style: AppText.body(
                            12,
                            color: AppColors.white(0.4),
                            height: 1.7,
                          ),
                        ),
                        const SizedBox(height: 12),
                        WhiteButton(
                          label: busy ? '確認中…' : 'WiiM を保存して接続',
                          onPressed: busy ? null : _saveWiim,
                        ),
                        const SizedBox(height: 28),

                        // ── 2. app_id / app_secret ─────────────────
                        const CapsLabel('2. QOBUZ の鍵', size: 10),
                        const SizedBox(height: 12),
                        _Field(
                          label: 'app_id',
                          hint: '数字 9 桁',
                          controller: _appId,
                          keyboardType: TextInputType.number,
                        ),
                        const SizedBox(height: 16),
                        _Field(
                          label: 'app_secret',
                          hint: 'bundle.js から取り直せます',
                          controller: _appSecret,
                          obscure: true,
                        ),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            OutlineButton(
                              label: '保存',
                              onPressed: busy ? null : _saveKeys,
                            ),
                            const SizedBox(width: 12),
                            OutlineButton(
                              label: busy ? '取得中…' : 'Web から取り直す',
                              onPressed: busy ? null : _refreshKeys,
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Text(
                          '「Web から取り直す」は play.qobuz.com の bundle.js から '
                          'app_id と app_secret の候補を拾い、実際に再生 URL を'
                          '取れたものだけを残します。401 や「署名が違う」が出たら'
                          'ここを叩き直してください。',
                          style: AppText.body(
                            12,
                            color: AppColors.white(0.4),
                            height: 1.7,
                          ),
                        ),
                        const SizedBox(height: 28),

                        // ── 3. ログイン ────────────────────────────
                        const CapsLabel('3. QOBUZ のログイン', size: 10),
                        const SizedBox(height: 12),
                        if (controller.isSignedIn)
                          _SignedIn(controller: controller)
                        else ...[
                          _Field(
                            label: 'メールアドレス',
                            hint: 'you@example.com',
                            controller: _email,
                            keyboardType: TextInputType.emailAddress,
                          ),
                          const SizedBox(height: 16),
                          _Field(
                            label: 'パスワード',
                            hint: '',
                            controller: _password,
                            obscure: true,
                          ),
                          const SizedBox(height: 12),
                          WhiteButton(
                            label: busy ? 'ログイン中…' : 'ログイン',
                            onPressed: busy ? null : _login,
                          ),
                        ],

                        if (error != null) ...[
                          const SizedBox(height: 20),
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
                        Text(
                          'この経路は Qobuz の非公式な app_id / app_secret に'
                          '依存しています。**個人利用専用**で、App Store 配布や'
                          'OSS 公開はしません（docs/qobuz-wiim-integration.md §6）。',
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

class _SignedIn extends StatelessWidget {
  const _SignedIn({required this.controller});

  final QobuzController controller;

  @override
  Widget build(BuildContext context) {
    final account = controller.account;
    return Row(
      children: [
        const Icon(Icons.check_circle, size: 18, color: AppColors.green),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                account?.displayName ?? 'ログイン済み',
                style: AppText.body(15, color: Colors.white),
              ),
              if (account?.subscription != null)
                Text(
                  account!.subscription!,
                  style: AppText.body(12, color: AppColors.white(0.45)),
                ),
            ],
          ),
        ),
        OutlineButton(label: 'ログアウト', onPressed: controller.logout),
      ],
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
