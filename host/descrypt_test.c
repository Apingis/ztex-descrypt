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
#include "pkt_comm/cmp_config.h"

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

		if (fpga->wr.io_state.app_status) {
			fprintf(stderr, "SN %s FPGA #%d error: app_status=0x%02x\n",
				device->ztex_device->snString, num, fpga->wr.io_state.app_status);
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


// *****************************************
//
// *** Sort hashes in ascending order!!! ***
//
// *****************************************

struct cmp_config cmp_55_my = {
	0x01c7, // salt: ASCII "55"
	50, // 50 hashes (25 known)
	{
		{ 0xc0, 0x98, 0x93, 0xd8, 0xa9, 0x37, 0x84, 0x04 }, // myabc101
		{ 0xd4, 0x7a, 0x8c, 0x16, 0xa6, 0x03, 0x56, 0x1f }, // myabc130
		{ 0x1b, 0x7f, 0xa1, 0x21, 0x7f, 0x5e, 0x19, 0x28 }, // myabc120
		{ 0xd8, 0x48, 0xe9, 0xf2, 0xfa, 0x03, 0x45, 0x34 }, // myzzz020
		{ 0xaf, 0x60, 0x0f, 0xcb, 0xdd, 0x29, 0x38, 0x3a }, // myabc100

		{ 0xbb, 0xbb, 0xbb, 0xbb, 0xbb, 0xbb, 0x00, 0x40 },
		{ 0xbb, 0xbb, 0xbb, 0xbb, 0xbb, 0xbb, 0x00, 0x40 },
		{ 0xbb, 0xbb, 0xbb, 0xbb, 0xbb, 0xbb, 0x00, 0x40 },
		{ 0xbb, 0xbb, 0xbb, 0xbb, 0xbb, 0xbb, 0x00, 0x40 },
		{ 0xbb, 0xbb, 0xbb, 0xbb, 0xbb, 0xbb, 0x00, 0x40 },

		{ 0xab, 0x0f, 0xee, 0x77, 0xeb, 0xac, 0xc8, 0x4d }, // myabc877
		{ 0x48, 0xf3, 0xf1, 0xb7, 0x1f, 0xaf, 0xc3, 0x5b }, // myab876
		{ 0xb1, 0x11, 0xb7, 0x67, 0xf9, 0xf2, 0xa8, 0x60 }, // myaaa000
		{ 0x16, 0xa3, 0x74, 0x82, 0xb4, 0x5c, 0x81, 0x63 }, // my**333
		{ 0x36, 0xf1, 0x4e, 0xc7, 0xf4, 0x40, 0xa6, 0x7f }, // myabc876
		
		{ 0xfb, 0x50, 0x9a, 0x9d, 0xb7, 0xd1, 0x5e, 0x80 }, // 2005000
		{ 0xa2, 0xb6, 0x31, 0x18, 0x39, 0xe0, 0xd7, 0x94 }, // 0005000
		{ 0xe9, 0xf2, 0x55, 0x3b, 0x23, 0xcc, 0x84, 0x95 }, // 7440442
		{ 0xe2, 0x3b, 0x58, 0x82, 0x1e, 0xb6, 0x9a, 0x97 }, // 5555999
		{ 0x52, 0xc7, 0x95, 0xfb, 0xed, 0x69, 0x64, 0x9b }, // 2555991
		// 20

		{ 0x3c, 0x27, 0xa6, 0xb4, 0x57, 0xc5, 0xcc, 0xa9 }, // mypwd938		
		{ 0xad, 0x31, 0x87, 0xcc, 0xe3, 0xf4, 0x51, 0xac }, // mypwd123
		{ 0x17, 0x28, 0xf5, 0x9b, 0xe8, 0x6f, 0x23, 0xb4 }, // my***333
		{ 0x39, 0xf4, 0xf5, 0xe3, 0x44, 0x65, 0xc0, 0xd6 }, // my777
		{ 0x1a, 0xa2, 0x64, 0xd4, 0xcc, 0xd8, 0xc7, 0xdf }, // mypwd512

		{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xe0 },
		{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xe0 },
		{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xe0 },
		{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xe0 },
		{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xe0 },

		{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xe0 },
		{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xe0 },
		{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xe0 },
		{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xe0 },
		{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xe0 },
		
		{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xe0 },
		{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xe0 },
		{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xe0 },
		{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xe0 },
		{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xe0 },
		// 40
		
		{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xe0 },
		{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xe0 },
		{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xe0 },
		{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xe0 },
		{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xe0 },
		
		{ 0xcb, 0x68, 0x00, 0x08, 0x8f, 0x7a, 0x7d, 0xe4 }, // mypwd999
		{ 0xac, 0xf3, 0xc7, 0x58, 0x6d, 0x81, 0xf3, 0xe4 }, // myzzz999
		{ 0x2b, 0x94, 0x5f, 0x22, 0x82, 0x54, 0x73, 0xe5 }, // myzzz015
		{ 0xb4, 0x16, 0x07, 0x6a, 0x16, 0xc3, 0x70, 0xfa }, // myzzz019
		{ 0x11, 0x2e, 0x50, 0x58, 0x87, 0xc7, 0x28, 0xfe }, // mypwd000
	}
};

// 26**4 = 456,976
// 456 976 000 candidates
struct word_gen word_gen_m_llllddd = {
	8,
	{
		{ 1, 0, 'm' },
		{ 26, 0, 'a','b','c','d','e','f','g','h','i','j','k','l','m',
				'n','o','p','q','r','s','t','u','v','w','x','y','z' },
		{ 26, 0, 'a','b','c','d','e','f','g','h','i','j','k','l','m',
				'n','o','p','q','r','s','t','u','v','w','x','y','z' },
		{ 26, 0, 'a','b','c','d','e','f','g','h','i','j','k','l','m',
				'n','o','p','q','r','s','t','u','v','w','x','y','z' },
		{ 26, 0, 'a','b','c','d','e','f','g','h','i','j','k','l','m',
				'n','o','p','q','r','s','t','u','v','w','x','y','z' },
		{ 10, 0, 48, 49, 50, 51, 52,  53, 54, 55, 56, 57 },
		{ 10, 0, 48, 49, 50, 51, 52,  53, 54, 55, 56, 57 },
		{ 10, 0, 48, 49, 50, 51, 52,  53, 54, 55, 56, 57 }
	},
	0
	//, {}, 1000
};

// ?w?d?d?d
struct word_gen word_gen_wddd = {
	3,
	{
		{ 10, 0, 48, 49, 50, 51, 52,  53, 54, 55, 56, 57 },
		{ 10, 0, 48, 49, 50, 51, 52,  53, 54, 55, 56, 57 },
		{ 10, 0, 48, 49, 50, 51, 52,  53, 54, 55, 56, 57 }
	},
	1, 0 // insert word at position 0
};

char *words[] = {
	"my", "myaaa", "myab", "myabc",
	"mypwd", "my**", "my***", "myzzz",
	NULL };


// This configuration generates 1 word "01234567"
struct word_gen word_gen_test_input = {
	8,
	{
		{ 1, 0, 48 }, { 1, 0, 49 }, { 1, 0, 50 }, { 1, 0, 51 },
		{ 1, 0, 52 }, { 1, 0, 53 }, { 1, 0, 54 }, { 1, 0, 55 }
	},
	0
};

// 4K total, 2184 x "mypwd123"
struct word_gen word_gen_test_output = {
	8,
	{
		{ 1, 0, 'm' }, { 1, 0, 'y' }, { 1, 0, 'p' }, { 1, 0, 'w' }, { 1, 0, 'd' },
		{ 16, 0, '1','1','1','1','1','1','^','1','1','1','^','1','1','1','1','1' },
		{ 16, 0, '2','2','2','2','2','/','2','\\','2','/','2','\\','2','2','2','2' },
		{ 16, 0, '3','3','3','3','/','3','3','3','V','3','3','3','\\','3','3','3' }
	},
	0
};

struct word_gen word_gen_7d = {
	7,
	{
		{ 10, 0, 48, 49, 50, 51, 52,  53, 54, 55, 56, 57 },
		{ 10, 0, 48, 49, 50, 51, 52,  53, 54, 55, 56, 57 },
		{ 10, 0, 48, 49, 50, 51, 52,  53, 54, 55, 56, 57 },
		{ 10, 0, 48, 49, 50, 51, 52,  53, 54, 55, 56, 57 },
		{ 10, 0, 48, 49, 50, 51, 52,  53, 54, 55, 56, 57 },
		{ 10, 0, 48, 49, 50, 51, 52,  53, 54, 55, 56, 57 },
		{ 10, 0, 48, 49, 50, 51, 52,  53, 54, 55, 56, 57 }
	},
	0
};


//////////////////////////////////////////////////////////////////////////////

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


// Range bbb00000 - bbb99999
// - Start from bbb00500, generate 1000 (until bbb01499)
struct word_gen word_gen_100k = {
	8,
	{ 
		{ 1, 0, 98 },
		{ 1, 0, 98 },
		{ 1, 0, 98 },
		{ 10, 0, 48, 49, 50, 51, 52, 53, 54, 55, 56, 57 },
		{ 10, 0, 48, 49, 50, 51, 52, 53, 54, 55, 56, 57 },
		{ 10, 5, 48, 49, 50, 51, 52, 53, 54, 55, 56, 57 }, 
		{ 10, 0, 48, 49, 50, 51, 52, 53, 54, 55, 56, 57 },
		{ 10, 0, 48, 49, 50, 51, 52, 53, 54, 55, 56, 57 }
	},
	0, {},
	1000
};



	int do_exit = 0;
	int pkt_id = 0;
	int pkt_count = 0;
	int sent = 0;
	int inpkt_210_count = 0;

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
usleep(20);
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
			int inpkt_type;
			// Using FPGA #0 of each device for tests
			while ( (inpkt = pkt_queue_fetch(device->fpga[0].comm->input_queue) ) ) {
				
				printf("inpkt type %d len %d: ",inpkt->type,inpkt->data_len);
				int i;
				for (i=0; i < inpkt->data_len; i++)
					printf("%02x ", inpkt->data[i]);
				printf("\n");
							
				//if (!(++pkt_count % 256000)) {
				//	printf(".");
				//	fflush(stdout);
				//}
				inpkt_type = inpkt->type;
				pkt_delete(inpkt);
				
				if (inpkt_type == 210 && ++inpkt_210_count >= 2) {
					do_exit = 1;
					break;
				}
			}
			//printf("\n");
			//printf("pkt_count: %d\n", get_pkt_count());
			if (do_exit)
				break;
		
			struct pkt *outpkt;
			struct pkt *outpkt2;
			int i;
			if (sent)
				break;
				
			if (!sent) {
				outpkt = pkt_cmp_config_new(&cmp_55_my);
				pkt_queue_push(device->fpga[0].comm->output_queue, outpkt);
				//sent = 1;
			}

			for (i=0; i < 1; i++) {
				outpkt = pkt_word_gen_new(&word_gen_wddd);
				outpkt->id = 0xabcd;//pkt_id++;
				pkt_queue_push(device->fpga[0].comm->output_queue, outpkt);
				
				outpkt = pkt_word_list_new(words);
				pkt_queue_push(device->fpga[0].comm->output_queue, outpkt);
			
				
				outpkt = pkt_word_gen_new(&word_gen_m_llllddd);
				outpkt->id = 0xabcd;//pkt_id++;
				pkt_queue_push(device->fpga[0].comm->output_queue, outpkt);
				
				sent = 1;
			}
			

		} // for (device_list)

		if (do_exit)
			break;
			
		if (signal_received) {
			fprintf(stderr, "Signal received.\n");
			break;
		}
	} // for(;;)



/*
	struct timeval tv2, tv3;
	gettimeofday(&tv2, NULL);

		if (!device_count) {
			gettimeofday(&tv3, NULL);
			if (tv3.tv_sec - tv2.tv_sec == 1) {
				printf("x"); fflush(stdout);
			}
			tv2 = tv3;
			usleep(500 *1000);
		}

	} // for(;;)
*/
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

