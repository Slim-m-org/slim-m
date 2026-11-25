// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
#include "app_identity.h"

#include <windows.h>
#include <knownfolders.h>
#include <propkey.h>
#include <propvarutil.h>
#include <shlobj.h>
#include <shobjidl.h>
#include <wrl/client.h>

#include <fstream>
#include <iterator>
#include <string>
#include <vector>

#include "shortcut_identity.h"
#include "startup_handoff.h"
#include "utils.h"

using Microsoft::WRL::ComPtr;

namespace {

std::wstring KnownFolder(REFKNOWNFOLDERID id) {
  PWSTR path = nullptr;
  std::wstring result;
  if (SUCCEEDED(::SHGetKnownFolderPath(id, KF_FLAG_DEFAULT, nullptr, &path))) {
    result = path;
  }
  ::CoTaskMemFree(path);
  return result;
}

std::vector<std::wstring> ShortcutsIn(const std::wstring& folder) {
  std::vector<std::wstring> found;
  if (folder.empty()) return found;
  WIN32_FIND_DATAW entry;
  const HANDLE search = ::FindFirstFileW((folder + L"\\*.lnk").c_str(), &entry);
  if (search == INVALID_HANDLE_VALUE) return found;
  do {
    if (!(entry.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY)) {
      found.push_back(folder + L"\\" + entry.cFileName);
    }
  } while (::FindNextFileW(search, &entry));
  ::FindClose(search);
  return found;
}

std::wstring AppUserModelIdOf(IPropertyStore* store) {
  PROPVARIANT value;
  ::PropVariantInit(&value);
  std::wstring id;
  if (SUCCEEDED(store->GetValue(PKEY_AppUserModel_ID, &value)) &&
      value.vt == VT_LPWSTR && value.pwszVal != nullptr) {
    id = value.pwszVal;
  }
  ::PropVariantClear(&value);
  return id;
}

bool SetAppUserModelId(IPropertyStore* store) {
  PROPVARIANT id;
  if (FAILED(::InitPropVariantFromString(slimm::kAppUserModelId, &id))) {
    return false;
  }
  const bool set = SUCCEEDED(store->SetValue(PKEY_AppUserModel_ID, id)) &&
                   SUCCEEDED(store->Commit());
  ::PropVariantClear(&id);
  return set;
}

void Repair(const std::wstring& shortcut, const std::wstring& root) {
  ComPtr<IShellLinkW> link;
  ComPtr<IPersistFile> file;
  ComPtr<IPropertyStore> store;
  if (FAILED(::CoCreateInstance(CLSID_ShellLink, nullptr, CLSCTX_INPROC_SERVER,
                                IID_PPV_ARGS(&link))) ||
      FAILED(link.As(&file)) || FAILED(link.As(&store)) ||
      FAILED(file->Load(shortcut.c_str(), STGM_READ))) {
    return;
  }
  std::vector<wchar_t> target(32768, L'\0');
  if (link->GetPath(target.data(), static_cast<int>(target.size()), nullptr, 0) != S_OK) {
    return;
  }
  const std::wstring wanted =
      slimm::ShortcutTargetFor(root, target.data(), AppUserModelIdOf(store.Get()));
  if (wanted.empty()) return;
  // Only a shortcut that needs the change is opened for writing; the rest stay untouched.
  if (FAILED(file->Load(shortcut.c_str(), STGM_READWRITE))) return;
  link->SetPath(wanted.c_str());
  link->SetWorkingDirectory(root.c_str());
  link->SetIconLocation(wanted.c_str(), 0);
  if (!SetAppUserModelId(store.Get()) || FAILED(file->Save(shortcut.c_str(), TRUE))) {
    return;
  }
  ::SHChangeNotify(SHCNE_UPDATEITEM, SHCNF_PATHW, shortcut.c_str(), nullptr);
}

std::string ReadText(const std::wstring& path) {
  std::ifstream in(path, std::ios::binary);
  return slimm::TrimLineEnding(
      std::string(std::istreambuf_iterator<char>(in), std::istreambuf_iterator<char>()));
}

constexpr wchar_t kRepairMarker[] = L"shortcuts-repaired";

HANDLE g_repair = nullptr;

DWORD WINAPI RepairShortcuts(LPVOID) {
  const std::wstring root = slimm::LayoutRootFor(ExecutablePath(), IsFile);
  if (root.empty()) return 0;
  const std::string current = ReadText(root + L"\\" + slimm::kCurrentPointer);
  const std::wstring marker = root + L"\\" + kRepairMarker;
  if (!slimm::ShortcutRepairDue(current, ReadText(marker))) return 0;
  if (FAILED(::CoInitializeEx(nullptr, COINIT_MULTITHREADED))) return 0;
  const std::wstring pinned = KnownFolder(FOLDERID_UserPinned);
  for (const std::wstring& folder :
       {KnownFolder(FOLDERID_Programs), KnownFolder(FOLDERID_Desktop),
        pinned.empty() ? pinned : pinned + L"\\TaskBar"}) {
    for (const std::wstring& shortcut : ShortcutsIn(folder)) {
      Repair(shortcut, root);
    }
  }
  ::CoUninitialize();
  std::ofstream(marker, std::ios::binary | std::ios::trunc) << current;
  return 0;
}

}  // namespace

void ClaimAppIdentity() {
  ::SetCurrentProcessExplicitAppUserModelID(slimm::kAppUserModelId);
}

void StartShortcutRepair() {
  if (g_repair != nullptr) return;
  g_repair = ::CreateThread(nullptr, 0, RepairShortcuts, nullptr, 0, nullptr);
}

void FinishShortcutRepair() {
  if (g_repair == nullptr) return;
  ::WaitForSingleObject(g_repair, 10000);
  ::CloseHandle(g_repair);
  g_repair = nullptr;
}
