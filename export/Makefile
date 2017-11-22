include $(SRCROOT)/etc/utility-Makefile

#
# makefile for export/
#
NDIR = docs nagios sysmon rancid cacti ethers smokeping bind named dhcpd rfc952 unilstat apache git git/zone pb

FILES := `find . -type f |egrep -v '\.svn|Makefile' |sed -e 's/\.\///'`

all: dir
	$(substitute)

	for dir in $(NDIR); do \
	  chown $(APACHEUSER):$(APACHEGROUP) $(STAGEDIR)/$(DIR)/$$dir; \
	  chmod 0755 $(STAGEDIR)/$(DIR)/$$dir; \
	done

# This section creates the export/ subdirs
dir:
	$(mkdirs)
