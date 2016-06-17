
// Find Ztex USB devices (of supported type)
// Upload firmware (device resets) if necessary
// Returns number of newly found devices (excluding those that were reset)
int ztex_scan(struct ztex_dev_list *new_dev_list, struct ztex_dev_list *dev_list, int *fw_upload_count);

// Scan interval in seconds. Consider following:
// If some board is buggy it might timely upload bitstream then fail.
// bitstream upload takes ~1s and other boards don't perform I/O during that time.
extern int ztex_scan_interval;
#define ZTEX_SCAN_INTERVAL_DEFAULT	15

extern struct timeval ztex_scan_prev_time;

// if firmware was uploaded, perform rescan after that many sec
#define ZTEX_FW_UPLOAD_DELAY	2

// Function to be invoked timely to scan for new devices.
// Skip valid devices from 'dev_list'.
// Upload firmware if necessary. After upload device resets.
// Immediately returns number of ready devices.
int ztex_timely_scan(struct ztex_dev_list *new_dev_list, struct ztex_dev_list *dev_list);

// Function to be invoked at program initialization.
// If no devices immediately ready and it was firmware upload - waits and rescans.
// Returns number of ready devices with uploaded firmware.
int ztex_init_scan(struct ztex_dev_list *new_dev_list);
