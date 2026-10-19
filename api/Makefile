include $(SRCROOT)/etc/utility-Makefile

#
# makefile for api (the OpenAPI spec; gen_openapi.pl is a dev tool)

FILES := `find . -type f |egrep -v '\.svn|Makefile|gen_openapi' |sed -e 's/\.\///'`

all: dir
	$(substitute)

# This section creates the api/ subdirs
dir:
	$(mkdirs)
