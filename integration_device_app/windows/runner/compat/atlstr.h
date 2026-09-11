#pragma once

#include <windows.h>

#include <string>

// Minimal compatibility subset used by flutter_secure_storage_windows.
// The plugin only needs CA2W/CW2A conversion and the m_psz member exposed by
// ATL's conversion classes; the storage implementation itself remains the
// plugin's Windows Credential Manager/BCrypt code.
class CA2W {
 public:
  explicit CA2W(const char* value, UINT code_page = CP_ACP) {
    if (value == nullptr) {
      return;
    }
    const int length = MultiByteToWideChar(
        code_page, 0, value, -1, nullptr, 0);
    if (length <= 0) {
      return;
    }
    value_.resize(static_cast<size_t>(length));
    if (MultiByteToWideChar(
            code_page, 0, value, -1, value_.data(), length) <= 0) {
      value_.clear();
    }
    m_psz = value_.data();
  }

  LPWSTR m_psz = nullptr;

 private:
  std::wstring value_;
};

class CW2A {
 public:
  explicit CW2A(const wchar_t* value, UINT code_page = CP_ACP) {
    if (value == nullptr) {
      return;
    }
    const int length = WideCharToMultiByte(
        code_page, 0, value, -1, nullptr, 0, nullptr, nullptr);
    if (length <= 0) {
      return;
    }
    value_.resize(static_cast<size_t>(length));
    if (WideCharToMultiByte(
            code_page, 0, value, -1, value_.data(), length, nullptr, nullptr) <=
        0) {
      value_.clear();
    }
    m_psz = value_.c_str();
  }

  operator LPCSTR() const { return m_psz; }

  LPCSTR m_psz = nullptr;

 private:
  std::string value_;
};
