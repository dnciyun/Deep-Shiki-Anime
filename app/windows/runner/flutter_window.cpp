#include "flutter_window.h"

#include <optional>

#include "flutter/generated_plugin_registrant.h"
// 独立播放窗口（desktop_multi_window）：插件创建的每个子窗口都有自己的
// FlutterEngine，插件必须为那些引擎显式注册，否则子窗口里的 MethodChannel
// 永远不 resolve（插件 README 明确要求这两处改动）。
#include "desktop_multi_window/desktop_multi_window_plugin.h"

namespace {

// 主窗口（frame 与它的 FLUTTERVIEW）**注册插件之前**的原始 WndProc。
//
// 用文件级静态而不是 lambda 捕获：`DesktopMultiWindowSetWindowCreatedCallback` 只接受
// **无捕获**的 C 函数指针。见 `FlutterWindow::OnCreate` 里的长注释。
HWND g_main_frame = nullptr;
HWND g_main_view = nullptr;
WNDPROC g_main_frame_proc = nullptr;
WNDPROC g_main_view_proc = nullptr;

/// 谁把主窗口的 WndProc 换掉了就还原回"原件"。
///
/// 为什么要这一层：`media_kit_video` 的 Windows 端是**进程级单例**
/// （`static MediaKitVideoPlugin* instance_`）并且会 `SetWindowLongPtr(GWLP_WNDPROC)`；
/// 主窗口引擎与每个弹出播放窗口引擎都会注册一次它，后注册的那次会把 `instance_` 抢走，
/// 于是先被换掉 WndProc 的主窗口转发消息时会用**别人**的 `original_window_proc_`，
/// 转发不成直接 `DefWindowProc` ⇒ 主窗口从此收不到任何消息（用户 2026-10-11 第四次：
// 「打开播放器后，除了播放器，其余全部卡死」）。主窗口这一侧从不播放视频，
/// 所以它不需要这个子类化：注册完就还原。
void RestoreMainWindowProcs() {
  if (g_main_frame != nullptr && g_main_frame_proc != nullptr) {
    if (reinterpret_cast<WNDPROC>(
            ::GetWindowLongPtr(g_main_frame, GWLP_WNDPROC)) != g_main_frame_proc) {
      ::SetWindowLongPtr(g_main_frame, GWLP_WNDPROC,
                         reinterpret_cast<LONG_PTR>(g_main_frame_proc));
    }
  }
  if (g_main_view != nullptr && g_main_view_proc != nullptr) {
    if (reinterpret_cast<WNDPROC>(
            ::GetWindowLongPtr(g_main_view, GWLP_WNDPROC)) != g_main_view_proc) {
      ::SetWindowLongPtr(g_main_view, GWLP_WNDPROC,
                         reinterpret_cast<LONG_PTR>(g_main_view_proc));
    }
  }
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  // 注册插件前先记下两个窗口自己的 WndProc（见本文件顶部的长注释）。
  // ⚠️ 此刻 `SetChildContent` 还没跑，所以 view 还是**独立的顶层窗口**，
  // `media_kit_video` 的 `GetAncestor(view, GA_ROOT)` 拿到的就是 view 自己 ——
  // 真机实测被换掉 WndProc 的正是 **FLUTTERVIEW**（鼠标消息进的也是它）。
  g_main_frame = GetHandle();
  g_main_view = flutter_controller_->view()->GetNativeWindow();
  g_main_frame_proc = reinterpret_cast<WNDPROC>(
      ::GetWindowLongPtr(g_main_frame, GWLP_WNDPROC));
  g_main_view_proc = reinterpret_cast<WNDPROC>(
      ::GetWindowLongPtr(g_main_view, GWLP_WNDPROC));
  RegisterPlugins(flutter_controller_->engine());
  RestoreMainWindowProcs();

  // 子窗口引擎也要注册插件（否则 window_manager / tray 等在子窗口里不可用）。
  DesktopMultiWindowSetWindowCreatedCallback([](void* controller) {
    auto* flutter_view_controller =
        reinterpret_cast<flutter::FlutterViewController*>(controller);
    auto* registry = flutter_view_controller->engine();
    RegisterPlugins(registry);
    // 每多一个引擎就多注册一次那几个"进程级单例"插件：注册完把主窗口的 WndProc 再还原一次
    // （这一整类 bug 都是这么来的，见 RestoreMainWindowProcs 的注释）。
    RestoreMainWindowProcs();
  });
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
