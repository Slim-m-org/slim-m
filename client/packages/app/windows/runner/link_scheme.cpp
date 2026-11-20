#include "link_scheme.h"

#include <windows.h>

#include <cwchar>
#include <string>

#include "link_handoff.h"
#include "utils.h"

namespace {

constexpr wchar_t kSchemeKey[] = L"Software\\Classes\\slimm";
constexpr wchar_t kCommandKey[] = L"Software\\Classes\\slimm\\shell\\open\\command";
constexpr wchar_t kIconKey[] = L"Software\\Classes\\slimm\\DefaultIcon";

std::wstring ReadDefault(const wchar_t* subkey) {
  DWORD size = 0;
  if (::RegGetValueW(HKEY_CURRENT_USER, subkey, nullptr, RRF_RT_REG_SZ, nullptr,
                     nullptr, &size) != ERROR_SUCCESS) {
    return std::wstring();
  }
  std::wstring value(size / sizeof(wchar_t), L'\0');
  if (::RegGetValueW(HKEY_CURRENT_USER, subkey, nullptr, RRF_RT_REG_SZ, nullptr,
                     value.data(), &size) != ERROR_SUCCESS) {
    return std::wstring();
  }
  value.resize(::wcsnlen(value.c_str(), value.size()));
  return value;
}

void Write(const wchar_t* subkey, const wchar_t* name,
           const std::wstring& value) {
  ::RegSetKeyValueW(HKEY_CURRENT_USER, subkey, name, REG_SZ, value.c_str(),
                    static_cast<DWORD>((value.size() + 1) * sizeof(wchar_t)));
}

}  // namespace

void RegisterLinkScheme() {
  const std::wstring own = ExecutablePath();
  if (own.empty()) return;
  const std::wstring handler = slimm::LinkHandlerFor(own, IsFile);
  const std::wstring command = slimm::OpenCommandFor(handler);
  if (ReadDefault(kCommandKey) == command) return;
  Write(kSchemeKey, nullptr, L"URL:slim-m");
  Write(kSchemeKey, L"URL Protocol", L"");
  Write(kIconKey, nullptr, handler + L",0");
  // The command goes last: the check above retries a registration cut short.
  Write(kCommandKey, nullptr, command);
}
