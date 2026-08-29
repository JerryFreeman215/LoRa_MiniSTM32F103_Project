/**
  ******************************************************************************
  * @file    stm32f1xx_it.c
  * @brief   Interrupt service routines
  ******************************************************************************
  */

#include "main.h"
#include "stm32f1xx_it.h"

extern UART_HandleTypeDef huart1;
extern UART_HandleTypeDef huart5;

void NMI_Handler(void)
{
  while (1)
  {
  }
}

void HardFault_Handler(void)
{
  Error_Handler();
}

void MemManage_Handler(void)
{
  Error_Handler();
}

void BusFault_Handler(void)
{
  Error_Handler();
}

void UsageFault_Handler(void)
{
  Error_Handler();
}

void SVC_Handler(void)
{
}

void DebugMon_Handler(void)
{
}

void PendSV_Handler(void)
{
}

void SysTick_Handler(void)
{
  HAL_IncTick();
}

void USART1_IRQHandler(void)
{
  HAL_UART_IRQHandler(&huart1);
}

void UART5_IRQHandler(void)
{
  HAL_UART_IRQHandler(&huart5);
}
