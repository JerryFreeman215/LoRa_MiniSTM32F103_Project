/* USER CODE BEGIN Header */
/**
  ******************************************************************************
  * @file           : main.h
  * @brief          : MiniSTM32F103 LoRa gateway declarations
  ******************************************************************************
  */
/* USER CODE END Header */

#ifndef __MAIN_H
#define __MAIN_H

#ifdef __cplusplus
extern "C" {
#endif

#include "stm32f1xx_hal.h"

typedef enum
{
  GATEWAY_STATE_BOOT = 0U,
  GATEWAY_STATE_RUNNING,
  GATEWAY_STATE_ERROR
} GatewayState;

typedef struct
{
  volatile uint32_t lora_rx_bytes;
  volatile uint32_t lora_uart_errors;
  volatile uint32_t frames_received;
  volatile uint32_t frames_forwarded;
  volatile uint32_t frames_dropped;
  volatile uint32_t forward_errors;
  volatile uint32_t parser_timeouts;
  volatile uint32_t vehicle_rx_bytes;
  volatile uint32_t vehicle_uart_errors;
  volatile uint32_t aux_busy_edges;
  volatile uint32_t safety_lock_frames_sent;
  volatile uint32_t safety_lock_errors;
  volatile uint16_t parser_index;
  volatile uint16_t pending_length;
  volatile uint16_t last_frame_length;
  volatile uint8_t pending;
  volatile uint8_t last_vehicle_rx_byte;
  volatile uint8_t safety_watchdog_active;
} GatewayStats;

extern volatile GatewayState gateway_state;
extern volatile GatewayStats gateway_stats;

void Error_Handler(void);

#define LORA_MD0_Pin GPIO_PIN_4
#define LORA_MD0_GPIO_Port GPIOA
#define STATUS_LED_Pin GPIO_PIN_8
#define STATUS_LED_GPIO_Port GPIOA
#define LORA_AUX_Pin GPIO_PIN_4
#define LORA_AUX_GPIO_Port GPIOC

#ifdef __cplusplus
}
#endif

#endif /* __MAIN_H */
