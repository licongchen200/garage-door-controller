# ESP32-C3 firmware

This is the v1 hardware replacement for [`deploy/mock-esp32.py`](../deploy/mock-esp32.py).
It reads the GPIO5 closed and GPIO6 open reed switches and drives the GPIO4 opener relay.
See [`docs/sensor-relay-wiring.md`](docs/sensor-relay-wiring.md) for the implemented wiring.

## Configuration

Copy `include/config.example.h` to `include/config.h` for the MQTT/TLS values used by a
development device:

```sh
cd esp32
cp include/config.example.h include/config.h
```

`include/config.h` is gitignored. Do not commit credentials. WiFi credentials are not required
for a shipped device: on first boot WiFiManager creates an open setup network named
`GarageDoor-Setup-<last four MAC characters>` and stores credentials in persistent flash after
they are submitted. The iOS app joins that network and submits them. A `WIFI_SSID`/
`WIFI_PASSWORD` pair in the ignored header is an optional captain-only development default and is
used only when WiFiManager has no saved credentials. The `wokwi` environment retains safe
development defaults (`Wokwi-GUEST` and `broker.hivemq.com`) when no config header is present.

The door indicator uses the ESP32-C3 Super Mini's onboard plain blue LED on **GPIO8**. It is lit
when the sensor-derived state is `open` and off when `closed`; it is not an RGB LED. During
`unknown`/transit it retains the last known position indication. The LED is wired active-low
(LOW = on, HIGH = off), so keep that polarity in sync with the firmware if the board or pin
changes. No external LED wiring or library is required.

## PlatformIO

From the repository root:

```sh
pio run -d esp32 -e esp32-c3                 # compile firmware
pio run -d esp32 -e esp32-c3 -t upload       # flash a connected board
pio device monitor -d esp32 -b 115200        # optional serial output
```

The upload command is intentionally not run by this project task. Select the correct upload port
for the machine hosting the board rather than assuming a port from another checkout.

## Wokwi

`diagram.json` contains an ESP32-C3 DevKitM-1, a simulated plain blue LED connected to GPIO8,
pushbuttons standing in for the closed/open reed switches on GPIO5/GPIO6, and an active-low
simulated relay module on GPIO4. Press `C` to close the closed-reed switch or `O` to close the
open-reed switch. Build the simulation firmware and run it from the `esp32/` directory:

```sh
pio run -e wokwi
wokwi-cli . --timeout 30000
```

Alternatively, open `esp32/` in VS Code with the Wokwi extension and start the simulation. The
Wokwi default WiFi is available without a password. If using a broker other than the documented
development default, create the ignored `include/config.h` before building. A local broker must be
reachable from the simulator; `localhost` inside Wokwi is not the host machine.

The CLI requires a Wokwi CI token in `WOKWI_CLI_TOKEN`; the VS Code extension can be used without
that CLI token. `wokwi-cli lint` checks the diagram's part types and pin connections.

To exercise the contract, publish commands to `garage/door/<mac>/cmd` with JSON such as
`{"cmd":"open","id":"wokwi-1"}`. The firmware publishes the matching ack on
`garage/door/<mac>/cmd/ack`, retained state on `garage/door/<mac>/state`, and the retained LWT on
`garage/door/<mac>/lwt`. `<mac>` is lower-case, separator-free, and is the same MAC identity used
when issuing a new device certificate with `deploy/issue-device-cert.sh <mac-address>`.
