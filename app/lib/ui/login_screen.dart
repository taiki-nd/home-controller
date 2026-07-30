import 'package:flutter/material.dart';

import '../services/auth_service.dart';
import '../services/spotify_config.dart';
import '../theme/tokens.dart';
import 'widgets/atoms.dart';

class LoginScreen extends StatelessWidget {
  const LoginScreen({super.key, required this.auth});

  final AuthService auth;

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final wide = width >= kTabletBreakpoint;

    return Scaffold(
      body: DecoratedBox(
        // 緑と紫のラジアルを重ねた login 背景。
        decoration: const BoxDecoration(
          color: AppColors.frameBg,
          gradient: RadialGradient(
            center: Alignment(-0.6, -0.8),
            radius: 1.1,
            colors: [Color(0x331DB954), Color(0x00000000)],
            stops: [0, 0.6],
          ),
        ),
        child: DecoratedBox(
          decoration: const BoxDecoration(
            gradient: RadialGradient(
              center: Alignment(0.8, 0.8),
              radius: 1.0,
              colors: [Color(0x337C3AED), Color(0x00000000)],
              stops: [0, 0.6],
            ),
          ),
          child: SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding: EdgeInsets.symmetric(
                  horizontal: wide ? width * 0.09 : 28,
                  vertical: 40,
                ),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 720),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const _SpotifyAttribution(),
                      const SizedBox(height: 28),
                      Text(
                        'Everyone adds\nthe next track.',
                        style: AppText.body(
                          wide ? 60 : 40,
                          weight: FontWeight.w900,
                          height: 1.02,
                          letterSpacing: wide ? -1.8 : -1.2,
                        ),
                      ),
                      const SizedBox(height: 28),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 460),
                        child: Text(
                          'Spotify アカウントを繋いで、リビングの WiiM に直接曲を送ります。'
                          '再生とキューは全て Spotify 側が持ちます。',
                          style: AppText.body(
                            17,
                            color: AppColors.white(0.62),
                            height: 1.7,
                          ),
                        ),
                      ),
                      const SizedBox(height: 28),
                      if (!SpotifyConfig.isConfigured)
                        const _MissingClientIdCard()
                      else
                        ListenableBuilder(
                          listenable: auth,
                          builder: (context, _) {
                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                if (auth.isBusy)
                                  const Padding(
                                    padding: EdgeInsets.symmetric(vertical: 20),
                                    child: SizedBox.square(
                                      dimension: 28,
                                      child: CircularProgressIndicator(
                                        color: AppColors.green,
                                        strokeWidth: 3,
                                      ),
                                    ),
                                  )
                                else
                                  GreenButton(
                                    label: 'Connect with Spotify',
                                    onPressed: auth.signIn,
                                    fontSize: 21,
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 40,
                                      vertical: 20,
                                    ),
                                  ),
                                if (auth.error != null) ...[
                                  const SizedBox(height: 16),
                                  ConstrainedBox(
                                    constraints: const BoxConstraints(
                                      maxWidth: 460,
                                    ),
                                    child: Text(
                                      auth.error!,
                                      style: AppText.body(
                                        14,
                                        color: AppColors.danger,
                                        height: 1.6,
                                      ),
                                    ),
                                  ),
                                ],
                              ],
                            );
                          },
                        ),
                      const SizedBox(height: 28),
                      Text(
                        'Authorization Code + PKCE で認可します。パスワードはこのアプリを通りません。\n'
                        'Development Mode のため、認可できるアカウントは 5 人までです。',
                        style: AppText.body(
                          13,
                          color: AppColors.white(0.35),
                          height: 1.6,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Spotify への帰属表示（デザインガイドライン上必須 — 設計メモ §12）。
class _SpotifyAttribution extends StatelessWidget {
  const _SpotifyAttribution();

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 30,
          height: 30,
          decoration: const BoxDecoration(
            color: AppColors.green,
            shape: BoxShape.circle,
          ),
          alignment: Alignment.center,
          child: const Icon(
            Icons.graphic_eq_rounded,
            size: 17,
            color: AppColors.onGreen,
          ),
        ),
        const SizedBox(width: 12),
        Text(
          'POWERED BY SPOTIFY',
          style: AppText.caps(13, AppColors.white(0.5), em: 0.14),
        ),
      ],
    );
  }
}

/// dart-define を忘れているとログインが必ず失敗するので、原因を先に出す。
class _MissingClientIdCard extends StatelessWidget {
  const _MissingClientIdCard();

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 560),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        borderRadius: AppRadius.card,
        color: AppColors.white(0.05),
        border: Border.all(color: AppColors.danger.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const CapsLabel('Setup required', size: 11, color: AppColors.danger),
          const SizedBox(height: 12),
          Text(
            'SPOTIFY_CLIENT_ID が埋め込まれていません。',
            style: AppText.body(16, weight: FontWeight.w900),
          ),
          const SizedBox(height: 10),
          SelectableText(
            'flutter run --dart-define=SPOTIFY_CLIENT_ID=xxxxxxxx',
            style: AppText.grotesk(size: 13, color: AppColors.white(0.6)),
          ),
          const SizedBox(height: 10),
          Text(
            'Dashboard の Redirect URIs に ${SpotifyConfig.redirectUri} も登録してください。',
            style: AppText.body(13, color: AppColors.white(0.5), height: 1.6),
          ),
        ],
      ),
    );
  }
}
