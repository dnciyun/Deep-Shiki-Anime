# DSAnima

Windows 桌面端的实时磁力播放器：番剧订阅 / 聚合搜索 → 边下边播（内嵌 ShikiiN 播放器 +
rqbit 引擎边车）。

解压即用、**完全便携**：双击 `dsanima.exe` 就能跑，所有数据（设置、播放记录、下载队列、
封面缓存）都在**同目录的 `DSAnima-data`** 里 —— 换文件夹、换台机器，把整个目录拷过去就行。

## 能干什么

* **边下边播**：磁力 / 种子直接播，不用等下完。内嵌 ShikiiN 播放器 + rqbit 引擎边车：
  进度可拖、播放位置自动记住（"看到几分几秒"）；
* **番剧订阅与聚合搜索**：mikan 等来源；可按字幕组 / 画质筛；搜索支持多源聚合与单源切换；
* **今日推荐 + 动漫库**：首页轮播、分类库（季度 / 放送状态 / 标签），点进详情看剧集列表；
* **下载队列与做种**：限速、做种比例、"暂停 / 继续全部"、后台常驻（托盘）继续下载；
* **观看记录**：续播位置、已看完标记；历史按保留天数自动清理；
* **8 套外观**：点击即换（带圆形揭开动画）、扁平化界面、封面尺寸与轮播形状可调；
* **程序内更新**：设置 → 更新 · 版本，填更新源即可检查新版本 → 下载整包 → 自动覆盖并重启
  （私有仓库或匿名读不到时，填一个只读令牌）。

## 下载 / 安装

到 [Releases](https://github.com/dnciyun/Deep-Shiki-Anime/releases/latest) 下载最新的
`DSAnima-<日期>-win-x64.zip`，**解压**后双击里面的 `dsanima.exe`。

> ⚠️ 别把 exe 单独拖出来：`data/`、`flutter_windows.dll`、`rqbit-engine.exe` 必须和它在一起。

## 更新

程序内：**设置 → 更新 · 版本** → 直接点「检查更新」。更新源**已内置**
（`dnciyun/Deep-Shiki-Anime` —— 那一格留空就用它，只有想换成自己的仓库才需要填）
→ 发现新版本后「下载更新包」→「立即重启并更新」。程序会正常退出（先落盘、再停边车），
几秒后以新版本重新打开；设置与观看记录都在 `DSAnima-data` 里，不受影响。

> 2026-10-18：仓库从旧的 `ciciyouxihao-source/DSAnima` 换到这里 —— 旧地址被 GitHub
> 限制可见性，匿名访问（也就是程序里那条检查更新）一律 404。源码与发布包现在都在
> Deep-Shiki-Anime 这个仓库；想在程序里绑别的仓库，把「更新源」那一格填上即可。

* 检查更新与下载走 GitHub 的**公开接口（匿名）**，匿名额度 60 次/小时 —— 所以检查是手动点的；
* 匿名读不到发布信息时（私有仓库、或账号对未登录访客不可见），在同一组里填一个**只读访问令牌**：
  GitHub → `Settings → Developer settings → Fine-grained tokens`，权限只勾
  **Contents: Read-only**。它只存在你自己的机器上（`DSAnima-data/store`），不会发往任何地方；
* 覆盖更新时，脚本最多等程序 45 秒；还退不掉就强制关掉**本安装目录**里的
  `dsanima` / `rqbit-engine` 再复制（别处的实例不受影响）。覆盖用 `robocopy /E`，
  **不删**安装目录里其它文件。全过程记录在 `DSAnima-data/update/apply.log`。

## 从源码构建

需要 Flutter（Windows 桌面版）与 Rust（引擎边车）；播放器库 `ShikiiN` 已包含在本仓库
（`app/pubspec.yaml` 里是 `path: ../ShikiiN`）。

```powershell
# ① 引擎边车（Rust）
cd engine
cargo build --release          # 产物：engine\target\release\rqbit-engine.exe
cargo test                     # 可选：单元 + 集成测试（全部走本机回环，不访问公网）
cd ..

# ② 宿主（Flutter）
cd app
flutter pub get
flutter build windows --release   # 产物：app\build\windows\x64\runner\Release
```

### 打包成便携版（发布包）

1. 把 `app\build\windows\x64\runner\Release\` 里的**全部内容**复制到一个新文件夹；
2. 把 `engine\target\release\rqbit-engine.exe` 放进**同一层**（程序优先用 exe 同目录的边车）；
3. 压缩这个文件夹 —— 就是发布包，形如 `DSAnima-<日期>-win-x64.zip`，解压即用。

**别把 `DSAnima-data\` 打进包里**：那是每台机器自己的设置 / 记录 / 缓存。

### 版本号

`app/pubspec.yaml` 的 `version:`（形如 `1.0.0+1`）就是程序内「检查更新」的比较基准；
发布新版本时把它与 `app/lib/domain/app_version.dart` 的 `kAppVersion` **一起改**
（两处不一致会有一条测试直接报错）。

## 目录

| 路径 | 是什么 |
| --- | --- |
| `app/` | Flutter 宿主（UI / 状态 / 适配层） |
| `core/` | 纯 Dart 领域层（判定、解析、模型），不认识 Flutter |
| `ShikiiN/` | 内嵌播放器库（独立包） |
| `engine/` | rqbit 边车（Rust） |

## 许可

见 [LICENSE](LICENSE)。
