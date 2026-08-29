/**
  ******************************************************************************
  * @file           : main.c
  * @brief          : MiniSTM32F103 LoRa-to-AGV UART gateway
  ******************************************************************************
  */

#include "main.h"

#include <string.h>

#define LORA_DATA_BAUD_RATE 9600U
#define VEHICLE_UART_BAUD_RATE 460800U

#define AGV_FRAME_MAX_SIZE 128U
#define AGV_FRAME_HEADER_0 0xAAU
#define AGV_FRAME_HEADER_1 0x55U
#define AGV_FRAME_TAIL_0 0x0DU
#define AGV_FRAME_TAIL_1 0x0AU
#define AGV_FRAME_OVERHEAD 10U
#define AGV_RX_INTERBYTE_TIMEOUT_MS 250U
#define VEHICLE_TX_TIMEOUT_MS 20U
#define STATUS_LED_INTERVAL_MS 500U

UART_HandleTypeDef huart1;
UART_HandleTypeDef huart5;

volatile GatewayState gateway_state = GATEWAY_STATE_BOOT;
volatile GatewayStats gateway_stats;

static uint8_t lora_rx_byte;
static uint8_t vehicle_rx_byte;
static uint8_t parser_buffer[AGV_FRAME_MAX_SIZE];
static uint8_t pending_frame[AGV_FRAME_MAX_SIZE];
static volatile uint16_t parser_index;
static volatile uint16_t parser_expected_length;
static volatile uint16_t pending_frame_length;
static volatile uint8_t pending_frame_ready;
static volatile uint32_t parser_last_byte_tick;

static void SystemClock_Config(void);
static void MX_GPIO_Init(void);
static void MX_UART5_Init(void);
static void MX_USART1_UART_Init(void);
static void Agv_ResetParser(void);
static void Agv_ProcessRxByte(uint8_t byte);
static void Agv_CheckParserTimeout(void);
static void Agv_ForwardPendingFrame(void);

int main(void)
{
  uint32_t led_tick;
  GPIO_PinState previous_aux_state;

  HAL_Init();
  SystemClock_Config();
  MX_GPIO_Init();
  MX_UART5_Init();
  MX_USART1_UART_Init();

  memset((void *)&gateway_stats, 0, sizeof(gateway_stats));
  Agv_ResetParser();

  /* Normal communication mode. No control frame is generated at startup. */
  HAL_GPIO_WritePin(LORA_MD0_GPIO_Port, LORA_MD0_Pin, GPIO_PIN_RESET);
  HAL_Delay(50U);

  if (HAL_UART_Receive_IT(&huart5, &lora_rx_byte, 1U) != HAL_OK)
  {
    Error_Handler();
  }
  if (HAL_UART_Receive_IT(&huart1, &vehicle_rx_byte, 1U) != HAL_OK)
  {
    Error_Handler();
  }

  previous_aux_state = HAL_GPIO_ReadPin(LORA_AUX_GPIO_Port, LORA_AUX_Pin);
  led_tick = HAL_GetTick();
  gateway_state = GATEWAY_STATE_RUNNING;

  while (1)
  {
    GPIO_PinState aux_state;

    Agv_CheckParserTimeout();
    Agv_ForwardPendingFrame();

    aux_state = HAL_GPIO_ReadPin(LORA_AUX_GPIO_Port, LORA_AUX_Pin);
    if ((aux_state == GPIO_PIN_SET) &&
        (previous_aux_state == GPIO_PIN_RESET))
    {
      gateway_stats.aux_busy_edges++;
    }
    previous_aux_state = aux_state;

    if ((HAL_GetTick() - led_tick) >= STATUS_LED_INTERVAL_MS)
    {
      led_tick = HAL_GetTick();
      HAL_GPIO_TogglePin(STATUS_LED_GPIO_Port, STATUS_LED_Pin);
    }
  }
}

static void SystemClock_Config(void)
{
  RCC_OscInitTypeDef oscillator = {0};
  RCC_ClkInitTypeDef clocks = {0};

  oscillator.OscillatorType = RCC_OSCILLATORTYPE_HSE;
  oscillator.HSEState = RCC_HSE_ON;
  oscillator.HSEPredivValue = RCC_HSE_PREDIV_DIV1;
  oscillator.HSIState = RCC_HSI_ON;
  oscillator.PLL.PLLState = RCC_PLL_ON;
  oscillator.PLL.PLLSource = RCC_PLLSOURCE_HSE;
  oscillator.PLL.PLLMUL = RCC_PLL_MUL9;
  if (HAL_RCC_OscConfig(&oscillator) != HAL_OK)
  {
    Error_Handler();
  }

  clocks.ClockType = RCC_CLOCKTYPE_HCLK | RCC_CLOCKTYPE_SYSCLK |
                     RCC_CLOCKTYPE_PCLK1 | RCC_CLOCKTYPE_PCLK2;
  clocks.SYSCLKSource = RCC_SYSCLKSOURCE_PLLCLK;
  clocks.AHBCLKDivider = RCC_SYSCLK_DIV1;
  clocks.APB1CLKDivider = RCC_HCLK_DIV2;
  clocks.APB2CLKDivider = RCC_HCLK_DIV1;
  if (HAL_RCC_ClockConfig(&clocks, FLASH_LATENCY_2) != HAL_OK)
  {
    Error_Handler();
  }
}

static void MX_UART5_Init(void)
{
  huart5.Instance = UART5;
  huart5.Init.BaudRate = LORA_DATA_BAUD_RATE;
  huart5.Init.WordLength = UART_WORDLENGTH_8B;
  huart5.Init.StopBits = UART_STOPBITS_1;
  huart5.Init.Parity = UART_PARITY_NONE;
  huart5.Init.Mode = UART_MODE_TX_RX;
  huart5.Init.HwFlowCtl = UART_HWCONTROL_NONE;
  huart5.Init.OverSampling = UART_OVERSAMPLING_16;
  if (HAL_UART_Init(&huart5) != HAL_OK)
  {
    Error_Handler();
  }
}

static void MX_USART1_UART_Init(void)
{
  huart1.Instance = USART1;
  huart1.Init.BaudRate = VEHICLE_UART_BAUD_RATE;
  huart1.Init.WordLength = UART_WORDLENGTH_8B;
  huart1.Init.StopBits = UART_STOPBITS_1;
  huart1.Init.Parity = UART_PARITY_NONE;
  huart1.Init.Mode = UART_MODE_TX_RX;
  huart1.Init.HwFlowCtl = UART_HWCONTROL_NONE;
  huart1.Init.OverSampling = UART_OVERSAMPLING_16;
  if (HAL_UART_Init(&huart1) != HAL_OK)
  {
    Error_Handler();
  }
}

static void MX_GPIO_Init(void)
{
  GPIO_InitTypeDef gpio = {0};

  __HAL_RCC_GPIOA_CLK_ENABLE();
  __HAL_RCC_GPIOC_CLK_ENABLE();

  HAL_GPIO_WritePin(GPIOA, LORA_MD0_Pin, GPIO_PIN_RESET);
  HAL_GPIO_WritePin(GPIOA, STATUS_LED_Pin, GPIO_PIN_SET);

  gpio.Pin = LORA_MD0_Pin;
  gpio.Mode = GPIO_MODE_OUTPUT_PP;
  gpio.Pull = GPIO_NOPULL;
  gpio.Speed = GPIO_SPEED_FREQ_LOW;
  HAL_GPIO_Init(LORA_MD0_GPIO_Port, &gpio);

  gpio.Pin = STATUS_LED_Pin;
  gpio.Mode = GPIO_MODE_OUTPUT_PP;
  gpio.Pull = GPIO_NOPULL;
  gpio.Speed = GPIO_SPEED_FREQ_LOW;
  HAL_GPIO_Init(STATUS_LED_GPIO_Port, &gpio);

  gpio.Pin = LORA_AUX_Pin;
  gpio.Mode = GPIO_MODE_INPUT;
  gpio.Pull = GPIO_PULLDOWN;
  HAL_GPIO_Init(LORA_AUX_GPIO_Port, &gpio);
}

static void Agv_ResetParser(void)
{
  parser_index = 0U;
  parser_expected_length = 0U;
  gateway_stats.parser_index = 0U;
}

static void Agv_ProcessRxByte(uint8_t byte)
{
  parser_last_byte_tick = HAL_GetTick();

  if (parser_index == 0U)
  {
    if (byte != AGV_FRAME_HEADER_0)
    {
      return;
    }
    parser_buffer[parser_index++] = byte;
    gateway_stats.parser_index = parser_index;
    return;
  }

  if (parser_index == 1U)
  {
    if (byte != AGV_FRAME_HEADER_1)
    {
      parser_index = (byte == AGV_FRAME_HEADER_0) ? 1U : 0U;
      parser_buffer[0] = AGV_FRAME_HEADER_0;
      gateway_stats.parser_index = parser_index;
      return;
    }
    parser_buffer[parser_index++] = byte;
    gateway_stats.parser_index = parser_index;
    return;
  }

  if (parser_index >= AGV_FRAME_MAX_SIZE)
  {
    gateway_stats.frames_dropped++;
    Agv_ResetParser();
    return;
  }

  parser_buffer[parser_index++] = byte;
  gateway_stats.parser_index = parser_index;

  if (parser_index == 4U)
  {
    uint16_t payload_length = (uint16_t)parser_buffer[2] |
                              ((uint16_t)parser_buffer[3] << 8U);
    uint16_t total_length = (uint16_t)(payload_length + AGV_FRAME_OVERHEAD);

    if ((payload_length == 0U) || (total_length > AGV_FRAME_MAX_SIZE))
    {
      gateway_stats.frames_dropped++;
      Agv_ResetParser();
      return;
    }
    parser_expected_length = total_length;
  }

  if ((parser_expected_length != 0U) &&
      (parser_index >= parser_expected_length))
  {
    uint16_t tail_index = (uint16_t)(parser_expected_length - 2U);

    if ((parser_buffer[tail_index] == AGV_FRAME_TAIL_0) &&
        (parser_buffer[tail_index + 1U] == AGV_FRAME_TAIL_1))
    {
      if (pending_frame_ready == 0U)
      {
        memcpy(pending_frame, parser_buffer, parser_expected_length);
        pending_frame_length = parser_expected_length;
        pending_frame_ready = 1U;
        gateway_stats.frames_received++;
        gateway_stats.pending = 1U;
        gateway_stats.pending_length = pending_frame_length;
        gateway_stats.last_frame_length = pending_frame_length;
      }
      else
      {
        gateway_stats.frames_dropped++;
      }
    }
    else
    {
      gateway_stats.frames_dropped++;
    }
    Agv_ResetParser();
  }
}

static void Agv_CheckParserTimeout(void)
{
  uint32_t irq_state;

  if ((parser_index == 0U) ||
      ((HAL_GetTick() - parser_last_byte_tick) <
       AGV_RX_INTERBYTE_TIMEOUT_MS))
  {
    return;
  }

  irq_state = __get_PRIMASK();
  __disable_irq();
  if ((parser_index != 0U) &&
      ((HAL_GetTick() - parser_last_byte_tick) >=
       AGV_RX_INTERBYTE_TIMEOUT_MS))
  {
    gateway_stats.frames_dropped++;
    gateway_stats.parser_timeouts++;
    Agv_ResetParser();
  }
  if (irq_state == 0U)
  {
    __enable_irq();
  }
}

static void Agv_ForwardPendingFrame(void)
{
  uint8_t frame_copy[AGV_FRAME_MAX_SIZE];
  uint16_t frame_length;
  uint32_t irq_state;

  if (pending_frame_ready == 0U)
  {
    return;
  }

  irq_state = __get_PRIMASK();
  __disable_irq();
  frame_length = pending_frame_length;
  if ((frame_length > 0U) && (frame_length <= AGV_FRAME_MAX_SIZE))
  {
    memcpy(frame_copy, pending_frame, frame_length);
  }
  pending_frame_ready = 0U;
  pending_frame_length = 0U;
  gateway_stats.pending = 0U;
  gateway_stats.pending_length = 0U;
  if (irq_state == 0U)
  {
    __enable_irq();
  }

  if ((frame_length == 0U) || (frame_length > AGV_FRAME_MAX_SIZE))
  {
    gateway_stats.frames_dropped++;
    return;
  }

  if (HAL_UART_Transmit(&huart1, frame_copy, frame_length,
                        VEHICLE_TX_TIMEOUT_MS) == HAL_OK)
  {
    gateway_stats.frames_forwarded++;
  }
  else
  {
    gateway_stats.forward_errors++;
  }
}

void HAL_UART_RxCpltCallback(UART_HandleTypeDef *huart)
{
  if (huart->Instance == UART5)
  {
    gateway_stats.lora_rx_bytes++;
    Agv_ProcessRxByte(lora_rx_byte);
    if (HAL_UART_Receive_IT(&huart5, &lora_rx_byte, 1U) != HAL_OK)
    {
      gateway_stats.lora_uart_errors++;
    }
  }
  else if (huart->Instance == USART1)
  {
    gateway_stats.vehicle_rx_bytes++;
    gateway_stats.last_vehicle_rx_byte = vehicle_rx_byte;
    if (HAL_UART_Receive_IT(&huart1, &vehicle_rx_byte, 1U) != HAL_OK)
    {
      gateway_stats.vehicle_uart_errors++;
    }
  }
}

void HAL_UART_ErrorCallback(UART_HandleTypeDef *huart)
{
  if (huart->Instance == UART5)
  {
    gateway_stats.lora_uart_errors++;
    __HAL_UART_CLEAR_OREFLAG(&huart5);
    (void)HAL_UART_Receive_IT(&huart5, &lora_rx_byte, 1U);
  }
  else if (huart->Instance == USART1)
  {
    gateway_stats.vehicle_uart_errors++;
    __HAL_UART_CLEAR_OREFLAG(&huart1);
    (void)HAL_UART_Receive_IT(&huart1, &vehicle_rx_byte, 1U);
  }
}

void Error_Handler(void)
{
  gateway_state = GATEWAY_STATE_ERROR;
  __disable_irq();
  while (1)
  {
    HAL_GPIO_TogglePin(STATUS_LED_GPIO_Port, STATUS_LED_Pin);
    for (volatile uint32_t delay = 0U; delay < 300000U; delay++)
    {
      __NOP();
    }
  }
}

#ifdef USE_FULL_ASSERT
void assert_failed(uint8_t *file, uint32_t line)
{
  (void)file;
  (void)line;
  Error_Handler();
}
#endif
