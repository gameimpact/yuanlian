#include "quality_process.h"

#include <algorithm>
#include <cwctype>

namespace {
void Close(HANDLE handle) {
  if (handle && handle != INVALID_HANDLE_VALUE) CloseHandle(handle);
}
std::vector<wchar_t> ChildEnvironment() {
  auto* block = GetEnvironmentStringsW();
  if (!block) return {};
  std::vector<wchar_t> result;
  for (auto* item = block; *item; item += wcslen(item) + 1) {
    const std::wstring entry(item);
    std::wstring name = entry.substr(0, entry.find(L'='));
    std::transform(name.begin(), name.end(), name.begin(),
        [](wchar_t ch) { return static_cast<wchar_t>(std::towupper(ch)); });
    if (name.rfind(L"YUANLIAN_", 0) == 0 || name.rfind(L"QT_", 0) == 0 ||
        name.rfind(L"QML", 0) == 0 || name == L"SSLKEYLOGFILE" ||
        name == L"OPENSSL_CONF" || name == L"OPENSSL_MODULES" ||
        name == L"SDL_DYNAMIC_API" || name == L"FFREPORT") continue;
    result.insert(result.end(), entry.begin(), entry.end());
    result.push_back(L'\0');
  }
  FreeEnvironmentStringsW(block);
  result.push_back(L'\0');
  return result;
}
}

std::wstring QualityProcess::Quote(const std::wstring& value) {
  std::wstring result = L"\"";
  size_t slashes = 0;
  for (wchar_t ch : value) {
    if (ch == L'\\') { ++slashes; continue; }
    result.append(ch == L'\"' ? slashes * 2 + 1 : slashes, L'\\');
    result += ch;
    slashes = 0;
  }
  result.append(slashes * 2, L'\\');
  return result + L"\"";
}

std::unique_ptr<QualityProcess> QualityProcess::Start(
    const std::wstring& executable, const std::vector<std::wstring>& arguments,
    bool capture_output, DWORD* error, const std::wstring& working_directory) {
  *error = ERROR_SUCCESS;
  if (executable.empty() || executable.find(L'\0') != std::wstring::npos ||
      arguments.size() > 64) {
    *error = ERROR_INVALID_PARAMETER;
    return nullptr;
  }
  std::wstring command = Quote(executable);
  for (const auto& argument : arguments) {
    if (argument.find(L'\0') != std::wstring::npos) {
      *error = ERROR_INVALID_PARAMETER;
      return nullptr;
    }
    command += L" " + Quote(argument);
  }
  if (command.size() >= 32767) {
    *error = ERROR_BAD_LENGTH;
    return nullptr;
  }
  auto environment = ChildEnvironment();
  if (environment.empty()) { *error = ERROR_ENVVAR_NOT_FOUND; return nullptr; }
  auto child = std::unique_ptr<QualityProcess>(new QualityProcess());
  child->job_ = CreateJobObjectW(nullptr, nullptr);
  JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits{};
  limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
  if (!child->job_ || !SetInformationJobObject(child->job_,
      JobObjectExtendedLimitInformation, &limits, sizeof(limits))) {
    *error = GetLastError();
    return nullptr;
  }

  SECURITY_ATTRIBUTES security{sizeof(SECURITY_ATTRIBUTES), nullptr, TRUE};
  HANDLE null_handle = CreateFileW(L"NUL", GENERIC_READ | GENERIC_WRITE,
      FILE_SHARE_READ | FILE_SHARE_WRITE, &security, OPEN_EXISTING, 0, nullptr);
  if (null_handle == INVALID_HANDLE_VALUE) {
    *error = GetLastError();
    return nullptr;
  }
  HANDLE output_write = null_handle;
  HANDLE error_write = null_handle;
  if (capture_output) {
    if (!CreatePipe(&child->output_read_, &output_write, &security, 4096) ||
        !SetHandleInformation(child->output_read_, HANDLE_FLAG_INHERIT, 0) ||
        !CreatePipe(&child->error_read_, &error_write, &security, 4096) ||
        !SetHandleInformation(child->error_read_, HANDLE_FLAG_INHERIT, 0)) {
      *error = GetLastError();
      if (output_write != null_handle) Close(output_write);
      if (error_write != null_handle) Close(error_write);
      Close(null_handle);
      return nullptr;
    }
  }

  STARTUPINFOEXW startup{};
  startup.StartupInfo.cb = sizeof(startup);
  startup.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
  startup.StartupInfo.hStdInput = null_handle;
  startup.StartupInfo.hStdOutput = output_write;
  startup.StartupInfo.hStdError = error_write;
  SIZE_T attribute_size = 0;
  InitializeProcThreadAttributeList(nullptr, 2, 0, &attribute_size);
  std::vector<unsigned char> storage(attribute_size);
  startup.lpAttributeList = reinterpret_cast<LPPROC_THREAD_ATTRIBUTE_LIST>(storage.data());
  bool initialized = InitializeProcThreadAttributeList(startup.lpAttributeList,
      2, 0, &attribute_size) != FALSE;
  std::vector<HANDLE> inherited{null_handle};
  if (capture_output) { inherited.push_back(output_write); inherited.push_back(error_write); }
  PROCESS_INFORMATION info{};
  BOOL created = FALSE;
  HANDLE jobs[] = {child->job_};
  if (initialized && UpdateProcThreadAttribute(startup.lpAttributeList, 0,
      PROC_THREAD_ATTRIBUTE_HANDLE_LIST, inherited.data(),
      inherited.size() * sizeof(HANDLE), nullptr, nullptr) &&
      UpdateProcThreadAttribute(startup.lpAttributeList, 0,
          PROC_THREAD_ATTRIBUTE_JOB_LIST, jobs, sizeof(jobs), nullptr, nullptr)) {
    const auto slash = executable.find_last_of(L"/\\");
    const auto directory = !working_directory.empty() ? working_directory :
        (slash == std::wstring::npos ? L"" : executable.substr(0, slash));
    created = CreateProcessW(executable.c_str(), command.data(), nullptr, nullptr,
        TRUE, CREATE_SUSPENDED | CREATE_NO_WINDOW | EXTENDED_STARTUPINFO_PRESENT | CREATE_UNICODE_ENVIRONMENT,
        environment.data(), directory.empty() ? nullptr : directory.c_str(),
        &startup.StartupInfo, &info);
  }
  if (!created) *error = GetLastError();
  if (initialized) DeleteProcThreadAttributeList(startup.lpAttributeList);
  if (capture_output) { Close(output_write); Close(error_write); }
  Close(null_handle);
  if (!created) return nullptr;

  child->process_ = info.hProcess;
  child->pid_ = info.dwProcessId;
  if (ResumeThread(info.hThread) == static_cast<DWORD>(-1)) {
    *error = GetLastError();
    TerminateProcess(child->process_, 1);
    Close(info.hThread);
    return nullptr;
  }
  Close(info.hThread);
  return child;
}

QualityProcess::~QualityProcess() {
  Close(job_);
  if (process_) WaitForSingleObject(process_, 300);
  Close(process_);
  Close(output_read_);
  Close(error_read_);
}

bool QualityProcess::Stop() { return TerminateJobObject(job_, 1) != FALSE; }

void QualityProcess::RequestClose() {
  EnumWindows([](HWND window, LPARAM owner) -> BOOL {
    DWORD process = 0;
    GetWindowThreadProcessId(window, &process);
    if (process == static_cast<DWORD>(owner)) PostMessageW(window, WM_CLOSE, 0, 0);
    return TRUE;
  }, static_cast<LPARAM>(pid_));
}

void QualityProcess::Drain(HANDLE pipe, bool capture) {
  if (!pipe) return;
  char buffer[4096];
  size_t budget = 65536;
  while (budget) {
    DWORD available = 0;
    if (!PeekNamedPipe(pipe, nullptr, 0, nullptr, &available, nullptr) || available == 0) return;
    DWORD read = 0;
    const DWORD count = std::min<DWORD>(available,
        static_cast<DWORD>(std::min(budget, sizeof(buffer))));
    if (!ReadFile(pipe, buffer, count, &read, nullptr) || read == 0) return;
    budget -= read;
    if (capture) {
      if (output_.size() + read > 65536) { overflow_ = true; Stop(); return; }
      output_.append(buffer, read);
    }
  }
}

bool QualityProcess::Poll(DWORD* exit_code, DWORD* error) {
  *error = ERROR_SUCCESS;
  Drain(output_read_, true);
  Drain(error_read_, false);
  const DWORD result = WaitForSingleObject(process_, 0);
  if (result == WAIT_TIMEOUT) return true;
  if (result != WAIT_OBJECT_0 || !GetExitCodeProcess(process_, exit_code)) {
    *error = GetLastError();
    return false;
  }
  Drain(output_read_, true);
  Drain(error_read_, false);
  return false;
}
