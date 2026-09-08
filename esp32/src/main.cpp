#include <Arduino.h>
#include <ArduinoJson.h>
#include <PubSubClient.h>
#include <WiFi.h>
#include <WiFiManager.h>

#include <time.h>

#include "wifi_provisioning.h"

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

static constexpr char LWT_ONLINE[] = R"({"online":true})";
static constexpr char LWT_OFFLINE[] = R"({"online":false})";

static constexpr unsigned long MQTT_RETRY_MS = 5000;

WiFiClient wifiClient;
PubSubClient mqttClient(wifiClient);
WiFiManager wifiManager;
const char *doorState = "unknown";
unsigned long lastMqttAttempt = 0;
bool ntpConfigured = false;
bool lastKnownDoorWasOpen = false;
String deviceMac;
String commandTopic;
String ackTopic;
String stateTopic;
String lwtTopic;
String deviceMetadata;

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

String normalizedMacAddress() {
  String mac = WiFi.macAddress();
  mac.replace(":", "");
  mac.toLowerCase();
  return mac;
}

String setupAccessPointName() {
  String suffix = deviceMac.substring(deviceMac.length() > 4 ? deviceMac.length() - 4 : 0);
  suffix.toUpperCase();
  return String("GarageDoor-Setup-") + suffix;
}

void configureMqttTopics() {
  commandTopic = String("garage/door/") + deviceMac + "/cmd";
  ackTopic = String("garage/door/") + deviceMac + "/cmd/ack";
  stateTopic = String("garage/door/") + deviceMac + "/state";
  lwtTopic = String("garage/door/") + deviceMac + "/lwt";
}

void startWifiProvisioning() {
  const bool savedCredentials = wifiManager.getWiFiIsSaved();
  const bool hasCompileTimeDefaults = WIFI_SSID[0] != '\0';
  const garage_door::WifiStartupPath startupPath =
      garage_door::wifiStartupPath(savedCredentials, hasCompileTimeDefaults);

  // WiFiManager's autoconnect always tries NVS credentials before opening its
  // portal. Only preload config.h values when NVS is empty; a dev default must
  // never replace credentials that the device owner already saved.
  if (startupPath == garage_door::WifiStartupPath::compileTimeDefaults) {
    wifiManager.preloadWiFi(WIFI_SSID, WIFI_PASSWORD);
    Serial.printf("no saved WiFi credentials; trying development default %s first\n", WIFI_SSID);
  } else if (startupPath == garage_door::WifiStartupPath::savedCredentials) {
    Serial.println("trying saved WiFi credentials first");
  } else {
    Serial.println("no WiFi credentials saved; starting setup portal");
  }

  wifiManager.setConnectTimeout(10);
  wifiManager.setSaveConnectTimeout(10);
  wifiManager.setConnectRetries(3);

  // WiFiManager keeps this pointer for every portal page, so the backing String
  // must outlive this function.
  deviceMetadata = String("<meta name=\"garage-device-mac\" content=\"") + deviceMac +
                   String("\">");
  wifiManager.setCustomHeadElement(deviceMetadata.c_str());

  const String apName = setupAccessPointName();
  if (!wifiManager.autoConnect(apName.c_str())) {
    Serial.println("WiFi setup portal ended without a connection");
  }
}

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
  const bool published = mqttClient.publish(stateTopic.c_str(), payload, true);
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
  mqttClient.publish(ackTopic.c_str(), payload);
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
  if (strcmp(topic, commandTopic.c_str()) != 0) {
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
  mqttClient.subscribe(commandTopic.c_str());
  mqttClient.publish(lwtTopic.c_str(), LWT_ONLINE, true);
  publishState();
  Serial.printf("connected - subscribing to %s\n", commandTopic.c_str());
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
    connected = mqttClient.connect(clientId.c_str(), MQTT_USERNAME, MQTT_PASSWORD, lwtTopic.c_str(), 0,
                                   true, LWT_OFFLINE);
  } else {
    connected = mqttClient.connect(clientId.c_str(), lwtTopic.c_str(), 0, true, LWT_OFFLINE);
  }

  if (connected) {
    announceMqttConnection();
  } else {
    Serial.printf("MQTT connect failed, state=%d\n", mqttClient.state());
  }
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
  deviceMac = normalizedMacAddress();
  configureMqttTopics();
  startWifiProvisioning();

  if (MQTT_HOST[0] == '\0') {
    Serial.println("MQTT not configured; firmware is offline until include/config.h is added");
  }
}

void loop() {
  if (WiFi.status() == WL_CONNECTED && !ntpConfigured) {
    configTime(0, 0, "pool.ntp.org", "time.nist.gov");
    ntpConfigured = true;
  }
  connectMqttIfNeeded();
  pollDoorSensors();
  serviceRelayPulse();
  if (mqttClient.connected()) {
    mqttClient.loop();
  }
  delay(10);
}
