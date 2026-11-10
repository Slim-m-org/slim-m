// Run by scripts/lib/test_windows_runner_logic.py; no Windows headers needed.
#include <cstdio>

#include "../bounded_retry.h"

namespace {

int g_failures = 0;

#define CHECK(condition)                                                   \
  do {                                                                     \
    if (!(condition)) {                                                    \
      std::fprintf(stderr, "%s:%d: %s\n", __FILE__, __LINE__, #condition); \
      ++g_failures;                                                        \
    }                                                                      \
  } while (0)

void ARetryStopsAtTheFirstSuccess() {
  int attempts = 0;
  int waits = 0;
  const bool ok = slimm::RetryWithWaits(
      7, [&attempts] { return ++attempts == 3; }, [&waits] { ++waits; });
  CHECK(ok);
  CHECK(attempts == 3);
  CHECK(waits == 2);
}

void ARetryThatNeverSucceedsWaitsOneLessThanItTries() {
  int attempts = 0;
  int waits = 0;
  const bool ok = slimm::RetryWithWaits(
      7, [&attempts] { ++attempts; return false; }, [&waits] { ++waits; });
  CHECK(!ok);
  CHECK(attempts == 7);
  CHECK(waits == 6);
}

void AFirstTrySuccessNeverWaits() {
  int waits = 0;
  CHECK(slimm::RetryWithWaits(7, [] { return true; }, [&waits] { ++waits; }));
  CHECK(waits == 0);
}

void ASingleAttemptNeverWaits() {
  int waits = 0;
  CHECK(!slimm::RetryWithWaits(1, [] { return false; }, [&waits] { ++waits; }));
  CHECK(waits == 0);
}

}  // namespace

int main() {
  ARetryStopsAtTheFirstSuccess();
  ARetryThatNeverSucceedsWaitsOneLessThanItTries();
  AFirstTrySuccessNeverWaits();
  ASingleAttemptNeverWaits();
  if (g_failures != 0) {
    std::fprintf(stderr, "%d check(s) failed\n", g_failures);
    return 1;
  }
  std::puts("runner logic ok");
  return 0;
}
