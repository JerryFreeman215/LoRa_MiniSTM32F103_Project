# LoRa MiniSTM32F103 Project

Target board: ALIENTEK MiniSTM32 V4 with STM32F103RCT6.

This firmware receives complete AGV `CONTROL_CMD` frames from LoRa B and
forwards them unchanged to the vehicle MCU. A continuous command (`pulses=0`)
arms a local 60-second safety watchdog. If the timeout expires, the gateway
sends three lock frames directly to the vehicle MCU.

## Clone

```powershell
git clone https://github.com/JerryFreeman215/LoRa_MiniSTM32F103_Project.git
cd LoRa_MiniSTM32F103_Project
```

The repository root contains this README, the STM32CubeIDE project, firmware
sources, build and JTAG flashing scripts, PC control tools, and retained
validation records.

## Hardware mapping

### LoRa B on the ATK MODULE socket

| LoRa pin | MCU pin | Function |
| --- | --- | --- |
| VCC | ATK VCC5 | Module power |
| GND | GND | Common ground |
| TXD | PD2 | UART5_RX |
| RXD | PC12 | UART5_TX |
| AUX | PC4 | GPIO input |
| MD0 | PA4 | GPIO output, held low in data mode |

UART5 is configured as 9600 baud, 8 data bits, no parity, 1 stop bit.
Do not use LED1, the onboard EEPROM I2C clock, NRF, ADC, or DAC functions that
share PD2, PC12, PC4, and PA4.

### Vehicle MCU

| MiniSTM32 pin | Vehicle MCU | Function |
| --- | --- | --- |
| PA9 | RX | USART1_TX, control frames |
| PA10 | TX | USART1_RX, optional diagnostics |
| GND | GND | Common ground |

USART1 is configured as 460800 baud, 8N1. Remove both P3 USB-UART jumper caps
that connect PA9/PA10 to the onboard CH340 before connecting the vehicle MCU.
Do not connect the two boards' power rails together.

### CMSIS-DAP through the 20-pin JTAG connector

The firmware leaves full JTAG enabled. The important connector signals are:

| JTAG pin | Signal |
| --- | --- |
| 1/2 | 3.3 V target reference |
| 4/6/8/10/... | GND |
| 3 | nTRST |
| 5 | TDI |
| 7 | TMS |
| 9 | TCK |
| 13 | TDO |
| 15 | nRESET |

Power the MiniSTM32 from its USB power input. The DAP target-reference pin is
not the main board supply. Keep BOOT0 low for normal Flash boot.

## Build

From this directory:

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\build.ps1
```

Outputs are written to `build/Debug/`:

- `MiniSTM32F103_Gateway.elf`
- `MiniSTM32F103_Gateway.hex`
- `MiniSTM32F103_Gateway.bin`

## Program with CMSIS-DAP in JTAG mode

Connect the complete JTAG cable and power the target, then run:

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\flash_jtag.ps1
```

The script programs the ELF, verifies Flash, resets the target, and exits.

## JTAG diagnostics

The global symbols `gateway_state` and `gateway_stats` remain available in the
ELF. Useful counters include received bytes, valid frames, forwarded frames,
drops, parser timeouts, UART errors, vehicle return bytes, watchdog state,
safety lock frames, and safety lock errors. PA8 toggles every 500 ms while the
main loop is running. A fast PA8 blink indicates the error handler.

## Keyboard vehicle test

The keyboard console uses COM8 at 9600 baud and adds the directed LoRa header
`00 01 17` before the original AGV `CONTROL_CMD` frame. The target address and
channel are script parameters and can be changed without rebuilding firmware.

Before starting:

1. Remove both P3 jumpers that connect PA9/PA10 to the onboard CH340.
2. Connect PA9 to the vehicle MCU RX, PA10 to MCU TX, and connect GND to GND.
3. Confirm that both UART interfaces use 3.3 V TTL levels.
4. Close XCOM or any other program using COM8.
5. Keep the first test short and ensure the vehicle has a clear path.

Start the console by double-clicking `tools/start_control_console.cmd`, or run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\control_console.ps1
```

The current baseline uses PWM 8/8 and `pulses=0` for continuous motion. The PC
console sends a soft safety lock after 58 seconds. The gateway enforces a local
60-second hard limit, leaving two seconds for the directed lock frames to cross
the LoRa link before local fallback is required.

| Key | Action |
| --- | --- |
| A | Arm the continuous RUN command |
| R | Start continuous motion, only after A |
| L or Space | Send the lock burst immediately |
| Q | Send the lock burst and exit |

The console sends a lock burst when it starts, after the PC safety timeout,
when L/Space/Q is pressed, and again during normal cleanup. Each session writes
a timestamped CSV file under `logs/runtime/`. The verified single-vehicle
baseline logs are retained under `logs/single_vehicle_baseline_20260829/`.

## Multi-vehicle control

Both vehicles use the same gateway firmware. Their LoRa receivers use unique
directed addresses, configured in `tools/vehicles.psd1`:

| Key | Vehicle | Directed target |
| --- | --- | --- |
| 1 | Vehicle 1 | `00:01:17` |
| 2 | Vehicle 2 | `00:02:17` |

Start the multi-vehicle console with:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\multi_vehicle_console.ps1
```

or double-click `tools/start_multi_vehicle_console.cmd`.

For a continuous outdoor communication test, use the separate launcher:

```text
tools\start_multi_vehicle_continuous_console.cmd
```

It explicitly uses `pulses=0`, keeps the PC-side 58-second soft lock, and
relies on the gateway's independent 60-second hard lock as the final timeout.
The regular multi-vehicle launcher remains the short `pulses=50` test.

The controller maintains one active scope: Vehicle 1, Vehicle 2, or ALL.
Single-vehicle scopes use directed unicast headers `00:01:17` and `00:02:17`.
The ALL scope sends one directed broadcast per configured channel using the
reserved target `FF:FF:<channel>`, so every receiver on that channel gets the
same AGV frame from one LoRa transmission. Changing scope first locks the
active scope. Repeated RUN commands are blocked until the active scope has
been locked. `L` locks the active or selected scope. Space, startup, exit, and
abnormal cleanup send a three-round directed broadcast lock burst. A normal Q
exit does not send a duplicate cleanup burst after its exit lock has completed.

The broadcast target is used only in the transmitted directed header; vehicle
modules retain their unique local addresses. See
`logs/directed_broadcast_validation_20260830/design_change_report.md` for the
protocol basis, failed sequential-unicast timing evidence, successful vehicle
test, and safety boundaries.

| Key | Action |
| --- | --- |
| 0 | Select ALL vehicles as one group |
| 1 / 2 | Select one vehicle by directed address |
| A | Arm the selected vehicle or group |
| R | Start the selected scope, only after A |
| L | Lock the active or selected scope |
| Space | Emergency lock all vehicles |
| Q | Lock all vehicles and exit |

Only one console may open COM8 at a time. Multi-vehicle logs are written to
`logs/runtime/multi_control_tx_*.csv` and include the vehicle ID, name, target,
event, and reason for every transmitted frame.
