#include "flutter_window.h"

#include <Windows.h>
#include <knownfolders.h>
#include <shlobj.h>

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <deque>
#include <functional>
#include <optional>
#include <filesystem>
#include <fstream>
#include <regex>
#include <set>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

#include <flutter/event_stream_handler_functions.h>
#include "flutter/generated_plugin_registrant.h"

namespace {

constexpr char kYtDlpChannelName[] = "com.example.video_player_app/yt_dlp";
constexpr char kYtDlpEventChannelName[] =
    "com.example.video_player_app/yt_dlp_events";
constexpr UINT kExecuteUiTasksMessage = WM_APP + 101;
constexpr DWORD kResolveTimeoutMs = 90000;

std::filesystem::path GetExecutableDirectory() {
  wchar_t buffer[MAX_PATH];
  const auto length = GetModuleFileNameW(nullptr, buffer, MAX_PATH);
  std::filesystem::path exe_path(std::wstring(buffer, length));
  return exe_path.parent_path();
}

std::string WideToUtf8(const std::wstring& value) {
  if (value.empty()) {
    return {};
  }
  const int size = WideCharToMultiByte(
      CP_UTF8, 0, value.c_str(), static_cast<int>(value.size()), nullptr, 0,
      nullptr, nullptr);
  std::string result(size, '\0');
  WideCharToMultiByte(CP_UTF8, 0, value.c_str(), static_cast<int>(value.size()),
                      result.data(), size, nullptr, nullptr);
  return result;
}

std::wstring Utf8ToWide(const std::string& value) {
  if (value.empty()) {
    return {};
  }
  const int size = MultiByteToWideChar(
      CP_UTF8, 0, value.c_str(), static_cast<int>(value.size()), nullptr, 0);
  std::wstring result(size, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, value.c_str(), static_cast<int>(value.size()),
                      result.data(), size);
  return result;
}

std::string Trim(const std::string& value) {
  const auto start = value.find_first_not_of(" \r\n\t");
  if (start == std::string::npos) {
    return {};
  }
  const auto end = value.find_last_not_of(" \r\n\t");
  return value.substr(start, end - start + 1);
}

std::string EscapeJson(const std::string& value) {
  std::ostringstream output;
  for (const char ch : value) {
    switch (ch) {
      case '\\':
        output << "\\\\";
        break;
      case '"':
        output << "\\\"";
        break;
      case '\b':
        output << "\\b";
        break;
      case '\f':
        output << "\\f";
        break;
      case '\n':
        output << "\\n";
        break;
      case '\r':
        output << "\\r";
        break;
      case '\t':
        output << "\\t";
        break;
      default:
        output << ch;
        break;
    }
  }
  return output.str();
}

std::wstring QuoteArg(const std::wstring& arg) {
  std::wstring quoted = L"\"";
  for (const wchar_t ch : arg) {
    if (ch == L'"') {
      quoted += L'\\';
    }
    quoted += ch;
  }
  quoted += L"\"";
  return quoted;
}

std::optional<std::filesystem::path> FindExecutable(
    const std::vector<std::wstring>& candidates) {
  // 优先搜索托管安装目录（Dart 安装器/更新器写入的位置），
  // 确保在线更新后的二进制文件能被正确发现。
  std::vector<std::filesystem::path> managed_roots;
  auto append_known_folder = [](std::vector<std::filesystem::path>& roots,
                                const KNOWNFOLDERID& folder_id) {
    PWSTR folder_path = nullptr;
    if (SHGetKnownFolderPath(folder_id, KF_FLAG_DEFAULT, nullptr, &folder_path) !=
        S_OK) {
      return;
    }
    const std::filesystem::path base_path{std::wstring(folder_path)};
    CoTaskMemFree(folder_path);
    roots.push_back(base_path / L"video_player_app" / L"yt_dlp");
  };

  append_known_folder(managed_roots, FOLDERID_RoamingAppData);
  append_known_folder(managed_roots, FOLDERID_LocalAppData);

  for (const auto& root : managed_roots) {
    for (const auto& candidate : candidates) {
      const auto local_path = root / candidate;
      if (std::filesystem::exists(local_path)) {
        return local_path;
      }
    }
  }

  // 回退到 exe 目录及其 resources 子目录
  std::vector<std::filesystem::path> fallback_roots;
  const auto exe_dir = GetExecutableDirectory();
  fallback_roots.push_back(exe_dir);
  fallback_roots.push_back(exe_dir / L"resources");

  for (const auto& root : fallback_roots) {
    for (const auto& candidate : candidates) {
      const auto local_path = root / candidate;
      if (std::filesystem::exists(local_path)) {
        return local_path;
      }
    }
  }

  wchar_t* env_path = nullptr;
  size_t env_len = 0;
  if (_wdupenv_s(&env_path, &env_len, L"PATH") != 0 || env_path == nullptr) {
    return std::nullopt;
  }
  std::wstring path_value(env_path);
  free(env_path);

  size_t cursor = 0;
  while (cursor <= path_value.size()) {
    const size_t next = path_value.find(L';', cursor);
    const std::wstring segment = path_value.substr(
        cursor, next == std::wstring::npos ? std::wstring::npos : next - cursor);
    if (!segment.empty()) {
      for (const auto& candidate : candidates) {
        const auto path = std::filesystem::path(segment) / candidate;
        if (std::filesystem::exists(path)) {
          return path;
        }
      }
    }
    if (next == std::wstring::npos) {
      break;
    }
    cursor = next + 1;
  }
  return std::nullopt;
}

std::string BuildBinaryDiagnostic(
    const std::vector<std::wstring>& yt_dlp_candidates,
    const std::vector<std::wstring>& ffmpeg_candidates) {
  std::ostringstream output;
  output << "windows search roots:";

  const auto exe_dir = GetExecutableDirectory();
  output << "\n- " << WideToUtf8(exe_dir.wstring());
  output << "\n- " << WideToUtf8((exe_dir / L"resources").wstring());

  auto append_known_folder = [&output](const KNOWNFOLDERID& folder_id,
                                       const char* label) {
    PWSTR folder_path = nullptr;
    if (SHGetKnownFolderPath(folder_id, KF_FLAG_DEFAULT, nullptr, &folder_path) !=
        S_OK) {
      return;
    }
    const std::filesystem::path base_path{std::wstring(folder_path)};
    CoTaskMemFree(folder_path);
    output << "\n- " << label << ": "
           << WideToUtf8((base_path / L"video_player_app" / L"yt_dlp").wstring());
  };

  append_known_folder(FOLDERID_RoamingAppData, "RoamingAppData");
  append_known_folder(FOLDERID_LocalAppData, "LocalAppData");
  output << "\nyt-dlp candidates:";
  for (const auto& candidate : yt_dlp_candidates) {
    output << "\n- " << WideToUtf8(candidate);
  }
  output << "\nffmpeg candidates:";
  for (const auto& candidate : ffmpeg_candidates) {
    output << "\n- " << WideToUtf8(candidate);
  }
  return output.str();
}

struct ProcessResult {
  bool success = false;
  int exit_code = -1;
  std::string stdout_text;
  std::string stderr_text;
  bool timed_out = false;
};

struct StreamingProcess {
  PROCESS_INFORMATION process_info{};
  HANDLE output_read = nullptr;

  bool valid() const { return process_info.hProcess != nullptr; }
};

ProcessResult RunProcess(const std::filesystem::path& executable,
                         const std::vector<std::wstring>& args,
                         DWORD timeout_ms = INFINITE) {
  SECURITY_ATTRIBUTES security_attributes{};
  security_attributes.nLength = sizeof(SECURITY_ATTRIBUTES);
  security_attributes.bInheritHandle = TRUE;

  HANDLE output_read = nullptr;
  HANDLE output_write = nullptr;
  if (!CreatePipe(&output_read, &output_write, &security_attributes, 0)) {
    return {};
  }
  SetHandleInformation(output_read, HANDLE_FLAG_INHERIT, 0);

  std::wstring command = QuoteArg(executable.wstring());
  for (const auto& arg : args) {
    command += L" ";
    command += QuoteArg(arg);
  }

  STARTUPINFOW startup_info{};
  startup_info.cb = sizeof(STARTUPINFOW);
  startup_info.dwFlags = STARTF_USESTDHANDLES;
  startup_info.hStdOutput = output_write;
  startup_info.hStdError = output_write;
  startup_info.hStdInput = GetStdHandle(STD_INPUT_HANDLE);

  PROCESS_INFORMATION process_info{};
  std::vector<wchar_t> command_buffer(command.begin(), command.end());
  command_buffer.push_back(L'\0');

  const BOOL created = CreateProcessW(
      nullptr, command_buffer.data(), nullptr, nullptr, TRUE,
      CREATE_NO_WINDOW, nullptr, executable.parent_path().c_str(), &startup_info,
      &process_info);

  CloseHandle(output_write);

  if (!created) {
    CloseHandle(output_read);
    return {};
  }

  std::string combined_output;
  std::thread output_reader([output_read, &combined_output]() {
    char buffer[4096];
    DWORD read = 0;
    while (ReadFile(output_read, buffer, sizeof(buffer), &read, nullptr) &&
           read > 0) {
      combined_output.append(buffer, read);
    }
  });

  const DWORD wait_result = WaitForSingleObject(process_info.hProcess, timeout_ms);
  bool timed_out = false;
  if (wait_result == WAIT_TIMEOUT) {
    timed_out = true;
    TerminateProcess(process_info.hProcess, 124);
    WaitForSingleObject(process_info.hProcess, 5000);
  }
  if (output_reader.joinable()) {
    output_reader.join();
  }

  DWORD exit_code = 0;
  GetExitCodeProcess(process_info.hProcess, &exit_code);

  CloseHandle(output_read);
  CloseHandle(process_info.hThread);
  CloseHandle(process_info.hProcess);

  return {
      !timed_out && exit_code == 0,
      static_cast<int>(exit_code),
      combined_output,
      exit_code == 0 && !timed_out ? std::string() : combined_output,
      timed_out,
  };
}

StreamingProcess StartStreamingProcess(
    const std::filesystem::path& executable,
    const std::vector<std::wstring>& args,
    const std::filesystem::path& working_directory) {
  SECURITY_ATTRIBUTES security_attributes{};
  security_attributes.nLength = sizeof(SECURITY_ATTRIBUTES);
  security_attributes.bInheritHandle = TRUE;

  HANDLE output_read = nullptr;
  HANDLE output_write = nullptr;
  if (!CreatePipe(&output_read, &output_write, &security_attributes, 0)) {
    return {};
  }
  SetHandleInformation(output_read, HANDLE_FLAG_INHERIT, 0);

  std::wstring command = QuoteArg(executable.wstring());
  for (const auto& arg : args) {
    command += L" ";
    command += QuoteArg(arg);
  }

  STARTUPINFOW startup_info{};
  startup_info.cb = sizeof(STARTUPINFOW);
  startup_info.dwFlags = STARTF_USESTDHANDLES;
  startup_info.hStdOutput = output_write;
  startup_info.hStdError = output_write;
  startup_info.hStdInput = GetStdHandle(STD_INPUT_HANDLE);

  PROCESS_INFORMATION process_info{};
  std::vector<wchar_t> command_buffer(command.begin(), command.end());
  command_buffer.push_back(L'\0');

  const auto working_dir = working_directory.empty()
                               ? executable.parent_path()
                               : working_directory;
  const BOOL created = CreateProcessW(
      nullptr, command_buffer.data(), nullptr, nullptr, TRUE,
      CREATE_NO_WINDOW, nullptr, working_dir.c_str(), &startup_info,
      &process_info);

  CloseHandle(output_write);
  if (!created) {
    CloseHandle(output_read);
    return {};
  }

  return {process_info, output_read};
}

void CloseStreamingProcess(StreamingProcess* process) {
  if (process == nullptr) {
    return;
  }
  if (process->output_read != nullptr) {
    CloseHandle(process->output_read);
    process->output_read = nullptr;
  }
  if (process->process_info.hThread != nullptr) {
    CloseHandle(process->process_info.hThread);
    process->process_info.hThread = nullptr;
  }
  if (process->process_info.hProcess != nullptr) {
    CloseHandle(process->process_info.hProcess);
    process->process_info.hProcess = nullptr;
  }
}

std::optional<std::string> ReadFileUtf8(const std::filesystem::path& path) {
  std::ifstream input(path, std::ios::binary);
  if (!input.is_open()) {
    return std::nullopt;
  }
  std::ostringstream stream;
  stream << input.rdbuf();
  return stream.str();
}

std::filesystem::path GetSessionConfigPath() {
  return GetExecutableDirectory() / "yt_dlp_session_config.json";
}

std::vector<std::wstring> BuildSessionArgs(
    const flutter::EncodableMap* session_config) {
  std::vector<std::wstring> args;
  if (session_config == nullptr) {
    return args;
  }

  const auto find_bool = [&](const char* key) -> bool {
    const auto it = session_config->find(flutter::EncodableValue(key));
    if (it == session_config->end()) {
      return false;
    }
    if (const auto* value = std::get_if<bool>(&it->second)) {
      return *value;
    }
    return false;
  };
  const auto find_string = [&](const char* key) -> std::optional<std::wstring> {
    const auto it = session_config->find(flutter::EncodableValue(key));
    if (it == session_config->end()) {
      return std::nullopt;
    }
    if (const auto* text = std::get_if<std::string>(&it->second)) {
      if (!text->empty()) {
        return Utf8ToWide(*text);
      }
    }
    return std::nullopt;
  };
  const auto find_int = [&](const char* key) -> std::optional<int> {
    const auto it = session_config->find(flutter::EncodableValue(key));
    if (it == session_config->end()) {
      return std::nullopt;
    }
    if (const auto* value = std::get_if<int32_t>(&it->second)) {
      return static_cast<int>(*value);
    }
    if (const auto* value64 = std::get_if<int64_t>(&it->second)) {
      return static_cast<int>(*value64);
    }
    return std::nullopt;
  };
  const auto find_string_list =
      [&](const char* key) -> std::vector<std::wstring> {
    std::vector<std::wstring> values;
    const auto it = session_config->find(flutter::EncodableValue(key));
    if (it == session_config->end()) {
      return values;
    }
    const auto* list = std::get_if<flutter::EncodableList>(&it->second);
    if (list == nullptr) {
      return values;
    }
    for (const auto& entry : *list) {
      if (const auto* text = std::get_if<std::string>(&entry)) {
        const auto trimmed = Trim(*text);
        if (!trimmed.empty()) {
          values.push_back(Utf8ToWide(trimmed));
        }
      }
    }
    return values;
  };
  const auto build_extractor_args = [&]() -> std::optional<std::wstring> {
    std::vector<std::wstring> parts;

    const auto clients = find_string_list("enabledPlayerClients");
    if (!clients.empty()) {
      std::wstring joined;
      for (size_t index = 0; index < clients.size(); ++index) {
        if (index > 0) {
          joined += L",";
        }
        joined += clients[index];
      }
      parts.push_back(L"player_client=" + joined);
    }

    if (const auto visitor_data = find_string("visitorData")) {
      parts.push_back(L"visitor_data=" + *visitor_data);
    }

    const auto po_tokens_it =
        session_config->find(flutter::EncodableValue("poTokens"));
    if (po_tokens_it != session_config->end()) {
      const auto* po_tokens =
          std::get_if<flutter::EncodableList>(&po_tokens_it->second);
      if (po_tokens != nullptr) {
        std::vector<std::wstring> enabled_tokens;
        for (const auto& entry : *po_tokens) {
          const auto* token_map = std::get_if<flutter::EncodableMap>(&entry);
          if (token_map == nullptr) {
            continue;
          }
          const auto get_token_string =
              [&](const char* key) -> std::optional<std::wstring> {
            const auto item = token_map->find(flutter::EncodableValue(key));
            if (item == token_map->end()) {
              return std::nullopt;
            }
            if (const auto* text = std::get_if<std::string>(&item->second)) {
              const auto trimmed = Trim(*text);
              if (!trimmed.empty()) {
                return Utf8ToWide(trimmed);
              }
            }
            return std::nullopt;
          };
          bool enabled = true;
          const auto enabled_it = token_map->find(flutter::EncodableValue("enabled"));
          if (enabled_it != token_map->end()) {
            if (const auto* enabled_value = std::get_if<bool>(&enabled_it->second)) {
              enabled = *enabled_value;
            }
          }
          const auto client = get_token_string("client");
          const auto context = get_token_string("context");
          const auto token = get_token_string("token");
          if (!enabled || !client || !context || !token) {
            continue;
          }
          enabled_tokens.push_back(*client + L"." + *context + L"+" + *token);
        }
        if (!enabled_tokens.empty()) {
          std::wstring joined;
          for (size_t index = 0; index < enabled_tokens.size(); ++index) {
            if (index > 0) {
              joined += L",";
            }
            joined += enabled_tokens[index];
          }
          parts.push_back(L"po_token=" + joined);
        }
      }
    }

    if (parts.empty()) {
      return std::nullopt;
    }
    std::wstring joined = L"youtube:";
    for (size_t index = 0; index < parts.size(); ++index) {
      if (index > 0) {
        joined += L";";
      }
      joined += parts[index];
    }
    return joined;
  };

  if (find_bool("useCookies")) {
    if (const auto cookies_path = find_string("cookiesFilePath")) {
      args.push_back(L"--cookies");
      args.push_back(*cookies_path);
    }
  }
  if (find_bool("useCustomUserAgent")) {
    if (const auto user_agent = find_string("userAgent")) {
      args.push_back(L"--add-header");
      args.push_back(L"User-Agent:" + *user_agent);
    }
  }
  if (find_bool("useProxy")) {
    if (const auto proxy = find_string("proxy")) {
      args.push_back(L"--proxy");
      args.push_back(*proxy);
    }
  }
  if (const auto timeout = find_int("socketTimeoutSeconds")) {
    if (*timeout > 0) {
      args.push_back(L"--socket-timeout");
      args.push_back(std::to_wstring(*timeout));
    }
  }
  if (const auto retries = find_int("retries")) {
    if (*retries > 0) {
      args.push_back(L"--retries");
      args.push_back(std::to_wstring(*retries));
    }
  }
  if (const auto fragment_retries = find_int("fragmentRetries")) {
    if (*fragment_retries > 0) {
      args.push_back(L"--fragment-retries");
      args.push_back(std::to_wstring(*fragment_retries));
    }
  }
  if (const auto fragments = find_int("concurrentFragments")) {
    if (*fragments > 0) {
      args.push_back(L"-N");
      args.push_back(std::to_wstring(*fragments));
    }
  }
  if (const auto rate_limit = find_string("rateLimit")) {
    args.push_back(L"-r");
    args.push_back(*rate_limit);
  }
  if (find_bool("forceIpv4")) {
    args.push_back(L"-4");
  }
  if (const auto extractor_args = build_extractor_args()) {
    args.push_back(L"--extractor-args");
    args.push_back(*extractor_args);
  }
  return args;
}

std::string StripWrappingQuotes(std::string value) {
  value = Trim(value);
  if (value.size() >= 2 && value.front() == '"' && value.back() == '"') {
    return value.substr(1, value.size() - 2);
  }
  return value;
}

std::string NormalizeYtDlpMarkerPath(const std::string& marker,
                                     const std::string& line) {
  const auto pos = line.find(marker);
  if (pos == std::string::npos) {
    return {};
  }
  return StripWrappingQuotes(line.substr(pos + marker.size()));
}

bool LooksLikeTemporaryArtifact(const std::filesystem::path& path) {
  const auto extension = path.extension().wstring();
  return extension == L".part" || extension == L".ytdl" || extension == L".tmp";
}

bool LooksLikeSubtitleSidecar(const std::filesystem::path& path) {
  static const std::set<std::wstring> extensions = {
      L".srt", L".ass", L".ssa", L".vtt", L".lrc", L".json3", L".srv1",
      L".srv2", L".srv3", L".ttml"};
  return extensions.find(path.extension().wstring()) != extensions.end();
}

}  // namespace

struct WindowsYtDlpTask {
  std::string task_id;
  std::filesystem::path output_dir;
  std::string output_template;
  StreamingProcess process;
  std::string status = "queued";
  double progress = 0.0;
  std::string speed_text;
  std::string eta_text;
  std::string output_path;
  std::vector<std::string> produced_paths;
  std::string error_code;
  std::string message;
  std::string termination_reason;
  std::deque<std::string> log_tail;
  double last_emitted_progress = -1.0;
  std::chrono::steady_clock::time_point last_progress_emit_at{};
};

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
  RegisterYtDlpChannel();
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

void FlutterWindow::RegisterYtDlpChannel() {
  yt_dlp_event_channel_ =
      std::make_unique<flutter::EventChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), kYtDlpEventChannelName,
          &flutter::StandardMethodCodec::GetInstance());
  yt_dlp_event_channel_->SetStreamHandler(
      std::make_unique<
          flutter::StreamHandlerFunctions<flutter::EncodableValue>>(
          [this](const flutter::EncodableValue*,
                 std::unique_ptr<flutter::EventSink<flutter::EncodableValue>>&&
                     events) {
            std::lock_guard<std::mutex> lock(yt_dlp_mutex_);
            yt_dlp_event_sink_ = std::shared_ptr<flutter::EventSink<
                flutter::EncodableValue>>(std::move(events));
            return nullptr;
          },
          [this](const flutter::EncodableValue*) {
            std::lock_guard<std::mutex> lock(yt_dlp_mutex_);
            yt_dlp_event_sink_.reset();
            return nullptr;
          }));

  yt_dlp_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), kYtDlpChannelName,
          &flutter::StandardMethodCodec::GetInstance());

  yt_dlp_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        if (call.method_name() == "getYtDlpBinaryStatus") {
          flutter::EncodableMap payload;
          const std::vector<std::wstring> yt_dlp_candidates = {L"yt-dlp.exe"};
          const std::vector<std::wstring> ffmpeg_candidates = {L"ffmpeg.exe"};

          const auto yt_dlp = FindExecutable(yt_dlp_candidates);
          const auto ffmpeg = FindExecutable(ffmpeg_candidates);

          payload[flutter::EncodableValue("ytDlpReady")] =
              flutter::EncodableValue(yt_dlp.has_value());
          payload[flutter::EncodableValue("ffmpegReady")] =
              flutter::EncodableValue(ffmpeg.has_value());
          payload[flutter::EncodableValue("ytDlpPath")] =
              yt_dlp ? flutter::EncodableValue(WideToUtf8(yt_dlp->wstring()))
                     : flutter::EncodableValue();
          payload[flutter::EncodableValue("ffmpegPath")] =
              ffmpeg ? flutter::EncodableValue(WideToUtf8(ffmpeg->wstring()))
                     : flutter::EncodableValue();
          payload[flutter::EncodableValue("diagnosticMessage")] =
              flutter::EncodableValue(
                  BuildBinaryDiagnostic(yt_dlp_candidates, ffmpeg_candidates));

          if (yt_dlp) {
            const auto version_result = RunProcess(*yt_dlp, {L"--version"});
            payload[flutter::EncodableValue("ytDlpVersion")] =
                version_result.success
                    ? flutter::EncodableValue(Trim(version_result.stdout_text))
                    : flutter::EncodableValue();
          } else {
            payload[flutter::EncodableValue("ytDlpVersion")] =
                flutter::EncodableValue();
          }

          if (ffmpeg) {
            const auto version_result = RunProcess(*ffmpeg, {L"-version"});
            std::string first_line = Trim(version_result.stdout_text);
            const auto newline_pos = first_line.find('\n');
            if (newline_pos != std::string::npos) {
              first_line = first_line.substr(0, newline_pos);
            }
            payload[flutter::EncodableValue("ffmpegVersion")] =
                version_result.success ? flutter::EncodableValue(first_line)
                                       : flutter::EncodableValue();
          } else {
            payload[flutter::EncodableValue("ffmpegVersion")] =
                flutter::EncodableValue();
          }

          result->Success(flutter::EncodableValue(payload));
          return;
        }

        if (call.method_name() == "saveYoutubeSessionConfig") {
          const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
          if (args == nullptr) {
            result->Success(flutter::EncodableValue(false));
            return;
          }
          const auto config_it = args->find(flutter::EncodableValue("config"));
          if (config_it == args->end()) {
            result->Success(flutter::EncodableValue(false));
            return;
          }
          auto& codec = flutter::StandardMessageCodec::GetInstance();
          const auto bytes = codec.EncodeMessage(config_it->second);
          std::ofstream output(GetSessionConfigPath(), std::ios::binary);
          output.write(reinterpret_cast<const char*>(bytes->data()),
                       static_cast<std::streamsize>(bytes->size()));
          result->Success(flutter::EncodableValue(true));
          return;
        }

        if (call.method_name() == "loadYoutubeSessionConfig") {
          const auto bytes = ReadFileUtf8(GetSessionConfigPath());
          if (!bytes.has_value()) {
            result->Success();
            return;
          }
          auto& codec = flutter::StandardMessageCodec::GetInstance();
          const auto decoded = codec.DecodeMessage(
              reinterpret_cast<const uint8_t*>(bytes->data()), bytes->size());
          if (decoded == nullptr) {
            result->Success();
            return;
          }
          result->Success(*decoded);
          return;
        }

        if (call.method_name() == "resolveYoutubeMeta") {
          const auto yt_dlp = FindExecutable({L"yt-dlp.exe"});
          if (!yt_dlp) {
            result->Error("YT_DLP_NOT_FOUND", "yt-dlp executable not found");
            return;
          }

          const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
          if (args == nullptr) {
            result->Error("INVALID_ARGS", "missing resolve arguments");
            return;
          }

          const auto url_it = args->find(flutter::EncodableValue("url"));
          if (url_it == args->end()) {
            result->Error("INVALID_ARGS", "missing url");
            return;
          }

          const auto* url = std::get_if<std::string>(&url_it->second);
          if (url == nullptr || url->empty()) {
            result->Error("INVALID_ARGS", "url is empty");
            return;
          }

          const flutter::EncodableMap* session_config = nullptr;
          const auto config_it =
              args->find(flutter::EncodableValue("sessionConfig"));
          if (config_it != args->end()) {
            session_config =
                std::get_if<flutter::EncodableMap>(&config_it->second);
          }

          auto command_args = BuildSessionArgs(session_config);
          command_args.push_back(L"--dump-single-json");
          command_args.push_back(L"--skip-download");
          command_args.push_back(L"--no-warnings");
          command_args.push_back(Utf8ToWide(*url));
          auto thumbnail_args = BuildSessionArgs(session_config);
          thumbnail_args.push_back(L"--get-thumbnail");
          thumbnail_args.push_back(L"--skip-download");
          thumbnail_args.push_back(L"--no-warnings");
          thumbnail_args.push_back(Utf8ToWide(*url));
          auto async_result = std::shared_ptr<
              flutter::MethodResult<flutter::EncodableValue>>(std::move(result));
          std::thread([this, yt_dlp = *yt_dlp, command_args = std::move(command_args),
                       thumbnail_args = std::move(thumbnail_args),
                       async_result]() mutable {
            const auto process_result =
                RunProcess(yt_dlp, command_args, kResolveTimeoutMs);
            std::string resolved_thumbnail_url;
            const auto thumbnail_result =
                RunProcess(yt_dlp, thumbnail_args, 15000);
            if (thumbnail_result.success) {
              std::istringstream thumbnail_stream(thumbnail_result.stdout_text);
              std::string line;
              while (std::getline(thumbnail_stream, line)) {
                const auto trimmed_line = Trim(line);
                if (!trimmed_line.empty()) {
                  resolved_thumbnail_url = trimmed_line;
                  break;
                }
              }
            }
            PostUiTask([async_result, process_result,
                        resolved_thumbnail_url]() {
              if (!process_result.success) {
                std::string message = Trim(process_result.stderr_text);
                if (message.empty()) {
                  message = process_result.timed_out
                                ? "yt-dlp resolve timed out"
                                : "yt-dlp resolve failed";
                }
                async_result->Error("YT_DLP_RESOLVE_FAILED", message);
                return;
              }

              flutter::EncodableMap payload;
              payload[flutter::EncodableValue("rawInfoJson")] =
                  flutter::EncodableValue(process_result.stdout_text);
              if (!resolved_thumbnail_url.empty()) {
                payload[flutter::EncodableValue("thumbnailUrl")] =
                    flutter::EncodableValue(resolved_thumbnail_url);
              }
              async_result->Success(flutter::EncodableValue(payload));
            });
          }).detach();
          return;
        }

        if (call.method_name() == "importYoutubeCookies") {
          const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
          if (args == nullptr) {
            result->Success();
            return;
          }
          const auto file_path_it = args->find(flutter::EncodableValue("filePath"));
          const auto* file_path =
              file_path_it == args->end()
                  ? nullptr
                  : std::get_if<std::string>(&file_path_it->second);
          if (file_path == nullptr || file_path->empty()) {
            result->Success();
            return;
          }

          const auto target_dir = GetExecutableDirectory() / "yt_dlp_cookies";
          std::error_code error_code;
          std::filesystem::create_directories(target_dir, error_code);
          const auto target_path = target_dir / "cookies.txt";
          std::filesystem::copy_file(
              Utf8ToWide(*file_path), target_path,
              std::filesystem::copy_options::overwrite_existing, error_code);
          if (error_code) {
            result->Success();
            return;
          }
          result->Success(
              flutter::EncodableValue(WideToUtf8(target_path.wstring())));
          return;
        }

        if (call.method_name() == "startYoutubeDownload") {
          const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
          if (args == nullptr) {
            result->Error("INVALID_ARGS", "missing download request");
            return;
          }
          std::string error_message;
          const bool started = StartYtDlpDownload(*args, &error_message);
          if (!started && !error_message.empty()) {
            result->Error("YT_DLP_START_FAILED", error_message);
            return;
          }
          result->Success(flutter::EncodableValue(started));
          return;
        }

        if (call.method_name() == "pauseYoutubeDownload") {
          const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
          if (args == nullptr) {
            result->Success(flutter::EncodableValue(false));
            return;
          }
          const auto task_id_it = args->find(flutter::EncodableValue("taskId"));
          const auto* task_id =
              task_id_it == args->end()
                  ? nullptr
                  : std::get_if<std::string>(&task_id_it->second);
          result->Success(flutter::EncodableValue(
              task_id == nullptr ? false : PauseYtDlpDownload(*task_id)));
          return;
        }

        if (call.method_name() == "cancelYoutubeDownload") {
          const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
          if (args == nullptr) {
            result->Success(flutter::EncodableValue(false));
            return;
          }
          const auto task_id_it = args->find(flutter::EncodableValue("taskId"));
          const auto* task_id =
              task_id_it == args->end()
                  ? nullptr
                  : std::get_if<std::string>(&task_id_it->second);
          result->Success(flutter::EncodableValue(
              task_id == nullptr ? false : CancelYtDlpDownload(*task_id)));
          return;
        }

        if (call.method_name() == "removeYoutubeTask") {
          const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
          if (args == nullptr) {
            result->Success(flutter::EncodableValue(false));
            return;
          }
          const auto task_id_it = args->find(flutter::EncodableValue("taskId"));
          const auto* task_id =
              task_id_it == args->end()
                  ? nullptr
                  : std::get_if<std::string>(&task_id_it->second);
          result->Success(flutter::EncodableValue(
              task_id == nullptr ? false : RemoveYtDlpTask(*task_id)));
          return;
        }

        if (call.method_name() == "getYoutubeTaskStatus") {
          const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
          if (args == nullptr) {
            result->Success();
            return;
          }
          const auto task_id_it = args->find(flutter::EncodableValue("taskId"));
          const auto* task_id =
              task_id_it == args->end()
                  ? nullptr
                  : std::get_if<std::string>(&task_id_it->second);
          if (task_id == nullptr) {
            result->Success();
            return;
          }
          auto payload = GetYtDlpTaskStatus(*task_id);
          if (!payload) {
            result->Success();
            return;
          }
          result->Success(*payload);
          return;
        }

        result->NotImplemented();
      });
}

void FlutterWindow::OnDestroy() {
  {
    std::lock_guard<std::mutex> lock(yt_dlp_mutex_);
    for (auto& entry : yt_dlp_tasks_) {
      auto& task = entry.second;
      task->termination_reason = "cancel";
      if (task->process.process_info.hProcess != nullptr) {
        TerminateProcess(task->process.process_info.hProcess, 1);
      }
    }
    yt_dlp_tasks_.clear();
    yt_dlp_event_sink_.reset();
  }
  {
    std::lock_guard<std::mutex> lock(ui_task_mutex_);
    pending_ui_tasks_.clear();
  }
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  switch (message) {
    case kExecuteUiTasksMessage:
      DrainUiTasks();
      return 0;
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
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

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}

void FlutterWindow::PostUiTask(std::function<void()> task) {
  HWND handle = nullptr;
  {
    std::lock_guard<std::mutex> lock(ui_task_mutex_);
    pending_ui_tasks_.push_back(std::move(task));
    handle = GetHandle();
  }
  if (handle != nullptr) {
    PostMessage(handle, kExecuteUiTasksMessage, 0, 0);
  }
}

void FlutterWindow::DrainUiTasks() {
  std::vector<std::function<void()>> tasks;
  {
    std::lock_guard<std::mutex> lock(ui_task_mutex_);
    tasks.swap(pending_ui_tasks_);
  }
  for (auto& task : tasks) {
    if (task) {
      task();
    }
  }
}

void FlutterWindow::EmitYtDlpEvent(const flutter::EncodableMap& payload) {
  PostUiTask([this, payload]() {
    std::shared_ptr<flutter::EventSink<flutter::EncodableValue>> sink;
    {
      std::lock_guard<std::mutex> lock(yt_dlp_mutex_);
      sink = yt_dlp_event_sink_;
    }
    if (sink) {
      sink->Success(flutter::EncodableValue(payload));
    }
  });
}

bool FlutterWindow::StartYtDlpDownload(const flutter::EncodableMap& request,
                                       std::string* error_message) {
  const auto get_string = [&](const char* key) -> std::optional<std::string> {
    const auto it = request.find(flutter::EncodableValue(key));
    if (it == request.end()) {
      return std::nullopt;
    }
    if (const auto* value = std::get_if<std::string>(&it->second)) {
      if (!value->empty()) {
        return *value;
      }
    }
    return std::nullopt;
  };

  const auto task_id = get_string("taskId");
  const auto output_dir = get_string("outputDir");
  const auto output_template = get_string("outputTemplate");
  if (!task_id || !output_dir) {
    if (error_message) {
      *error_message = "missing taskId or outputDir";
    }
    return false;
  }

  const auto args_it = request.find(flutter::EncodableValue("args"));
  const auto* raw_args = args_it == request.end()
                             ? nullptr
                             : std::get_if<flutter::EncodableList>(&args_it->second);
  if (raw_args == nullptr || raw_args->empty()) {
    if (error_message) {
      *error_message = "missing yt-dlp args";
    }
    return false;
  }

  const auto yt_dlp = FindExecutable({L"yt-dlp.exe"});
  if (!yt_dlp) {
    if (error_message) {
      *error_message = "yt-dlp executable not found";
    }
    return false;
  }

  std::vector<std::wstring> command_args;
  const auto ffmpeg = FindExecutable({L"ffmpeg.exe"});
  if (ffmpeg) {
    command_args.push_back(L"--ffmpeg-location");
    command_args.push_back(ffmpeg->wstring());
  }
  for (const auto& item : *raw_args) {
    if (const auto* text = std::get_if<std::string>(&item)) {
      command_args.push_back(Utf8ToWide(*text));
    }
  }

  const auto output_path = std::filesystem::path(Utf8ToWide(*output_dir));
  std::error_code ec;
  std::filesystem::create_directories(output_path, ec);
  if (ec) {
    if (error_message) {
      *error_message = "failed to create output directory";
    }
    return false;
  }

  auto process = StartStreamingProcess(*yt_dlp, command_args, output_path);
  if (!process.valid()) {
    if (error_message) {
      *error_message = "failed to start yt-dlp process";
    }
    return false;
  }

  auto task = std::make_shared<WindowsYtDlpTask>();
  task->task_id = *task_id;
  task->output_dir = output_path;
  task->output_template = output_template.value_or("%(title)s.%(ext)s");
  task->process = process;
  task->status = "queued";
  task->message = "Queued";

  {
    std::lock_guard<std::mutex> lock(yt_dlp_mutex_);
    auto existing = yt_dlp_tasks_.find(*task_id);
    if (existing != yt_dlp_tasks_.end()) {
      existing->second->termination_reason = "cancel";
      if (existing->second->process.process_info.hProcess != nullptr) {
        TerminateProcess(existing->second->process.process_info.hProcess, 1);
      }
      yt_dlp_tasks_.erase(existing);
    }
    yt_dlp_tasks_[*task_id] = task;
  }

  EmitYtDlpEvent({{flutter::EncodableValue("taskId"),
                   flutter::EncodableValue(*task_id)},
                  {flutter::EncodableValue("type"),
                   flutter::EncodableValue("task_queued")},
                  {flutter::EncodableValue("message"),
                   flutter::EncodableValue("Queued")}});

  std::thread([this, task]() { MonitorYtDlpTask(task); }).detach();
  return true;
}

bool FlutterWindow::PauseYtDlpDownload(const std::string& task_id) {
  std::shared_ptr<WindowsYtDlpTask> task;
  {
    std::lock_guard<std::mutex> lock(yt_dlp_mutex_);
    const auto it = yt_dlp_tasks_.find(task_id);
    if (it == yt_dlp_tasks_.end()) {
      return false;
    }
    task = it->second;
    task->termination_reason = "pause";
    task->status = "paused";
    task->message = "Paused";
  }
  return TerminateProcess(task->process.process_info.hProcess, 0) == TRUE;
}

bool FlutterWindow::CancelYtDlpDownload(const std::string& task_id) {
  std::shared_ptr<WindowsYtDlpTask> task;
  {
    std::lock_guard<std::mutex> lock(yt_dlp_mutex_);
    const auto it = yt_dlp_tasks_.find(task_id);
    if (it == yt_dlp_tasks_.end()) {
      return false;
    }
    task = it->second;
    task->termination_reason = "cancel";
    task->status = "cancelled";
    task->message = "Cancelled";
  }
  return TerminateProcess(task->process.process_info.hProcess, 1) == TRUE;
}

bool FlutterWindow::RemoveYtDlpTask(const std::string& task_id) {
  std::shared_ptr<WindowsYtDlpTask> task;
  {
    std::lock_guard<std::mutex> lock(yt_dlp_mutex_);
    const auto it = yt_dlp_tasks_.find(task_id);
    if (it != yt_dlp_tasks_.end()) {
      task = it->second;
      task->termination_reason = "cancel";
      task->status = "cancelled";
      task->message = "Removed";
    }
  }
  if (task && task->process.process_info.hProcess != nullptr) {
    TerminateProcess(task->process.process_info.hProcess, 1);
  }
  if (task) {
    std::error_code ec;
    if (!task->output_path.empty()) {
      std::filesystem::remove(std::filesystem::path(Utf8ToWide(task->output_path)),
                              ec);
    }
    for (const auto& produced_path : task->produced_paths) {
      if (produced_path.empty()) {
        continue;
      }
      std::filesystem::remove(std::filesystem::path(Utf8ToWide(produced_path)),
                              ec);
    }
  }
  return true;
}

std::unique_ptr<flutter::EncodableValue> FlutterWindow::GetYtDlpTaskStatus(
    const std::string& task_id) {
  std::lock_guard<std::mutex> lock(yt_dlp_mutex_);
  const auto it = yt_dlp_tasks_.find(task_id);
  if (it == yt_dlp_tasks_.end()) {
    return nullptr;
  }
  const auto& task = it->second;
  flutter::EncodableMap payload;
  payload[flutter::EncodableValue("taskId")] =
      flutter::EncodableValue(task->task_id);
  payload[flutter::EncodableValue("status")] =
      flutter::EncodableValue(task->status);
  payload[flutter::EncodableValue("progress")] =
      flutter::EncodableValue(task->progress);
  payload[flutter::EncodableValue("speedText")] =
      flutter::EncodableValue(task->speed_text);
  payload[flutter::EncodableValue("etaText")] =
      flutter::EncodableValue(task->eta_text);
  payload[flutter::EncodableValue("outputPath")] =
      flutter::EncodableValue(task->output_path);
  flutter::EncodableList produced_paths;
  for (const auto& path : task->produced_paths) {
    produced_paths.emplace_back(path);
  }
  payload[flutter::EncodableValue("producedPaths")] =
      flutter::EncodableValue(produced_paths);
  payload[flutter::EncodableValue("message")] =
      flutter::EncodableValue(task->message);
  payload[flutter::EncodableValue("errorCode")] =
      flutter::EncodableValue(task->error_code);
  return std::make_unique<flutter::EncodableValue>(payload);
}

void FlutterWindow::MonitorYtDlpTask(
    const std::shared_ptr<WindowsYtDlpTask>& task) {
  {
    std::lock_guard<std::mutex> lock(yt_dlp_mutex_);
    task->status = "downloading";
    task->message = "Starting";
  }
  EmitYtDlpEvent({{flutter::EncodableValue("taskId"),
                   flutter::EncodableValue(task->task_id)},
                  {flutter::EncodableValue("type"),
                   flutter::EncodableValue("task_started")},
                  {flutter::EncodableValue("progress"),
                   flutter::EncodableValue(0.0)},
                  {flutter::EncodableValue("message"),
                   flutter::EncodableValue("Starting")}});

  std::string pending;
  char buffer[4096];
  DWORD read = 0;
  while (ReadFile(task->process.output_read, buffer, sizeof(buffer), &read,
                  nullptr) &&
         read > 0) {
    pending.append(buffer, read);
    size_t newline = std::string::npos;
    while ((newline = pending.find('\n')) != std::string::npos) {
      std::string line = pending.substr(0, newline);
      if (!line.empty() && line.back() == '\r') {
        line.pop_back();
      }
      pending.erase(0, newline + 1);
      HandleYtDlpOutput(task, line);
    }
  }
  if (!Trim(pending).empty()) {
    HandleYtDlpOutput(task, pending);
  }

  WaitForSingleObject(task->process.process_info.hProcess, INFINITE);
  DWORD exit_code = 0;
  GetExitCodeProcess(task->process.process_info.hProcess, &exit_code);
  CloseStreamingProcess(&task->process);

  std::string event_type;
  std::string message;
  std::string error_code;
  double progress = 0.0;
  std::string speed_text;
  std::string eta_text;
  std::string output_path;
  flutter::EncodableList produced_paths;
  {
    std::lock_guard<std::mutex> lock(yt_dlp_mutex_);
    progress = task->progress;
    speed_text = task->speed_text;
    eta_text = task->eta_text;
    output_path = task->output_path;
    for (const auto& path : task->produced_paths) {
      if (!path.empty()) {
        produced_paths.emplace_back(path);
      }
    }
    if (task->termination_reason == "pause") {
      task->status = "paused";
      yt_dlp_tasks_.erase(task->task_id);
      return;
    }
    if (task->termination_reason == "cancel") {
      task->status = "cancelled";
      event_type = "task_cancelled";
      message = task->message.empty() ? "Cancelled" : task->message;
      error_code = "USER_CANCELLED";
    } else if (exit_code == 0) {
      std::string resolved_output_path = output_path;
      auto prefer_candidate = [&](const std::string& candidate) {
        if (candidate.empty()) {
          return false;
        }
        const std::filesystem::path candidate_path(Utf8ToWide(candidate));
        if (!std::filesystem::exists(candidate_path) ||
            LooksLikeTemporaryArtifact(candidate_path)) {
          return false;
        }
        resolved_output_path = candidate;
        return !LooksLikeSubtitleSidecar(candidate_path);
      };
      if (!prefer_candidate(output_path)) {
        for (const auto& produced_path : task->produced_paths) {
          if (prefer_candidate(produced_path)) {
            break;
          }
        }
      }
      output_path = resolved_output_path;
      task->output_path = resolved_output_path;
      if (resolved_output_path.empty()) {
        task->status = "failed";
        task->error_code = "NO_OUTPUT_FILE";
        event_type = "task_failed";
        error_code = task->error_code;
        message = "yt-dlp exited successfully but no final output file was found";
      } else {
      task->status = "completed";
      task->progress = 1.0;
      progress = 1.0;
      event_type = "task_completed";
      message = task->message.empty() ? "Completed" : task->message;
      eta_text = "00:00";
      }
    } else {
      task->status = "failed";
      task->error_code = "EXIT_" + std::to_string(exit_code);
      event_type = "task_failed";
      error_code = task->error_code;
      std::ostringstream tail;
      for (const auto& line : task->log_tail) {
        if (!line.empty()) {
          if (tail.tellp() > 0) {
            tail << "\n";
          }
          tail << line;
        }
      }
      message = !task->message.empty() ? task->message : Trim(tail.str());
      if (message.empty()) {
        message = "Download failed";
      }
    }
    yt_dlp_tasks_.erase(task->task_id);
  }

  EmitYtDlpEvent({
      {flutter::EncodableValue("taskId"), flutter::EncodableValue(task->task_id)},
      {flutter::EncodableValue("type"), flutter::EncodableValue(event_type)},
      {flutter::EncodableValue("progress"), flutter::EncodableValue(progress)},
      {flutter::EncodableValue("speedText"),
       flutter::EncodableValue(speed_text)},
      {flutter::EncodableValue("etaText"), flutter::EncodableValue(eta_text)},
      {flutter::EncodableValue("outputPath"),
       flutter::EncodableValue(output_path)},
      {flutter::EncodableValue("producedPaths"),
       flutter::EncodableValue(produced_paths)},
      {flutter::EncodableValue("errorCode"), flutter::EncodableValue(error_code)},
      {flutter::EncodableValue("message"), flutter::EncodableValue(message)},
  });
}

void FlutterWindow::HandleYtDlpOutput(
    const std::shared_ptr<WindowsYtDlpTask>& task,
    const std::string& line) {
  const auto trimmed = Trim(line);
  if (trimmed.empty()) {
    return;
  }

  flutter::EncodableMap payload;
  bool should_emit = false;
  {
    std::lock_guard<std::mutex> lock(yt_dlp_mutex_);
    if (task->log_tail.size() >= 12) {
      task->log_tail.pop_front();
    }
    task->log_tail.push_back(trimmed);

    const auto register_output_path = [&](const std::string& path) {
      const auto normalized = StripWrappingQuotes(path);
      if (normalized.empty()) {
        return;
      }
      task->output_path = normalized;
      if (std::find(task->produced_paths.begin(), task->produced_paths.end(),
                    normalized) == task->produced_paths.end()) {
        task->produced_paths.push_back(normalized);
      }
    };
    const auto update_output_path = [&](const std::string& marker) {
      const auto pos = trimmed.find(marker);
      if (pos == std::string::npos) {
        return;
      }
      register_output_path(trimmed.substr(pos + marker.size()));
    };
    update_output_path("Destination:");
    update_output_path("Merging formats into");
    update_output_path("[ExtractAudio] Destination:");

    const auto before_dl_path = NormalizeYtDlpMarkerPath(
        "__YTDLP_BEFORE_DL__:", trimmed);
    if (!before_dl_path.empty()) {
      register_output_path(before_dl_path);
      task->status = "downloading";
      task->message = "Preparing output";
      should_emit = true;
      payload[flutter::EncodableValue("taskId")] =
          flutter::EncodableValue(task->task_id);
      payload[flutter::EncodableValue("type")] =
          flutter::EncodableValue("task_step");
      payload[flutter::EncodableValue("progress")] =
          flutter::EncodableValue(task->progress);
      payload[flutter::EncodableValue("speedText")] =
          flutter::EncodableValue(task->speed_text);
      payload[flutter::EncodableValue("etaText")] =
          flutter::EncodableValue(task->eta_text);
      payload[flutter::EncodableValue("outputPath")] =
          flutter::EncodableValue(task->output_path);
      payload[flutter::EncodableValue("producedPaths")] =
          flutter::EncodableValue(flutter::EncodableList{
              flutter::EncodableValue(task->output_path)});
      payload[flutter::EncodableValue("message")] =
          flutter::EncodableValue("Preparing output");
      return;
    }

    const auto after_move_path = NormalizeYtDlpMarkerPath(
        "__YTDLP_AFTER_MOVE__:", trimmed);
    if (!after_move_path.empty()) {
      register_output_path(after_move_path);
      task->status = "post_processing";
      task->message = "Finalizing file";
      should_emit = true;
      flutter::EncodableList task_outputs;
      for (const auto& produced_path : task->produced_paths) {
        task_outputs.emplace_back(produced_path);
      }
      payload[flutter::EncodableValue("taskId")] =
          flutter::EncodableValue(task->task_id);
      payload[flutter::EncodableValue("type")] =
          flutter::EncodableValue("task_step");
      payload[flutter::EncodableValue("progress")] =
          flutter::EncodableValue(task->progress);
      payload[flutter::EncodableValue("speedText")] =
          flutter::EncodableValue(task->speed_text);
      payload[flutter::EncodableValue("etaText")] =
          flutter::EncodableValue(task->eta_text);
      payload[flutter::EncodableValue("outputPath")] =
          flutter::EncodableValue(task->output_path);
      payload[flutter::EncodableValue("producedPaths")] =
          flutter::EncodableValue(task_outputs);
      payload[flutter::EncodableValue("message")] =
          flutter::EncodableValue("Finalizing file");
      return;
    }

    if (trimmed.rfind("ERROR:", 0) == 0) {
      task->message = Trim(trimmed.substr(6));
      task->error_code = "YT_DLP_ERROR";
      return;
    }

    if (trimmed.find("[Merger]") != std::string::npos ||
        trimmed.find("[ExtractAudio]") != std::string::npos ||
        trimmed.find("Merging formats into") != std::string::npos ||
        trimmed.find("Deleting original file") != std::string::npos ||
        trimmed.find("Post-process") != std::string::npos) {
      task->status = "post_processing";
      task->message = trimmed;
      should_emit = true;
      payload[flutter::EncodableValue("taskId")] =
          flutter::EncodableValue(task->task_id);
      payload[flutter::EncodableValue("type")] =
          flutter::EncodableValue("task_post_processing");
      payload[flutter::EncodableValue("progress")] =
          flutter::EncodableValue(task->progress);
      payload[flutter::EncodableValue("speedText")] =
          flutter::EncodableValue(task->speed_text);
      payload[flutter::EncodableValue("etaText")] =
          flutter::EncodableValue(task->eta_text);
      payload[flutter::EncodableValue("outputPath")] =
          flutter::EncodableValue(task->output_path);
      flutter::EncodableList task_outputs;
      for (const auto& produced_path : task->produced_paths) {
        task_outputs.emplace_back(produced_path);
      }
      payload[flutter::EncodableValue("producedPaths")] =
          flutter::EncodableValue(task_outputs);
      payload[flutter::EncodableValue("message")] =
          flutter::EncodableValue(trimmed);
    } else if (trimmed.rfind("[download]", 0) == 0) {
      std::smatch match;
      if (std::regex_search(trimmed, match,
                            std::regex(R"((\d+(?:\.\d+)?)%)")) &&
          match.size() > 1) {
        task->progress =
            std::min(1.0, std::max(0.0, std::stod(match[1].str()) / 100.0));
      }
      if (std::regex_search(trimmed, match,
                            std::regex(R"(\bat\s+(.+?)\s+ETA\b)")) &&
          match.size() > 1) {
        task->speed_text = Trim(match[1].str());
      }
      if (std::regex_search(trimmed, match, std::regex(R"(\bETA\s+([0-9:]+))")) &&
          match.size() > 1) {
        task->eta_text = Trim(match[1].str());
      }
      task->status = "downloading";
      task->message = "Downloading";
      const auto now = std::chrono::steady_clock::now();
      const auto emit_due_to_time =
          task->last_progress_emit_at.time_since_epoch().count() == 0 ||
          now - task->last_progress_emit_at >= std::chrono::milliseconds(250);
      const auto emit_due_to_progress =
          task->last_emitted_progress < 0 ||
          (task->progress - task->last_emitted_progress) >= 0.01 ||
          task->progress >= 1.0;
      should_emit = emit_due_to_time || emit_due_to_progress;
      if (should_emit) {
        task->last_progress_emit_at = now;
        task->last_emitted_progress = task->progress;
      }
      payload[flutter::EncodableValue("taskId")] =
          flutter::EncodableValue(task->task_id);
      payload[flutter::EncodableValue("type")] =
          flutter::EncodableValue("task_progress");
      payload[flutter::EncodableValue("progress")] =
          flutter::EncodableValue(task->progress);
      payload[flutter::EncodableValue("speedText")] =
          flutter::EncodableValue(task->speed_text);
      payload[flutter::EncodableValue("etaText")] =
          flutter::EncodableValue(task->eta_text);
      payload[flutter::EncodableValue("outputPath")] =
          flutter::EncodableValue(task->output_path);
      flutter::EncodableList task_outputs;
      for (const auto& produced_path : task->produced_paths) {
        task_outputs.emplace_back(produced_path);
      }
      payload[flutter::EncodableValue("producedPaths")] =
          flutter::EncodableValue(task_outputs);
      payload[flutter::EncodableValue("message")] =
          flutter::EncodableValue(task->message);
    }
  }

  if (should_emit) {
    EmitYtDlpEvent(payload);
  }
}
