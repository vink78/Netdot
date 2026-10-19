include $(SRCROOT)/etc/utility-Makefile

#
# makefile for htdocs

NDIR =  advanced css help img img/graphs java_script layouts management management/device reports search

FILES := `find . -name "*" | egrep ".*(\.ep|\.css|\.png|\.gif|\.js|\.ico)$$" | sed -e 's/\.\///'`

all: wipedir dir
	$(substitute)

# Wipe out dir before installing
wipedir:
	$(wipedir)

# This section creates the htdocs/ subdirs
dir:
	$(mkdirs)
	# Graphs are updated dynamically, so the app user needs write access.
	chown -R $(APACHEUSER):$(APACHEGROUP) $(STAGEDIR)/$(DIR)/img/graphs
	chmod 0750 $(STAGEDIR)/$(DIR)/img/graphs
