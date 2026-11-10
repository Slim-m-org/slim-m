#ifndef RUNNER_BOUNDED_RETRY_H_
#define RUNNER_BOUNDED_RETRY_H_

namespace slimm {

/// Calls `attempt` until it succeeds or `attempts` calls are spent, running
/// `wait` between calls only, so a failure costs (attempts - 1) waits at most.
template <typename Attempt, typename Wait>
bool RetryWithWaits(int attempts, Attempt attempt, Wait wait) {
  for (int tried = 0; tried < attempts; ++tried) {
    if (attempt()) return true;
    if (tried + 1 < attempts) wait();
  }
  return false;
}

}  // namespace slimm

#endif  // RUNNER_BOUNDED_RETRY_H_
