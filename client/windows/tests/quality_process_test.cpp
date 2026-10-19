#include "quality_process.h"
#include <cstdio>
#include <filesystem>
#include <string>

namespace {
bool Wait(QualityProcess* process, DWORD* code, DWORD timeout = 10000) {
  const auto deadline = GetTickCount64() + timeout;
  while (GetTickCount64() < deadline) {
    DWORD error = 0;
    if (!process->Poll(code, &error)) return error == ERROR_SUCCESS;
    Sleep(10);
  }
  return false;
}
}

int wmain(int argc, wchar_t** argv) {
  if (argc > 1 && std::wstring(argv[1]) == L"--sleep") { Sleep(60000); return 0; }
  if (argc > 1 && std::wstring(argv[1]) == L"--exit259") return 259;
  if (argc > 1 && std::wstring(argv[1]) == L"--env") {
    wchar_t value[256];
    return GetEnvironmentVariableW(L"YUANLIAN_JOB_TEST_SECRET", value, 256) == 0 &&
        GetEnvironmentVariableW(L"SystemRoot", value, 256) > 0 ? 0 : 16;
  }
  if (argc > 1 && std::wstring(argv[1]) == L"--args") {
    return argc == 6 && std::wstring(argv[2]) == L"two words" &&
        std::wstring(argv[3]) == L"quote\"slash\\" &&
        std::wstring(argv[4]).empty() && std::wstring(argv[5]) == L"中文 空格" ? 0 : 13;
  }
  if (argc > 1 && std::wstring(argv[1]) == L"--output") {
    const std::string block(4096, 'x');
    for (int i = 0; i < 256; ++i) std::fwrite(block.data(), 1, block.size(), stderr);
    std::printf("expected stdout\n"); return 7;
  }
  if (argc > 1 && std::wstring(argv[1]) == L"--overflow") {
    const std::string block(4096, 'x');
    for (int i = 0; i < 32; ++i) std::fwrite(block.data(), 1, block.size(), stdout);
    return 0;
  }
  wchar_t buffer[32768];
  const DWORD length = GetModuleFileNameW(nullptr, buffer, 32768);
  if (!length || length >= 32768) return 2;
  const std::wstring executable(buffer, length);
  if (argc > 2 && std::wstring(argv[1]) == L"--parent") {
    DWORD error = 0;
    auto child = QualityProcess::Start(executable, {L"--sleep"}, false, &error);
    if (!child) return 3;
    HANDLE file = CreateFileW(argv[2], GENERIC_WRITE, FILE_SHARE_READ, nullptr,
        CREATE_ALWAYS, 0, nullptr);
    if (file == INVALID_HANDLE_VALUE) return 4;
    const DWORD pid = child->pid();
    DWORD written = 0;
    WriteFile(file, &pid, sizeof(pid), &written, nullptr);
    CloseHandle(file);
    Sleep(60000); return 0;
  }
  DWORD error = 0, code = 0;
  SetEnvironmentVariableW(L"YUANLIAN_JOB_TEST_SECRET", L"synthetic");
  auto env = QualityProcess::Start(executable, {L"--env"}, false, &error);
  SetEnvironmentVariableW(L"YUANLIAN_JOB_TEST_SECRET", nullptr);
  if (!env || !Wait(env.get(), &code) || code != 0) return 16;
  auto args = QualityProcess::Start(executable,
      {L"--args", L"two words", L"quote\"slash\\", L"", L"中文 空格"}, false, &error);
  if (!args || !Wait(args.get(), &code) || code != 0) return 10;
  auto output = QualityProcess::Start(executable, {L"--output"}, true, &error);
  if (!output || !Wait(output.get(), &code) || code != 7 || output->output() != "expected stdout\r\n") return 11;
  auto overflow = QualityProcess::Start(executable, {L"--overflow"}, true, &error);
  if (!overflow || !Wait(overflow.get(), &code) || !overflow->overflow() || overflow->output().size() > 65536) return 12;
  auto exit259 = QualityProcess::Start(executable, {L"--exit259"}, false, &error);
  if (!exit259 || !Wait(exit259.get(), &code) || code != 259) return 14;
  auto discarded = QualityProcess::Start(executable, {L"--output"}, false, &error);
  if (!discarded || !Wait(discarded.get(), &code) || code != 7 || !discarded->output().empty()) return 15;

  const auto pid_file = (std::filesystem::path(executable).parent_path() / L"child.pid").wstring();
  auto parent = QualityProcess::Start(executable, {L"--parent", pid_file}, false, &error);
  if (!parent) return 20;
  DWORD child_pid = 0;
  const auto deadline = GetTickCount64() + 5000;
  while (GetTickCount64() < deadline) {
    HANDLE file = CreateFileW(pid_file.c_str(), GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE,
        nullptr, OPEN_EXISTING, 0, nullptr);
    if (file != INVALID_HANDLE_VALUE) {
      DWORD read = 0;
      ReadFile(file, &child_pid, sizeof(child_pid), &read, nullptr);
      CloseHandle(file);
      if (read == sizeof(child_pid)) break;
    }
    Sleep(10);
  }
  HANDLE child_handle = OpenProcess(SYNCHRONIZE | PROCESS_QUERY_LIMITED_INFORMATION, FALSE, child_pid);
  HANDLE parent_handle = OpenProcess(PROCESS_TERMINATE, FALSE, parent->pid());
  if (!child_handle || !parent_handle) return 21;
  // Kill only the parent process, not its outer job. The child's private job
  // handle must be closed by the OS and kill the still-live grandchild.
  TerminateProcess(parent_handle, 99);
  const bool dead = WaitForSingleObject(child_handle, 3000) == WAIT_OBJECT_0;
  CloseHandle(child_handle); CloseHandle(parent_handle);
  if (!dead) return 22;
  DeleteFileW(pid_file.c_str());
  std::printf("PASS: argv quoting, bounded output, discarded logs, exit 259, parent crash kills child\n");
  return 0;
}
