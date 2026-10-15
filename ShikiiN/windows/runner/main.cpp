#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>
#include <shellapi.h>

#include "flutter_window.h"
#include "utils.h"
#include "crash_handler.h"

namespace {

constexpr const wchar_t kSingleInstanceMutexName[] = L"ShikiiN_SingleInstance_Mutex";
// 必须与 win32_window.cpp 的 kWindowClassName 一致。
constexpr const wchar_t kRunnerWindowClass[] = L"SHIKIIN_RUNNER_WIN32_WINDOW";
// WM_COPYDATA 的 dwData 魔数：'SHKN'，接收侧据此过滤无关消息。
constexpr ULONG_PTR kCopyDataOpenFile = 0x53484B4E;

// 已有实例：把命令行里的文件路径 WM_COPYDATA 过去并激活其窗口。
// 返回 false 表示没找到已有窗口，或有文件要转发但发送失败（对方挂死/超时）——
// 两种情况都退化为正常启动，宁可双开也不吞掉用户的打开请求。
bool ForwardToExistingInstance() {
  HWND hwnd = nullptr;
  // 互斥体已存在但窗口可能尚未创建完：重试最多 3 秒。
  for (int i = 0; i < 15 && !hwnd; ++i) {
    hwnd = ::FindWindowW(kRunnerWindowClass, nullptr);
    if (!hwnd) ::Sleep(200);
  }
  if (!hwnd) return false;

  bool delivered = true;
  int argc = 0;
  wchar_t** argv = ::CommandLineToArgvW(::GetCommandLineW(), &argc);
  if (argv != nullptr && argc > 1) {
    // 取第一个不像开关的参数：真实文件路径不会以 '-' 开头，而 flutter run 等
    // 会混入 --xxx 调试开关。有效性（存在/是视频）由接收侧 Dart 校验。
    wchar_t* file_arg = nullptr;
    for (int i = 1; i < argc && file_arg == nullptr; ++i) {
      if (argv[i][0] != L'-') file_arg = argv[i];
    }
    if (file_arg != nullptr) {
      COPYDATASTRUCT cds{};
      cds.dwData = kCopyDataOpenFile;
      cds.cbData = static_cast<DWORD>((wcslen(file_arg) + 1) * sizeof(wchar_t));
      cds.lpData = file_arg;
      // wParam 传 0 是有意为之：本进程没有窗口，接收侧不得假设有有效的发送者 HWND。
      delivered = ::SendMessageTimeoutW(hwnd, WM_COPYDATA, 0,
                                        reinterpret_cast<LPARAM>(&cds),
                                        SMTO_ABORTIFHUNG, 3000, nullptr) != 0;
    }
  }
  if (argv != nullptr) ::LocalFree(argv);
  if (!delivered) return false;

  if (::IsIconic(hwnd)) ::ShowWindow(hwnd, SW_RESTORE);
  ::SetForegroundWindow(hwnd);
  return true;
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Install our minidump writer before anything else (esp. before the Flutter
  // engine / crashpad), so native crashes during startup are captured too.
  InstallCrashHandler();

  // 单实例：互斥体已存在则把打开请求转发给已有实例后退出。
  // 创建失败（极端情况）不阻断启动，退化为多实例。
  HANDLE single_instance_mutex =
      ::CreateMutexW(nullptr, TRUE, kSingleInstanceMutexName);
  if (single_instance_mutex != nullptr &&
      ::GetLastError() == ERROR_ALREADY_EXISTS) {
    if (ForwardToExistingInstance()) {
      ::CloseHandle(single_instance_mutex);
      return EXIT_SUCCESS;
    }
    // 找不到已有窗口（对方启动超时/卡死）：退化为正常启动，宁可双开也不吞掉用户的打开请求。
  }

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"shikiin", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
