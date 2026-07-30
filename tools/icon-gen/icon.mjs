// 「home.ctl」ワードマークのアプリアイコン生成 (SVG → PNG)。
//
// sonir-workspace/tools/icon-gen/icon.mjs を手本にした同型のツール。
// ピリオドを accent (Spotify グリーン) にして差し色にするのも同じ考え方。
// 書体はアプリのラベル書体 Space Grotesk (OFL) を fonts/ に同梱して resvg の
// fontFiles で読む = マシン非依存の決定論ビルド。
//   カラー: app/lib/theme/tokens.dart より
//
// 使い方:
//   node icon.mjs wordmark            … 全案を 1024px で preview/ に出力
//   node icon.mjs adaptive-preview <v>… Android adaptive の円マスク合成を確認
//   node icon.mjs png <v> <size> [out]… 単一案を任意サイズで出力
//   node icon.mjs play-icon [v] [out] … Google Play 用 512x512
//   node icon.mjs build [v]           … app/ の全プラットフォームへ展開 (既定: word-dark)
//
// 依存: @resvg/resvg-js (prebuilt。システムに rsvg/inkscape 等は不要)

import { Resvg } from '@resvg/resvg-js';
import { PNG } from 'pngjs';
import { mkdirSync, writeFileSync } from 'node:fs';
import { dirname, join, relative } from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const ROOT = join(__dirname, '..', '..'); // home-controller/
const APP = join(ROOT, 'app');
const CANVAS = 1024; // 基準キャンバス (1024px = ストアの最大アイコン)

// アプリの pubspec で同梱している Space Grotesk。ただし配布物は wght 可変フォントで、
// resvg は可変軸を動かさない (既定インスタンス = Light 300 で描かれてしまう)。
// fonts/make-font.py で wght=700 の静的インスタンスを作って同梱している。
const FONT_FILES = [join(__dirname, 'fonts', 'SpaceGrotesk-Bold.ttf')];
const WORDMARK_FONT = 'Space Grotesk';

// --- カラー (tokens.dart より) -------------------------------------------------
const C = {
  ink: '#F5F6F8', // 暗背景に載せる文字
  green: '#1ED760', // AppColors.green (差し色のピリオド)
  bgInner: '#15291D', // AppColors.bg をグリーン寄りに持ち上げた中心
  bgOuter: '#08080A', // AppColors.bg
};

const BG = { inner: C.bgInner, outer: C.bgOuter };

// --- アイコン案 ---------------------------------------------------------------
//   lines   … 1 行なら ['home.ctl']、2 行なら ['home', '.ctl']
//   '.' は常に accent 色で描かれる (行頭・行中どちらでも)
//   fit     … 文字ブロックの実測 bbox をキャンバスの何割に収めるか (幅・高さの両方)
//   lineGap … 行送り (font-size 比)。align は行の揃え。
//   dy      … 視覚中心からの縦補正 (キャンバス比)
const WORDMARK = {
  // 2 段組み。1 段目 home / 2 段目 .ctl。字が大きく取れるのでランチャー小サイズでも読める。
  'stack-dark': {
    lines: ['home', '.ctl'], fit: 0.60, lineGap: 0.94, align: 'start', dy: 0,
    bg: BG, ink: C.ink, accent: C.green,
  },
  // 1 行組み。ワードマークとしては最も素直だが、iOS の 40px 級では潰れる。
  'word-dark': {
    lines: ['home.ctl'], fit: 0.78, lineGap: 1, align: 'start', dy: 0,
    bg: BG, ink: C.ink, accent: C.green,
  },
  // 「h.」モノグラム。ランチャー 48px 重視に振るならこちら (小サイズの保険)。
  'mono-h': {
    lines: ['h.'], fit: 0.52, lineGap: 1, align: 'start', dy: 0,
    bg: BG, ink: C.ink, accent: C.green,
  },
};

/** 組版の基準 font-size。実寸は bbox 実測 → スケールで決まるので、これ自体に意味はない。 */
const BASE_SIZE = 300;

/** '.' を accent 色の tspan に割った 1 行分のマークアップ。 */
function inkLine(text, accent) {
  return text
    .split(/(\.)/)
    .filter(Boolean)
    .map((part) => (part === '.' ? `<tspan fill="${accent}">.</tspan>` : part))
    .join('');
}

/** 基準サイズで組んだ <text> 群 (原点 0,0 起点)。まだ位置合わせはしていない。 */
function rawLines(spec, { mono = false } = {}) {
  const ink = mono ? '#FFFFFF' : spec.ink;
  const accent = mono ? '#FFFFFF' : spec.accent;
  const gap = BASE_SIZE * (spec.lineGap ?? 1);
  const anchor = spec.align === 'middle' ? 'middle' : 'start';
  const tracking = -(BASE_SIZE * 0.02).toFixed(1);
  return spec.lines
    .map((line, i) => {
      const y = (i * gap).toFixed(1);
      return `<text x="0" y="${y}" font-family="${WORDMARK_FONT}" font-weight="700" font-size="${BASE_SIZE}" letter-spacing="${tracking}" text-anchor="${anchor}" fill="${ink}">${inkLine(line, accent)}</text>`;
    })
    .join('\n    ');
}

/**
 * 文字ブロックの実測 bbox（グリフの外形。行送りやフォントのアセンダには依存しない）。
 * これでスケールと中心を決めるので、案ごとに font-size を手で詰める必要がない。
 */
function measure(body) {
  const box = new Resvg(svgDoc(body), {
    font: { fontFiles: FONT_FILES, loadSystemFonts: false, defaultFontFamily: WORDMARK_FONT },
  }).getBBox();
  if (!box) throw new Error('bbox を取れなかった (フォント読み込み失敗の疑い)');
  return box;
}

/**
 * ワードマークを fit 比に収めてキャンバス中央へ置いた <g>。
 * scale で全体をさらに縮小できる (Android adaptive の安全域用)。
 */
function wordmarkText(spec, { scale = 1, mono = false } = {}) {
  const body = rawLines(spec, { mono });
  const box = measure(body);
  const target = CANVAS * (spec.fit ?? 0.7) * scale;
  const s = Math.min(target / box.width, target / box.height);
  // bbox の中心 = 光学中心。キャンバス中央に合わせ、dy で微調整する。
  const tx = CANVAS / 2 - (box.x + box.width / 2) * s;
  const ty = CANVAS / 2 + CANVAS * (spec.dy ?? 0) - (box.y + box.height / 2) * s;
  return `<g transform="translate(${tx.toFixed(2)} ${ty.toFixed(2)}) scale(${s.toFixed(5)})">
    ${body}
  </g>`;
}

/** 背景 (放射グラデ or 単色) の rect + defs。 */
function background(spec) {
  if (typeof spec.bg !== 'object') {
    return `<rect width="${CANVAS}" height="${CANVAS}" fill="${spec.bg}"/>`;
  }
  return `<defs><radialGradient id="bg" cx="50%" cy="40%" r="78%">
    <stop offset="0%" stop-color="${spec.bg.inner}"/>
    <stop offset="100%" stop-color="${spec.bg.outer}"/>
  </radialGradient></defs>
  <rect width="${CANVAS}" height="${CANVAS}" fill="url(#bg)"/>`;
}

const svgDoc = (body) =>
  `<svg xmlns="http://www.w3.org/2000/svg" width="${CANVAS}" height="${CANVAS}" viewBox="0 0 ${CANVAS} ${CANVAS}">
  ${body}
</svg>`;

/** アイコン本体 (背景 + ワードマーク)。 */
function buildWordmarkSvg(spec) {
  return svgDoc(`${background(spec)}\n  ${wordmarkText(spec)}`);
}

/**
 * Android adaptive icon 用の前景 (透明背景)。
 * 可視域は中央 ~66dp 円なので本体より小さく組む (size を 0.70 倍)。
 * mono=true で themed icon 用モノクロ (白文字)。
 */
function buildWordmarkForegroundSvg(spec, { mono = false } = {}) {
  return svgDoc(wordmarkText(spec, { scale: 0.7, mono }));
}

/** adaptive icon の背景レイヤー (全面)。 */
function buildAdaptiveBackgroundSvg(spec) {
  return svgDoc(background(spec));
}

// --- 出力先マップ (各 Contents.json / mipmap に合わせた実ピクセル) -------------
const TARGETS = {
  // iOS: ファイル名は AppIcon.appiconset/Contents.json に対応。alpha 不可。
  ios: {
    dir: join(APP, 'ios/Runner/Assets.xcassets/AppIcon.appiconset'),
    noAlpha: true,
    files: {
      'Icon-App-20x20@1x.png': 20,
      'Icon-App-20x20@2x.png': 40,
      'Icon-App-20x20@3x.png': 60,
      'Icon-App-29x29@1x.png': 29,
      'Icon-App-29x29@2x.png': 58,
      'Icon-App-29x29@3x.png': 87,
      'Icon-App-40x40@1x.png': 40,
      'Icon-App-40x40@2x.png': 80,
      'Icon-App-40x40@3x.png': 120,
      'Icon-App-60x60@2x.png': 120,
      'Icon-App-60x60@3x.png': 180,
      'Icon-App-76x76@1x.png': 76,
      'Icon-App-76x76@2x.png': 152,
      'Icon-App-83.5x83.5@2x.png': 167,
      'Icon-App-1024x1024@1x.png': 1024,
    },
  },
  // Android: mipmap 密度ごとに ic_launcher.png (legacy)。adaptive は別途生成。
  android: {
    dir: join(APP, 'android/app/src/main/res'),
    files: {
      'mipmap-mdpi/ic_launcher.png': 48,
      'mipmap-hdpi/ic_launcher.png': 72,
      'mipmap-xhdpi/ic_launcher.png': 96,
      'mipmap-xxhdpi/ic_launcher.png': 144,
      'mipmap-xxxhdpi/ic_launcher.png': 192,
    },
  },
};

// --- Android adaptive icon (余白問題の解消) -----------------------------------
// レガシーの正方形 ic_launcher.png しか無いと、丸/squircle マスクのランチャーは
// 「白い台紙に載せて縮小」する legacy 互換処理を入れる。
// adaptive icon は 108dp キャンバス。中央 72dp が常時可視、さらに中央 66dp 円が
// 「key shape の安全領域」。ワードマーク前景はこの安全領域に収める。
const ADAPTIVE_DENSITIES = {
  'mipmap-mdpi': 108,
  'mipmap-hdpi': 162,
  'mipmap-xhdpi': 216,
  'mipmap-xxhdpi': 324,
  'mipmap-xxxhdpi': 432,
};

/** 案名 → spec。 */
function specFor(name) {
  const spec = WORDMARK[name];
  if (!spec) throw new Error(`unknown variant "${name}". 候補: ${Object.keys(WORDMARK).join(', ')}`);
  return spec;
}

/**
 * SVG 文字列を size px 幅の PNG (Buffer) にラスタライズする。
 * noAlpha=true のとき alpha チャンネルを落とす (iOS の App Store 要件)。
 * ベクタから毎サイズ再描画するので縮小時も輪郭がシャープ。
 */
function renderPng(svg, size, { noAlpha = false } = {}) {
  const opts = { fitTo: { mode: 'width', value: size } };
  if (svg.includes('<text')) {
    opts.font = { fontFiles: FONT_FILES, loadSystemFonts: false, defaultFontFamily: WORDMARK_FONT };
  }
  const png = new Resvg(svg, opts).render().asPng();
  if (!noAlpha) return png;
  // 背景 rect で全面不透明なので、RGBA → RGB (colorType 2) で再エンコードするだけ。
  return PNG.sync.write(PNG.sync.read(png), { colorType: 2 });
}

const out = (...p) => join(__dirname, ...p);

function writeFile(file, data) {
  mkdirSync(dirname(file), { recursive: true });
  writeFileSync(file, data);
  console.log(`  ✓ ${relative(ROOT, file)}`);
}

/** 全案の SVG と 1024px PNG を preview/ に出力。 */
function cmdWordmark() {
  console.log('preview/ にワードマーク案を生成:');
  for (const name of Object.keys(WORDMARK)) {
    const svg = buildWordmarkSvg(WORDMARK[name]);
    writeFile(out('preview', `wordmark-${name}.svg`), svg);
    writeFile(out('preview', `wordmark-${name}-1024.png`), renderPng(svg, 1024));
  }
}

/** 単一案を任意サイズで出力。 */
function cmdPng([name, size, dest]) {
  if (!size) throw new Error('size を指定してください (例: node icon.mjs png word-dark 1024)');
  const svg = buildWordmarkSvg(specFor(name));
  writeFile(dest ?? out('preview', `${name}-${size}.png`), renderPng(svg, Number(size)));
}

/** Android adaptive icon レイヤー (前景/背景/モノクロ) + anydpi-v26 XML を書き出す。 */
function buildAndroidAdaptive(name) {
  const spec = specFor(name);
  const dir = TARGETS.android.dir;
  const fg = buildWordmarkForegroundSvg(spec);
  const bg = buildAdaptiveBackgroundSvg(spec);
  const mono = buildWordmarkForegroundSvg(spec, { mono: true });
  for (const [density, size] of Object.entries(ADAPTIVE_DENSITIES)) {
    writeFile(join(dir, density, 'ic_launcher_foreground.png'), renderPng(fg, size));
    writeFile(join(dir, density, 'ic_launcher_background.png'), renderPng(bg, size));
    writeFile(join(dir, density, 'ic_launcher_monochrome.png'), renderPng(mono, size));
  }
  // O+ では anydpi-v26 の XML が @mipmap/ic_launcher を上書きして adaptive 化。
  const xml = `<?xml version="1.0" encoding="utf-8"?>
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@mipmap/ic_launcher_background"/>
    <foreground android:drawable="@mipmap/ic_launcher_foreground"/>
    <monochrome android:drawable="@mipmap/ic_launcher_monochrome"/>
</adaptive-icon>
`;
  writeFile(join(dir, 'mipmap-anydpi-v26', 'ic_launcher.xml'), xml);
  writeFile(join(dir, 'mipmap-anydpi-v26', 'ic_launcher_round.xml'), xml);
}

/** 選択案を app/ の全プラットフォームへ展開。 */
function cmdBuild([name = 'word-dark']) {
  const svg = buildWordmarkSvg(specFor(name));
  console.log(`build "${name}" → app/ の全プラットフォーム:`);
  for (const { dir, files, noAlpha } of Object.values(TARGETS)) {
    for (const [file, size] of Object.entries(files)) {
      writeFile(join(dir, file), renderPng(svg, size, { noAlpha }));
    }
  }
  buildAndroidAdaptive(name);
  // 原本 SVG も残す (再現・手直し用)。アプリには同梱しないので app/assets には置かない。
  writeFile(out('out', `app_icon-${name}.svg`), svg);
}

/**
 * Google Play ストア掲載用ハイレゾアイコン (512x512)。
 * ランチャーで実際に見えるのは adaptive アイコンなので、それと同じ構図
 * (背景=放射グラデ全面 + 前景=安全域に縮小したワードマーク) を「マスク無しの正方形」で出す。
 * Play が掲載時に角丸/円マスクを当てるため、こちらは角を切らずフルブリードで渡す。
 */
function buildPlayIconSvg(name) {
  const spec = specFor(name);
  return svgDoc(`${background(spec)}\n  ${wordmarkText(spec, { scale: 0.7 })}`);
}

function cmdPlayIcon([name = 'word-dark', dest]) {
  console.log('Google Play ハイレゾアイコン (512x512) を生成:');
  writeFile(dest ?? out('preview', `play-icon-${name}-512.png`), renderPng(buildPlayIconSvg(name), 512));
}

/**
 * adaptive icon の見え方確認用。背景+前景を合成し円マスク + 安全領域ガイドを重ねて
 * preview/ に出力。
 */
function cmdAdaptivePreview([name = 'word-dark']) {
  const spec = specFor(name);
  const c = CANVAS / 2;
  const fg = wordmarkText(spec, { scale: 0.7 });
  const r72 = ((CANVAS * 72) / 108 / 2).toFixed(0);
  const r66 = ((CANVAS * 66) / 108 / 2).toFixed(0);
  const clip = `<defs><clipPath id="circle"><circle cx="${c}" cy="${c}" r="${c}"/></clipPath></defs>`;
  writeFile(
    out('preview', `adaptive-${name}.png`),
    renderPng(
      svgDoc(`${background(spec)}
  ${clip}
  <g clip-path="url(#circle)">${fg}</g>
  <circle cx="${c}" cy="${c}" r="${r72}" fill="none" stroke="#FF00AA" stroke-opacity="0.6" stroke-width="3" stroke-dasharray="8 8"/>
  <circle cx="${c}" cy="${c}" r="${r66}" fill="none" stroke="#00FFAA" stroke-opacity="0.6" stroke-width="3" stroke-dasharray="8 8"/>`),
      512,
    ),
  );
  // ガイド無しの素の合成 (円マスク) も。
  writeFile(
    out('preview', `adaptive-${name}-clean.png`),
    renderPng(svgDoc(`${background(spec)}\n  ${clip}\n  <g clip-path="url(#circle)">${fg}</g>`), 512),
  );
}

const [cmd, ...args] = process.argv.slice(2);
switch (cmd) {
  case 'wordmark':
    cmdWordmark();
    break;
  case 'png':
    cmdPng(args);
    break;
  case 'build':
    cmdBuild(args);
    break;
  case 'adaptive-preview':
    cmdAdaptivePreview(args);
    break;
  case 'play-icon':
    cmdPlayIcon(args);
    break;
  default:
    console.log('usage: node icon.mjs <command>');
    console.log('  wordmark                      「home.ctl」ワードマーク案を preview/ に出力');
    console.log('  png <variant> <size> [out]    単一案を任意サイズで出力');
    console.log('  adaptive-preview [variant]    Android adaptive icon の円マスク合成を確認');
    console.log('  play-icon [variant] [out]     Google Play ハイレゾアイコン 512x512 を生成');
    console.log('  build [variant]               app/ の全プラットフォームへ展開 (既定: word-dark)');
    console.log(`\nvariants: ${Object.keys(WORDMARK).join(', ')}`);
}
