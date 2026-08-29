# MiniSTM32F103 LoRa AGV Gateway

Target board: ALIENTEK MiniSTM32 V4 with STM32F103RCT6.

This firmware receives complete AGV `CONTROL_CMD` frames from LoRa B and
forwards them unchanged to the vehicle MCU. It never creates a motion or lock
frame by itself.

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
drops, parser timeouts, UART errors, and vehicle return bytes. PA8 toggles every
500 ms while the main loop is running. A fast PA8 blink indicates the error
handler.
