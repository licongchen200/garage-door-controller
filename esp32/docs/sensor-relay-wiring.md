# Door sensor and relay wiring reference

This is the wiring plan for the exact ESP32-C3 SuperMini board used by the
controller. The pin assignments below were verified from the board photo and
its silkscreen.

## Board pin assignments

The board silkscreen is arranged as follows when viewed from the component
side:

| Left column | Right column |
| --- | --- |
| 5V | 5 |
| G | 6 |
| 3.3 | 7 |
| 4 | 8 |
| 3 | 9 |
| 2 | 10 |
| 1 | 20 |
| 0 | 21 |

Use the GPIO number, not the physical row number, when making connections:

| GPIO | Function | Electrical mode | Connection |
| ---: | --- | --- | --- |
| 4 | Opener relay control | Output; momentary pulse | Relay module input/control pin |
| 5 | Door-closed reed switch | Input with `INPUT_PULLUP` | One reed contact to GPIO5, the other to GND |
| 6 | Door-open reed switch | Input with `INPUT_PULLUP` | One reed contact to GPIO6, the other to GND |
| 8 | Onboard status LED | Existing active-low output | Onboard blue LED; LOW turns it on |

The two reed switches are position sensors: the closed sensor is active when
the door is fully closed, and the open sensor is active when the door is fully
open. With `INPUT_PULLUP`, an open switch reads HIGH and a closed switch to
GND reads LOW.

No external resistor is needed for either reed-switch connection. The ESP32's
internal pull-up provides the input bias.

The relay module has its own onboard driver and resistor. Wire GPIO4 directly
to the module's control/input pin, with a shared ground. Do not add an external
resistor to this connection.

## Relay connection to the opener

Use a momentary dry-contact relay output in parallel with the opener's existing
wall-button terminals. The relay should briefly close those same two terminals
to emulate a button press. One pulse is used for either opening or closing;
the opener determines the direction from the door's actual position and its
own controller state.

The relay is not a motor-power switch. Never connect it to the motor side or
to household mains.

Before wiring the relay, unplug the opener or otherwise power it off. The
wall-button terminals are low-voltage, but they must still be treated as a
separate low-voltage control circuit and kept isolated from mains wiring.

## Behavior after firmware support is added

The reed sensors will replace the current software-only `door_state` guess
with real position reads. Firmware should use the GPIO5/GPIO6 readings to
report the door's observed position, and GPIO4 should produce only the
momentary relay pulse required to trigger the opener.

Sensor and relay firmware support is a follow-up task; it is not shipped yet.
At present, `esp32/src/main.cpp` still maintains `doorState` in memory and
only configures the onboard LED on GPIO8. This document records the planned
wiring and behavior and does not imply that GPIO4, GPIO5, or GPIO6 are already
implemented.
