#include "utils.h"

#include <flutter_windows.h>
#include <io.h>
#include <stdio.h>
#include <windows.h>

#include <iostream>

void CreateAndAttachConsole() {
  if (::AllocConsole()) {
    FILE *unused;
    if (freopen_s(&unused, "CONOUT$", "w", stdout)) {
      _dup2(_fileno(stdout), 1);
    }
    if (freopen_s(&unused, "CONOUT$", "w", stderr)) {
      _dup2(_fileno(stdout), 2);
    }
    std::ios::sync_with_stdio();
    FlutterDesktopResyncOutputStreams();
  }
}

std::vector<std::string> GetCommandLineArguments() {
  int argc;
  wchar_t** argv = ::CommandLineToArgvW(::GetCommandLineW(), &argc);
  if (argv == nullptr) {
    return std::vector<std::string>();
  }

  std::vector<std::string> command_line_arguments;

  // Skip the first argument as it's the binary name.
  for (int i = 1; i < argc; i++) {
    command_line_arguments.push_back(Utf8FromUtf16(argv[i]));
  }

  ::LocalFree(argv);

  return command_line_arguments;
}

std::string Utf8FromUtf16(const wchar_t* utf16_string) {
  if (utf16_string == nullptr) {
    return std::string();
  }
  unsigned int target_length = ::WideCharToMultiByte(
      CP_UTF8, WC_ERR_INVALID_CHARS, utf16_string, -1, nullptr, 0, nullptr, nullptr) - 1;
  int input_length = (int)wcslen(utf16_string);
  std::string utf8_string;
  if (target_length == 0 || target_length > utf8_string.max_size()) {
    return utf8_string;
  }
  utf8_string.resize(target_length);
  int converted_length = ::WideCharToMultiByte(
      CP_UTF8, WC_ERR_INVALID_CHARS, utf16_string, input_length,
      utf8_string.data(), target_length, nullptr, nullptr);
  if (converted_length == 0) {
    return std::string();
  }
  return utf8_string;
}

// Visual Studio 2022 compatibility shims for pre-compiled static dependencies
// (e.g. Firebase C++ SDK FlatBuffers object files expecting vectorized STL helpers).
extern "C" {
  void* __cdecl __std_remove_8(void* first, void* last, uint64_t val) {
    uint64_t* f = static_cast<uint64_t*>(first);
    uint64_t* l = static_cast<uint64_t*>(last);
    uint64_t* result = f;
    for (; f != l; ++f) {
      if (*f != val) {
        *result = *f;
        ++result;
      }
    }
    return result;
  }

  size_t __cdecl __std_find_last_of_trivial_pos_1(
      const char* haystack, size_t haystack_size,
      const char* needle, size_t needle_size) {
    if (haystack_size == 0 || needle_size == 0) return static_cast<size_t>(-1);
    for (size_t i = haystack_size; i > 0; --i) {
      char c = haystack[i - 1];
      for (size_t j = 0; j < needle_size; ++j) {
        if (c == needle[j]) {
          return i - 1;
        }
      }
    }
    return static_cast<size_t>(-1);
  }
}
