#ifndef RUNNER_CRASH_HANDLER_H_
#define RUNNER_CRASH_HANDLER_H_

// Installs a process-wide unhandled-exception filter that writes a minidump
// (.dmp) to %LOCALAPPDATA%\ShikiiN\crashes\ and then chains to any previously
// installed filter (e.g. Flutter/crashpad). Call once, as early as possible in
// wWinMain, before the Flutter engine starts.
void InstallCrashHandler();

#endif  // RUNNER_CRASH_HANDLER_H_
