#!/bin/bash
set -e

if [ -z "$NODE_TYPE" ]; then 
	echo >&2 'error: Cluster node type is required'
        echo >&2 '  You need to specify NODE_TYPE with a possible value of sql, management, or data'
        exit 1
fi

# if command starts with an option, save them as CMD arguments
if [ "${1:0:1}" = '-' ]; then
        ARGS="$@"
fi

# If we're setting up a mysqld/SQL API node 
if [ "$NODE_TYPE" = 'sql' ]; then

        echo 'Setting up node as a new MySQL API node...'

        CMD="mysqld"

        # we need to ensure that they have specified and endpoint for an existing management server
        if [ -z "$MANAGEMENT_SERVER" ]; then
                echo >&2 'error: Cluster management server is required'
                echo >&2 '  You need to specify MANAGEMENT_SERVER=<hostname> in order to setup this new data node'
                exit 1
        fi

        # now we need to ensure that we can communicate with the management server 
        # would like to use `ndb_mgm -t 0 -c "$MANAGEMENT_SERVER" -e "49 status"` but you can't disable the retry...
        if ! $(nc -z "$MANAGEMENT_SERVER" 1186 >& /dev/null); then
        	echo >&2 "error: Could not reach the specified Cluster management server at $MANAGEMENT_SERVER"
                echo >&2 '  You need to specify a valid MANAGEMENT_SERVER=<hostname> option in order to setup this new sql node'
                exit 1
        fi

	# Get config
	DATADIR="$("$CMD" --verbose --help --log-bin-index=/tmp/tmp.index 2>/dev/null | awk '$1 == "datadir" { print $2; exit }')"

	if [ ! -d "$DATADIR/mysql" ]; then
		if [ -z "$MYSQL_ROOT_PASSWORD" -a -z "$MYSQL_ALLOW_EMPTY_PASSWORD" -a -z "$MYSQL_RANDOM_ROOT_PASSWORD" ]; then
			echo >&2 'error: database is uninitialized and password option is not specified '
			echo >&2 '  You need to specify one of MYSQL_ROOT_PASSWORD, MYSQL_ALLOW_EMPTY_PASSWORD and MYSQL_RANDOM_ROOT_PASSWORD'
			exit 1
		fi
		# If the password variable is a filename we use the contents of the file
		if [ -f "$MYSQL_ROOT_PASSWORD" ]; then
			MYSQL_ROOT_PASSWORD="$(cat $MYSQL_ROOT_PASSWORD)"
		fi
		mkdir -p "$DATADIR"
		chown -R mysql:mysql "$DATADIR"

		echo -n 'Initializing database... '
		"$CMD" --initialize-insecure=on
		echo 'done'

		"$CMD" --skip-networking &
		pid="$!"

		mysql=( mysql --protocol=socket -uroot )

		for i in {30..0}; do
			if echo 'SELECT 1' | "${mysql[@]}" &> /dev/null; then
				break
			fi
			echo 'MySQL init process in progress...'
			sleep 1
		done
		if [ "$i" = 0 ]; then
			echo >&2 'MySQL init process failed!'
			exit 1
		fi

		mysql_tzinfo_to_sql /usr/share/zoneinfo | "${mysql[@]}" mysql
		
		if [ ! -z "$MYSQL_RANDOM_ROOT_PASSWORD" ]; then
			MYSQL_ROOT_PASSWORD="$(pwmake 128)"
			echo "GENERATED ROOT PASSWORD: $MYSQL_ROOT_PASSWORD"
		fi
		"${mysql[@]}" <<-EOSQL
			-- What's done in this file shouldn't be replicated
			--  or products like mysql-fabric won't work
			SET @@SESSION.SQL_LOG_BIN=0;
			DELETE FROM mysql.user WHERE user NOT IN ('mysql.sys', 'mysqlxsys');
			CREATE USER 'root'@'%' IDENTIFIED BY '${MYSQL_ROOT_PASSWORD}' ;
			GRANT ALL ON *.* TO 'root'@'%' WITH GRANT OPTION ;
			DROP DATABASE IF EXISTS test ;
			FLUSH PRIVILEGES ;
		EOSQL
		if [ ! -z "$MYSQL_ROOT_PASSWORD" ]; then
			mysql+=( -p"${MYSQL_ROOT_PASSWORD}" )
		fi

		if [ "$MYSQL_DATABASE" ]; then
			echo "CREATE DATABASE IF NOT EXISTS \`$MYSQL_DATABASE\` ;" | "${mysql[@]}"
			mysql+=( "$MYSQL_DATABASE" )
		fi

		if [ "$MYSQL_USER" -a "$MYSQL_PASSWORD" ]; then
			echo "CREATE USER '"$MYSQL_USER"'@'%' IDENTIFIED BY '"$MYSQL_PASSWORD"' ;" | "${mysql[@]}"

			if [ "$MYSQL_DATABASE" ]; then
				echo "GRANT ALL ON \`"$MYSQL_DATABASE"\`.* TO '"$MYSQL_USER"'@'%' ;" | "${mysql[@]}"
			fi

			echo 'FLUSH PRIVILEGES ;' | "${mysql[@]}"
		fi
		echo
		for f in /docker-entrypoint-initdb.d/*; do
			case "$f" in
				*.sh)  echo "$0: running $f"; . "$f" ;;
				*.sql) echo "$0: running $f"; "${mysql[@]}" < "$f" && echo ;;
				*)     echo "$0: ignoring $f" ;;
			esac
			echo
		done

		if [ ! -z "$MYSQL_ONETIME_PASSWORD" ]; then
			"${mysql[@]}" <<-EOSQL
				ALTER USER 'root'@'%' PASSWORD EXPIRE;
			EOSQL
		fi
		if ! kill -s TERM "$pid" || ! wait "$pid"; then
			echo >&2 'MySQL init process failed!'
			exit 1
		fi

		echo 'MySQL API node init process complete. Ready for node start up ...'
	fi

	chown -R mysql:mysql "$DATADIR"

        mkdir /var/lib/mysql-files
	chown -R mysql:mysql /var/lib/mysql-files

	CMD="mysqld --ndb_connectstring=$MANAGEMENT_SERVER:1186 $ARGS"


# If we're setting up a management node 
elif [ "$NODE_TYPE" = 'management' ]; then

        # if they're bootstrapping a new cluster, then we just need to start with a fresh Cluster
	if [ ! -z "$BOOTSTRAP" ]; then
		echo 'Bootstrapping new Cluster with a fresh management node ...'

	# otherwise we need to ensure that they have specified endpoint info for an existing ndb_mgmd node 
	elif [ ! -z "$MANAGEMENT_SERVER" ]; then
		echo "Adding new management node and registering it with the existing server: $MANAGEMENT_SERVER ..."

        else
     		echo >&2 'error: Cluster management node is required'
		echo >&2 '  You need to specify MANAGEMENT_SERVER=<hostname> in order to add a new managmeent node, or you must specify BOOTSTRAP in order to create a new Cluster'
      		exit 1

        fi

	mkdir /var/lib/ndb/management

        CMD="ndb_mgmd --config-file=/etc/mysql/cluster-config.ini --config-dir=/etc/mysql --nodaemon=TRUE $ARGS"
   

# If we're setting up a data node 
elif [ "$NODE_TYPE" = 'data' ]; then
	echo 'Setting up node as a new MySQL Cluster data node ...'

	# we need to ensure that they have specified endpoint info for an existing ndb_mgmd node 
	if [ -z "$MANAGEMENT_SERVER" ]; then
     		echo >&2 'error: Cluster management server is required'
		echo >&2 '  You need to specify MANAGEMENT_SERVER=<hostname> in order to setup this new data node'
      		exit 1
	fi

        # we need to then modify the cluster config on the management server(s) and add the basic defintion:
	#[NDBD]
	#NodeId=<node ID>
	#HostName=<IP/hostname>

        # then we'll start an ndbmtd process in this container 
        CMD="ndbmtd --ndb_connectstring=$MANAGEMENT_SERVER:1186 $ARGS"

else 
	echo 'Invalid node type set. Valid node types are sql, management, and data.'
fi


exec $CMD
