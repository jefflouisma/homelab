#pragma once

#include <atomic>
#include <cstdint>

namespace control {

// Moonlight Android remotes without joystick axes share controller 0 without
// reserving its active-mask bit. Only a pad that advertised that bit can unplug
// by clearing it. Keep unadvertised remotes alive for their stream's lifetime.
class ControllerLifecycle {
public:
  enum class Action { ignore, input, remove };

  Action update(int number, std::uint16_t mask, bool exists, bool has_input) {
    if (number < 0 || number >= 16) return Action::ignore;
    const auto bit = static_cast<std::uint16_t>(1u << number);
    if (mask & bit) {
      advertised.fetch_or(bit);
      return Action::input;
    }
    if (advertised.load() & bit) {
      advertised.fetch_and(static_cast<std::uint16_t>(~bit));
      return exists ? Action::remove : Action::ignore;
    }
    // A trailing neutral packet must not create a phantom controller.
    return exists || has_input ? Action::input : Action::ignore;
  }

private:
  std::atomic<std::uint16_t> advertised{0};
};

} // namespace control
