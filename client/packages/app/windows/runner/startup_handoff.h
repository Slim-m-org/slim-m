// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
#ifndef RUNNER_STARTUP_HANDOFF_H_
#define RUNNER_STARTUP_HANDOFF_H_

#include <cstddef>
#include <string>
#include <utility>
#include <vector>

namespace slimm {

/// Links a later launch forwarded before Dart had a handler for them, kept in
/// arrival order until Dart asks. Bounded, so a flood cannot grow it.
class PendingLinks {
 public:
  static constexpr std::size_t kLimit = 16;

  /// Hands `link` to `deliver` when Dart is already listening, else holds it.
  /// False when the queue is full and the link was dropped.
  template <typename Deliver>
  bool Offer(std::string link, Deliver deliver) {
    if (listening_) {
      deliver(std::move(link));
      return true;
    }
    if (links_.size() >= kLimit) return false;
    links_.push_back(std::move(link));
    return true;
  }

  /// Dart's handler is installed: returns what was held and delivers directly from now on.
  std::vector<std::string> StartListening() {
    listening_ = true;
    return std::exchange(links_, {});
  }

 private:
  bool listening_ = false;
  std::vector<std::string> links_;
};

/// Whether the shortcut repair has to run for the version `current` names,
/// given the version it last ran for.
inline bool ShortcutRepairDue(const std::string& current,
                              const std::string& recorded) {
  return current.empty() || current != recorded;
}

/// A pointer file's text without the line ending an editor or script adds.
inline std::string TrimLineEnding(std::string text) {
  while (!text.empty() &&
         (text.back() == '\n' || text.back() == '\r' || text.back() == ' ')) {
    text.pop_back();
  }
  return text;
}

}  // namespace slimm

#endif  // RUNNER_STARTUP_HANDOFF_H_
