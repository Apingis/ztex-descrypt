#include "pkt_comm.h"

#define PKT_TYPE_CMP_EQUAL	0xd1
#define PKT_TYPE_PROCESSING_DONE 0xd2

// ***************************************************************
//
// output packets (from remote device)
//
// ***************************************************************

struct outpkt_cmp_equal {
	int pkt_id;
	int word_id;
	unsigned long gen_id;
	int hash_num_eq;
};

struct outpkt_done {
	int pkt_id;
	unsigned long num_processed;
};

