import 'package:path/path.dart' as p;
import '../models/anime4k_preset.dart';
import '../models/upscale_scheme.dart';
import '../infra/diagnostics/diag.dart';

/// 把「超分方案 + 档位」翻译成 libmpv 命令并下发。
///
/// 历史：本类原本只管 Anime4K 三档（`change-list glsl-shaders set/clr`）；
/// 2026-10-17 扩成方案制，随后按用户「去除内置的mpv这套」砍掉了 mpv 缩放器
/// （不再改 `scale` 属性、不再存/还原属性原值）。现在只有一条通路：
/// **一串 GLSL 文件 → `change-list glsl-shaders set <paths>`**。
///
/// [runner] 注入「下发一条 mpv 命令」（生产接 PlayerController.runMpvCommand）；
/// [readProperty] 注入「读一个 mpv 属性」—— 只用于诊断：apply 时把硬解状态、
/// 像素格式、片源/输出尺寸写进日志（真机排查用，不做任何自动降级动作）。
class Anime4kController {
  final Future<void> Function(List<String> args) runner;

  /// 读 mpv 属性（诊断用；不注入时日志里就是空）。
  final Future<String> Function(String name)? readProperty;

  Anime4kController({required this.runner, this.readProperty});

  String? _shaderDir;

  /// 当前方案清单（内置 + 已安装的 GLSL 包；宿主导入后替换）。
  List<UpscaleScheme> _schemes = builtinUpscaleSchemes();

  UpscaleSelection _selection = UpscaleSelection.off;

  /// shader 解包目录（Anime4K 与随包 GLSL 共用；解包完成后由启动流程注入）。
  void setShaderDir(String dir) => _shaderDir = dir;

  /// 替换方案清单（内置 + 扩展安装的 GLSL 包）。空清单 → 回到内置。
  void setSchemes(List<UpscaleScheme> schemes) {
    _schemes = schemes.isEmpty ? builtinUpscaleSchemes() : List<UpscaleScheme>.unmodifiable(schemes);
  }

  List<UpscaleScheme> get schemes => _schemes;

  UpscaleSelection get selection => _selection;

  /// 兼容旧调用：仅 Anime4K 档位。
  Anime4kPreset get preset => _selection.preset;

  String get schemeId => _selection.schemeId;

  bool get isOff => _selection.isOff;

  /// 是否有实际生效的超分（任何方案）；换片窗口据此决定要不要补发。
  bool get hasEffect => !isOff;

  /// 当前是否有文件链要挂（任何非关方案都有；关 → false）。
  bool get hasShaders => _chainOf(_resolve()).isNotEmpty;

  /// 只记选择、**不下发**（主窗口不播时用：下发会经 runner 凭空建 mpv 实例）。
  void loadSelection(UpscaleSelection selection) {
    _selection = UpscaleSelection(schemeId: selection.schemeId, preset: selection.preset);
  }

  /// 兼容旧调用：只记 Anime4K 档位。
  void loadPreset(Anime4kPreset preset) => loadSelection(UpscaleSelection(preset: preset));

  /// 切换选择并立即下发。
  Future<void> setSelection(UpscaleSelection selection) async {
    _selection = UpscaleSelection(schemeId: selection.schemeId, preset: selection.preset);
    await _apply();
  }

  /// 兼容旧调用：只切 Anime4K 档位。
  Future<void> setPreset(Anime4kPreset preset) =>
      setSelection(UpscaleSelection(preset: preset));

  /// 用当前选择重新下发（换片后保持生效）。
  Future<void> reapply() => _apply();

  // ── 换片保护窗口 ──────────────────────────────────────────────────────────
  // 从 open 到新文件 VO 重建稳定之间，任何 glsl-shaders `set` 都会与 GPU 渲染
  // 上下文重建竞争 → libmpv 原生崩溃。窗口内的下发一律记账延后，出窗口按最新
  // 选择补发；`clr` 任意 VO 状态下都安全，不受窗口影响。
  bool _inSwitchWindow = false;
  bool _pendingApply = false;
  int _switchEpoch = 0;

  /// 进入保护窗口，返回票据。重叠换片时旧票据自动失效（epoch 递增）。
  int enterSwitchWindow() {
    _inSwitchWindow = true;
    _pendingApply = hasEffect;
    diag.breadcrumb('anime4k:switchWindow enter (pending=$_pendingApply)');
    return ++_switchEpoch;
  }

  /// 离开保护窗口并补发窗口期内的最新选择。仅当 [token] 仍是当前窗口时生效；
  /// [reapply]=false 只解除窗口不补发（open 失败 / 无视频轨 / 超时等 set 不安全的情形）。
  Future<void> exitSwitchWindow(int token, {bool reapply = true}) async {
    if (token != _switchEpoch || !_inSwitchWindow) return;
    _inSwitchWindow = false;
    final bool pending = _pendingApply;
    _pendingApply = false;
    diag.breadcrumb('anime4k:switchWindow exit (pending=$pending, reapply=$reapply)');
    if (pending && reapply) await _apply();
  }

  /// 换片前清掉 shader，但保留当前选择（新文件 VO 就绪后再 [reapply]）。
  Future<void> clearForSwitch() async {
    await diag.breadcrumbFlushed(
        'anime4k:clearForSwitch (keep ${_selection.schemeId}/${_selection.preset.name})');
    try {
      await runner(['change-list', 'glsl-shaders', 'clr', '']);
    } catch (e, st) {
      diag.warn('anime4k', 'clearForSwitch failed', e, st);
    }
  }

  // ── 内部 ───────────────────────────────────────────────────────────────────

  UpscaleScheme _resolve() {
    for (final UpscaleScheme scheme in _schemes) {
      if (scheme.id == _selection.schemeId) return scheme;
    }
    for (final UpscaleScheme scheme in _schemes) {
      if (scheme.isAnime4k) return scheme;
    }
    return anime4kScheme();
  }

  /// 方案 → 当前要挂的文件链。
  List<String> _chainOf(UpscaleScheme scheme) {
    switch (scheme.kind) {
      case UpscaleSchemeKind.anime4kChain:
        return anime4kShaderChain(_selection.preset);
      case UpscaleSchemeKind.glslPack:
        return scheme.files;
    }
  }

  Future<void> _apply() async {
    final UpscaleScheme scheme = _resolve();
    if (_selection.isOff) {
      await _deactivate();
      return;
    }
    if (_inSwitchWindow) {
      _pendingApply = true;
      diag.breadcrumb(
          'anime4k:_apply deferred(switchWindow) ${_selection.schemeId}/${_selection.preset.name}');
      return;
    }
    await _activate(scheme);
  }

  Future<void> _activate(UpscaleScheme scheme) async {
    final String where = '${_selection.schemeId}/${_selection.preset.name}';
    await diag.breadcrumbFlushed('anime4k:_apply $where${await _playbackContext()}');
    try {
      final List<String> chain = _chainOf(scheme);
      final String? dir = scheme.dir ?? _shaderDir;
      if (dir == null || chain.isEmpty) {
        // 没有可用的 shader 文件：安全降级为关，绝不假装生效。
        await _clearShaders();
        diag.warn('anime4k', 'apply $where skipped: no shader dir/chain');
        return;
      }
      // breadcrumb 的 await 间隙可能恰好进入新的换片窗口：改记账，绝不冒险。
      if (_inSwitchWindow) {
        _pendingApply = true;
        return;
      }
      final String paths = chain.map((String f) => p.join(dir, f)).join(';');
      await runner(['change-list', 'glsl-shaders', 'set', paths]);
      await diag.breadcrumbFlushed('anime4k:_apply done $where');
    } catch (e, st) {
      diag.warn('anime4k', 'apply $where failed', e, st);
    }
  }

  Future<void> _deactivate() async {
    _pendingApply = false;
    await diag.breadcrumbFlushed('anime4k:_apply off');
    try {
      // clr 在任意 VO 状态下都安全；即使当前没挂 shader 也照发一条（历史行为，幂等）。
      await _clearShaders();
      await diag.breadcrumbFlushed('anime4k:_apply off done');
    } catch (e, st) {
      diag.warn('anime4k', 'apply off failed', e, st);
    }
  }

  Future<void> _clearShaders() async {
    await runner(['change-list', 'glsl-shaders', 'clr', '']);
  }

  /// 诊断信息：硬解状态 + 像素格式 + 片源/输出尺寸。
  ///
  /// 随包方案里的 ACNet/ARNet 都 hook `LUMA` 且带 `//!WHEN` 放大比例门槛：
  /// 画面没有放大时它们不会跑，用户观感就是「点了没效果」。这行日志 + 后面的
  /// OSD 提示就是用来区分「没放大」和「真坏了」。
  Future<String> _playbackContext() async {
    final String hwdec = (await _readProp('hwdec-current')).trim();
    final String pixfmt = (await _readProp('video-params/pixelformat')).trim();
    final _FrameSize? src = await _frameSize();
    final _FrameSize? out = await _outputSize();
    final List<String> parts = <String>[
      if (hwdec.isNotEmpty) 'hwdec=$hwdec',
      if (pixfmt.isNotEmpty) 'pixfmt=$pixfmt',
      if (src != null) 'src=${src.w}x${src.h}',
      if (out != null) 'out=${out.w}x${out.h}',
    ];
    return parts.isEmpty ? '' : ' (${parts.join(', ')})';
  }

  /// 片源尺寸（mpv `width`/`height`，等于解码后显示尺寸）。
  Future<_FrameSize?> _frameSize() async {
    final int? w = int.tryParse((await _readProp('width')).trim());
    final int? h = int.tryParse((await _readProp('height')).trim());
    if (w == null || h == null || w <= 0 || h <= 0) return null;
    return _FrameSize(w, h);
  }

  /// 输出尺寸（mpv `osd-dimensions`：渲染目标/窗口像素尺寸）。
  /// 读不到返回 null：宁可不说，也不瞎猜一个比例去误导用户。
  Future<_FrameSize?> _outputSize() async {
    final int? w = int.tryParse((await _readProp('osd-dimensions/w')).trim());
    final int? h = int.tryParse((await _readProp('osd-dimensions/h')).trim());
    if (w == null || h == null || w <= 0 || h <= 0) return null;
    return _FrameSize(w, h);
  }

  Future<String> _readProp(String name) async {
    final Future<String> Function(String)? read = readProperty;
    if (read == null) return '';
    try {
      return await read(name);
    } catch (_) {
      return '';
    }
  }
}

/// 画面尺寸（像素）。
class _FrameSize {
  final int w;
  final int h;
  const _FrameSize(this.w, this.h);
}
