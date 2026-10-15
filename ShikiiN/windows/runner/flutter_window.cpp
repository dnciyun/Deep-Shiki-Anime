#include "flutter_window.h"

#include <windows.h>
#include <imm.h>

#include <optional>

#include "flutter/generated_plugin_registrant.h"
#include "utils.h"

namespace {

constexpr ULONG_PTR kCopyDataOpenFile = 0x53484B4E;  // 与 main.cpp 发送侧一致（'SHKN'）

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
  RegisterPlugins(flutter_controller_->engine());
  HWND view_hwnd = flutter_controller_->view()->GetNativeWindow();
  SetChildContent(view_hwnd);

  // 默认禁用 IME：播放/快捷键状态下中文输入法不应拦截字母/空格键做拼音合成。
  // 当 Dart 检测到文本输入框聚焦时，通过下面的通道临时启用 IME（可输入中文）。
  ImmAssociateContextEx(view_hwnd, nullptr, IACE_IGNORENOCONTEXT);

  ime_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "shikiin/ime",
      &flutter::StandardMethodCodec::GetInstance());
  ime_channel_->SetMethodCallHandler(
      [view_hwnd](const flutter::MethodCall<flutter::EncodableValue>& call,
                  std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        if (call.method_name() == "enable") {
          ImmAssociateContextEx(view_hwnd, nullptr, IACE_DEFAULT);
          result->Success();
        } else if (call.method_name() == "disable") {
          ImmAssociateContextEx(view_hwnd, nullptr, IACE_IGNORENOCONTEXT);
          result->Success();
        } else {
          result->NotImplemented();
        }
      });

  // 二次实例转发的打开文件通道。Dart 侧启动完成后调 "ready"：
  // 标记就绪并取回就绪前暂存的路径（若有），此后 WM_COPYDATA 直接 InvokeMethod。
  file_open_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "shikiin/file_open",
      &flutter::StandardMethodCodec::GetInstance());
  file_open_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        if (call.method_name() == "ready") {
          dart_ready_ = true;
          if (!pending_open_path_.empty()) {
            result->Success(flutter::EncodableValue(pending_open_path_));
            pending_open_path_.clear();
          } else {
            result->Success();
          }
        } else {
          result->NotImplemented();
        }
      });

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
  // 二次实例经 WM_COPYDATA 转发的打开文件请求（main.cpp 发送，魔数 'SHKN'）。
  // 非本应用魔数的 WM_COPYDATA 不吞：落到下面的默认处理链。
  if (message == WM_COPYDATA) {
    auto* cds = reinterpret_cast<COPYDATASTRUCT*>(lparam);
    if (cds != nullptr && cds->dwData == kCopyDataOpenFile && cds->lpData != nullptr &&
        cds->cbData >= sizeof(wchar_t) && cds->cbData <= 32768 * sizeof(wchar_t)) {
      // 跨进程数据：拷贝为 owned 字符串并剥掉尾部 null，再转 UTF-8。
      std::wstring wide(static_cast<const wchar_t*>(cds->lpData),
                        cds->cbData / sizeof(wchar_t));
      while (!wide.empty() && wide.back() == L'\0') wide.pop_back();
      if (!wide.empty()) {
        std::string path = Utf8FromUtf16(wide.c_str());
        // 同 WM_FONTCHANGE 的判空先例：OnDestroy 置空 flutter_controller_ 后
        // engine/messenger 已销毁，此时 InvokeMethod 是悬垂指针调用——退出期
        // 收到的转发走暂存分支（无害，进程即将退出）。
        if (flutter_controller_ && dart_ready_ && file_open_channel_) {
          file_open_channel_->InvokeMethod(
              "open", std::make_unique<flutter::EncodableValue>(path));
        } else {
          pending_open_path_ = path;  // Dart 未就绪：暂存，ready 握手时返回
        }
      }
      return TRUE;
    }
  }

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
      // OnDestroy 置空 flutter_controller_ 后仍可能收到广播消息：判空防退出期空指针崩溃。
      if (flutter_controller_) {
        flutter_controller_->engine()->ReloadSystemFonts();
      }
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
