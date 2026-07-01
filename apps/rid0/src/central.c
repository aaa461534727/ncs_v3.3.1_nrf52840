/* central.c - BLE 扫描 + RID 数据解析（Legacy + Extended Advertising） */

/*
 * Copyright (c) 2020 SixOctets Systems
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#include "common.h"
#include <errno.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>
#include <zephyr/bluetooth/bluetooth.h>
#include <zephyr/bluetooth/conn.h>
#include <zephyr/bluetooth/gatt.h>
#include <zephyr/bluetooth/hci.h>
#include <zephyr/bluetooth/uuid.h>
#include <zephyr/kernel.h>
#include <zephyr/sys/byteorder.h>
#include <zephyr/sys/printk.h>


static int scan_start(void);

static struct bt_conn *default_conn;
static struct bt_uuid_16 discover_uuid = BT_UUID_INIT_16(0);
static struct bt_gatt_discover_params discover_params;
static struct bt_gatt_subscribe_params subscribe_params;

// 定义 RID 结构体
typedef struct rid
{
    uint8_t msg_type;       // 报文类型
    uint8_t base_msg[31];   // 基本ID报文0x0
    uint8_t pos_msg[31];    // 位置向量报文0x1
    uint8_t diy_msg[31];    // 自定义保留报文0x2
    uint8_t run_msg[31];    // 运行描述报文0x3
    uint8_t sys_msg[31];    // 系统报文0x4
    uint8_t ope_msg[31];    // 操作人员报文0x5
    uint8_t mac[6];         // 蓝牙mac地址
} RID;


/* 在 ad 数据中查找 Service Data UUID 0xFFFA 的位置
 * 返回找到的 Service Data 起始索引，-1 表示没找到
 */
static int find_rid_service_data(struct net_buf_simple *ad)
{
    uint8_t *data = ad->data;
    uint8_t len = ad->len;
    uint8_t i = 0;

    while (i < len - 1) {
        uint8_t field_len = data[i];
        uint8_t field_type = data[i + 1];

        if (field_len == 0) {
            break; /* 无效数据 */
        }

        /* Service Data - 16-bit UUID (0x16) */
        if (field_type == 0x16 && i + 3 < len) {
            uint16_t uuid = data[i + 2] | (data[i + 3] << 8);
            if (uuid == 0xFFFA) {
                return i;
            }
        }

        /* Manufacturer Specific Data (0xFF) - 新国标用 0x06 或 0xFFFA 作为公司ID */
        if (field_type == 0xFF && i + 3 < len) {
            uint16_t company_id = data[i + 2] | (data[i + 3] << 8);
            if (company_id == 0x0006 || company_id == 0xFFFA) {
                return i;
            }
        }

        i += field_len + 1;
    }

    return -1;
}


/* 尝试解析旧国标格式 (Legacy Advertising)
 * 头部: 0x1E 0x16 0xFA 0xFF 0x0D ...
 * 特征: ad->data[0] == 0x1E, ad->data[1] == 0x16, ad->data[2] == 0xFA,
 *        ad->data[3] == 0xFF, ad->data[4] == 0x0D
 */
static int try_parse_legacy_rid(struct net_buf_simple *ad, const bt_addr_le_t *addr,
                                RID *rid_info, uint8_t *buf, int8_t rssi, uint8_t type)
{
    char dev[BT_ADDR_LE_STR_LEN];
    bt_addr_le_to_str(addr, dev, sizeof(dev));

    if (ad->len > 5 &&
        ad->data[0] == 0x1E && ad->data[1] == 0x16 &&
        ad->data[2] == 0xFA && ad->data[3] == 0xFF &&
        ad->data[4] == 0x0D)
    {
        // Legacy RID 格式数据
        rid_info->msg_type = ad->data[6] >> 4;
        memcpy(rid_info->mac, addr->a.val, sizeof(addr->a.val));

        if (ad->len > 30) {
            memcpy(rid_info->base_msg, ad->data, 31);
        }

        // 重构 buf: [0xAA, 0xBB, mac(6), rid_data..., 0xCC, 0xDD]
        buf[0] = 0xAA;
        buf[1] = 0xBB;
        memcpy(&buf[2], rid_info->mac, 6);
        memcpy(&buf[8], ad->data, MIN(ad->len, 31));
        buf[8 + MIN(ad->len, 31)] = 0xCC;
        buf[8 + MIN(ad->len, 31) + 1] = 0xDD;

        printk("[RID-Legacy]: %s, type %u, len %u, RSSI %i, data %s\n",
               dev, rid_info->msg_type, ad->len, rssi,
               Util_convertHex2Str(ad->data, ad->len));

        return 1; // 已解析
    }

    return 0; // 不是旧国标格式
}


/* 尝试解析新国标格式 (Extended Advertising)
 * 通过搜索 Service Data UUID 0xFFFA 在任何位置
 */
static int try_parse_extended_rid(struct net_buf_simple *ad, const bt_addr_le_t *addr,
                                   RID *rid_info, uint8_t *buf, int8_t rssi, uint8_t type)
{
    char dev[BT_ADDR_LE_STR_LEN];
    int svc_data_idx;
    uint8_t data_len;
    bt_addr_le_to_str(addr, dev, sizeof(dev));

    svc_data_idx = find_rid_service_data(ad);
    if (svc_data_idx < 0) {
        return 0; // 没找到 RID Service Data
    }

    // 找到 Service Data，从 UUID 后面开始取实际数据
    // 格式: [len][0x16][uuid_lo][uuid_hi][rid_data...]
    // svc_data_idx 指向字段开头，type 在 svc_data_idx+1
    // uuid 在 svc_data_idx+2, svc_data_idx+3
    // 实际数据从 svc_data_idx+4 开始
    uint8_t field_len = ad->data[svc_data_idx];
    uint8_t svc_data_start = svc_data_idx + 4; // +len byte + type byte + 2 bytes UUID
    uint8_t svc_data_len = field_len - 3;      // field_len includes type(1) + UUID(2)

    if (svc_data_len > 30) {
        svc_data_len = 30; // 限制到我们的 buffer
    }

    // 对于 Manufacturer Data (0xFF)，从 company ID 之后开始取数据
    uint8_t svc_data_start_actual = svc_data_start;
    if (ad->data[svc_data_idx + 1] == 0xFF) {
        // Manufacturer Specific Data: [len][0xFF][company_lo][company_hi][data...]
        // company ID 是 2 字节，数据从 idx+4 开始
        svc_data_start_actual = svc_data_start;
    }
    rid_info->msg_type = ad->data[svc_data_start_actual + 1] >> 4;
    memcpy(rid_info->mac, addr->a.val, sizeof(addr->a.val));

    // 重构 buf: [0xAA, 0xBB, mac(6), rid_data..., 0xCC, 0xDD]
    buf[0] = 0xAA;
    buf[1] = 0xBB;
    memcpy(&buf[2], rid_info->mac, 6);
    memcpy(&buf[8], &ad->data[svc_data_start], svc_data_len);
    buf[8 + svc_data_len] = 0xCC;
    buf[8 + svc_data_len + 1] = 0xDD;

    printk("[RID-Ext]: %s, type %u, svc_data_len %u, RSSI %i, raw %s\n",
           dev, rid_info->msg_type, svc_data_len, rssi,
           Util_convertHex2Str(ad->data, ad->len));

    return 1; // 已解析
}


static void device_found(const bt_addr_le_t *addr, int8_t rssi, uint8_t type, struct net_buf_simple *ad)
{
    char dev[BT_ADDR_LE_STR_LEN];
    uint8_t buf[41]; // 存放最终数据
    RID rid_info;
    int i;

    memset(buf, 0, sizeof(buf));
    memset(&rid_info, 0, sizeof(rid_info));

    bt_addr_le_to_str(addr, dev, sizeof(dev));

    // 1. 先试旧国标 (Legacy Advertising)
    if (try_parse_legacy_rid(ad, addr, &rid_info, buf, rssi, type)) {
        // 旧国标解析成功，发送到 UART
        UART_WriteData(0, buf, 41);
        UART_WriteData(1, buf, 41);
        return;
    }

    // 2. 再试新国标 (Extended Advertising / BLE 5.0)
    if (try_parse_extended_rid(ad, addr, &rid_info, buf, rssi, type)) {
        // 新国标解析成功，发送到 UART
        UART_WriteData(0, buf, 41);
        UART_WriteData(1, buf, 41);
        return;
    }

    // 3. Debug: 打印收到的所有广播包（前 5 个，用于分析数据格式）
    {
        static int pkt_count = 0;
        if (pkt_count < 10) {
            printk("[AD-PKT]: %s, RSSI %i, type %u, len %u, data %s\n",
                   dev, rssi, type, ad->len,
                   Util_convertHex2Str(ad->data, ad->len));
            pkt_count++;
            
            // 同时也把解析后的 AD structure 打出来
            uint8_t i = 0;
            while (i < ad->len - 1) {
                uint8_t flen = ad->data[i];
                uint8_t ftype = ad->data[i+1];
                if (flen == 0) break;
                uint8_t data_start = i + 2;
                uint8_t data_len = flen - 1;
                printk("  [AD-STRUCT]: type 0x%02x, len %u\n", ftype, data_len);
                i += flen + 1;
            }
        }
    }
}


static int scan_start(void)
{
    /* Use active scanning, disable duplicate filtering
     * Use extended advertising support for BLE 5.0 devices
     */
    struct bt_le_scan_param scan_param = {
        .type = BT_LE_SCAN_TYPE_ACTIVE,
        .options = BT_LE_SCAN_OPT_NONE,
        .interval = BT_GAP_SCAN_FAST_INTERVAL,
        .window = BT_GAP_SCAN_FAST_WINDOW,
    };

    return bt_le_scan_start(&scan_param, device_found);
}


static void disconnected(struct bt_conn *conn, uint8_t reason)
{
    char addr[BT_ADDR_LE_STR_LEN];
    int err;

    bt_addr_le_to_str(bt_conn_get_dst(conn), addr, sizeof(addr));

    printk("Disconnected: %s, reason 0x%02x %s\n", addr, reason, bt_hci_err_to_str(reason));

    if (default_conn != conn)
    {
        return;
    }

    bt_conn_unref(default_conn);
    default_conn = NULL;

    err = scan_start();
    if (err)
    {
        printk("Scanning failed to start (err %d)\n", err);
    }
}


BT_CONN_CB_DEFINE(conn_callbacks) = {
    .disconnected = disconnected,
};

int central_scan_adv(void)
{
    int err;

    err = bt_enable(NULL);
    if (err)
    {
        printk("Bluetooth init failed (err %d)\n", err);
        return 0;
    }

    printk("Bluetooth initialized\n");

    err = scan_start();

    if (err)
    {
        printk("Scanning failed to start (err %d)\n", err);
        return 0;
    }

    printk("Scanning successfully started\n");
    printk("ota test 5\n");
    /* 强制刷新 RTT buffer */
    printk("SCAN_ACTIVE_MARKER\n");
    return 0;
}

void stop_scan(void)
{
    int err = bt_le_scan_stop();
    if (err)
    {
        //printk("Stop LE scan failed (err %d)\n", err);
    }
    //printk("stop scan success\r\n");
}
