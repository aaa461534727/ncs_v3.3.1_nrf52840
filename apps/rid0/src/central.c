/* main.c - Application main entry point */

/*
 * Copyright (c) 2020 SixOctets Systems
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#include "common.h"
#include <errno.h>
#include <stddef.h>
#include <stdio.h>
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

static double pow(double x, double y)
{
    double result = 1;

    if (y < 0)
    {
        y = -y;
        while (y--)
        {
            result /= x;
        }
    }
    else
    {
        while (y--)
        {
            result *= x;
        }
    }

    return result;
}

static uint8_t notify_func(struct bt_conn *conn, struct bt_gatt_subscribe_params *params, const void *data, uint16_t length)
{
    double temperature;
    uint32_t mantissa;
    int8_t exponent;

    if (!data)
    {
        printk("[UNSUBSCRIBED]\n");
        params->value_handle = 0U;
        return BT_GATT_ITER_STOP;
    }

    /* temperature value display */
    mantissa = sys_get_le24(&((uint8_t *)data)[1]);
    exponent = ((uint8_t *)data)[4];
    temperature = (double)mantissa * pow(10, exponent);

    printf("Temperature %gC.\n", temperature);

    return BT_GATT_ITER_CONTINUE;
}

static uint8_t discover_func(struct bt_conn *conn, const struct bt_gatt_attr *attr, struct bt_gatt_discover_params *params)
{
    int err;

    if (!attr)
    {
        printk("Discover complete\n");
        (void)memset(params, 0, sizeof(*params));
        return BT_GATT_ITER_STOP;
    }

    printk("[ATTRIBUTE] handle %u\n", attr->handle);

    if (!bt_uuid_cmp(discover_params.uuid, BT_UUID_HTS))
    {
        memcpy(&discover_uuid, BT_UUID_HTS_MEASUREMENT, sizeof(discover_uuid));
        discover_params.uuid = &discover_uuid.uuid;
        discover_params.start_handle = attr->handle + 1;
        discover_params.type = BT_GATT_DISCOVER_CHARACTERISTIC;

        err = bt_gatt_discover(conn, &discover_params);
        if (err)
        {
            printk("Discover failed (err %d)\n", err);
        }
    }
    else if (!bt_uuid_cmp(discover_params.uuid, BT_UUID_HTS_MEASUREMENT))
    {
        memcpy(&discover_uuid, BT_UUID_GATT_CCC, sizeof(discover_uuid));
        discover_params.uuid = &discover_uuid.uuid;
        discover_params.start_handle = attr->handle + 2;
        discover_params.type = BT_GATT_DISCOVER_DESCRIPTOR;
        subscribe_params.value_handle = bt_gatt_attr_value_handle(attr);

        err = bt_gatt_discover(conn, &discover_params);
        if (err)
        {
            printk("Discover failed (err %d)\n", err);
        }
    }
    else
    {
        subscribe_params.notify = notify_func;
        subscribe_params.value = BT_GATT_CCC_INDICATE;
        subscribe_params.ccc_handle = attr->handle;

        err = bt_gatt_subscribe(conn, &subscribe_params);
        if (err && err != -EALREADY)
        {
            printk("Subscribe failed (err %d)\n", err);
        }
        else
        {
            printk("[SUBSCRIBED]\n");
        }

        return BT_GATT_ITER_STOP;
    }

    return BT_GATT_ITER_STOP;
}

static void connected(struct bt_conn *conn, uint8_t conn_err)
{
    char addr[BT_ADDR_LE_STR_LEN];
    int err;

    bt_addr_le_to_str(bt_conn_get_dst(conn), addr, sizeof(addr));

    if (conn_err)
    {
        printk("Failed to connect to %s (%u)\n", addr, conn_err);

        bt_conn_unref(default_conn);
        default_conn = NULL;

        scan_start();
        return;
    }

    printk("Connected: %s\n", addr);

    if (conn == default_conn)
    {
        memcpy(&discover_uuid, BT_UUID_HTS, sizeof(discover_uuid));
        discover_params.uuid = &discover_uuid.uuid;
        discover_params.func = discover_func;
        discover_params.start_handle = BT_ATT_FIRST_ATTRIBUTE_HANDLE;
        discover_params.end_handle = BT_ATT_LAST_ATTRIBUTE_HANDLE;
        discover_params.type = BT_GATT_DISCOVER_PRIMARY;

        err = bt_gatt_discover(default_conn, &discover_params);
        if (err)
        {
            printk("Discover failed(err %d)\n", err);
            return;
        }
    }
}

static bool eir_found(struct bt_data *data, void *user_data)
{
    bt_addr_le_t *addr = user_data;
    int i;

    printk("[AD]: %u data_len %u\n", data->type, data->data_len);

    switch (data->type)
    {
    case BT_DATA_UUID16_SOME:
    case BT_DATA_UUID16_ALL:
        if (data->data_len % sizeof(uint16_t) != 0U)
        {
            printk("AD malformed\n");
            return true;
        }

        for (i = 0; i < data->data_len; i += sizeof(uint16_t))
        {
            const struct bt_uuid *uuid;
            uint16_t u16;
            int err;

            memcpy(&u16, &data->data[i], sizeof(u16));
            uuid = BT_UUID_DECLARE_16(sys_le16_to_cpu(u16));
            if (bt_uuid_cmp(uuid, BT_UUID_HTS))
            {
                continue;
            }

            err = bt_le_scan_stop();
            if (err)
            {
                printk("Stop LE scan failed (err %d)\n", err);
                continue;
            }

            err = bt_conn_le_create(addr, BT_CONN_LE_CREATE_CONN, BT_LE_CONN_PARAM_DEFAULT, &default_conn);
            if (err)
            {
                printk("Create connection failed (err %d)\n", err);
                scan_start();
            }

            return false;
        }
    }

    return true;
}

// 定义结构体
typedef struct rid
{
    // 数据域
    uint8_t msg_type;       // 报文类型
    uint8_t base_msg[31];   // 基本ID报文0x0
    uint8_t pos_msg[31];    // 位置向量报文0x1
    uint8_t diy_msg[31];    // 自定义保留报文0x2
    uint8_t run_msg[31];    // 运行描述报文0x3
    uint8_t sys_msg[31];    // 系统报文0x4
    uint8_t ope_msg[31];    // 操作人员报文0x5
    uint8_t mac[6];         // 蓝牙mac地址
} RID;

static void device_found(const bt_addr_le_t *addr, int8_t rssi, uint8_t type, struct net_buf_simple *ad)
{
    char dev[BT_ADDR_LE_STR_LEN];
    uint8_t buf[41] = {0xAA, 0xBB};   // 存放最终数据
    RID rid_info;                     // 创建节点结构体准备保存数据添加进链表
	int i=0;
	
    bt_addr_le_to_str(addr, dev, sizeof(dev));
    // printk("[DEVICE]: %s, AD evt type %u, AD data len %u, RSSI %i adv %s \n",
    //        dev, type, ad->len, rssi,Util_convertHex2Str(ad->data,ad->len));

    // RID数据头部比对成功
    if (ad->data[0] == 0x1E && ad->data[1] == 0x16 && ad->data[2] == 0xFA && ad->data[3] == 0xFF && ad->data[4] == 0x0D && ad->len > 5)
    {
        printk("[DEVICE]: %s, AD evt type %u, AD data len %u, RSSI %i adv %s \n", dev, type, ad->len, rssi, Util_convertHex2Str(ad->data, ad->len));
        if (ad->data[6] >> 4 == 0x0)   // 基本ID报文
        {
            // 提取广播数据
            rid_info.msg_type = 0x0;
            // 将解析的数据存到数组转成16进制字节方式发送
            memcpy(rid_info.mac, addr->a.val, sizeof(addr->a.val));
            memcpy(rid_info.base_msg, ad->data, 31);
            for (i = 0; i < sizeof(addr->a.val) + ad->len + 2; i++)
            {
                if (i == 8 || i > 8)
                    buf[i] = rid_info.base_msg[i - 8];
                else
                    buf[i + 2] = rid_info.mac[i];
            }
            buf[8 + ad->len] = 0xCC;
            buf[8 + ad->len + 1] = 0xDD;
			UART_WriteData(0, buf, sizeof(buf));
            UART_WriteData(1, buf, sizeof(buf));
        }
        else if (ad->data[6] >> 4 == 0x1)   // 位置报文
        {
            // 提取广播数据
            rid_info.msg_type = 0x1;
            memcpy(rid_info.mac, addr->a.val, sizeof(addr->a.val));
            memcpy(rid_info.pos_msg, ad->data, 31);
            for (i = 0; i < sizeof(addr->a.val) + ad->len + 2; i++)
            {
                if (i == 8 || i > 8)
                    buf[i] = rid_info.pos_msg[i - 8];
                else
                    buf[i + 2] = rid_info.mac[i];
            }
            buf[8 + ad->len] = 0xCC;
            buf[8 + ad->len + 1] = 0xDD;
            UART_WriteData(0, buf, sizeof(buf));
            UART_WriteData(1, buf, sizeof(buf));
        }
        else if (ad->data[6] >> 4 == 0x2)   // 自定义报文
        {
            // 提取广播数据
            rid_info.msg_type = 0x2;
            memcpy(rid_info.mac, addr->a.val, sizeof(addr->a.val));
            memcpy(rid_info.diy_msg, ad->data, 31);
            for (i = 0; i < sizeof(addr->a.val) + ad->len + 2; i++)
            {
                if (i == 8 || i > 8)
                    buf[i] = rid_info.diy_msg[i - 8];
                else
                    buf[i + 2] = rid_info.mac[i];
            }
            buf[8 + ad->len] = 0xCC;
            buf[8 + ad->len + 1] = 0xDD;
            UART_WriteData(0, buf, sizeof(buf));
            UART_WriteData(1, buf, sizeof(buf));
        }
        else if (ad->data[6] >> 4 == 0x3)   // 运行报文
        {
            // 提取广播数据
            rid_info.msg_type = 0x3;
            memcpy(rid_info.mac, addr->a.val, sizeof(addr->a.val));
            memcpy(rid_info.run_msg, ad->data, 31);
            for (i = 0; i < sizeof(addr->a.val) + ad->len + 2; i++)
            {
                if (i == 8 || i > 8)
                    buf[i] = rid_info.run_msg[i - 8];
                else
                    buf[i + 2] = rid_info.mac[i];
            }
            buf[8 + ad->len] = 0xCC;
            buf[8 + ad->len + 1] = 0xDD;
           UART_WriteData(0, buf, sizeof(buf));
           UART_WriteData(1, buf, sizeof(buf));
        }
        else if (ad->data[6] >> 4 == 0x4)   // 系统报文
        {
            // 提取广播数据
            rid_info.msg_type = 0x4;
            memcpy(rid_info.mac, addr->a.val, sizeof(addr->a.val));
            memcpy(rid_info.sys_msg, ad->data, 31);
            for (i = 0; i < sizeof(addr->a.val) + ad->len + 2; i++)
            {
                if (i == 8 || i > 8)
                    buf[i] = rid_info.sys_msg[i - 8];
                else
                    buf[i + 2] = rid_info.mac[i];
            }
            buf[8 + ad->len] = 0xCC;
            buf[8 + ad->len + 1] = 0xDD;
            UART_WriteData(0, buf, sizeof(buf));
            UART_WriteData(1, buf, sizeof(buf));
        }
        else if (ad->data[6] >> 4 == 0x5)   // 操作人报文
        {
            // 提取广播数据
            rid_info.msg_type = 0x5;
            memcpy(rid_info.mac, addr->a.val, sizeof(addr->a.val));
            memcpy(rid_info.ope_msg, ad->data, 31);

            for (i = 0; i < sizeof(addr->a.val) + ad->len + 2; i++)
            {
                if (i == 8 || i > 8)
                    buf[i] = rid_info.ope_msg[i - 8];
                else
                    buf[i + 2] = rid_info.mac[i];
            }
            buf[8 + ad->len] = 0xCC;
            buf[8 + ad->len + 1] = 0xDD;
            UART_WriteData(0, buf, sizeof(buf));
            UART_WriteData(1, buf, sizeof(buf));
        }
    }

    // /* We're only interested in connectable events */
    // if (type == BT_HCI_ADV_IND || type == BT_HCI_ADV_DIRECT_IND)
    // {
    //     bt_data_parse(ad, eir_found, (void *)addr);
    // }
}

static int scan_start(void)
{
    /* Use active scanning and disable duplicate filtering to handle any
     * devices that might update their advertising data at runtime.
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
    .connected = connected,
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