include $(SRCROOT)/etc/utility-Makefile

#
# makefile for etc/


# `default_data` (the seed data applied by initdb) has no extension; list it
# explicitly so it is installed. The installed tree needs it too: `initdb`
# resolves it relative to the installed etc/ (see docker/entrypoint.sh).
FILES = Default.conf default_data netdot_apache.conf netdot.service netdot.meta

all: 
	$(substitute)
	# Install the site's Site.conf (with <<Make:...>> markers substituted)
	# only when a source Site.conf actually exists; a fresh clone has none,
	# and the `sed > tmp` redirect would otherwise install an empty file
	# that makes Netdot::Config fail to load (see docker/entrypoint.sh,
	# which generates one from the environment at first boot).
	if test -r Site.conf; then \
	  if ! test -r $(PREFIX)/$(DIR)/Site.conf; then \
	    $(SED) -r $(REPLACEMENT_EXPRESSIONS) Site.conf \
	            > Site.conf.tmp;\
	            install -m $(FMOD) Site.conf.tmp $(PREFIX)/$(DIR)/Site.conf;\
	            rm -rf Site.conf.tmp;\
	  fi; \
	fi;
