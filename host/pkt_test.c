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
#include "ztex_scan.h"

#include "pkt_comm/pkt_comm.h"
#include "pkt_comm/word_list.h"
#include "pkt_comm/word_gen.h"

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


struct pkt_comm_params params = { 2, 16384, 32766 };

int device_init_fpgas(struct device *device)
{
	int result;
	int i;
	for (i = 0; i < device->num_of_fpgas; i++) {
		struct fpga *fpga = &device->fpga[i];
		/*
		result = fpga_select(fpga);
		if (result < 0) {
			device_invalidate(device);
			return result;
		}
		*/
		fpga->comm = pkt_comm_new(&params);
		
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
			fprintf(stderr, "SN %s error %d initializing FPGAs.\n",
					device->ztex_device->snString, result);
			device_invalidate(device);
		}
		else
			ok_count ++;
	}
	return ok_count;
}


///////////////////////////////////////////////////////////////////
//
// Hardware Handling
//
// device_list_init() takes list of devices with uploaded firmware
// 1. upload bitstreams
// 2. initialize FPGAs
//
///////////////////////////////////////////////////////////////////

void device_list_init(struct device_list *device_list)
{
	// hardcoded into bitstream (vcr.v/BITSTREAM_TYPE)
	const int BITSTREAM_TYPE = 1;

	int result = device_list_check_bitstreams(device_list, BITSTREAM_TYPE, "../fpga/inouttraffic.bit");
	if (result < 0)
		return;
	if (result > 0) {
		//usleep(3000);
		result = device_list_check_bitstreams(device_list, BITSTREAM_TYPE, NULL);
	}

	device_list_fpga_reset(device_list);
	
	device_list_init_fpgas(device_list);

	device_list_set_app_mode(device_list, 2);
}


///////////////////////////////////////////////////////////////////
//
// Top Level Hardware Initialization Function.
//
// device_timely_scan() takes the list of devices currently in use
//
// 1. Performs ztex_timely_scan()
// 2. Initialize devices
// 3. Returns list of newly found and initialized devices.
//
///////////////////////////////////////////////////////////////////

struct device_list *device_timely_scan(struct device_list *device_list)
{
	struct ztex_dev_list *ztex_dev_list_1 = ztex_dev_list_new();
	ztex_timely_scan(ztex_dev_list_1, device_list->ztex_dev_list);

	struct device_list *device_list_1 = device_list_new(ztex_dev_list_1);
	device_list_init(device_list_1);

	return device_list_1;
}

struct device_list *device_init_scan()
{
	struct ztex_dev_list *ztex_dev_list = ztex_dev_list_new();
	ztex_init_scan(ztex_dev_list);
	
	struct device_list *device_list = device_list_new(ztex_dev_list);
	device_list_init(device_list);
	
	return device_list;
}


/////////////////////////////////////////////////////////////////////////////////////

unsigned long long wr_byte_count = 0, rd_byte_count = 0;

int device_fpgas_pkt_rw(struct device *device)
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

		if (fpga->wr.io_state.pkt_comm_status) {
			fprintf(stderr, "SN %s FPGA #%d error: pkt_comm_status=0x%02x\n",
				device->ztex_device->snString, num, fpga->wr.io_state.pkt_comm_status);
			return -1;
		}

		result = fpga_pkt_write(fpga);
		if (result < 0) {
			fprintf(stderr, "SN %s FPGA #%d write error: %d (%s)\n",
				device->ztex_device->snString, num, result, libusb_strerror(result));
			//fpga->valid = 0;
			return result; // on such a result, device invalidated
		}
		if (result > 0) {
			wr_byte_count += result;
			if ( wr_byte_count/1024/1024 != (wr_byte_count - result)/1024/1024 ) {
				//printf(".");
				//fflush(stdout);
			}
		}

		// read
		result = fpga_pkt_read(fpga);
		if (result < 0) {
			fprintf(stderr, "SN %s FPGA #%d read error: %d (%s)\n",
				device->ztex_device->snString, num, result, libusb_strerror(result));
			//fpga->valid = 0;
			return result; // on such a result, device invalidated
		}
		if (result > 0)
			rd_byte_count += result; //fpga->rd.read_limit;

	} // for( ;num_of_fpgas ;)
	return 1;
}
//////////////////////////////////////////////////////////////////////////////

// Range bbb00000 - bbb99999
// Start from bbb00500, generate 10 (until bbb00509)
struct word_gen word_gen_100k = {
	8,
	{ 
		{ 1, 0, 98 },
		{ 1, 0, 98 },
		{ 1, 0, 98 },
		{ 10, 0, 48, 49, 50, 51, 52, 53, 54, 55, 56, 57 },
		{ 10, 0, 48, 49, 50, 51, 52, 53, 54, 55, 56, 57 },
		{ 10, 5, 48, 49, 50, 51, 52, 53, 54, 55, 56, 57 }, // start from 00500
		{ 10, 0, 48, 49, 50, 51, 52, 53, 54, 55, 56, 57 },
		{ 10, 0, 48, 49, 50, 51, 52, 53, 54, 55, 56, 57 }
	},
	0, {},
	10
};

// Range [0-9]{insert_word}[0-9][0-9] (1000 per word)
struct word_gen word_gen_word1k = {
	3,
	{
		{ 10, 0, 48, 49, 50, 51, 52, 53, 54, 55, 56, 57 },
		{ 10, 0, 48, 49, 50, 51, 52, 53, 54, 55, 56, 57 },
		{ 10, 0, 48, 49, 50, 51, 52, 53, 54, 55, 56, 57 }
	},
	1, 1,	// insert word at position 1
	3		// generate 3 per word
};

// list of 16 words
char *words[] = {
	"aaaaa", "bbb", "cc", "dddddd", "e", "f", "g", "hh",
	"iii", "jjjj", "kkkkk", "llll", "mmm", "nn", "p", "q",
	NULL };

// This configuration generates 1 word
struct word_gen word_gen_test_input_bandwith = {
	8,
	{
		{ 1, 0, 48 }, { 1, 0, 49 }, { 1, 0, 50 }, { 1, 0, 51 },
		{ 1, 0, 52 }, { 1, 0, 53 }, { 1, 0, 54 }, { 1, 0, 55 }
	},
	0
};

//////////////////////////////////////////////////////////////

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
	// 1. Find ZTEX devices, initialize
	//
	///////////////////////////////////////////////////////////////
//ZTEX_DEBUG=1;
//DEBUG = 1;

	struct device_list *device_list = device_init_scan(device_list);
	
	int device_count = device_list_count(device_list);
	fprintf(stderr, "%d device(s) ZTEX 1.15y ready\n", device_count);
	
	if (device_count)
		ztex_dev_list_print(device_list->ztex_dev_list);
	//else
	//	exit(0);
	

	///////////////////////////////////////////////////////////////
	//
	// 2. Perform I/O.
	//
	///////////////////////////////////////////////////////////////

	// Signals aren't checked at time of firmware and bitstream uploads
	signal(SIGHUP, signal_handler);
	signal(SIGINT, signal_handler);
	signal(SIGTERM, signal_handler);
	signal(SIGALRM, signal_handler);


	int pkt_id = 0;
	int pkt_count = 0;

	struct timeval tv0, tv1;
	gettimeofday(&tv0, NULL);

	for ( ; ; ) {
		// timely scan for new devices
		struct device_list *device_list_1 = device_timely_scan(device_list);
		int found_devices = device_list_count(device_list_1);
		if (found_devices) {
			fprintf(stderr, "Found %d device(s) ZTEX 1.15y\n", found_devices);
			ztex_dev_list_print(device_list_1->ztex_dev_list);
		}
		device_list_merge(device_list, device_list_1);


		int device_count = 0;
		struct device *device;
		for (device = device_list->device; device; device = device->next) {
			if (!device_valid(device))
				continue;

			if (signal_received)
				break;

			result = device_fpgas_pkt_rw(device);
			if (result < 0) {
				fprintf(stderr, "SN %s error %d doing r/w of FPGAs (%s)\n",
					device->ztex_device->snString, result, libusb_strerror(result) );
				device_invalidate(device);
				continue;
			}
			device_count ++;


			struct pkt *inpkt;
			// Using FPGA #0 of each device for tests
			while ( (inpkt = pkt_queue_fetch(device->fpga[0].comm->input_queue) ) ) {
				
				printf("%s pkt 0x%02x len %d - id: %d w: %d cand: %d - %.8s\n",
					device->ztex_device->snString,
					inpkt->type,inpkt->data_len,
					inpkt->id,
					inpkt->data[8] + inpkt->data[9] * 256,
					inpkt->data[10] + inpkt->data[11] * 256 + inpkt->data[12] * 65536,
					inpkt->data);
				
				/*
				printf("inpkt type %d len %d: ",inpkt->type,inpkt->data_len);
				int i;
				for (i=0; i < inpkt->data_len; i++)
					printf("%02x ", inpkt->data[i]);
				printf("\n");
				*/
				/*
				if (!(++pkt_count % 256000)) {
					fprintf(stderr,".");
					fflush(stderr);
				}
				*/
				pkt_delete(inpkt);
			}
			//printf("\n");
			//printf("pkt_count: %d\n", get_pkt_count());
		
			struct pkt *outpkt;
			struct pkt *outpkt2;
			int i;
			int sent=0;
			if (sent)
				break;
			
			/*
			for (i=0; i<1; i++) {
				if (pkt_queue_full(device->fpga[0].comm->output_queue, 1))
					break;
				outpkt = pkt_word_gen_new(&word_gen_test_input_bandwith);
				outpkt->id = pkt_id++;
				pkt_queue_push(device->fpga[0].comm->output_queue, outpkt);
			}
			*/
			
			for (i=0; i<1; i++) {
				if (pkt_queue_full(device->fpga[0].comm->output_queue, 1))
					break;
				outpkt = pkt_word_gen_new(&word_gen_100k);
				outpkt->id = pkt_id++;
				pkt_queue_push(device->fpga[0].comm->output_queue, outpkt);
			}
			
			if (pkt_queue_full(device->fpga[0].comm->output_queue, 2))
				break;
			outpkt = pkt_word_gen_new(&word_gen_word1k);
			outpkt->id = pkt_id++;
			pkt_queue_push(device->fpga[0].comm->output_queue, outpkt);
		
			outpkt = pkt_word_list_new(words);
			pkt_queue_push(device->fpga[0].comm->output_queue, outpkt);
			
			//sent=1;

		} // for (device_list)

		if (signal_received) {
			fprintf(stderr, "Signal received.\n");
			break;
		}
	} // for(;;)


	gettimeofday(&tv1, NULL);
	unsigned long usec = (tv1.tv_sec - tv0.tv_sec)*1000000 + tv1.tv_usec - tv0.tv_usec;
	float kbyte_count = (wr_byte_count+rd_byte_count)/1024;
	unsigned long long cmd_count = 0;

	fprintf(stderr,
		"%.2f MB write, %.2f MB read, rate %.2f MB/s\n",
		(float)wr_byte_count/1024/1024,
		(float)rd_byte_count/1024/1024, kbyte_count *1000000/usec /1024
	);
	

	libusb_exit(NULL);
}

