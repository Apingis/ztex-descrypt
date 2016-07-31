
#define PKT_TYPE_CMP_CONFIG	3

// ***************************************************************
//
// Comparator Configuration
//
// ***************************************************************

#define CMP_CONFIG_NUM_HASHES_MAX 1023
#define CMP_CONFIG_HASH_LEN	8

#define CMP_CONFIG_MAX_SIZE ( 5 + \
		CMP_CONFIG_NUM_HASHES_MAX * CMP_CONFIG_HASH_LEN	)

struct cmp_hash {
	unsigned char b[CMP_CONFIG_HASH_LEN];
};

struct cmp_config {
	unsigned short salt;	// 12 LSB's used
	unsigned short num_hashes;
	// Excess hashes are not transmitted
	struct cmp_hash cmp_hash[CMP_CONFIG_NUM_HASHES_MAX];
	unsigned char magic;	// 0xCC
};

struct pkt *pkt_cmp_config_new(struct cmp_config *cmp_config);

