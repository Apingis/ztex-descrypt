#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "pkt_comm.h"
#include "word_gen.h"


struct word_gen word_gen_words_pass_by = {
	0, { },	// ranges
	1, 0	// insert 1 word at position 0
};


struct pkt *pkt_word_gen_new(struct word_gen *word_gen)
{

	char *data = malloc(WORD_GEN_MAX_SIZE);
	if (!data) {
		pkt_error("pkt_word_gen_new(): unable to allocate %d bytes\n",
				WORD_GEN_MAX_SIZE);
		return NULL;
	}

	int offset = 0;

	int i;

	data[offset++] = word_gen->num_ranges;
	for (i = 0; i < word_gen->num_ranges; i++) {
		struct word_gen_char_range *range = &word_gen->ranges[i];
		data[offset++] = range->num_chars;
		data[offset++] = range->start_idx;
		int j;
		for (j = 0; j < range->num_chars; j++)
			data[offset++] = range->chars[j];
	}
	
	data[offset++] = word_gen->num_words;
	for (i = 0; i < word_gen->num_words; i++) {
		data[offset++] = word_gen->word_insert_pos[i];
	}
	
	data[offset++] = word_gen->num_generate;
	data[offset++] = word_gen->num_generate >> 8;
	data[offset++] = word_gen->num_generate >> 16;
	data[offset++] = word_gen->num_generate >> 24;

	data[offset++] = 0xBB;
	
	struct pkt *pkt = pkt_new(PKT_TYPE_WORD_GEN, data, offset);
	//printf("pkt_word_gen_new: data_len %d\n", offset);
	return pkt;
}
