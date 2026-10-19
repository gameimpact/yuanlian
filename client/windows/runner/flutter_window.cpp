#include "flutter_window.h"

#include <optional>
#include <flutter/standard_method_codec.h>
#include <variant>

#include "flutter/generated_plugin_registrant.h"

namespace {
std::wstring FromUtf8(const std::string& text) {
  if (text.empty() || text.size() > 32766 || text.find('\0') != std::string::npos) return L"";
  const int length = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
      text.data(), static_cast<int>(text.size()), nullptr, 0);
  if (length <= 0) return L"";
  std::wstring result(length, L'\0');
  MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text.data(),
      static_cast<int>(text.size()), result.data(), length);
  return result;
}
}

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
  quality_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "yuanlian/quality-process",
      &flutter::StandardMethodCodec::GetInstance());
  quality_channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    using V = flutter::EncodableValue;
    using M = flutter::EncodableMap;
    const auto* args = std::get_if<M>(call.arguments());
    if (!args) { result->Error("invalid_arguments", "Expected an argument map"); return; }
    if (call.method_name() == "start") {
      const auto path_it = args->find(V("executable"));
      const auto argv_it = args->find(V("arguments"));
      const auto capture_it = args->find(V("capture"));
      if (path_it == args->end() || argv_it == args->end() || quality_processes_.size() >= 4) {
        result->Error("invalid_arguments", "Missing arguments or process limit reached"); return;
      }
      const auto* path = std::get_if<std::string>(&path_it->second);
      const auto* argv = std::get_if<flutter::EncodableList>(&argv_it->second);
      if (!path || !argv || argv->size() > 64) { result->Error("invalid_arguments", "Invalid process arguments"); return; }
      const auto executable = FromUtf8(*path);
      const auto slash = executable.find_last_of(L"/\\");
      if (slash == std::wstring::npos || executable.size() < 3 ||
          executable[1] != L':' ||
          (executable[2] != L'\\' && executable[2] != L'/') ||
          _wcsicmp(executable.substr(slash + 1).c_str(), L"Moonlight.exe") != 0) {
        result->Error("invalid_arguments", "An absolute local Moonlight.exe path is required"); return;
      }
      std::vector<std::wstring> arguments;
      for (const auto& value : *argv) {
        const auto* text = std::get_if<std::string>(&value);
        if (!text) { result->Error("invalid_arguments", "Expected string arguments"); return; }
        auto wide = FromUtf8(*text);
        if (!text->empty() && wide.empty()) { result->Error("invalid_arguments", "Invalid argument encoding"); return; }
        arguments.push_back(std::move(wide));
      }
      bool capture = false;
      if (capture_it != args->end()) {
        const auto* flag = std::get_if<bool>(&capture_it->second);
        if (!flag) { result->Error("invalid_arguments", "Invalid capture flag"); return; }
        capture = *flag;
      }
      // Only read-only application-list queries may retain bounded stdout.
      // Pairing/streaming output can contain private data and goes to NUL.
      if (capture && (arguments.size() != 3 || arguments[0] != L"list" || arguments[1] != L"--csv")) {
        result->Error("invalid_arguments", "Capture is only allowed for list queries"); return;
      }
      std::wstring directory;
      const auto cwd_it=args->find(V("workingDirectory"));
      if(cwd_it!=args->end()) {
        const auto* cwd=std::get_if<std::string>(&cwd_it->second);
        if(!cwd) {result->Error("invalid_arguments","Invalid working directory");return;}
        directory=FromUtf8(*cwd);
        if(directory.size()<3 || directory[1]!=L':' || directory.find(L'\0')!=std::wstring::npos ||
            (directory[2]!=L'\\' && directory[2]!=L'/')) {result->Error("invalid_arguments","Local absolute directory required");return;}
      }
      DWORD error = 0;
      auto child = QualityProcess::Start(executable, arguments, capture, &error,directory);
      if (!child) { result->Error("start_failed", "Windows process/job creation failed", V(static_cast<int64_t>(error))); return; }
      const auto pid = child->pid();
      const auto id = next_quality_id_++;
      quality_processes_.emplace(id, std::move(child));
      result->Success(V(M{{V("id"), V(id)}, {V("pid"), V(static_cast<int64_t>(pid))}}));
      return;
    }
    const auto id_it = args->find(V("id"));
    if (id_it == args->end()) { result->Error("invalid_arguments", "Missing process id"); return; }
    int64_t id = 0;
    if (const auto* wide_number = std::get_if<int64_t>(&id_it->second)) id = *wide_number;
    else if (const auto* small_number = std::get_if<int32_t>(&id_it->second)) id = *small_number;
    auto child = quality_processes_.find(id);
    if (child == quality_processes_.end()) { result->Error("unknown_process", "Process is not owned by this client"); return; }
    if (call.method_name() == "stop") { result->Success(V(child->second->Stop())); return; }
    if (call.method_name() == "release") { quality_processes_.erase(child); result->Success(); return; }
    if (call.method_name() == "poll") {
      DWORD code = 0, error = 0;
      const bool running = child->second->Poll(&code, &error);
      if (error) { result->Error("poll_failed", "Process status unavailable", V(static_cast<int64_t>(error))); return; }
      M status{{V("running"), V(running)}};
      if (!running) {
        status[V("exitCode")] = V(static_cast<int64_t>(code));
        status[V("output")] = V(child->second->output());
        status[V("overflow")] = V(child->second->overflow());
      }
      result->Success(V(status)); return;
    }
    result->NotImplemented();
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
  quality_processes_.clear();
  quality_channel_ = nullptr;
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
