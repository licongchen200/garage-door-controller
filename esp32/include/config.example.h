#pragma once

// Copy this file to config.h and replace the values needed for a development device.
// config.h is gitignored and must never be committed.
// WIFI_SSID/WIFI_PASSWORD are optional: shipped devices receive WiFi through
// the WiFiManager setup portal instead of compile-time credentials.
#define WIFI_SSID "your-wifi-name"
#define WIFI_PASSWORD "your-wifi-password"
#define MQTT_HOST "192.168.1.10"
#define MQTT_PORT 8883

// Paste the PEM contents of the three files printed by deploy/issue-device-cert.sh.
// Keep the embedded newlines as \n escapes inside each string literal.
#define MQTT_CA_CERT ""
#define MQTT_CLIENT_CERT ""
#define MQTT_CLIENT_KEY ""
