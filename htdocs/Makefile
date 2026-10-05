include $(SRCROOT)/etc/utility-Makefile

#
# makefile for htdocs

NDIR =  cable_plant css generic help img img/graphs java_script layouts management contacts operations reports export user_management user_help rest

FILES := `find . -name "*" | egrep ".*(rest\/.*|handler|\.?html|\.ep|\.css|\.png|\.gif|\.js|\.ico)$$" | sed -e 's/\.\///'`

all: wipedir dir
	$(substitute)
	ln -s $(PREFIX)/doc/manual/netdot-manual.htm  $(STAGEDIR)/$(DIR)/help/manual.html

# Wipe out dir before installing
wipedir:
	$(wipedir)

# This section creates the htdocs/ subdirs
dir:
	$(mkdirs)
	# Graphs are updated dynamically, so the app user needs write access.
	chown -R $(APACHEUSER):$(APACHEGROUP) $(STAGEDIR)/$(DIR)/img/graphs
	chmod 0750 $(STAGEDIR)/$(DIR)/img/graphs

