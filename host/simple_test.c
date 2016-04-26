#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>
#include <signal.h>
#include <libusb-1.0/libusb.h>

#include "ztex.h"
#include "inouttraffic.h"


#define IGNORE_BAD_DATA 0
int test_factor = 8;
int test_num = 0;

const int BUF_SIZE_MAX = 65536;

//============================================================================================

void test_select_fpga(struct ztex_device *dev, int count)
{
	printf("Test #%d. Performing %d K ztex_select_fpga() commands\n", test_num++, count/1024);
	
	int i;
	int result;
	int num = 0;
	struct timeval tv0, tv1;

	gettimeofday(&tv0, NULL);
	for (i = 0; i < count; i++) {

		result = ztex_select_fpga(dev, num);
		if (result < 0) {
			fprintf(stderr,"ztex_select_fpga(%d) returned %d, usb_strerror: %s\n", num, result, libusb_strerror(result));
			break;
		}
		if (++num >= dev->num_of_fpgas)
			num = 0;
		if (!(i%1024)) {
			printf(".");
			fflush(stdout);
		}
	}
	gettimeofday(&tv1, NULL);
	unsigned long usec = (tv1.tv_sec - tv0.tv_sec)*1000000 + tv1.tv_usec - tv0.tv_usec;
	printf("rate: %.1f K cmd/s\n", (float)count*1000000/usec /1024 );
}

//============================================================================================
unsigned long long buf_set(unsigned char *buf, int buf_size, unsigned long long data)
{
	int i;
	for (i = 0; i < buf_size; i+=8, data++) {
		buf[i] = data & 0xff; buf[i+1] = (data >> 8) & 0xff;
		buf[i+2] = (data >> 16) & 0xff; buf[i+3] = (data >> 24) & 0xff;
		buf[i+4] = (data >> 32) & 0xff; buf[i+5] = (data >> 40) & 0xff;
		buf[i+6] = (data >> 48) & 0xff; buf[i+7] = (data >> 56) & 0xff;
		//printf("%08x\n",data);
	}
	return data;
}

void test_hs_inout(struct libusb_device_handle *handle, int buf_size, int pkt_count_max)
{
	int mbytes_total = pkt_count_max/1024*buf_size/1024;
	printf("Test #%d. Sending %d MB via high-speed interface and reading it back (%d-byte r/w)\n",
		test_num++, mbytes_total, buf_size);

	int i;
	int result;
	unsigned long long data_out, data_in, final_data;
	unsigned char buf_out[BUF_SIZE_MAX];
	unsigned char buf_in[BUF_SIZE_MAX];
	int pkt_count = 0;
	int write_ok = 0;
	int read_ok = 0;
	struct timeval tv0, tv1;

	data_in = data_out = 0x4000300020001000;//0x12345678;//0xABC00DEF;
	final_data = data_in + pkt_count_max/8*buf_size;
	gettimeofday(&tv0, NULL);
	
	for ( ; ; ) {
		if (pkt_count < pkt_count_max) {
			if (!pkt_count || write_ok)
				data_out = buf_set(buf_out, buf_size, data_out);

			int transferred = 0;
			result = libusb_bulk_transfer(handle, 0x06, buf_out, buf_size, &transferred, 200);
			if (result < 0) {
				fprintf(stderr, "usb_bulk_write returned %d, usb_strerror: %s\n", result, libusb_strerror(result));
				break;
			}
			else if (transferred != buf_size) {
				fprintf(stderr, "usb_bulk_transfer: write %d of %d\n", transferred, result);
				break;
			}
			else {
				write_ok = 1;
				pkt_count++;
				if ( (uint64_t)(pkt_count*buf_size/1024/1024)
					!=  (uint64_t)( (pkt_count+1)*buf_size/1024/1024) ) {
					printf(".");
					fflush(stdout);
				}
			}
		} // pkt_count < pkt_count_max

		int transferred = 0;
		result = libusb_bulk_transfer(handle, 0x82, buf_in, buf_size, &transferred, 200);
		if (result < 0) {
			fprintf(stderr, "usb_bulk_read returned %d, usb_strerror: %s\n", result, libusb_strerror(result));
			break;
		}
		else if (transferred != buf_size) {
			fprintf(stderr, "partial read: transferred %d of %d\n", transferred, buf_size);
			break;
		}
		else {
			//if (DEBUG) fprintf(stderr,"usb_bulk_read: %d\n", result);
			read_ok = 1;
        		for (i = 0; i < transferred; i+=8, data_in++) {
				unsigned long long tmp = buf_in[i] | (buf_in[i+1] << 8) | (buf_in[i+2] << 16) | (buf_in[i+3] << 24);
				unsigned long long tmp1 = buf_in[i+4] | (buf_in[i+5] << 8) | (buf_in[i+6] << 16) | (buf_in[i+7] << 24);
				tmp |= (tmp1 << 32);
				if (!IGNORE_BAD_DATA && tmp != data_in) {
					read_ok = 0;
					fprintf(stderr, "Received invalid data %016llx, must be %016llx\n", tmp, data_in);
					if (!(DEBUG >= 2)) break;
				} else {
					if (DEBUG >= 2) fprintf(stderr, "%016llx\n",tmp);
				}
			}
			if (!read_ok)
				break;
			//else printf("PACKET RECEIVED OK\n");
			if (pkt_count == pkt_count_max && data_in == final_data) {
				gettimeofday(&tv1, NULL);
				unsigned long usec = (tv1.tv_sec - tv0.tv_sec)*1000000 + tv1.tv_usec - tv0.tv_usec;
				printf("in+out: %.1f MB/s\n", 2* (float)mbytes_total*1000000/usec );
				break;
			}
		}
		
	} // for(;;)
}

//============================================================================================


void main(int argc, char **argv)
{
	int result = libusb_init(NULL);
	if (result < 0) {
		printf("libusb_init(): %s\n", libusb_strerror(result));
		exit(EXIT_FAILURE);
	}

	struct ztex_dev_list *ztex_dev_list = ztex_dev_list_new();
	// find all ZTEX devices of supported type
	ztex_scan_new_devices(ztex_dev_list, NULL);
	printf("Found %d device(s) ZTEX 1.15y\n", ztex_dev_list_count(ztex_dev_list));
	ztex_dev_list_print(ztex_dev_list);
	if (!ztex_dev_list_count(ztex_dev_list))
		exit(0);

	printf("Simple test. Using 1st device, FPGA #0. Only most basic functions used.\n");

	struct ztex_device *dev = ztex_dev_list->dev;
	struct libusb_device_handle *handle = dev->handle;

//DEBUG=1;

	result = ztex_select_fpga(dev, 0);
	if (result < 0) {
		fprintf(stderr, "ztex_select_fpga() returns %d, usb_strerror: %s\n", result, libusb_strerror(result));
		exit(EXIT_FAILURE);
	}

	// Inouttraffic bitstreams have High-Speed interface disabled by default.
	// fpga_reset() enables High-Speed interface, also clears internal buffers.
	result = fpga_reset(handle); 
	if (result < 0) {
		fprintf(stderr, "Soft reset returns %d, usb_strerror: %s\n", result, libusb_strerror(result));
		exit(EXIT_FAILURE);
	}

	// With output limit disabled, FPGA sends data when it has data to send.
	result = fpga_output_limit_enable(handle,0);
	if (result < 0) {
		fprintf(stderr, "fpga_output_limit_enable() returns %d, usb_strerror: %s\n", result, libusb_strerror(result));
		exit(EXIT_FAILURE);
	}
	printf("Output limit disabled.\n");

	result = libusb_claim_interface(handle,0);
	if (result < 0) {
		fprintf(stderr, "libusb_claim_interface(): %d, error: %s\n", result, libusb_strerror(result));
		exit(0);
	}

	// FPGA application operates High-Speed interface with 8-byte words,
	// expects you don't write unaligned
	test_hs_inout(handle, 128, 8*1024*(test_factor > 4 ? 4 : test_factor));

	test_hs_inout(handle, 1024, 4*1024*(test_factor > 16 ? 16 : test_factor));

	test_hs_inout(handle, 8192, 1*1024*test_factor);

	printf("Using max. r/w size: 16K input + (8K -8B) output FPGA buffers + 2* 2K USB device controller's buffers\n");
	// It predictably returns with USB_ETIMEDOUT if 8 more bytes added.
	// Correction: there's extra 8 bytes somewhere,
	// probably in input FIFO because of its "1st Word Fall-Through" option.
	test_hs_inout(handle, 16384+8192/*-8*/+2*2048, 1*1024/2*test_factor);

	test_select_fpga(dev, 4096*(test_factor > 8 ? 8 : test_factor));


	libusb_release_interface(handle,0);
	libusb_exit(NULL);
}

