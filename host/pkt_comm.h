
// ***************************************************************
//
// Communication to a remote system
//
// * communication goes in sequential packets
// * API is independent from hardware and link layer
//
// ***************************************************************

#ifndef _PKT_COMM_H_

// *****************************************************************
//
// That's how packet looks when transmitted
// over link layer
//
//	struct pkt {
//		unsigned char version; // version 1
//		unsigned char type;
//		unsigned char checksum; // xor all bytes (except header) and invert
//		unsigned char reserved0;
//		unsigned char data_len0;
//		unsigned char data_len1;
//		unsigned char data_len2; // doesn't count header
//		unsigned char reserved1;
//		unsigned short id;
//		unsigned char data[pkt_data_len];
//	};
//
// *****************************************************************

#define PKT_COMM_VERSION	1

#define PKT_HEADER_LEN	10

// packet can be split when transmitted over link layer
#define PKT_MAX_LEN	(4 * 65536) // 256K

struct pkt {
	unsigned char version;
	unsigned char type; // type must be > 0
	unsigned char checksum;
	int data_len;	// data length
	unsigned short id;
	unsigned char *data;
	int header_ok;
	// partially received packet
	int partial_header_len;
	int partial_data_len;
	// variable usage for output and input
	unsigned char *header;
};

void pkt_error(const char *s, ...);

int get_pkt_count(void);

// Creates new packet. Does not allocate memory for data
struct pkt *pkt_new(int type, char *data, int data_len);

// Deletes packet, also frees pkt->data
void pkt_delete(struct pkt *pkt);


struct pkt *pkt_wordlist_new(char **words);



// *****************************************************************
// 
// packet queue
//
// *****************************************************************

#define PKT_QUEUE_MAX	2000

struct pkt_queue {
	int count;			// number of packets currently in queue
	int empty_slot_idx;	// index of 1st empty slot
	int first_pkt_idx;	// index of first packet
	struct pkt *pkt[PKT_QUEUE_MAX];
};

struct pkt_queue *pkt_queue_new();

// returns false if queue has space for 'num' more packets
int pkt_queue_full(struct pkt_queue *queue, int num);

// returns -1 if queue is full
int pkt_queue_push(struct pkt_queue *queue, struct pkt *pkt);

// returns NULL if queue is empty
struct pkt *pkt_queue_fetch(struct pkt_queue *queue);


// *****************************************************************
//
// struct pkt_comm
//
// Represents a communication to some independently communicating
// device (part of device)
// * Queue for output packets
// * Queue for input packets
//
// *****************************************************************

// Parameters for link layer
struct pkt_comm_params {
	int alignment;
	int output_max_len;	// link layer max. transmit length
	int input_max_len;	// link layer max. receive length
};

struct pkt_comm {
	struct pkt_comm_params *params;
	
	struct pkt_queue *output_queue;
	unsigned char *output_buf;
	int output_buf_size;
	int output_buf_offset;

	struct pkt_queue *input_queue;
	unsigned char *input_buf;
	int input_buf_len;
	int input_buf_offset;
	struct pkt *input_pkt;

	int error;
};

struct pkt_comm *pkt_comm_new(struct pkt_comm_params *params);


// *****************************************************************
//
// Following functions are for I/O over link layer
//
// *****************************************************************

// Get data for output over link layer
// Return NULL if no data for output
unsigned char *pkt_comm_get_output_data(struct pkt_comm *comm, int *len);

// Data previously got by pkt_comm_output_get_data() - transmit completed
// 'len' is length of actually transmitted data
// < 0 on error
void pkt_comm_output_completed(struct pkt_comm *comm, int len, int error);

// Returns true if pkt_comm is ready for input
//int pkt_comm_input_ready(struct pkt_comm *comm);

// Get buffer for link layer input
// Return NULL if input is full
unsigned char *pkt_comm_input_get_buf(struct pkt_comm *comm);

// Data received into buffer taken with pkt_comm_input_get_buf()
// 'len' is length of actually transmitted data
// < 0 on error
int pkt_comm_input_completed(struct pkt_comm *comm, int len, int error);


#define _PKT_COMM_H_
#endif
