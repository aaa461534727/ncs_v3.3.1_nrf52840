// uart.c
#include "common.h"
// 声明设备指针（全局可见）
const struct device *uart0;
const struct device *uart1;

void uart_init(const struct device *uart_dev) {
    if (uart_dev == NULL) {
        printk("UART device is NULL\n");
        return;
    }
    if (!device_is_ready(uart_dev)) {
        printk("UART device not ready\n");
        return;
    }
    // 可选：动态配置波特率等
}

// 串口发送函数
void UART_WriteData(uint8_t uartNum, uint8_t *pData, uint16_t dataLen)
{
    const struct device *target_uart = NULL;
    
    // 选择目标UART设备
    switch(uartNum) {
        case 0:
            target_uart = uart0;
            break;
        case 1:
            target_uart = uart1;
            break;
        default:
            printk("Invalid UART number: %d\n", uartNum);
            return;
    }
    
    // 检查设备是否就绪
    if (target_uart == NULL || !device_is_ready(target_uart)) {
        printk("UART%d not ready\n", uartNum);
        return;
    }
    
    // 发送数据
    for (uint16_t i = 0; i < dataLen; i++) {
        uart_poll_out(target_uart, pData[i]);
    }
}

// 初始化设备指针（在文件内完成）
static int uart_devices_init(void) {
    
    uart0 = DEVICE_DT_GET(DT_NODELABEL(uart0));
    uart1 = DEVICE_DT_GET(DT_NODELABEL(uart1));
    return 0;
}
SYS_INIT(uart_devices_init, POST_KERNEL, CONFIG_APPLICATION_INIT_PRIORITY);
