# Test Logs

`single_vehicle_baseline_20260829/` contains the retained single-vehicle test
records used to establish this baseline.

| Log | RUN | LOCK | RUN pulses | Session duration |
| --- | ---: | ---: | ---: | ---: |
| `control_tx_20260829_214608.csv` | 4 | 24 | 5 | 84.573 s |
| `control_tx_20260829_215604.csv` | 4 | 24 | 50 | 369.804 s |
| `control_tx_20260829_220516.csv` | 0 | 3 | - | 0.449 s |
| `control_tx_20260829_221358.csv` | 1 | 12 | 50 | 18.387 s |
| `control_tx_20260829_222414.csv` | 3 | 18 | 0 | 63.513 s |

The last record verifies the PC-side continuous command flow: three
`pulses=0` RUN commands, one manual lock after about 4.95 seconds, and two
10-second safety lock events. PC logs prove serial transmission only; they do
not independently confirm LoRa reception or vehicle MCU execution.

New console sessions are written to `runtime/`. That directory is ignored by
Git so routine tests do not dirty the repository.
