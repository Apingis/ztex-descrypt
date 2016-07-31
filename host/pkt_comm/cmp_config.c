#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>
#include <errno.h>

#include "pkt_comm.h"
#include "cmp_config.h"


struct pkt *pkt_cmp_config_new(struct cmp_config *cmp_config)
{

	char *data = malloc(CMP_CONFIG_MAX_SIZE);
	if (!data) {
		pkt_error("pkt_cmp_config_new(): unable to allocate %d bytes\n",
				CMP_CONFIG_MAX_SIZE);
		return NULL;
	}

	int offset = 0;

	int i;

	if (cmp_config->salt & 0xf000) {
		pkt_error("pkt_cmp_config_new(): bad salt 0x%04x\n", cmp_config->salt);
		return NULL;
	}
	data[offset++] = cmp_config->salt;
	data[offset++] = cmp_config->salt >> 8;

	if (!cmp_config->num_hashes || cmp_config->num_hashes > CMP_CONFIG_NUM_HASHES_MAX) {
		pkt_error("pkt_cmp_config_new(): bad num_hashes %d\n", cmp_config->num_hashes);
		return NULL;
	}
	data[offset++] = cmp_config->num_hashes;
	data[offset++] = cmp_config->num_hashes >> 8;
	
	for (i = 0; i < cmp_config->num_hashes; i++) {
		int j;
		for (j = 0; j < CMP_CONFIG_HASH_LEN; j++)
			data[offset++] = cmp_config->cmp_hash[i].b[j];
	}
	
	data[offset++] = 0xCC;
	
	struct pkt *pkt = pkt_new(PKT_TYPE_CMP_CONFIG, data, offset);
	//for (i=0; i < offset; i++)
	//	printf("0x%02x ", data[i] & 0xff);
	//printf("\nlen: %d\n", offset);
	return pkt;
}
