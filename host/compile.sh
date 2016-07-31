#gcc ztex.c inouttraffic.c pkt_comm/pkt_comm.c simple_test.c -osimple_test -lusb-1.0
#gcc ztex.c inouttraffic.c ztex_scan.c pkt_comm/pkt_comm.c test.c -otest -lusb-1.0
#gcc ztex.c inouttraffic.c ztex_scan.c pkt_comm/*.o pkt_test.c -opkt_test -lusb-1.0
gcc ztex.c inouttraffic.c ztex_scan.c pkt_comm/*.o descrypt_test.c -odescrypt_test -lusb-1.0
