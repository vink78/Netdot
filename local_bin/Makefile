#
# makefile for /usr/local/bin/


FILES = git_push.sh netdot2arpcsv.pl netdot2syslog.pl netdot_authenticator.pl netdot_backup.sh netdot_check_auth.pl netdot_cleanup.pl netdot_iparp.sh stat.pl

all:
	for file in $(FILES); do\
	  /bin/sed -r -e "s|<<DB_DBA>>|root|g" -e "s|<<DB_DBA_PASSWORD>>|power|g" -e "s|<<DB_DATABASE>>|netdot|g" \
	  -e "s|<<DB_HOST>>|localhost|g" -e "s|<<NETDOTNAME>>|prdnetdot.unil.ch|g" $$file > $$file.tmp;\
	  cp $$file.tmp /usr/local/bin/$$file;\
	  chmod +x /usr/local/bin/$$file;\
	  rm $$file.tmp;\
	done
