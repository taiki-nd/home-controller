import 'package:flutter/material.dart';

import '../../services/wiim_discovery.dart';
import '../../state/qobuz_controller.dart';
import '../../theme/tokens.dart';
import '../widgets/atoms.dart';
import 'qobuz_web_login_screen.dart';

/// hi-res（Qobuz 直叩き + WiiM）の設定
/// （`docs/qobuz-wiim-integration.md` §6・§7）。
///
/// 立て付けは `HaSetupScreen` と同じ。入れるものは 3 つ:
///
/// 1. **WiiM。** LAN から探して一覧から選ぶ（§5.1）。手入力も残してある
/// 2. **app_id / app_secret。** 非公式の値なのでビルドに埋めず、
///    アプリ内ブラウザか bundle.js から取る（§3.2）
/// 3. **Qobuz のログイン。** アプリ内ブラウザか、メール + パスワード
///    （パスワードは MD5 にして送り、平文は保存しない）
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

  /// 逃げ道（手入力・メールログイン）を開いているか。**既定は畳む。**
  bool _manual = false;

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

  Future<void> _discover() async {
    setState(() => _localError = null);
    await widget.controller.discoverWiim();
  }

  /// 一覧から 1 台選ぶ。**入力欄にも反映する**——次に開いたときに
  /// どれを選んだのかが見えるように。
  Future<void> _select(WiimCandidate candidate) async {
    setState(() {
      _localError = null;
      _host.text = candidate.host;
    });
    await widget.controller.selectWiim(candidate);
  }

  /// アプリ内ブラウザで Qobuz にログインし、鍵とトークンを取り込む（§3.2）。
  Future<void> _webLogin() async {
    setState(() => _localError = null);
    final result = await QobuzWebLoginScreen.open(context);
    if (!mounted || result == null) return;
    await widget.controller.applyWebLogin(result);
    if (!mounted) return;
    final config = widget.controller.appConfig;
    if (config != null) {
      _appId.text = config.appId;
      _appSecret.text = config.appSecret;
    }
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

  /// **この画面自身がコントローラを購読する。**
  ///
  /// Drawer から `Navigator.push` で開いたときは `QobuzView` の
  /// `ListenableBuilder` の外側に居るので、これが無いと `notifyListeners` が
  /// どこにも届かない——「取り直す」を押しても、進行中もエラーも何も出ない
  /// （押しても無反応に見えていたのはこれ）。
  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) => _build(context),
    );
  }

  Widget _build(BuildContext context) {
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
                  const CapsLabel('QOBUZ'),
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
                        _WiimPicker(
                          controller: controller,
                          onDiscover: _discover,
                          onCancel: controller.cancelDiscovery,
                          onSelect: _select,
                        ),
                        const SizedBox(height: 16),
                        _Field(
                          label: 'IP アドレス',
                          hint: '192.168.1.42',
                          controller: _host,
                          keyboardType: TextInputType.url,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          '探して出てこなければ IP を直接入れてください'
                          '（WiiM 側は DHCP 予約で固定しておくと確実です）。'
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

                        // ── 2. Qobuz ───────────────────────────────
                        //
                        // **入口はアプリ内ブラウザ 1 つ。** 鍵もログインも
                        // ここで一度に揃う。以前は「2. 鍵」「3. ログイン」と
                        // 2 段に見せていたが、実際にやることは 1 回なので
                        // 段を分けるほど手数が増えたように見えていた。
                        const CapsLabel('2. QOBUZ', size: 10),
                        const SizedBox(height: 12),
                        _QobuzState(controller: controller),
                        const SizedBox(height: 16),
                        WhiteButton(
                          label: busy
                              ? '取り込み中…'
                              : (controller.isSignedIn
                                    ? 'アプリ内ブラウザで取り直す'
                                    : 'アプリ内ブラウザでログイン'),
                          onPressed: busy ? null : _webLogin,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Qobuz の Web プレイヤーにいつもどおりログインする'
                          'だけです。**鍵とログインを一度にまとめて取り込みます。**'
                          'このアプリはパスワードを見ません。',
                          style: AppText.body(
                            12,
                            color: AppColors.white(0.4),
                            height: 1.7,
                          ),
                        ),
                        if (controller.isSignedIn) ...[
                          const SizedBox(height: 12),
                          OutlineButton(
                            label: 'ログアウト',
                            onPressed: busy ? null : controller.logout,
                          ),
                        ],
                        const SizedBox(height: 20),

                        // ── 逃げ道 ─────────────────────────────────
                        //
                        // **畳んでおく。** 手入力もメール + パスワードも、
                        // ブラウザ経路が転んだときにしか要らない。
                        _Disclosure(
                          label: 'うまくいかないときは',
                          open: _manual,
                          onToggle: () => setState(() => _manual = !_manual),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const SizedBox(height: 16),
                              const CapsLabel('鍵を手で入れる', size: 10),
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
                                '「Web から取り直す」は play.qobuz.com の '
                                'bundle.js を素の HTTP で読みに行きます。'
                                '**Qobuz 側のボット避けで空振りすることがある**'
                                'ので、基本は上のアプリ内ブラウザを使ってください。',
                                style: AppText.body(
                                  12,
                                  color: AppColors.white(0.4),
                                  height: 1.7,
                                ),
                              ),
                              if (!controller.isSignedIn) ...[
                                const SizedBox(height: 24),
                                const CapsLabel('メールとパスワードで入る', size: 10),
                                const SizedBox(height: 12),
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
                                const SizedBox(height: 8),
                                Text(
                                  '先に app_id / app_secret が要ります。'
                                  'パスワードは MD5 にして送り、端末には残しません。',
                                  style: AppText.body(
                                    12,
                                    color: AppColors.white(0.4),
                                    height: 1.7,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                        const SizedBox(height: 8),

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

/// LAN から WiiM を探して選ばせる（§5.1）。
///
/// **1 台でも自動では選ばない。** 隣の部屋の別の個体や、集合住宅で隣家の
/// WiiM が見えることがあるので、決めるのは人。
class _WiimPicker extends StatelessWidget {
  const _WiimPicker({
    required this.controller,
    required this.onDiscover,
    required this.onCancel,
    required this.onSelect,
  });

  final QobuzController controller;
  final VoidCallback onDiscover;
  final VoidCallback onCancel;
  final ValueChanged<WiimCandidate> onSelect;

  @override
  Widget build(BuildContext context) {
    final scanning = controller.scanning;
    final candidates = controller.candidates;
    final current = controller.wiimConnection?.host;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            OutlineButton(
              label: scanning
                  ? '探索中 ${(controller.scanProgress * 100).round()}%'
                  : 'LAN から探す',
              onPressed: scanning ? onCancel : onDiscover,
              fontSize: 14,
              padding: const EdgeInsets.symmetric(
                horizontal: 18,
                vertical: 11,
              ),
            ),
            if (scanning) ...[
              const SizedBox(width: 12),
              Text(
                'タップで中止',
                style: AppText.body(12, color: AppColors.white(0.35)),
              ),
            ],
          ],
        ),
        if (candidates.isNotEmpty) ...[
          const SizedBox(height: 12),
          for (final candidate in candidates)
            _CandidateRow(
              candidate: candidate,
              selected: candidate.host == current,
              onTap: () => onSelect(candidate),
            ),
        ],
      ],
    );
  }
}

class _CandidateRow extends StatelessWidget {
  const _CandidateRow({
    required this.candidate,
    required this.selected,
    required this.onTap,
  });

  final WiimCandidate candidate;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: AppColors.white(selected ? 0.12 : 0.06),
        borderRadius: AppRadius.row,
        child: InkWell(
          onTap: onTap,
          borderRadius: AppRadius.row,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                Icon(
                  selected ? Icons.check_circle : Icons.speaker,
                  size: 18,
                  color: selected ? AppColors.green : AppColors.white(0.45),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        candidate.label,
                        style: AppText.body(15, color: Colors.white),
                      ),
                      Text(
                        [
                          candidate.host,
                          ?candidate.device.model,
                        ].join(' · '),
                        style: AppText.body(12, color: AppColors.white(0.45)),
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
}

/// いま何が揃っていて何が足りないかを 2 行で見せる。
///
/// **「ログイン済みか」と「鍵が揃っているか」は別の話。** ここを 1 つの
/// 見出しに混ぜていたせいで、ログインは取り込めているのに設定画面が
/// 未設定にしか見えず、もう一度ログインさせられているように感じていた。
class _QobuzState extends StatelessWidget {
  const _QobuzState({required this.controller});

  final QobuzController controller;

  @override
  Widget build(BuildContext context) {
    final account = controller.account;
    final config = controller.appConfig;
    final hasSecret = config?.isComplete ?? false;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _StateRow(
          ok: controller.isSignedIn,
          title: controller.isSignedIn
              ? (account?.displayName ?? 'ログイン済み')
              : 'ログインしていません',
          subtitle: controller.isSignedIn ? account?.subscription : null,
        ),
        const SizedBox(height: 10),
        _StateRow(
          ok: hasSecret,
          title: hasSecret ? '鍵は揃っています' : 'app_secret がまだです',
          subtitle: hasSecret
              ? 'app_id ${config!.appId}'
              : (config?.appId.isNotEmpty ?? false)
              // **ここが分かれ目。** 検索とブラウズは署名が要らないので
              // app_id だけでも動く。止まるのは再生だけ。
              ? '検索とブラウズは動きますが、再生できません'
              : '取り込むとここが埋まります',
        ),
      ],
    );
  }
}

class _StateRow extends StatelessWidget {
  const _StateRow({required this.ok, required this.title, this.subtitle});

  final bool ok;
  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final subtitle = this.subtitle;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          ok ? Icons.check_circle : Icons.radio_button_unchecked,
          size: 18,
          color: ok ? AppColors.green : AppColors.white(0.3),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: AppText.body(15, color: Colors.white)),
              if (subtitle != null && subtitle.isNotEmpty)
                Text(
                  subtitle,
                  style: AppText.body(12, color: AppColors.white(0.45)),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 畳んでおける一塊。
class _Disclosure extends StatelessWidget {
  const _Disclosure({
    required this.label,
    required this.open,
    required this.onToggle,
    required this.child,
  });

  final String label;
  final bool open;
  final VoidCallback onToggle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        GestureDetector(
          onTap: onToggle,
          behavior: HitTestBehavior.opaque,
          child: Row(
            children: [
              Icon(
                open ? Icons.expand_less : Icons.expand_more,
                size: 18,
                color: AppColors.white(0.5),
              ),
              const SizedBox(width: 6),
              Text(
                label,
                style: AppText.body(13, color: AppColors.white(0.55)),
              ),
            ],
          ),
        ),
        if (open) child,
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
