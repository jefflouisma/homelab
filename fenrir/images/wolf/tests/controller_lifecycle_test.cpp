#include "control/controller_lifecycle.hpp"
#include <cassert>

int main() {
  using Action = control::ControllerLifecycle::Action;
  control::ControllerLifecycle remote;
  assert(remote.update(0, 0, false, false) == Action::ignore);
  assert(remote.update(0, 0, false, true) == Action::input);
  // Down, repeats during a hold, release, and the next press use one device.
  for (int i = 0; i < 30; ++i) assert(remote.update(0, 0, true, i % 3 != 0) == Action::input);
  // Advertising the same pad later restores normal hot-unplug semantics.
  assert(remote.update(0, 1, true, false) == Action::input);
  assert(remote.update(0, 0, true, false) == Action::remove);
  assert(remote.update(0, 0, false, false) == Action::ignore);
  // Each controller's lifecycle is independent, including the high mask bit.
  control::ControllerLifecycle pads;
  assert(pads.update(15, 0x8000, false, false) == Action::input);
  assert(pads.update(0, 0, false, true) == Action::input);
  assert(pads.update(15, 0, true, false) == Action::remove);
  assert(pads.update(0, 0, true, false) == Action::input);
  assert(pads.update(-1, 0, false, true) == Action::ignore);
  assert(pads.update(16, 0, false, true) == Action::ignore);
  // Tracking cannot leak between stream sessions.
  control::ControllerLifecycle other;
  assert(other.update(0, 0, true, false) == Action::input);
}
