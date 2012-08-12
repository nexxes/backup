#!/bin/bash

. /home/backup/bin/backup-read-config.sh

# Find backend for host
backup-find-backend

ssh="ssh root@$BACKEND"

# Allow more pattern matching
shopt -s extglob

ws=$'\n'$'\r'$'\t'" "

dl_file=$(mktemp)
conf_dir=$(mktemp -d)

conf_files=()

if $ssh "test -r \"${REMOTE_DIR}/image/etc/mysql/server.cnf\""; then
	conf_files[0]="${REMOTE_DIR}/image/etc/mysql/server.cnf"
else
	conf_files[0]="${REMOTE_DIR}/image/etc/mysql/my.cnf"
fi

conf_files[1]="${REMOTE_DIR}/image/root/.my.cnf"
i=0

while (( i < ${#conf_files[@]} )); do
	conf_file="${conf_files[$i]}"
	conf_file="${conf_file//\/\///}"
	
	info "parsing file \"${conf_file}\""
	
	$ssh "test -r ${conf_file}" || ( warn "config file is not readable, skipping!" ; continue )
	$ssh "cat ${conf_file}" >"$dl_file"
	
	while read; do
		# Skip lines containing whitespace only
		[ -z "${REPLY//[$ws]/}" ] && continue
		
		# Skip comments
		[ "${REPLY:0:1}" == "#" ] && continue
		
		# Found a section
		if [ "${REPLY/\[*([-a-zA-Z0-9_])]/}" == "" ]; then
			section="${REPLY//[\[\]]/}"
			[ "$section" == "server" ] && section="mysqld"
			info "parsing section \"[$section]\""
			continue
		fi
		
		# Include single file
		if [ "${REPLY:0:8}" == "!include" ]; then
			conf_files[${#conf_files[@]}]="${REMOTE_DIR}/image/${REPLY:9}"
			continue
		fi
		
		# Include directory
		if [ "${REPLY:0:11}" == "!includedir" ]; then
			dir="${REPLY:12}"
			
			for f in $($ssh "ls $REMOTE_DIR/image/$dir"); do
				conf_files[${#conf_files[@]}]="${REMOTE_DIR}/image/$dir/$f"
			done
			
			continue
		fi
		
		# Fix pathes
		if [ "${REPLY##?(datadir|socket|pid-file|language|tmpdir|basedir)*([$ws])=*([$ws])/}" != "${REPLY}" ]; then
			path="${REMOTE_DIR}/image/${REPLY##**([$ws])=*([$ws])}"
			path="${path//\/\///}"
			setting="${REPLY%%*([$ws])=*}"
			REPLY="$setting = $path"
			
			if [ "$setting" == "datadir" ] && [ "$section" == "mysqld" ]; then
				datadir="$path"
			elif [ "$setting" == "socket" ] && [ "$section" == "client" ]; then
				socket="$path"
			fi
		fi
		
		echo "$REPLY" >> "${conf_dir}/${section}.cnf"
		
	done <"$dl_file"
	
	(( i++ ))
done

if [ -z "$datadir" ]; then
	echo "datadir = ${REMOTE_DIR}/image/var/lib/mysql" >> "${conf_dir}/mysqld.cnf"
fi

if [ -z "$socket" ]; then
	echo "socket = ${REMOTE_DIR}/image/var/run/mysqld/mysqld.sock" >> "${conf_dir}/client.cnf"
fi

echo "[mysqld]"
cat "${conf_dir}/mysqld.cnf"
echo
echo "[client]"
cat "${conf_dir}/client.cnf"

rm -Rf "${conf_dir}" "${dl_file}"
