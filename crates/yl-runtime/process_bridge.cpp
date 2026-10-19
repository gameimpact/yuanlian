#include "quality_process.h"
extern "C" {
void* yl_process_start(const wchar_t* exe, const wchar_t* const* args,
    size_t count, const wchar_t* cwd, bool capture, DWORD* error) {
  std::vector<std::wstring> values;
  for (size_t i = 0; i < count; ++i) values.emplace_back(args[i]);
  return QualityProcess::Start(exe, values, capture, error, cwd).release();
}
int yl_process_poll(void* process, DWORD* code, DWORD* error) {
  return static_cast<QualityProcess*>(process)->Poll(code, error) ? 1 : 0;
}
const char* yl_process_output(void* process, size_t* size) {
  const auto& output = static_cast<QualityProcess*>(process)->output();
  *size = output.size();
  return output.data();
}
void yl_process_free(void* process) { delete static_cast<QualityProcess*>(process); }
void yl_process_close(void* process) { static_cast<QualityProcess*>(process)->RequestClose(); }
DWORD yl_process_pid(void* process) { return static_cast<QualityProcess*>(process)->pid(); }
}
