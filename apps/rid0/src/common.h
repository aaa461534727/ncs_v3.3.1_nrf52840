#ifndef COMMON_H
#define COMMON_H

#include <stdint.h>
#include <zephyr/device.h>
#include <zephyr/devicetree.h>
#include <zephyr/drivers/uart.h>
#include <zephyr/kernel.h>        // 添加printk所需头文件

/*********************************************************************
 * @fn      Util_convertBdAddr2Str
 *
 * @brief   Convert Bluetooth address to string. Only needed when
 *          LCD display is used.
 *
 * @param   pAddr - BD address
 *
 * @return  BD address as a string
 */
extern char *Util_convertBdAddr2Str(uint8_t *pAddr);

/*********************************************************************
 * @fn      Util_convertHex2Str
 *
 * @brief   将HEX转成String
 *
 * @param   Hex - Hex
 *          len - Hex len
 *
 * @return  Hex as a string
 */
extern char *Util_convertHex2Str(uint8_t *Hex, uint16_t Len);

void start_smp_bluetooth_adverts(void);
int central_scan_adv(void);
void stop_scan(void);

extern const struct device *uart0;
extern const struct device *uart1;
void uart_init(const struct device *dev);  // 声明初始化函数
void UART_WriteData(uint8_t uartNum, uint8_t *pData, uint16_t dataLen);
extern bool scan_active;
void mcumgr_callback_register(void);

#endif // COMMON_H


