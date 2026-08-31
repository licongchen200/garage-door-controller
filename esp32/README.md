# ESP32-C3 firmware

This is the v1 hardware replacement for [`deploy/mock-esp32.py`](../deploy/mock-esp32.py).
It tracks door state in memory only. There are no relay, sensor, or safety-interlock drivers yet.

## Configuration

Copy `include/config.example.h` to `include/config.h`, then set the WiFi and MQTT values:

```sh
cd esp32
cp include/config.example.h include/config.h
```

`include/config.h` is gitignored. Do not commit credentials. The `wokwi` environment has safe
development defaults (`Wokwi-GUEST` and `broker.hivemq.com`) when no config header is present;
use a private broker and a local `config.h` when testing the real MQTT contract.

The LED output is **GPIO4**. It is HIGH when the tracked state is `open` and LOW when `closed`.
Change `DOOR_LED_PIN` in `src/main.cpp` if the wiring changes.

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

`diagram.json` contains an ESP32-C3 DevKitM-1, a 220 ohm resistor, and an LED on GPIO4. Build the
simulation firmware and run it from the `esp32/` directory:

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

To exercise the contract, publish commands to `garage/door/cmd` with JSON such as
`{"cmd":"open","id":"wokwi-1"}`. The firmware publishes the matching ack on
`garage/door/cmd/ack`, then retained state on `garage/door/state`; the retained LWT is published on
`garage/door/lwt` and the broker will publish `{"online":false}` if the client disconnects
unexpectedly.
