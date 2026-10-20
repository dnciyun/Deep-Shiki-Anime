/// 本地文件交给播放器时用的是 **`file:` URI**，这个测试证明它能还原成真实路径。
///
/// 为什么要钉住这条：宿主 `PlayerRequest.streamUrl` 是 `Uri`，而
/// `Uri.parse(r'F:\a\b.mkv')` 会解析成 scheme 为盘符的垃圾 URI（实测，见
/// `app/test/local_media_test.dart`）。所以本地文件一律经 `Uri.file()` 转成
/// `file:///F:/…` 再交给 media_kit —— **它到底认不认**这件事不能靠猜：
/// media_kit 的 `Media.normalizeURI()` 走 `URIParser`，对 `file:` 类型返回
/// `parser.file!.path`（真实路径）。这条测试一旦红了，说明升级 media_kit 之后
/// 这套约定变了，本地播放会「打不开」，必须回头看。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path/path.dart' as p;

void main() {
  test('file: URI（含中文 / 空格）被 media_kit 还原成真实 Windows 路径', () {
    final String path = p.join('F:', 'Ai', 'アニメ 番剧', '第01話 [1080p].mkv');
    final Uri uri = Uri.file(path);
    expect(uri.scheme, 'file');

    final String normalized = Media.normalizeURI(uri.toString());
    // ⚠️ media_kit 交回的是**正斜杠**形态（`F:/Ai/…`），不是反斜杠 —— mpv 在 Windows
    // 上两种都吃。所以这里用 `p.equals`（分隔符不敏感）比，而不是字符串全等。
    expect(p.equals(normalized, path), isTrue,
        reason: '中文与空格都不能丢（实际：$normalized）');
    expect(normalized.contains('%'), isFalse, reason: '不能留着百分号编码');
  });

  test('真实路径本身也能识别（media_kit 两种写法都吃，但宿主只用 file: URI）', () {
    final String path = p.join('F:', 'a', 'b.mkv');
    expect(p.equals(Media.normalizeURI(path), path), isTrue);
  });

  test('http 串流（边下边播）不会被改写', () {
    const String url = 'http://127.0.0.1:9/torrents/3/files/0/stream?token=abc';
    expect(Media.normalizeURI(url), url);
  });
}
