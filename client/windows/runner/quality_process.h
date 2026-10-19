#ifndef YUANLIAN_QUALITY_PROCESS_H_
#define YUANLIAN_QUALITY_PROCESS_H_

#include <windows.h>
#include <memory>
#include <string>
#include <vector>

// The job is private and non-inheritable. Assign atomically at creation using
// PROC_THREAD_ATTRIBUTE_JOB_LIST, then resume after successful initialization.
class QualityProcess {
 public:
  static std::unique_ptr<QualityProcess> Start(
      const std::wstring& executable, const std::vector<std::wstring>& arguments,
      bool capture_output, DWORD* error, const std::wstring& working_directory = L"");
  ~QualityProcess();
  bool Stop();
  void RequestClose();
  bool Poll(DWORD* exit_code, DWORD* error);
  DWORD pid() const { return pid_; }
  const std::string& output() const { return output_; }
  bool overflow() const { return overflow_; }
  static std::wstring Quote(const std::wstring& value);

 private:
  QualityProcess() = default;
  void Drain(HANDLE pipe, bool capture);
  HANDLE job_ = nullptr;
  HANDLE process_ = nullptr;
  HANDLE output_read_ = nullptr;
  HANDLE error_read_ = nullptr;
  DWORD pid_ = 0;
  std::string output_;
  bool overflow_ = false;
};

#endif
