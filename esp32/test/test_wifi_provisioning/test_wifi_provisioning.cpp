#include <unity.h>

#include "wifi_provisioning.h"

void test_saved_credentials_are_attempted_first() {
  TEST_ASSERT_EQUAL(
      garage_door::WifiStartupPath::savedCredentials,
      garage_door::wifiStartupPath(true, false)
  );
}

void test_missing_credentials_enters_setup_portal() {
  TEST_ASSERT_EQUAL(
      garage_door::WifiStartupPath::setupPortal,
      garage_door::wifiStartupPath(false, false)
  );
}

void test_optional_defaults_are_used_when_nvs_is_empty() {
  TEST_ASSERT_EQUAL(
      garage_door::WifiStartupPath::compileTimeDefaults,
      garage_door::wifiStartupPath(false, true)
  );
}

int main(int, char **) {
  UNITY_BEGIN();
  RUN_TEST(test_saved_credentials_are_attempted_first);
  RUN_TEST(test_missing_credentials_enters_setup_portal);
  RUN_TEST(test_optional_defaults_are_used_when_nvs_is_empty);
  return UNITY_END();
}
