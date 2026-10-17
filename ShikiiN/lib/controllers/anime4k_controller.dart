import 'package:path/path.dart' as p;
import '../models/anime4k_preset.dart';
import '../models/upscale_scheme.dart';
import '../infra/diagnostics/diag.dart';

/// 把「超分方案 + 档位」翻译成 libmpv 命令并下发。
///
/// 历史：本类原本只管 Anime4K 三档（`change-list glsl-shaders set/clr`）。
/// 2026-10-17 起扩成方案制（用户「模型我想多试试其他的，只使用可以实时播放的」）：
/// * Anime4K：行为与以前**逐字一致**（默认方案、三档、换片保护窗口都保留）；
/// * mpv 内置缩放器：`clr` 掉 shader 后 `set scale <算法>`，离开时把原值写回；
/// * 第三方 GLSL 包：与 Anime4K 同一条 `glsl-shaders` 通路，只是目录/文件链来自方案。
///
/// [runner] 注入「下发一条 mpv 命令」（生产接 PlayerController.runMpvCommand），
/// [readProperty] 注入「读一个 mpv 属性」（mpv 缩放器方案要存原值，离开时恢复）。
class Anime4kController {
  final Future<void> Function(List<String> args) runner;

  /// 读 mpv 属性；不注入时 mpv 缩放器方案无法恢复原值（仅测试会出现）。
  final Future<String> Function(String name)? readProperty;

  Anime4kController({required this.runner, this.readProperty});

  String? _shaderDir;

  /// 当前方案清单（内置 + 已安装的 GLSL 包；宿主导入后替换）。
  List<UpscaleScheme> _schemes = builtinUpscaleSchemes();

  UpscaleSelection _selection = UpscaleSelection.off;

  /// mpv 缩放器改过的属性原值（key → 原值；空串 = 读不到，不恢复）。
  final Map<String, String> _savedMpvProps = <String, String>{};

  /// shader 解包目录（Anime4K；解包完成后由启动流程注入）。
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

  /// 当前是否挂了 shader 链（mpv 缩放器方案 → false）。
  bool get hasShaders => _chainOf(_resolve()).isNotEmpty;

  /// 只记选择、**不下发**（主窗口不播时用：下发会经 runner 凭空建 mpv 实例）。
  void loadSelection(UpscaleSelection selection) {
    _selection = UpscaleSelection(schemeId: selection.schemeId, preset: selection.preset);
    _savedMpvProps.clear();
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

  /// 方案 → 当前要挂的文件链（mpvScaler 为空）。
  List<String> _chainOf(UpscaleScheme scheme) {
    switch (scheme.kind) {
      case UpscaleSchemeKind.anime4kChain:
        return anime4kShaderChain(_selection.preset);
      case UpscaleSchemeKind.glslPack:
        if (scheme.tiers.isEmpty) return const <String>[];
        return scheme.tiers.first.files;
      case UpscaleSchemeKind.mpvScaler:
        return const <String>[];
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
    await diag.breadcrumbFlushed('anime4k:_apply $where');
    try {
      if (scheme.kind == UpscaleSchemeKind.mpvScaler) {
        // 先摘 shader（避免与缩放器叠加），再下发 scale。
        await _clearShaders();
        await _applyMpvScaler(scheme);
      } else {
        await _restoreMpvProps();
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
      }
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
      await _restoreMpvProps();
      await diag.breadcrumbFlushed('anime4k:_apply off done');
    } catch (e, st) {
      diag.warn('anime4k', 'apply off failed', e, st);
    }
  }

  Future<void> _clearShaders() async {
    await runner(['change-list', 'glsl-shaders', 'clr', '']);
  }

  Future<void> _applyMpvScaler(UpscaleScheme scheme) async {
    if (scheme.properties.isEmpty) return;
    // 第一次进入缩放器方案时记下原值（切到另一个缩放器方案也沿用最初那份）。
    if (_savedMpvProps.isEmpty) {
      for (final String key in scheme.properties.keys) {
        _savedMpvProps[key] = await _readProp(key);
      }
    }
    for (final MapEntry<String, String> e in scheme.properties.entries) {
      await runner(['set', e.key, e.value]);
    }
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

  Future<void> _restoreMpvProps() async {
    if (_savedMpvProps.isEmpty) return;
    final List<MapEntry<String, String>> saved = _savedMpvProps.entries.toList(growable: false);
    _savedMpvProps.clear();
    for (final MapEntry<String, String> e in saved) {
      final String value = e.value.trim();
      if (value.isEmpty) continue; // 读不到原值：宁可不改，也不要写一个猜的默认值
      await runner(['set', e.key, value]);
    }
  }
}
