#pragma once

namespace garage_door {

enum class WifiStartupPath {
  savedCredentials,
  compileTimeDefaults,
  setupPortal,
};

inline WifiStartupPath wifiStartupPath(bool savedCredentials, bool hasDefaults) {
  if (savedCredentials) {
    return WifiStartupPath::savedCredentials;
  }
  return hasDefaults ? WifiStartupPath::compileTimeDefaults : WifiStartupPath::setupPortal;
}

}  // namespace garage_door
