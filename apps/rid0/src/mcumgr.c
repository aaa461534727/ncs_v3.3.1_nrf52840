#include <zephyr/mgmt/mcumgr/mgmt/mgmt.h>
#include <zephyr/mgmt/mcumgr/mgmt/callbacks.h>
#include <zephyr/mgmt/mcumgr/grp/img_mgmt/img_mgmt_callbacks.h>
#include <zephyr/bluetooth/bluetooth.h>
#include <zephyr/bluetooth/gap.h>
#include "common.h"

/* 全局扫描控制标志 */
bool scan_active = true;
/* 回调函数实现 */
static enum mgmt_cb_return img_mgmt_callback(uint32_t event, enum mgmt_cb_return prev_status,
	int32_t *rc, uint16_t *group, bool *abort_more, void *data, size_t data_size)
{
    switch (event) {
	case MGMT_EVT_OP_IMG_MGMT_DFU_CHUNK:
	    scan_active = false;
		stop_scan();
        break;

    case MGMT_EVT_OP_IMG_MGMT_DFU_STARTED:
        scan_active = false;

        break;
        
    case MGMT_EVT_OP_IMG_MGMT_DFU_STOPPED:
        scan_active = true;

        break;
        
    default:
        /* 忽略其他事件 */
        break;
    }
    
    return MGMT_ERR_EOK;
}

/* 注册DFU回调 */
static struct mgmt_callback img_mgmt_cb_chunk = {
    .callback = img_mgmt_callback,
    .event_id = MGMT_EVT_OP_IMG_MGMT_DFU_CHUNK
};
static struct mgmt_callback img_mgmt_cb_start = {
    .callback = img_mgmt_callback,
    .event_id = MGMT_EVT_OP_IMG_MGMT_DFU_STARTED
};
static struct mgmt_callback img_mgmt_cb_stop = {
    .callback = img_mgmt_callback,
    .event_id = MGMT_EVT_OP_IMG_MGMT_DFU_STOPPED
};

void mcumgr_callback_register(void)
{
	mgmt_callback_register(&img_mgmt_cb_chunk);
	mgmt_callback_register(&img_mgmt_cb_start);
	mgmt_callback_register(&img_mgmt_cb_stop);
}
