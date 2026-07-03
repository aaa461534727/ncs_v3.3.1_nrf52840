# boards/ — 板级设备树覆盖文件

每块板子需要一个 `.overlay` 文件来配置该板专属的硬件（引脚、外设等）。

命名规则: `<BOARD_NAME>.overlay`，其中 `/` 替换为 `_`

例如: `BOARD=nrf52840dk/nrf52840` → `nrf52840dk_nrf52840.overlay`

---

## 如何切换板子

```bash
# 方式 1: 环境变量
BOARD=nrf52840dk/nrf52840 ./build.sh rid0

# 方式 2: export
export BOARD=nrf5340dk/nrf5340_cpuapp
./build.sh rid0
```

默认: `nrf52840dk/nrf52840`

---

## NCS v3.3.1 支持的 nRF 板子列表

### nRF52 系列 (Cortex-M4, BLE 5.0)

| BOARD 名 | 芯片 | 说明 |
|----------|------|------|
| `nrf52dk/nrf52832` | nRF52832 | nRF52 DK |
| `nrf52dk/nrf52810` | nRF52810 | nRF52 DK (52810) |
| `nrf52dk/nrf52805` | nRF52805 | nRF52 DK (52805) |
| `nrf52840dk/nrf52840` | **nRF52840** | ⭐ nRF52840 DK (当前默认) |
| `nrf52840dk/nrf52811` | nRF52811 | nRF52840 DK (52811) |
| `nrf52840dongle/nrf52840` | nRF52840 | nRF52840 USB Dongle |
| `nrf52833dk/nrf52833` | nRF52833 | nRF52833 DK |
| `nrf52833dk/nrf52820` | nRF52820 | nRF52833 DK (52820) |
| `thingy52/nrf52832` | nRF52832 | Nordic Thingy:52 |
| `nrf21540dk/nrf52840` | nRF52840 | nRF21540 DK (带 FEM) |

### nRF53 系列 (Cortex-M33 双核, BLE 5.x)

| BOARD 名 | 芯片 | 说明 |
|----------|------|------|
| `nrf5340dk/nrf5340_cpuapp` | nRF5340 | nRF5340 DK (应用核) |
| `nrf5340dk/nrf5340_cpuapp_ns` | nRF5340 | nRF5340 DK (应用核, 非安全) |
| `nrf5340dk/nrf5340_cpunet` | nRF5340 | nRF5340 DK (网络核) |
| `nrf5340_audio_dk/nrf5340_cpuapp` | nRF5340 | nRF5340 Audio DK |
| `nrf7002dk/nrf5340_cpuapp` | nRF5340 | nRF7002 DK (WiFi 6) |
| `thingy53/nrf5340_cpuapp` | nRF5340 | Nordic Thingy:53 |

### nRF54L 系列 (Cortex-M33, BLE 6.0 低功耗)

| BOARD 名 | 芯片 | 说明 |
|----------|------|------|
| `nrf54l15dk/nrf54l15_cpuapp` | nRF54L15 | nRF54L15 DK |
| `nrf54l15dk/nrf54l15_cpuapp_ns` | nRF54L15 | nRF54L15 DK (非安全) |
| `nrf54l15dk/nrf54l10_cpuapp` | nRF54L10 | nRF54L15 DK (L10) |
| `nrf54l15tag/nrf54l15_cpuapp` | nRF54L15 | nRF54L15 Tag |

### nRF54H 系列 (Cortex-M33 多核, BLE 6.0 高性能)

| BOARD 名 | 芯片 | 说明 |
|----------|------|------|
| `nrf54h20dk/nrf54h20_cpuapp` | nRF54H20 | nRF54H20 DK (应用核) |
| `nrf54h20dk/nrf54h20_cpurad` | nRF54H20 | nRF54H20 DK (Radio 核) |
| `nrf54h20dk/nrf54h20_cpuflpr` | nRF54H20 | nRF54H20 DK (FLPR 核) |
| `nrf54lm20dk/nrf54lm20a_cpuapp` | nRF54LM20A | nRF54LM20 DK (A 版) |
| `nrf54lm20dk/nrf54lm20b_cpuapp` | nRF54LM20B | nRF54LM20 DK (B 版) |

---

## overlay 文件模板

```dts
/* <板子名> — 自定义外设配置 */

/ {
    chosen {
        zephyr,console = &uart0;     /* 调试串口 */
        zephyr,uart-mcumgr = &uart1; /* DFU 升级串口 */
    };
};

/* 引脚配置 */
&pinctrl {
    uart1_custom: uart1_custom {
        group1 {
            psels = <NRF_PSEL(UART_RX, 1, 4)>;   /* RX 脚 */
            bias-pull-up;
        };
        group2 {
            psels = <NRF_PSEL(UART_TX, 1, 2)>;   /* TX 脚 */
        };
    };
};

/* 开启外设 */
&uart1 {
    status = "okay";
    current-speed = <115200>;
    pinctrl-0 = <&uart1_custom>;
    pinctrl-names = "default";
};
```

`.overlay` 文件名和 `BOARD=` 的值一一对应。如果 BOARD 变了但没对应 overlay，Zephyr 会用板子默认 .dts 配置（可能缺关键外设）。
