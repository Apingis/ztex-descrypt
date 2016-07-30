#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "pkt_comm.h"
#include "word_list.h"

struct pkt *pkt_word_list_new(char **words)
{
	int len = 0;
	int i;
	for (i = 0; words[i]; i++) {
		len += strlen(words[i]) + 1;
	}

	char *data = malloc(len);
	if (!data) {
		pkt_error("pkt_wordlist_new(): unable to allocate %d bytes\n", len);
		return NULL;
	}
	
	int offset = 0;
	for (i = 0; words[i]; i++) {
		strcpy(data + offset, words[i]);
		offset += strlen(words[i]) + 1;
	}

	struct pkt *pkt = pkt_new(PKT_TYPE_WORD_LIST, data, len);
	return pkt;
}

