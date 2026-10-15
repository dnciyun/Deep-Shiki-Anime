/// 新拟态规范**守卫测试**（决策 A47 + 规范 §10 禁止事项）。
///
/// 规范：`docs/specs/2026-10-10-dsanima-neo-theme.md` §10。
///
/// 为什么要有这个文件：视觉规范靠人眼守不住。这一层直接扫 app/lib 的源码，
/// 把「边框 / 字号字面量 / 颜色字面量 / 手写阴影 / elevation」这几类
/// 会在后续改动里悄悄回潮的东西钉死。它比逐像素断言稳得多，也不会因为
/// 换配色而红。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 允许出现这些字面量的文件（基建本身就定义它们）。
///
/// 注意：路径是相对 `lib/` 的（`_rel` 用的就是它），所以不要带 `lib/` 前缀。
const Set<String> _allowed = <String>{
  'theme/tokens.dart', // 颜色与几何的唯一事实来源（也在这里创建 BoxShadow）
  'theme/app_theme.dart', // Material 组件主题里必须写 0 与透明色
  'ui/widgets/neo.dart', // 凹槽渐变 / 柔光内边 / 圆点尺寸在这里定义
  'ui/preview_page.dart', // 组件总览页本身就是展示各档的样例
};

/// 总览页/调试页：路径命中即跳过。
bool _isAllowed(String rel) => _allowed.contains(rel) || rel.startsWith('ui/preview_page.dart');

/// 注释行（含文档注释）不算代码，守卫不该把说明文字当违规。
bool _isComment(String line) {
  final String s = line.trimLeft();
  return s.startsWith('//') || s.startsWith('///') || s.startsWith('*');
}

List<File> _dartFiles(Directory root) => root
    .listSync(recursive: true)
    .whereType<File>()
    .where((File f) => f.path.endsWith('.dart'))
    .toList();

String _rel(Directory root, File f) => f.path.substring(root.path.length + 1).replaceAll(r'\', '/');

void main() {
  final Directory lib = Directory('lib');

  test('守卫：描边只允许「1px line / 极淡 divider / 焦点 2px 强调色 / 语义色细条」（规范 §7）', () {
    // 扁平化（第二十九轮）后的描边语言 —— 旧的「柔光内边 hairline」已随新拟态删除：
    //   1. `t.line` 1px —— 卡片 / 控件 / 凹槽的统一描边（规范 §3、§6）；
    //   2. `t.divider` —— 表格行等「必须分区」的极淡线；
    //   3. `t.accent` 2px —— 焦点 / 选中态（唯一允许的强调色描边）；
    //   4. `transparent` —— 明确不要边（如语义色胶囊选中态）；
    //   5. 语义色细条 `width: 3`（错误面板 / 横幅左侧，规范 §2.3）；
    //   6. 语义色 1px 描边（危险按钮的 danger 边）。
    // 其余一切硬边框（灰色实线、2px 以上的非强调色边、带颜色的装饰边）禁止。
    final RegExp borderish = RegExp(r'Border\.all\(|Border\.only\(|BorderSide\(');
    final List<String> offenders = <String>[];
    for (final File f in _dartFiles(lib)) {
      final String rel = _rel(lib, f);
      if (_isAllowed(rel)) continue;
      final List<String> lines = f.readAsLinesSync();
      for (int i = 0; i < lines.length; i++) {
        final String line = lines[i];
        if (_isComment(line)) continue;
        if (!borderish.hasMatch(line)) continue;
        // 例外 1：**颜色来自 token**（`t.line` / `t.base` / `tokens.accent` …）即合法 ——
        // 「颜色只从 DsTokens 取」这条由下面的 `Color(0x…)` 守卫保证，这里不再逐个名字列举
        //（第二十九轮加角标色点的 `t.base` 描边时，白名单式的写法就漏了一个）。
        if (RegExp(r'\b(t|tokens)\.\w+').hasMatch(line)) continue;
        // 旧命名参数（`divider`）与显式「不要边」。
        if (line.contains('divider')) continue;
        if (line.contains('transparent')) continue; // 无边框（chip 选中态等）
        // 例外 2：焦点 / 选中态强调色 2px
        if (line.contains('accent') && line.contains('2')) continue;
        // 例外 3：语义色描边（危险按钮的 danger 边）
        if (line.contains('danger') || line.contains('success') || line.contains('warning')) {
          continue;
        }
        // 例外 4：语义色细条（错误面板/横幅左侧）。声明可能跨行，
        // 所以往后看几行里有没有 `width: 3`（规范 §2.3 唯一允许的粗线）。
        final String window = lines.skip(i).take(4).join(' ').replaceAll(RegExp(r'\s+'), ' ');
        if (RegExp(r'width:\s*3\b').hasMatch(window)) continue;
        offenders.add('$rel:${i + 1}  ${line.trim()}');
      }
    }
    expect(offenders, isEmpty, reason: '描边只允许 1px line / divider / 焦点 2px 强调色 / 语义色。\n${offenders.join('\n')}');
  });

  test('守卫：lib 下不得再有硬编码 fontSize 字面量（规范 §10 第 4 条 / 决策 A35）', () {
    final RegExp literal = RegExp(r'fontSize:\s*[0-9]');
    final List<String> offenders = <String>[];
    for (final File f in _dartFiles(lib)) {
      final String rel = _rel(lib, f);
      if (_isAllowed(rel)) continue;
      final List<String> lines = f.readAsLinesSync();
      for (int i = 0; i < lines.length; i++) {
        if (_isComment(lines[i])) continue;
        if (literal.hasMatch(lines[i])) {
          offenders.add('$rel:${i + 1}  ${lines[i].trim()}');
        }
      }
    }
    expect(
      offenders,
      isEmpty,
      reason: '字号必须走 DsTypeScale（当前档位 12/14/15/17/24，见 theme/tokens.dart）。\n'
          '⚠️ 这个守卫只查"有没有数字字面量"，**不校验档位本身**：\n'
          '改档位时它不会红，得靠 tokens 的单测/代码评审。\n${offenders.join('\n')}',
    );
  });

  test('守卫：lib 下不得再有字面量圆角（规范 §10 第 3 条）', () {
    final RegExp literal = RegExp(r'BorderRadius\.circular\(\s*[0-9]');
    final List<String> offenders = <String>[];
    for (final File f in _dartFiles(lib)) {
      final String rel = _rel(lib, f);
      if (_isAllowed(rel)) continue;
      final List<String> lines = f.readAsLinesSync();
      for (int i = 0; i < lines.length; i++) {
        if (_isComment(lines[i])) continue;
        if (literal.hasMatch(lines[i])) {
          offenders.add('$rel:${i + 1}  ${lines[i].trim()}');
        }
      }
    }
    expect(
      offenders,
      isEmpty,
      reason: '圆角只用 t.radiusCard / t.radiusControl / t.radiusPill。\n${offenders.join('\n')}',
    );
  });

  test('守卫：lib 下不得再有 Color(0x…) 字面量（规范 §10 第 1 条）', () {
    final RegExp literal = RegExp(r'Color\(0x');
    final List<String> offenders = <String>[];
    for (final File f in _dartFiles(lib)) {
      final String rel = _rel(lib, f);
      if (_isAllowed(rel)) continue;
      final List<String> lines = f.readAsLinesSync();
      for (int i = 0; i < lines.length; i++) {
        if (_isComment(lines[i])) continue;
        if (literal.hasMatch(lines[i])) {
          offenders.add('$rel:${i + 1}  ${lines[i].trim()}');
        }
      }
    }
    expect(offenders, isEmpty, reason: '颜色只从 DsTokens 取；硬编码颜色会绕过两套外观。\n${offenders.join('\n')}');
  });

  test('守卫：lib 下不得手写 BoxShadow，也不得用非 0 elevation（规范 §10 第 5/6 条）', () {
    final List<String> shadowOffenders = <String>[];
    final List<String> elevationOffenders = <String>[];
    for (final File f in _dartFiles(lib)) {
      final String rel = _rel(lib, f);
      if (_isAllowed(rel)) continue;
      final List<String> lines = f.readAsLinesSync();
      for (int i = 0; i < lines.length; i++) {
        final String line = lines[i];
        if (line.contains('BoxShadow(')) {
          shadowOffenders.add('$rel:${i + 1}  ${line.trim()}');
        }
        if (RegExp(r'elevation:\s*(?!0\b)[0-9]').hasMatch(line)) {
          elevationOffenders.add('$rel:${i + 1}  ${line.trim()}');
        }
      }
    }
    expect(
      shadowOffenders,
      isEmpty,
      reason: '阴影只走 t.shadows(档位)，否则「简洁模式」关不掉。\n${shadowOffenders.join('\n')}',
    );
    expect(
      elevationOffenders,
      isEmpty,
      reason: '新拟态不用 Material elevation。\n${elevationOffenders.join('\n')}',
    );
  });

  test('守卫：阴影只允许悬浮层 —— 业务代码里不得出现 `shadows(`（规范 §7 / 决策 F19）', () {
    // 悬浮层（对话框 / 菜单 / tooltip / 下拉）在白名单里画阴影；其余一律零阴影。
    final RegExp call = RegExp(r'\.shadows\(');
    final List<String> offenders = <String>[];
    for (final File f in _dartFiles(lib)) {
      final String rel = _rel(lib, f);
      if (_isAllowed(rel)) continue;
      final List<String> lines = f.readAsLinesSync();
      for (int i = 0; i < lines.length; i++) {
        if (_isComment(lines[i])) continue;
        if (call.hasMatch(lines[i])) {
          offenders.add('$rel:${i + 1}  ${lines[i].trim()}');
        }
      }
    }
    expect(
      offenders,
      isEmpty,
      reason: '除悬浮层外一律零阴影（卡片/按钮/导航/表格/网格都不许有 boxShadow）。'
          '悬浮层请用 `elevation: t.overlayElevation` 或 `t.shadows(NeoShadowLevel.high)`。\n'
          '${offenders.join('\n')}',
    );
  });

  test('守卫：动画时长必须走 DsMotion（不得在 Animated* 里写死 Duration）', () {
    final RegExp durLiteral = RegExp(r'duration:\s*(const\s+)?Duration\(');
    final List<String> offenders = <String>[];
    for (final File f in _dartFiles(lib)) {
      final String rel = _rel(lib, f);
      if (_isAllowed(rel)) continue;
      final List<String> lines = f.readAsLinesSync();
      for (int i = 0; i < lines.length; i++) {
        final String line = lines[i];
        if (_isComment(line)) continue;
        if (!durLiteral.hasMatch(line)) continue;
        // ⚠️ 只看**动画 widget** 的 duration：`Timer` / 提示条存续时间不是动画时长
        //（把它们也算进来的话，spec F19③ 的原措辞会误伤一批无辜代码）。
        final String window = lines.skip(i > 4 ? i - 4 : 0).take(4).join(' ');
        if (!window.contains('Animated') &&
            !window.contains('AnimationController')) {
          continue;
        }
        offenders.add('$rel:${i + 1}  ${line.trim()}');
      }
    }
    expect(
      offenders,
      isEmpty,
      reason: '动画时长走 DsMotion（悬停 90 / 按下 60 / 页面·列表·浮层 180 / 轮播 320 / 外观 240）。\n'
          '${offenders.join('\n')}',
    );
  });

  test('守卫：第二十九轮删掉的过渡名不许回潮', () {
    const List<String> gone = <String>[
      'InsetSurface',
      'raisedDecoration',
      'sunkenDecoration',
      'hairline',
      'statusBarHeight',
      'simpleMode',
      'DsBrightness',
      'NeoShadowLevel.soft',
      'NeoShadowLevel.raised',
      'NeoShadowLevel.none',
      'DsTokens.light',
      'DsTokens.dark',
    ];
    final List<String> offenders = <String>[];
    for (final File f in _dartFiles(lib)) {
      final String rel = _rel(lib, f);
      if (_isAllowed(rel)) continue;
      final List<String> lines = f.readAsLinesSync();
      for (int i = 0; i < lines.length; i++) {
        if (_isComment(lines[i])) continue;
        for (final String name in gone) {
          if (lines[i].contains(name)) {
            offenders.add('$rel:${i + 1}  $name  ${lines[i].trim()}');
          }
        }
      }
    }
    expect(
      offenders,
      isEmpty,
      reason: '这些名字是过渡期的临时兼容层（第二十九轮已删）：新代码请用 8 套外观常量 / '
          '[cardDecoration] / [inset] / [DsInset]。\n${offenders.join('\n')}',
    );
  });

  test('守卫：主窗口不得创建 mpv（用户 2026-10-10 第二阶段优化 1）', () {
    // 主窗口从不播放（只有弹出播放窗口播），而 shikiin 默认会建一个 media_kit
    // `Player`（原生 mpv）。装配根必须传 `lazyPlayer: true`。
    final String src = File('lib/main.dart').readAsStringSync();
    expect(
      src.contains('lazyPlayer: true'),
      isTrue,
      reason: '主窗口 bootstrapPlayer 必须 lazyPlayer: true（否则凭空多一个 mpv 实例）',
    );
    // 而且必须真的注册了主窗口自己的窗口通道：子窗口"收起来"之后要能从反方向
    // 通知主窗口（用户 2026-10-11：点播放窗口的 ✕ = 收起，状态栏要切回"唤回"）。
    expect(
      src.contains('bindSelf()'),
      isTrue,
      reason: '装配根必须 await playerWindow.bindSelf()，否则收起后的状态同步会断',
    );
  });

  test('守卫：状态栏那颗播放按钮区分「正在播放」与「已收起」（用户 2026-10-11）', () {
    // 关掉播放器 = 停播 + 隐藏（引擎留着），所以"窗口还在"不等于"在播"。
    // 只看 isOpen 的话，收起之后状态栏会一直显示"正在播放"。
    final String src = File('lib/ui/shell.dart').readAsStringSync();
    expect(
      src.contains('playerWindowVisibleProvider'),
      isTrue,
      reason: '状态栏必须用 isOpen && !isHidden 判断是否在播',
    );
  });

  test('守卫：滚动列表内的阴影必须走列表安全档（规范 §3 / 决策 A31）', () {
    // 这份清单是「会长到几百行的滚动列表」所在文件（或其行组件所在文件）。
    // 通过条件二选一：
    //   (a) 文件里自己出现 |listSafe: true|，或
    //   (b) 它把行组件委托给 widgets/ 里已带 listSafe 的组件（自身完全不写阴影）。
    final Map<String, String> longListFiles = <String, String>{
      'lib/ui/home_page.dart': '主页网格',
      'lib/ui/queue_page.dart': '队列',
      'lib/ui/following_page.dart': '正在追',
      'lib/ui/widgets/search_sections.dart': '搜索结果表',
      'lib/ui/widgets/ds_cards.dart': '结果卡片/队列行/订阅行',
    };
    final List<String> offenders = <String>[];
    for (final MapEntry<String, String> e in longListFiles.entries) {
      final File f = File(e.key);
      if (!f.existsSync()) continue;
      final String src = f.readAsStringSync();
      if (src.contains('listSafe: true')) continue;
      // (b) 完全不碰阴影也算合格（阴影在别处、且那处带 listSafe）。
      if (!src.contains('t.shadows(')) continue;
      offenders.add('${e.key}（${e.value}）写了阴影但没有一处 listSafe: true');
    }
    expect(offenders, isEmpty, reason: '长列表里用模糊 > 2px 的阴影会掉帧。\n${offenders.join('\n')}');
  });

  test('守卫：播放流程不得操作主窗口（用户 2026-10-12 第八轮）', () {
    // 播放这一路（开窗 → 播放 → 收起/关闭）主窗口必须一次都不被碰。
    // 第七轮删掉了「给播放器腾地方」那条（它会取消主窗口最大化），第八轮又删掉了
    // 「收起播放器后把主窗口拽到前台」（它会显示主窗口 + 抢焦点）。这条守卫防它回潮。
    final String src = File('lib/app.dart').readAsStringSync();
    const List<String> forbidden = <String>[
      'windowManager.show(',
      'windowManager.focus(',
      'windowManager.maximize(',
      'windowManager.unmaximize(',
      'windowManager.setBounds(',
      'windowManager.setPosition(',
    ];
    final List<String> offenders = <String>[
      for (final String call in forbidden)
        if (src.contains(call)) call,
    ];
    expect(
      offenders,
      isEmpty,
      reason: 'lib/app.dart 不得再操作主窗口（用户 2026-10-12「播放后不要去动主窗口」）。\n'
          '${offenders.join('\n')}',
    );
  });
}
