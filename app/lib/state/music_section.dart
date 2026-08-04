import 'package:flutter/foundation.dart';

import '../services/auth_service.dart';
import '../services/musicbrainz_api.dart';
import '../services/spotify_api.dart';
import 'new_releases_controller.dart';
import 'player_controller.dart';

/// music（Spotify）側ひとまとめ。
///
/// 元は `main.dart` が直接持っていたものを、home と並べるために切り出した。
/// **`AppShell` は home と music を `IndexedStack` で生かしたまま切り替える**
/// ので、モードを行き来してもここは作り直されない
/// （`docs/home-assistant-integration.md` §10）。
class MusicSection extends ChangeNotifier {
  MusicSection() {
    _auth.addListener(_syncPlayer);
  }

  final AuthService _auth = AuthService();
  late final SpotifyApi _api = SpotifyApi(_auth);
  late final MusicBrainzApi _musicBrainz = MusicBrainzApi();
  late final ReleaseResolver _resolver = ReleaseResolver(_api);

  /// サインインするたびに作り直す。前のポーリングを確実に止めるため。
  PlayerController? _player;

  /// 新譜（設計メモ §14）。ポーリングも寿命も [PlayerController] と別物なので
  /// 混ぜず、サインイン状態にだけ追従させる。
  NewReleasesController? _newReleases;

  AuthService get auth => _auth;
  ReleaseResolver get resolver => _resolver;
  PlayerController? get player => _player;
  NewReleasesController? get newReleases => _newReleases;

  bool get isRestored => _auth.isRestored;
  bool get isSignedIn => _auth.isSignedIn;

  /// Drawer に添える一行。**Drawer を開いた瞬間に両モードの要約が見えれば、
  /// 確認のためだけにモードを切り替えなくて済む**（§10）。
  String? get drawerSubtitle {
    if (!_auth.isSignedIn) return 'サインインしていません';
    final track = _player?.currentTrack;
    if (track == null) return '停止中';
    return track.name;
  }

  Future<void> start() => _auth.restore();

  void _syncPlayer() {
    final signedIn = _auth.isSignedIn;
    if (signedIn && _player == null) {
      _player = PlayerController(_api)..addListener(notifyListeners);
      _newReleases = NewReleasesController(_api, _musicBrainz);
    } else if (!signedIn && _player != null) {
      _player?.removeListener(notifyListeners);
      _player?.dispose();
      _newReleases?.dispose();
      _player = null;
      _newReleases = null;
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _auth.removeListener(_syncPlayer);
    _player?.removeListener(notifyListeners);
    _player?.dispose();
    _newReleases?.dispose();
    _auth.dispose();
    super.dispose();
  }
}
