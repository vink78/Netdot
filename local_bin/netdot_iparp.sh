#!/bin/bash
/usr/local/bin/stat.pl | /usr/bin/bzip2 -c > /usr/local/netdot/export/ethers/iparp-`/bin/date +%Y-%m-%d`.csv.bz2
/usr/local/bin/netdot2arpcsv.pl  | /usr/bin/bzip2 -c > /tmp/out.csv.bz2 
