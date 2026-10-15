import 'package:path/path.dart' as p;
import '../models/anime4k_preset.dart';
import '../infra/diagnostics/diag.dart';

/// 把 Anime4K 档位翻译成 libmpv `glsl-shaders` 命令并下发。
/// [runner] 注入下发命令（生产接 PlayerController.runMpvCommand），便于单测。
class Anime4kController {
  final Future<void> Function(List<String> args) runner;
  Anime4kController({required this.runner});

  String? _shaderDir;
  Anime4kPreset _preset = Anime4kPreset.off;
  Anime4kPreset get preset => _preset;

  /// shader 解包目录（解包完成后由启动流程注入）。
  void setShaderDir(String dir) => _shaderDir = dir;

  /// 只记档位、**不下发**。
  ///
  /// 宿主自己不播（主窗口）时用：`setPreset` 会立刻走 `runner`，而 runner 绑的是
  /// 播放器 —— 那会在"从不播放的进程"里凭空建一个 mpv 实例。
  /// 档位仍然记着，真正播出时由换片流程（`reapply` / `exitSwitchWindow(reapply: true)`）
  /// 挂上链，行为与"启动时下发过一次"一致。
  void loadPreset(Anime4kPreset preset) => _preset = preset;

  /// 切换档位并立即下发。
  Future<void> setPreset(Anime4kPreset preset) async {
    _preset = preset;
    await _apply();
  }

  /// 用当前档位重新下发（换片后保持生效）。
  Future<void> reapply() => _apply();

  /// 当前档位是否有实际生效的 shader（off → false）。
  /// 换片流程据此决定是否需要「先清后恢复」超分。
  bool get hasShaders => anime4kShaderChain(_preset).isNotEmpty;

  /// 换片前清掉超分但保留当前档位。复刻用户实测安全的路径「先关超分→换片→再开」：
  /// `clr` 在任意视频输出状态下都安全，而 `set` 撞上换片时的渲染上下文重建会原生崩溃，
  /// 故换片前先 clr，等新文件 VO 就绪后再由 [reapply] 把档位 set 回去。
  Future<void> clearForSwitch() async {
    await diag.breadcrumbFlushed('anime4k:clearForSwitch (keep ${_preset.name})');
    try {
      await runner(['change-list', 'glsl-shaders', 'clr', '']);
    } catch (e, st) {
      diag.warn('anime4k', 'clearForSwitch failed', e, st);
    }
  }

  // ── 换片保护窗口 ──────────────────────────────────────────────────────────
  // 从 open 到新文件 VO 重建稳定之间，任何 glsl-shaders `set`（包括用户此刻在
  // 右键菜单切档）都会与 GPU 渲染上下文重建竞争 → libmpv 原生崩溃。窗口内的
  // set 一律记账延后，由 [exitSwitchWindow] 统一按「最新档位」补发；clr 任意
  // VO 状态下都安全，不受窗口影响。
  bool _inSwitchWindow = false;
  bool _pendingApply = false;
  int _switchEpoch = 0;

  /// 进入保护窗口，返回票据。重叠换片时旧票据自动失效（epoch 递增）。
  /// 进入时链非空 ⇒ 出窗口需补发（换片流程随后会 clearForSwitch 清掉现役 shader）。
  int enterSwitchWindow() {
    _inSwitchWindow = true;
    _pendingApply = hasShaders;
    diag.breadcrumb('anime4k:switchWindow enter (pending=$_pendingApply)');
    return ++_switchEpoch;
  }

  /// 离开保护窗口并补发窗口期内的最新档位。仅当 [token] 仍是当前窗口时生效；
  /// [reapply]=false 只解除窗口不补发（open 失败 / 无视频轨 / 超时等 set 不安全的情形，
  /// 此时不解除会把用户后续切档永久关死）。
  Future<void> exitSwitchWindow(int token, {bool reapply = true}) async {
    if (token != _switchEpoch || !_inSwitchWindow) return;
    _inSwitchWindow = false;
    final pending = _pendingApply;
    _pendingApply = false;
    diag.breadcrumb('anime4k:switchWindow exit (pending=$pending, reapply=$reapply)');
    if (pending && reapply) await _apply();
  }

  Future<void> _apply() async {
    final dir = _shaderDir;
    final chain = anime4kShaderChain(_preset);
    final wantSet = dir != null && chain.isNotEmpty;
    if (wantSet && _inSwitchWindow) {
      // 保护窗口内绝不下发 set：记账，出窗口统一补发最新档位。
      _pendingApply = true;
      diag.breadcrumb('anime4k:_apply deferred(switchWindow) ${_preset.name}');
      return;
    }
    if (!wantSet) _pendingApply = false; // 窗口内关掉超分：取消待补发
    // 超分下发是疑似原生崩溃高危点：先落一条同步面包屑，崩了也能看到「崩前在切超分」。
    await diag.breadcrumbFlushed('anime4k:_apply ${_preset.name} (${chain.length} shaders)');
    try {
      if (!wantSet) {
        await runner(['change-list', 'glsl-shaders', 'clr', '']);
      } else if (_inSwitchWindow) {
        // 上面 breadcrumb 落盘的 await 间隙可能恰好进入新窗口：改记账，绝不冒险。
        _pendingApply = true;
        return;
      } else {
        final paths = chain.map((f) => p.join(dir, f)).join(';');
        await runner(['change-list', 'glsl-shaders', 'set', paths]);
      }
      // 命令返回后再落一条:崩溃日志若只见上面的 _apply 而无此条,即崩在 set 命令内
      // (超分下发同步触发 GPU 着色器编译);若两条都在,则崩点在别处。
      await diag.breadcrumbFlushed('anime4k:_apply done ${_preset.name}');
    } catch (e, st) {
      diag.warn('anime4k', 'apply ${_preset.name} failed', e, st);
    }
  }
}
