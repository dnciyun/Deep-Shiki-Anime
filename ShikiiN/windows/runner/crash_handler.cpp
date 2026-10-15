#include "crash_handler.h"

#include <windows.h>
#include <dbghelp.h>
#include <shlobj.h>

#include <string>

namespace {

// Previously installed filter (Flutter/crashpad). We chain to it so we never
// swallow a crash that the engine also wants to handle.
LPTOP_LEVEL_EXCEPTION_FILTER g_previous_filter = nullptr;

// Build %LOCALAPPDATA%\ShikiiN\crashes and ensure it exists. Returns false on
// failure. Uses only crash-safe Win32 APIs (no CRT heap churn beyond std::wstring).
bool EnsureCrashDir(std::wstring& out_dir) {
  PWSTR local_app_data = nullptr;
  if (FAILED(SHGetKnownFolderPath(FOLDERID_LocalAppData, 0, nullptr,
                                  &local_app_data))) {
    return false;
  }
  std::wstring dir = local_app_data;
  CoTaskMemFree(local_app_data);
  dir += L"\\ShikiiN";
  CreateDirectoryW(dir.c_str(), nullptr);  // ok if it already exists
  dir += L"\\crashes";
  CreateDirectoryW(dir.c_str(), nullptr);
  out_dir = dir;
  return true;
}

LONG WINAPI OurFilter(EXCEPTION_POINTERS* exception_pointers) {
  std::wstring dir;
  if (EnsureCrashDir(dir)) {
    SYSTEMTIME st;
    GetLocalTime(&st);
    wchar_t path[MAX_PATH];
    swprintf_s(path, MAX_PATH,
               L"%s\\crash-%04d%02d%02d-%02d%02d%02d.dmp", dir.c_str(),
               st.wYear, st.wMonth, st.wDay, st.wHour, st.wMinute, st.wSecond);
    HANDLE file = CreateFileW(path, GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS,
                              FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file != INVALID_HANDLE_VALUE) {
      MINIDUMP_EXCEPTION_INFORMATION mei;
      mei.ThreadId = GetCurrentThreadId();
      mei.ExceptionPointers = exception_pointers;
      mei.ClientPointers = FALSE;
      const MINIDUMP_TYPE type = static_cast<MINIDUMP_TYPE>(
          MiniDumpWithIndirectlyReferencedMemory | MiniDumpScanMemory);
      MiniDumpWriteDump(GetCurrentProcess(), GetCurrentProcessId(), file,
                        type, &mei, nullptr, nullptr);
      CloseHandle(file);
    }
  }
  // Chain to the previously installed filter; do not swallow the crash.
  if (g_previous_filter != nullptr) {
    return g_previous_filter(exception_pointers);
  }
  return EXCEPTION_EXECUTE_HANDLER;
}

}  // namespace

void InstallCrashHandler() {
  g_previous_filter = SetUnhandledExceptionFilter(OurFilter);
}
