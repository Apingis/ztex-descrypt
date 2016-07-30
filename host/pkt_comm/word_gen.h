
#define PKT_TYPE_WORD_GEN	2

// ***************************************************************
//
// Word Generator
//
// ***************************************************************

#define CHAR_BITS		7 // 7 or 8
#define RANGES_MAX		8
#define WORD_MAX_LEN	RANGES_MAX
#define WORDS_INSERT_MAX 1

#define WORD_GEN_MAX_SIZE ( 7 \
	+ RANGES_MAX * (2+(CHAR_BITS==7 ? 96 : 224)) \
	+ WORDS_INSERT_MAX )


struct word_gen_char_range {
	unsigned char num_chars;		// number of chars in range
	unsigned char start_idx;		// index of char to start iteration
	unsigned char chars[CHAR_BITS==7 ? 96 : 224];
};
// range must have at least 1 char

struct word_gen {
	unsigned char num_ranges;
	struct word_gen_char_range ranges[RANGES_MAX];
	unsigned char num_words;
	unsigned char word_insert_pos[WORDS_INSERT_MAX];
	unsigned long num_generate;
	unsigned char magic;	// 0xBB
};

struct word_gen word_gen_words_pass_by;

struct pkt *pkt_word_gen_new(struct word_gen *word_gen);

