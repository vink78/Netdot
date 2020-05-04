#!/bin/bash

/usr/bin/mysql -u <<DB_DBA>> --password=<<DB_DBA_PASSWORD>> -N information_schema -e "select table_name from tables where table_schema='<<DB_DATABASE>>' AND !(table_name like 'fw%') AND !(table_name like 'interface%') AND !(table_name like 'arpcache%') AND !(table_name = 'oui') AND !(table_name = 'hostaudit')  AND !(table_name = 'audit') " > /tmp/tables.txt
/usr/bin/mysqldump --add-drop-table --single-transaction -u <<DB_DBA>> --password=<<DB_DBA_PASSWORD>> <<DB_DATABASE>> `cat /tmp/tables.txt` > /tmp/backup.sql
/usr/bin/bzip2 /tmp/backup.sql
mv /tmp/backup.sql.bz2 /var/lib/backup/`date +%Y%m%d%H%M%S`.sql.bz2
