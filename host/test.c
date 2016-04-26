#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>
#include <signal.h>
#include <errno.h>
#include <unistd.h>
#include <libusb-1.0/libusb.h>

#include "ztex.h"
#include "inouttraffic.h"


const int BUF_SIZE_MAX = 32768;


volatile int signal_received = 0;

void signal_handler(int signum)
{
	signal_received = 1;
}

void set_random()
{
	struct timeval tv0;
	gettimeofday(&tv0, NULL);
	srandom(tv0.tv_usec);
}

uint64_t buf_set(unsigned char *buf, int len, uint64_t data)
{
	int i;
	for (i = 0; i < len; i += 8) {
		buf[i] = data & 0xff; buf[i+1] = (data >> 8) & 0xff;
		buf[i+2] = (data >> 16) & 0xff; buf[i+3] = (data >> 24) & 0xff;
		buf[i+4] = (data >> 32) & 0xff; buf[i+5] = (data >> 40) & 0xff;
		buf[i+6] = (data >> 48) & 0xff; buf[i+7] = (data >> 56) & 0xff;
		data++;
	}
	return data;
}

uint64_t buf_check(unsigned char *buf, int len, uint64_t data)
{
	int i;
	//printf("check: %016llx\n", (unsigned long long)data);
	for (i = 0; i < len; i += 8) {
		unsigned long tmp0 = buf[i] | (buf[i+1] << 8) | (buf[i+2] << 16) | (buf[i+3] << 24);
		unsigned long long tmp1 = buf[i+4] | (buf[i+5] << 8) | (buf[i+6] << 16) | (buf[i+7] << 24);
		tmp1 <<= 32;
		tmp1 |= tmp0 & 0xffffffff;
		if (tmp1 != data) {
			fprintf(stderr, "len:%d i:%d Bad data: %016llx, must be: %016llx\n",
				len,i,tmp1, (unsigned long long)data);
			exit(0);
		}
		data++;
	}
	return data;
}

////////////////////////////////////////////////////////////////////////////////////////
//
// Checks if bitstreams on devices are loaded and of specified type.
// if (filename != NULL) performs upload in case of wrong or no bitstream
// Returns: number of devices with bitstreams uploaded
//
// TODO: bitstream_types & files handling
//
int device_list_check_bitstreams(struct device_list *device_list, unsigned short BITSTREAM_TYPE, const char *filename)
{
	int ok_count = 0;
	int uploaded_count = 0;
	int do_upload = filename != NULL;
	FILE *fp = NULL;
	struct device *device;

	for (device = device_list->device; device; device = device->next) {
		if (!device->valid)
			continue;

		int result;
		result = device_check_bitstream_type(device, BITSTREAM_TYPE);
		if (result > 0) {
			ok_count ++;
			continue;
		}
		else if (result < 0) {
			printf("SN %s: device_check_bitstream_type() failed: %d\n",
				device->ztex_device->snString, result);
			device_invalidate(device);
			continue;
		}

		if (!do_upload) {
			printf("SN %s: device_check_bitstream_type(): no bitstream or wrong type\n",
				device->ztex_device->snString);
			device_invalidate(device);
			continue;
		}

		if (!fp)
			if ( !(fp = fopen(filename, "r")) ) {
				printf("fopen(%s): %s\n", filename, strerror(errno));
				return -1;
			}	
		printf("SN %s: uploading bitstreams.. ", device->ztex_device->snString);
		fflush(stdout);

		result = ztex_upload_bitstream(device->ztex_device, fp);
		if (result < 0) {
			printf("failed\n");
			device_invalidate(device);
		}
		else {
			printf("ok\n");
			ok_count ++;
			uploaded_count ++;
		}
	}
	if (fp)
		fclose(fp);
	return ok_count;
}


int device_init_fpgas(struct device *device)
{
	int result;
	result = device_fpga_reset(device);
	if (result < 0) {
		device_invalidate(device);
		return result;
	}

	int i;
	int device_unique_id = 1;
	for (i = 0; i < device->num_of_fpgas; i++) {
		struct fpga *fpga = &device->fpga[i];
		
		//fpga_set_output_limit_min(fpga, (65536-8)/8); 
		result = fpga_set_app_mode(fpga, 1);
		if (result < 0) {
			device_invalidate(device);
			return result;
		}
		
		fpga->wr.buf = malloc(BUF_SIZE_MAX);
		fpga->rd.buf = malloc(BUF_SIZE_MAX);
		fpga->data_in = (unsigned)device_unique_id++ *16 + (unsigned)fpga->num + 1;
		fpga->data_in <<= 56;
		fpga->data_in |= 0xAB100020003000;
		fpga->data_out = fpga->data_in;
	} // for
	return 0;
}

int device_list_init_fpgas(struct device_list *device_list)
{
	int ok_count = 0;
	struct device *device;
	for (device = device_list->device; device; device = device->next) {
		if (!device_valid(device))
			continue;

		int result = device_init_fpgas(device);
		if (result < 0) {
			printf("SN %s error %d initializing FPGAs.\n", device->ztex_device->snString, result);
			device_invalidate(device);
		}
		else
			ok_count ++;
	}
	return ok_count;
}
/////////////////////////////////////////////////////////////////////////////////////

long long wr_byte_count = 0, rd_byte_count = 0;
// FPGA's input buffer size is 16K; input buffer's prog_full asserted at 8K - don't write more than 8K at once
// output buffer 8K minus 1 word (8184 bytes)
//int min_len = 64, max_len = 8192;
int min_len = 8192, max_len = 8192;

int device_fpgas_rw(struct device *device)
{
	int result;
	int num;
	for (num = 0; num < device->num_of_fpgas; num++) {
		struct fpga *fpga = &device->fpga[num];
		//if (!fpga->valid) // currently if r/w error on some FPGA, the entire device invalidated
		//	continue;

		//fpga_select(fpga); // unlike select_fpga() from Ztex SDK, it waits for i/o timeout
		result = fpga_select_setup_io(fpga); // combines fpga_select(), fpga_get_io_state() and fpga_setup_output() in 1 USB request
		if (result < 0) {
			fprintf(stderr, "SN %s FPGA #%d fpga_select_setup_io() error: %d\n",
				device->ztex_device->snString, num, result);
			return result;
		}

		// write
		if (!fpga->wr.wr_count || fpga->wr.wr_done) {
			// FPGA-based application processes in 8-byte words, don't write unaligned
			int len = 8* (random() % (max_len+1 - min_len)/8) + min_len;
			fpga->wr.len = len;
			fpga->data_out = buf_set(fpga->wr.buf, fpga->wr.len, fpga->data_out);
		}
		result = fpga_write(fpga);
		if (result < 0) {
			fprintf(stderr, "SN %s FPGA #%d write error: %d (%s)\n",
				device->ztex_device->snString, num, result, libusb_strerror(result));
			fpga->valid = 0;
			return result;
		}
		if (result > 0) {
			wr_byte_count += fpga->wr.len;
			if ( wr_byte_count/1024/1024 != (wr_byte_count - fpga->wr.len)/1024/1024 ) {
				printf(".");
				fflush(stdout);
			}
		}

		// read
		result = fpga_read(fpga);
		if (result < 0) {
			fprintf(stderr, "SN %s FPGA #%d read error: %d (%s)\n",
				device->ztex_device->snString, num, result, libusb_strerror(result));
			fpga->valid = 0;
			return result;
		}
		if (result > 0) {
			rd_byte_count += fpga->rd.read_limit;
			fpga->data_in = buf_check(fpga->rd.buf, fpga->rd.len, fpga->data_in);
		}

	} // for( ;num_of_fpgas ;)
	return 1;
}

////////////////////////////////////////////////////////////////////////////////////////

int firmware_upload(struct ztex_device *dev, const char *filename)
{
	int result;
	FILE *fp;
	if ( !(fp = fopen(filename, "r")) ) {
		printf("fopen(%s): %s\n", filename, strerror(errno));
		return -1;
	}
	printf("SN %s: uploading firmware.. ", dev->snString);
	fflush(stdout);
	
	struct ihx_data ihx_data;
	result = ihx_load_data(&ihx_data, fp);
	fclose(fp);
	if (result < 0) {
		return -1;
	}
	
	ztex_upload_firmware(dev, &ihx_data);
	printf("done\n");
	return 0;
}

///////////////////////////////////////////////////////////////////
//
// Find Ztex devices (of supported type)
// Upload firmware (device resets) if necessary
// Returns number of newly found devices
//
///////////////////////////////////////////////////////////////////

int ztex_scan(struct ztex_dev_list *new_dev_list, struct ztex_dev_list *dev_list, int *fw_upload_count)
{
	int count = 0;
	(*fw_upload_count) = 0;

	int result = ztex_scan_new_devices(new_dev_list, dev_list);
	if (result < 0) {
		printf("ztex_scan_new_devices(): %s\n", libusb_strerror(result));
		return 0;
	}

	struct ztex_device *dev, *dev_next;
	for (dev = new_dev_list->dev; dev; dev = dev_next) {
		dev_next = dev->next;

		// Check device type
		// only 1.15y devices supported for now
		if (dev->productId[0] == 10 && dev->productId[1] == 15) {
		}
		else {
			if (ZTEX_DEBUG) printf("SN %s: unsupported ZTEX device: %d.%d, skipping\n",
					dev->snString, dev->productId[0], dev->productId[1]);
			ztex_dev_list_remove(new_dev_list, dev);
			continue;
		}

		// Check firmware
		if (!strncmp("inouttraffic", dev->product_string, 12)) {
			count++;
			continue;
		}
		// dummy firmware, do upload
		else if (!strncmp("USB-FPGA Module 1.15y (default)", dev->product_string, 31)) {
			// upload firmware
			firmware_upload(dev, "../inouttraffic.ihx");
			(*fw_upload_count)++;
			ztex_dev_list_remove(new_dev_list, dev);
		}
		// device with some 3rd party firmware - skip it
		else {
			if (ZTEX_DEBUG) printf("SN %s: 3rd party firmware \"%s\", skipping\n",
					dev->snString, dev->product_string);
			ztex_dev_list_remove(new_dev_list, dev);
		}
	}
	return count;
}


///////////////////////////////////////////////////////////////////
//
// ztex_timely_scan()
// Function to be invoked timely to scan for new devices.
// Upload firmware if necessary. After upload device resets.
// Immediately returns number of ready devices.
//
///////////////////////////////////////////////////////////////////

const int ZTEX_SCAN_INTERVAL = 10;
struct timeval ztex_scan_prev_time = { 0, 0 };
// if firmware was uploaded, perform rescan after that many sec
const int ZTEX_FW_UPLOAD_DELAY = 2;
int ztex_scan_fw_upload_count = 0;

int ztex_timely_scan(struct ztex_dev_list *new_dev_list, struct ztex_dev_list *dev_list)
{
	struct timeval tv;
	gettimeofday(&tv, NULL);
	int time_diff = tv.tv_sec - ztex_scan_prev_time.tv_sec
			+ (tv.tv_usec - ztex_scan_prev_time.tv_usec > 0 ? 0 : -1);
	if ( !(ztex_scan_fw_upload_count && time_diff >= ZTEX_FW_UPLOAD_DELAY
			|| time_diff >= ZTEX_SCAN_INTERVAL) )
		return 0;

	int count, fw_upload_count;
	count = ztex_scan(new_dev_list, dev_list, &fw_upload_count);
	if (ztex_scan_fw_upload_count > count) {
		// Not exact; better record SNs of devices for fw upload
		fprintf(stderr, "%d device(s) lost after firmware upload\n",
				ztex_scan_fw_upload_count - count);
	}
	
	ztex_scan_fw_upload_count = fw_upload_count;
	gettimeofday(&ztex_scan_prev_time, NULL);
	return count;
}


///////////////////////////////////////////////////////////////////
//
// ztex_init_scan()
// Function to be invoked at program initialization.
// Waits and rescans if no devices immediately ready and it was firmware upload.
// Returns number of ready devices.
//
///////////////////////////////////////////////////////////////////

int ztex_init_scan(struct ztex_dev_list *new_dev_list)
{
	int count;
	count = ztex_scan(new_dev_list, NULL, &ztex_scan_fw_upload_count);
	// if some devices ready - return immediately
	gettimeofday(&ztex_scan_prev_time, NULL);
	if (count)
		return count;
	if (!ztex_scan_fw_upload_count)
		return 0;
	// no devices ready right now and there're some devices
	// in reset state after firmware upload 
	usleep(ZTEX_FW_UPLOAD_DELAY* 1000*1000);
	
	int fw_upload_count_stage2;
	count = ztex_scan(new_dev_list, NULL, &fw_upload_count_stage2);
	//if (fw_upload_count_stage2) { // device just plugged in. wait for timely_scan
	if (ztex_scan_fw_upload_count > count) {
		// Not exact; better record SNs of devices for fw upload
		fprintf(stderr, "%d device(s) lost after firmware upload\n",
				ztex_scan_fw_upload_count - count);
	}
	
	ztex_scan_fw_upload_count = fw_upload_count_stage2;
	gettimeofday(&ztex_scan_prev_time, NULL);
	return count;
}


///////////////////////////////////////////////////////////////////
//
// device_list_init() takes list of ztex devices with uploaded firmware
// 1. upload bitstreams
// 2. initialize FPGAs
//
///////////////////////////////////////////////////////////////////

int device_list_init(struct device_list *device_list)//, struct ztex_dev_list *ztex_dev_list)
{
	// hardcoded into bitstream (vcr.v/BITSTREAM_TYPE)
	const int BITSTREAM_TYPE = 1;

	int result = device_list_check_bitstreams(device_list, BITSTREAM_TYPE, "../fpga/inouttraffic.bit");
	if (result < 0)
		return -1;
	if (result > 0) {
		//usleep(3000);
		result = device_list_check_bitstreams(device_list, BITSTREAM_TYPE, NULL);
	}

	int dev_count = device_list_init_fpgas(device_list);
	return dev_count;
}


///////////////////////////////////////////////////////////////////
//
// device_timely_scan()
// 1. Performs ztex_timely_scan()
// 2. Initialize devices
// 3. Add new devices to list
//
///////////////////////////////////////////////////////////////////
void device_timely_scan(struct device_list *device_list, struct ztex_dev_list *ztex_dev_list)
{
	int count;
	struct ztex_dev_list *ztex_dev_list_1 = ztex_dev_list_new();
	count = ztex_timely_scan(ztex_dev_list_1, ztex_dev_list);
	if (!count)
		return;
	printf("Found %d device(s) ZTEX 1.15y\n", count);
	ztex_dev_list_print(ztex_dev_list_1);

	struct device_list *device_list_1 = device_list_new(ztex_dev_list_1);
	count = device_list_init(device_list_1);
	printf("%d devices with initialized FPGAs ready.\n", count);

	device_list_merge(device_list, device_list_1);
	ztex_dev_list_merge(ztex_dev_list, ztex_dev_list_1);
}


/////////////////////////////////////////////////////////////////////////////////////

int main(int argc, char **argv)
{
	set_random();

	int result = libusb_init(NULL);
	if (result < 0) {
		printf("libusb_init(): %s\n", libusb_strerror(result));
		exit(EXIT_FAILURE);
	}


	///////////////////////////////////////////////////////////////
	//
	// 1. Find ZTEX devices
	//
	///////////////////////////////////////////////////////////////
//ZTEX_DEBUG=1;

	struct ztex_dev_list *ztex_dev_list = ztex_dev_list_new();

	int count;
	count = ztex_init_scan(ztex_dev_list);
	
	printf("%d device(s) ZTEX 1.15y ready\n", count);
	ztex_dev_list_print(ztex_dev_list);
	//if (!count)
	//	exit(0);

	struct device_list *device_list = device_list_new(ztex_dev_list);
	count = device_list_init(device_list);

	///////////////////////////////////////////////////////////////
	//
	// 2. Perform I/O.
	//
	///////////////////////////////////////////////////////////////
//DEBUG = 1;

	signal(SIGHUP, signal_handler);
	signal(SIGINT, signal_handler);
	signal(SIGTERM, signal_handler);
	signal(SIGALRM, signal_handler);

	printf("Writing to each FPGA of each device and reading back, random length writes (%d-%d)\n",
			min_len, max_len);

	struct timeval tv0, tv1;
	gettimeofday(&tv0, NULL);

	struct timeval tv2, tv3;
	gettimeofday(&tv2, NULL);

	for ( ; ; ) {
		if (signal_received) {
			printf("Signal received.\n");
			break;
		}

		device_timely_scan(device_list, ztex_dev_list);

		int device_count = 0;
		struct device *device;
		for (device = device_list->device; device; device = device->next) {
			if (!device_valid(device))
				continue;

			result = device_fpgas_rw(device);
			if (result < 0) {
				printf("SN %s error %d doing r/w of FPGAs (%s)\n", device->ztex_device->snString,
						result, libusb_strerror(result) );
				device_invalidate(device);
			}
			device_count ++;
		}

		if (!device_count) {
			gettimeofday(&tv3, NULL);
			if (tv3.tv_sec - tv2.tv_sec == 1) {
				printf("x"); fflush(stdout);
			}
			tv2 = tv3;
			usleep(500 *1000);
		}

	} // for(;;)

	gettimeofday(&tv1, NULL);
	unsigned long usec = (tv1.tv_sec - tv0.tv_sec)*1000000 + tv1.tv_usec - tv0.tv_usec;
	float kbyte_count = (wr_byte_count+rd_byte_count)/1024;
	unsigned long long cmd_count = 0;

	printf("%.2f MB write, %.2f MB read, rate %.2f MB/s\n",
		(float)wr_byte_count/1024/1024, (float)rd_byte_count/1024/1024, kbyte_count *1000000/usec /1024);
	

	libusb_exit(NULL);
}

