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

static constexpr uint8_t RELAY_PIN = 4;
static constexpr uint8_t CLOSED_SENSOR_PIN = 5;
static constexpr uint8_t OPEN_SENSOR_PIN = 6;
static constexpr uint8_t DOOR_LED_PIN = 8;

// The wired relay module is active-low on its IN pin. Keep the pulse short and
// release the control line between commands so it behaves like a wall button.
static constexpr uint8_t RELAY_ACTIVE_LEVEL = LOW;
static constexpr uint8_t RELAY_INACTIVE_LEVEL = HIGH;
static constexpr unsigned long RELAY_PULSE_MS = 500;
static constexpr size_t RELAY_QUEUE_CAPACITY = 8;

static constexpr char CMD_TOPIC[] = "garage/door/cmd";
static constexpr char ACK_TOPIC[] = "garage/door/cmd/ack";
static constexpr char STATE_TOPIC[] = "garage/door/state";
static constexpr char LWT_TOPIC[] = "garage/door/lwt";
static constexpr char LWT_ONLINE[] = R"({"online":true})";
static constexpr char LWT_OFFLINE[] = R"({"online":false})";

static constexpr unsigned long WIFI_RETRY_MS = 10000;
static constexpr unsigned long MQTT_RETRY_MS = 5000;

WiFiClient wifiClient;
PubSubClient mqttClient(wifiClient);
const char *doorState = "unknown";
unsigned long lastWifiAttempt = 0;
unsigned long lastMqttAttempt = 0;
bool ntpConfigured = false;
bool lastKnownDoorWasOpen = false;

struct RelayCommand {
  char id[96];
};

RelayCommand relayQueue[RELAY_QUEUE_CAPACITY];
size_t relayQueueHead = 0;
size_t relayQueueCount = 0;
RelayCommand activeRelayCommand = {};
bool relayPulseActive = false;
unsigned long relayPulseStartedAt = 0;

bool publishState();

void setLedForState() {
  // The ESP32-C3 Super Mini onboard LED is active-low: LOW turns it on.
  // During transit/unknown, retain the last known open/closed indication.
  digitalWrite(DOOR_LED_PIN, lastKnownDoorWasOpen ? LOW : HIGH);
}

const char *readDoorState() {
  const bool doorIsClosed = digitalRead(CLOSED_SENSOR_PIN) == LOW;
  const bool doorIsOpen = digitalRead(OPEN_SENSOR_PIN) == LOW;

  if (doorIsClosed && !doorIsOpen) {
    return "closed";
  }
  if (doorIsOpen && !doorIsClosed) {
    return "open";
  }

  // Both HIGH means neither end-stop is active (transit/not fully seated).
  // Both LOW is also physically contradictory, so report it as unknown.
  return "unknown";
}

void pollDoorSensors() {
  const char *sensedState = readDoorState();
  if (strcmp(sensedState, doorState) == 0) {
    return;
  }

  doorState = sensedState;
  if (strcmp(doorState, "open") == 0) {
    lastKnownDoorWasOpen = true;
  } else if (strcmp(doorState, "closed") == 0) {
    lastKnownDoorWasOpen = false;
  }
  setLedForState();

  if (mqttClient.connected()) {
    publishState();
  }
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

void publishAck(const char *commandId, const char *result = "triggered") {
  JsonDocument document;
  document["id"] = commandId;
  document["result"] = result;

  char payload[128];
  serializeJson(document, payload, sizeof(payload));
  mqttClient.publish(ACK_TOPIC, payload);
}

bool enqueueRelayCommand(const char *commandId) {
  if (relayQueueCount >= RELAY_QUEUE_CAPACITY) {
    return false;
  }

  const size_t queueIndex = (relayQueueHead + relayQueueCount) % RELAY_QUEUE_CAPACITY;
  strncpy(relayQueue[queueIndex].id, commandId, sizeof(relayQueue[queueIndex].id) - 1);
  relayQueue[queueIndex].id[sizeof(relayQueue[queueIndex].id) - 1] = '\0';
  relayQueueCount++;
  return true;
}

bool dequeueRelayCommand(RelayCommand *command) {
  if (relayQueueCount == 0) {
    return false;
  }

  *command = relayQueue[relayQueueHead];
  relayQueueHead = (relayQueueHead + 1) % RELAY_QUEUE_CAPACITY;
  relayQueueCount--;
  return true;
}

void startNextRelayPulse() {
  if (relayPulseActive || !dequeueRelayCommand(&activeRelayCommand)) {
    return;
  }

  digitalWrite(RELAY_PIN, RELAY_ACTIVE_LEVEL);
  relayPulseStartedAt = millis();
  relayPulseActive = true;
  Serial.printf("relay pulse started (id=%s)\n", activeRelayCommand.id);
}

void serviceRelayPulse() {
  startNextRelayPulse();
  if (!relayPulseActive || millis() - relayPulseStartedAt < RELAY_PULSE_MS) {
    return;
  }

  digitalWrite(RELAY_PIN, RELAY_INACTIVE_LEVEL);
  relayPulseActive = false;
  publishAck(activeRelayCommand.id);
  Serial.printf("relay pulse released (id=%s)\n", activeRelayCommand.id);
  startNextRelayPulse();
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
  if (!enqueueRelayCommand(commandId)) {
    Serial.println("relay command queue full");
    publishAck(commandId, "error");
  }
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
  pinMode(RELAY_PIN, OUTPUT);
  digitalWrite(RELAY_PIN, RELAY_INACTIVE_LEVEL);
  pinMode(CLOSED_SENSOR_PIN, INPUT_PULLUP);
  pinMode(OPEN_SENSOR_PIN, INPUT_PULLUP);
  pinMode(DOOR_LED_PIN, OUTPUT);
  pollDoorSensors();
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
  pollDoorSensors();
  serviceRelayPulse();
  if (mqttClient.connected()) {
    mqttClient.loop();
  }
  delay(10);
}
