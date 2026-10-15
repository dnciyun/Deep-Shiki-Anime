#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <memory>
#include <string>

#include "win32_window.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  // 控制 IME 开关的方法通道（默认禁用，文本框聚焦时由 Dart 启用）。
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> ime_channel_;

  // 二次实例转发打开文件：原生 → Dart 的通道 + Dart 就绪前的暂存。
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> file_open_channel_;
  bool dart_ready_ = false;
  std::string pending_open_path_;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
