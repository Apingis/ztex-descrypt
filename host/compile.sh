gcc ztex.c inouttraffic.c simple_test.c -osimple_test -lusb-1.0
gcc ztex.c inouttraffic.c ztex_scan.c test.c -otest -lusb-1.0
#gcc ztex.c inouttraffic.c ztex_scan.c pkt_comm.c word_gen.c pkt_test.c -opkt_test -lusb-1.0
