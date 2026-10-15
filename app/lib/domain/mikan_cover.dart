/// mikan 图床的封面 URL 取档（与 Bangumi 的 [bangumiCoverAt] 同一套思路）。
///
/// **用户 2026-10-15 报的「今日更新的封面图还是显示不全」的真身不是布局**：
/// mikan 首页给的 `data-src` 长这样 ——
/// `/images/Bangumi/202603/712cede8.jpg?width=400&height=400&format=webp`。
/// 带上 `height=` 时，图床会**按正方形裁剪**。真机实测（2026-10-15，本机 curl +
/// Pillow 解码）同一张封面：
///
/// | 请求 | 拿到的图 | 说明 |
/// |---|---|---|
/// | 原图（不带参数） | `1429×2000`（0.715） | 真海报 |
/// | `?width=400&height=400&format=webp` | `400×400`（1.000） | **上下各裁掉约 30%** |
/// | `?width=400&format=webp` | `400×560`（0.714） | 完整海报，按比例缩放 |
/// | `?width=800&format=webp` | `800×1120`（0.714） | 同上，更大 |
///
/// 也就是说：**无论界面把封面槽开成多高的竖版框，拿到的图本身就已经被裁成方的了** ——
/// 第二十九轮把网格从正方框改成 0.705 竖版框之所以"还显示不全"，就是因为它只改了
/// 显示框，没改要图的 URL。
///
/// 另外实测（同日、24 张当天首页封面）：mikan 真封面比例中位 **0.7067**、最小 0.685、
/// 最大 0.926（少数是近似方形的 Key Visual）。所以 0.705 的槽位是对的，绝大多数封面
/// 现在能完整显示；少数比例差异大的靠调用方传 `BoxFit.contain` 保证不裁（见
/// `ui/widgets/cover.dart` 的 `kPosterFit`）。
///
/// 还有一条实测：**任意的 `width` 值图床都认**（200/240/260/400/500/800/1200 全试过，
/// 都按比例返回），所以这里按显示需要的档去取，不会像 Bangumi 那样只有固定几档。
library;

/// mikan 封面取图的宽度档（按显示需要的**设备像素**向上取）。
///
/// 三档就够：40pt 缩略图 → 200；208pt 海报卡（×1.25 = 260）→ 400；
/// 只有很大的槽（轮播卡那种）才会到 800。
const List<int> mikanCoverWidths = <int>[200, 400, 800];

/// 把想要的宽度抬到阶梯上最近的一档；`width <= 0` 返回 0 = **不改档**
/// （调用方还没算出尺寸时别乱猜，保留站点自己给的宽度）。
int snapMikanCoverWidth(int width) {
  if (width <= 0) return 0;
  for (final int step in mikanCoverWidths) {
    if (width <= step) return step;
  }
  return mikanCoverWidths.last;
}

/// 这个 URL 是不是「mikan 的封面图」——只在**确实是**的时候才动它。
///
/// 判据（两条都成立才算）：
/// 1. 带 `width` / `height` 参数（站点自己生成的缩放参数，删掉 `height` 一定是安全的）；
/// 2. 路径里有 `/images/Bangumi/`，或域名里带 `mikan`（含镜像站）。
///
/// 别的源、别的形状一律**一个字都不动** —— 改错 URL 会让封面直接显示不出来，
/// 那比糊更糟（第二十一轮踩过：给旧搜索接口的 URL 加 `/r/<宽>/` 前缀 → 全部 HTTP 400）。
bool _isMikanCoverUri(Uri uri) {
  final bool sized =
      uri.queryParameters.containsKey('width') || uri.queryParameters.containsKey('height');
  if (!sized) return false;
  return uri.path.contains('/images/Bangumi/') || uri.host.contains('mikan');
}

/// mikan 封面在某个**显示宽度（设备像素）**下该用的 URL。
///
/// 做两件事：
/// 1. **删掉 `height`**（修"被裁成正方形"的关键，见文件头实测）；
/// 2. 把 `width` 抬到显示需要的档（[mikanCoverWidths]），别一直拿 400 的图去铺大卡。
///
/// 规则：
/// * 空串 / null → 原样返回（`null` 进 `null` 出，调用方照旧走"无封面"占位）；
/// * 不是 mikan 封面（见 [_isMikanCoverUri]）→ 原样返回；
/// * `devicePixels <= 0` → 只删 `height`，宽度保留站点给的值（不猜档位）。
String? mikanCoverAt(String? url, int devicePixels) {
  final String raw = (url ?? '').trim();
  if (raw.isEmpty) return null;
  final Uri? uri = Uri.tryParse(raw);
  if (uri == null || !_isMikanCoverUri(uri)) return raw;

  // ⚠️ 用 `queryParameters`（会正确编码）而不是拼字符串：`Uri.replace(query:)` 要求
  // 调用方自己编码好，拼错就是 404。同一个键出现多次时保留最后一次（封面 URL 不会）。
  final Map<String, String> params = Map<String, String>.of(uri.queryParameters)
    ..remove('height');
  final int target = snapMikanCoverWidth(devicePixels);
  if (target > 0) params['width'] = '$target';
  return uri.replace(queryParameters: params).toString();
}

/// 这个 URL 是不是**旧版方形封面**（带 `height` 的 mikan 封面）。
///
/// 这一版之后再也不会有人请求它，所以缓存里那些 400×400 的文件是死重量
/// （启动时的封面缓存清理会按这个判据删掉它们）。
bool isLegacySquareMikanCoverUrl(String url) {
  final Uri? uri = Uri.tryParse(url.trim());
  if (uri == null) return false;
  return _isMikanCoverUri(uri) && uri.queryParameters.containsKey('height');
}
