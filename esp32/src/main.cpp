#include <Arduino.h>
#include <ArduinoJson.h>
#include <PubSubClient.h>
#include <WiFi.h>

#include <time.h>

#if __has_include("config.h")
#include "config.h"
#endif

#ifdef WOKWI_SIMULATION
#define DEFAULT_WIFI_SSID "Wokwi-GUEST"
#define DEFAULT_WIFI_PASSWORD ""
#define DEFAULT_MQTT_HOST "broker.hivemq.com"
#else
// An empty host/SSID keeps an unconfigured physical build offline.
#define DEFAULT_WIFI_SSID ""
#define DEFAULT_WIFI_PASSWORD ""
#define DEFAULT_MQTT_HOST ""
#endif

#ifndef WIFI_SSID
#define WIFI_SSID DEFAULT_WIFI_SSID
#endif
#ifndef WIFI_PASSWORD
#define WIFI_PASSWORD DEFAULT_WIFI_PASSWORD
#endif
#ifndef MQTT_HOST
#define MQTT_HOST DEFAULT_MQTT_HOST
#endif
#ifndef MQTT_PORT
#define MQTT_PORT 1883
#endif
#ifndef MQTT_USERNAME
#define MQTT_USERNAME ""
#endif
#ifndef MQTT_PASSWORD
#define MQTT_PASSWORD ""
#endif

// Keep this as the only hardware-specific output pin for the onboard RGB LED.
static constexpr uint8_t DOOR_LED_PIN = 8;

static constexpr char CMD_TOPIC[] = "garage/door/cmd";
static constexpr char ACK_TOPIC[] = "garage/door/cmd/ack";
static constexpr char STATE_TOPIC[] = "garage/door/state";
static constexpr char LWT_TOPIC[] = "garage/door/lwt";
static constexpr char LWT_ONLINE[] = R"({"online":true})";
static constexpr char LWT_OFFLINE[] = R"({"online":false})";

// Match deploy/mock-esp32.py's simulated transition delay until real hardware exists.
static constexpr unsigned long SIMULATED_TRANSITION_MS = 2000;
static constexpr unsigned long WIFI_RETRY_MS = 10000;
static constexpr unsigned long MQTT_RETRY_MS = 5000;

WiFiClient wifiClient;
PubSubClient mqttClient(wifiClient);
const char *doorState = "closed";
unsigned long lastWifiAttempt = 0;
unsigned long lastMqttAttempt = 0;
bool ntpConfigured = false;

void setLedForState() {
  const bool doorIsOpen = strcmp(doorState, "open") == 0;
  neopixelWrite(DOOR_LED_PIN, 0, doorIsOpen ? 255 : 0, 0);
}

uint32_t currentTimestamp() {
  const time_t now = time(nullptr);
  return now > 0 ? static_cast<uint32_t>(now) : 0;
}

bool publishState() {
  JsonDocument document;
  document["state"] = doorState;
  document["ts"] = currentTimestamp();

  char payload[96];
  serializeJson(document, payload, sizeof(payload));
  const bool published = mqttClient.publish(STATE_TOPIC, payload, true);
  if (published) {
    Serial.printf("-> state: %s\n", doorState);
  }
  return published;
}

void publishAck(const char *commandId) {
  JsonDocument document;
  document["id"] = commandId;
  document["result"] = "triggered";

  char payload[128];
  serializeJson(document, payload, sizeof(payload));
  mqttClient.publish(ACK_TOPIC, payload);
}

void onMqttMessage(char *topic, byte *payload, unsigned int length) {
  if (strcmp(topic, CMD_TOPIC) != 0) {
    return;
  }

  JsonDocument document;
  const DeserializationError error = deserializeJson(document, payload, length);
  if (error || !document.is<JsonObject>()) {
    Serial.println("ignoring invalid JSON command");
    return;
  }

  const char *command = document["cmd"];
  const char *commandId = document["id"];
  if (command == nullptr || commandId == nullptr || commandId[0] == '\0' ||
      (strcmp(command, "open") != 0 && strcmp(command, "close") != 0)) {
    Serial.println("ignoring malformed command");
    return;
  }

  Serial.printf("<- command: %s (id=%s)\n", command, commandId);
  delay(SIMULATED_TRANSITION_MS);

  doorState = strcmp(command, "open") == 0 ? "open" : "closed";
  setLedForState();
  publishAck(commandId);
  publishState();
}

String mqttClientId() {
  const uint64_t chipId = ESP.getEfuseMac();
  char clientId[32];
  snprintf(clientId, sizeof(clientId), "esp32-c3-%06llx",
           static_cast<unsigned long long>(chipId & 0xffffff));
  return String(clientId);
}

void announceMqttConnection() {
  mqttClient.subscribe(CMD_TOPIC);
  mqttClient.publish(LWT_TOPIC, LWT_ONLINE, true);
  publishState();
  Serial.printf("connected - subscribing to %s\n", CMD_TOPIC);
}

void connectMqttIfNeeded() {
  if (mqttClient.connected() || WiFi.status() != WL_CONNECTED || MQTT_HOST[0] == '\0' ||
      millis() - lastMqttAttempt < MQTT_RETRY_MS) {
    return;
  }

  lastMqttAttempt = millis();
  mqttClient.setServer(MQTT_HOST, MQTT_PORT);
  const String clientId = mqttClientId();
  bool connected;
  if (MQTT_USERNAME[0] != '\0') {
    connected = mqttClient.connect(clientId.c_str(), MQTT_USERNAME, MQTT_PASSWORD, LWT_TOPIC, 0,
                                   true, LWT_OFFLINE);
  } else {
    connected = mqttClient.connect(clientId.c_str(), LWT_TOPIC, 0, true, LWT_OFFLINE);
  }

  if (connected) {
    announceMqttConnection();
  } else {
    Serial.printf("MQTT connect failed, state=%d\n", mqttClient.state());
  }
}

void startWifiIfNeeded() {
  if (WiFi.status() == WL_CONNECTED) {
    if (!ntpConfigured) {
      configTime(0, 0, "pool.ntp.org", "time.nist.gov");
      ntpConfigured = true;
    }
    return;
  }
  if (WIFI_SSID[0] == '\0' || millis() - lastWifiAttempt < WIFI_RETRY_MS) {
    return;
  }

  lastWifiAttempt = millis();
  Serial.printf("connecting to WiFi %s ...\n", WIFI_SSID);
  WiFi.begin(WIFI_SSID, WIFI_PASSWORD);
}

void setup() {
  Serial.begin(115200);
  setLedForState();

  mqttClient.setCallback(onMqttMessage);
  WiFi.mode(WIFI_STA);
  WiFi.setAutoReconnect(true);
  startWifiIfNeeded();

  if (WIFI_SSID[0] == '\0' || MQTT_HOST[0] == '\0') {
    Serial.println("WiFi/MQTT not configured; firmware is offline until include/config.h is added");
  }
}

void loop() {
  startWifiIfNeeded();
  connectMqttIfNeeded();
  if (mqttClient.connected()) {
    mqttClient.loop();
  }
  delay(10);
}
