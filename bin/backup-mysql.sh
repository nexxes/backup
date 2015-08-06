#
# Generate a mysql config file to access a mysql server in a vm from the backend
# The generated config file is printed to stdout
#
# @param HOST String: The vm host to create the config file for
# @param BACKEND String: The backend server the vm host resides on
#
function backup-mysql-config() {
	local HOST="$1"
	local BACKEND="$2"
	
	local ssh="ssh root@$BACKEND"

	# Allow more pattern matching
	shopt -s extglob
	
	local ws=$'\n'$'\r'$'\t'" "

	local dl_file=$(mktemp)
	local conf_dir=$(mktemp -d)
	
	local conf_files=()
	local datadir socket
	
	local REMOTE_DIR=$(backup-conf REMOTE_ROOT_DIR)
	
	if $ssh "test -r \"${REMOTE_DIR}/etc/mysql/server.cnf\""; then
		conf_files[0]="${REMOTE_DIR}/etc/mysql/server.cnf"
	else
		conf_files[0]="${REMOTE_DIR}/etc/mysql/my.cnf"
	fi
	
	conf_files[1]="${REMOTE_DIR}/root/.my.cnf"
	local i=0
	
	while (( i < ${#conf_files[@]} )); do
		local conf_file="${conf_files[$i]}"
		conf_file="${conf_file//\/\///}"
		
		info "parsing file \"${conf_file}\""
		
		$ssh "test -r ${conf_file}" || ( warn "config file is not readable, skipping!" ; continue )
		$ssh "cat ${conf_file}" >"$dl_file"
		
		local section path setting dir f
		
		while read; do
			# Skip lines containing whitespace only
			[ -z "${REPLY//[$ws]/}" ] && continue
			
			# Skip comments
			[ "${REPLY:0:1}" == "#" ] && continue
			
			# Found a section
			if [ "${REPLY/\[*([-a-zA-Z0-9_])]/}" == "" ]; then
				section="${REPLY//[\[\]]/}"
				[ "$section" == "server" ] && section="mysqld"
				[ "$section" == "mysql" ] && section="client"
				info "parsing section \"[$section]\""
				continue
			fi
			
			# Include directory
			if [ "${REPLY:0:11}" == "!includedir" ]; then
				dir="${REPLY:12}"
				
				for f in $($ssh "ls ${REMOTE_DIR}/$dir"); do
					conf_files[${#conf_files[@]}]="${REMOTE_DIR}/$dir/$f"
				done
				
				continue
			fi
			
			# Include single file
			if [ "${REPLY:0:8}" == "!include" ]; then
				conf_files[${#conf_files[@]}]="${REMOTE_DIR}/${REPLY:9}"
				continue
			fi
			
			# Fix pathes
			if [ "${REPLY##?(datadir|socket|pid-file|language|tmpdir|basedir)*([$ws])=*([$ws])/}" != "${REPLY}" ]; then
				path="${REMOTE_DIR}/${REPLY##**([$ws])=*([$ws])}"
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
	
	if [ -z "${datadir:-""}" ]; then
		echo "datadir = ${REMOTE_DIR}/var/lib/mysql" >> "${conf_dir}/mysqld.cnf"
	fi
	
	if [ -z "${socket:-""}" ]; then
		echo "socket = ${REMOTE_DIR}/var/run/mysqld/mysqld.sock" >> "${conf_dir}/client.cnf"
	fi
	
	echo "[mysqld]"
	cat "${conf_dir}/mysqld.cnf"
	echo
	echo "[client]"
	cat "${conf_dir}/client.cnf"
	
	rm -Rf "${conf_dir}" "${dl_file}"
}


function backup-mysql() {
	local HOST="$1"
	local BACKEND="$2"
	
	local ssh="ssh $BACKEND"
	# Disable old multiplexing channel
	$ssh -O exit >/dev/null 2>&1
	# Enable ssh multiplexing
	$ssh -f -M -N
	
	################################################################################
	#
	# Preparation
	#
	################################################################################
	
	local DATA_DIR=$(backup-conf DATA_DIR)
	local MYSQL_DIR=$(backup-conf MYSQL_DIR)
	local REMOTE_DIR=$(backup-conf REMOTE_DIR)
	local STATUS_DIR=$(backup-conf STATUS_DIR)
	local INNODB_FILE=$(backup-conf INNODB_FILE)
	local MYSQL_STATIC_DIR=$(backup-conf MYSQL_STATIC_DIR)
	local COMPRESS_BIN=$(backup-conf COMPRESS_BIN)
	local COMPRESS_PARAMS=$(backup-conf COMPRESS_PARAMS)
	local COMPRESS_EXT=$(backup-conf COMPRESS_EXT)
	
	
	# Local name of mysql config
	local mysql_cnf="${DATA_DIR}/my.cnf"
	
	# Remote name of uploaded mysql config
	remote_mysql_cnf="$($ssh mktemp --suffix=.cnf)"
	
	# Put temporary backup data here
	$ssh mkdir --parent "${REMOTE_DIR}/tmp"
	remote_backup_dir="$($ssh mktemp --directory --tmpdir=\"${REMOTE_DIR}/tmp\")"
	
	# Store recorded size and md5sum of innodb backup here
	local innodb_size_file="${STATUS_DIR}/$(basename "$INNODB_FILE").size"
	local innodb_md5sum_file="${STATUS_DIR}/$(basename "$INNODB_FILE").md5sum"
	
	# Write return value of innodb backup process here
	remote_innodb_error_file="$($ssh mktemp)"
	
	# All fifos for mysql pipelining here
	fifo_dir="$(mktemp --directory)"
	
	# Numbers of the file descriptors to use
	file_reader=7
	mysql_control=8
	mysql_result=9
	
	# Listing of all remote tables here
	tables_list="$(mktemp --tmpdir table-XXXXXXXX.lst)"
	
	function backup-mysql-cleanup() {
		trap - INT TERM EXIT
		
		local HOST="$1"
		local BACKEND="$2"
		
		info "cleaning up"
		
		ssh $BACKEND "rm -Rfv \"$remote_mysql_cnf\" \"$remote_backup_dir\" \"$remote_innodb_error_file\""
		rm -Rfv "$fifo_dir" "$tables_list"
		
		ssh $BACKEND -O exit
		
		eval "exec $file_reader<&-"
		eval "exec $mysql_control>&-"
		eval "exec $mysql_result>&-"
		
		info "finishied cleaning up"
	}
	
	trap "{ backup-mysql-cleanup $HOST $BACKEND; exit 0; }" INT TERM EXIT

	################################################################################
	#
	# Generate and upload mysql config
	#
	################################################################################
	
	info "Generating mysql config"
	backup-mysql-config "$HOST" "$BACKEND" > "$mysql_cnf"
	
	cat >>"$mysql_cnf" <<-ENDL
		
		[xtrabackup]
		#compress = quicklz
		stream = xbstream
		#stream = tar
		tmpdir = $remote_backup_dir
		target-dir = $remote_backup_dir
		extra-lsndir = $remote_backup_dir
		backup
		no-timestamp
	ENDL
	
	if [ -L "${STATUS_DIR}/reference" ] && [ -r "${STATUS_DIR}/reference/mysql/xtrabackup_checkpoints" ]; then
		local ref_lsn=$(grep "to_lsn" "${STATUS_DIR}/reference/mysql/xtrabackup_checkpoints" | sed 's/^to_lsn = //')
		
		echo "incremental-lsn = $ref_lsn" >> "$mysql_cnf"
		info "  using incremental backup from lsn \"$ref_lsn\""
	fi
	
	info "Uploading mysql config"
	cat "$mysql_cnf" | $ssh "cat > \"$remote_mysql_cnf\""
	
	
	################################################################################
	#
	# InnoDB tables
	#
	################################################################################
	
	# Check that innodb is enabled
	if ! grep --quiet '^skip-innodb' "$mysql_cnf"; then
		# FIXME: try to find matching xtrabackup binary
		local xtrabackup_bin
		if ! xtrabackup_bin="$($ssh 'which xtrabackup')" || ! $ssh "test -x '$xtrabackup_bin'"; then
			error "could not find xtrabackup binary or file not executable: (tried \"$xtrabackup_bin\")"
			return $ERR_INNOBACKUP
		fi
		
		info "Starting InnoDB backup"
		$ssh "( ulimit -n 1048576; $xtrabackup_bin --defaults-file=\"$remote_mysql_cnf\" --backup || echo \"\$?\" > \"$remote_innodb_error_file\") | $COMPRESS_BIN $COMPRESS_PARAMS" 2>"${STATUS_DIR}/xtrabackup.log" |
		tee >(md5sum >"$innodb_md5sum_file" 2>/dev/null) >(wc --bytes > "$innodb_size_file") > "$INNODB_FILE"
		
		$ssh "test -s \"$remote_innodb_error_file\"" &&
		error "Failed to create innodb backup, see log for more details" &&
		return $ERR_INNOBACKUP
		
		backup-verify "$INNODB_FILE" "$innodb_size_file" "$innodb_md5sum_file" || return $ERR_INNOBACKUP
		
		$ssh "cat \"${remote_backup_dir}\"/xtrabackup_checkpoints" > "${MYSQL_DIR}/xtrabackup_checkpoints"
	fi
	
	
	################################################################################
	#
	# All table definitions and data except InnoDB data
	#
	################################################################################
	
	mkfifo "$fifo_dir/in.fifo"
	mkfifo "$fifo_dir/out.fifo"
	
	info "Creating mysql control"
	$ssh "mysql --defaults-file=\"$remote_mysql_cnf\" --skip-column-names --unbuffered --force" <"$fifo_dir/in.fifo" >"$fifo_dir/out.fifo" 2>&1 &
	
	eval "exec $mysql_control>\"$fifo_dir/in.fifo\""
	eval "exec $mysql_result<\"$fifo_dir/out.fifo\""
	
	info "Flushing tables"
	! flush_msg=$(backup-mysql-query "FLUSH TABLES;" $mysql_control $mysql_result) &&
		error "failed to flush tables: ($flush_msg)" && return $ERR_MYSQL
	
	# Generate tables listing
	$ssh "cd \"${REMOTE_DIR}/var/lib/mysql\" ; ls */*.frm" | grep -v '^\(information_schema\|performance_schema\|mysql\)/' | sed 's/\.frm$//g' > "$tables_list"
	
	# A little fix as a normal while ... done < "$myisam_tables" did break after the first iteration
	eval "exec $file_reader<\"$tables_list\""
	
	local tables_count=$(cat "$tables_list" | wc -l)
	local counter=0
	
	while read -u $file_reader; do
		(( counter++ ))
		
		local database_dir="${REPLY//\/*/}"
		local table_file="${REPLY//*\//}"
		
		local database="$(backup-mysql-fix-name "$database_dir")"
		local table="$(backup-mysql-fix-name "$table_file")"
		
		info "Working on table $counter of $tables_count: \"$database.$table\""
		
		# Check if table is a view
		echo "SELECT TABLE_TYPE FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA=\"$database\" AND TABLE_NAME=\"$table\";" >&$mysql_control
		read -u $mysql_result table_type
		if [ "$table_type" == "VIEW" ]; then
			info "  table is a view, skipping"
			continue
		fi
		
		# Require global locking for table if table name still contains encoded special characters
		local global_lock
		if [ "${database/@/}" != "${database}" ] || [ "${table/@/}" != "${table}" ]; then
			global_lock="yes"
			warn "  table \"$database.$table\" requires global lock"
		else
			global_lock=
		fi
		
		# Try table lock
		if [ -z "${global_lock:-""}" ]; then
			if ! lock_msg=$(backup-mysql-query "LOCK TABLE \`$database\`.\`$table\` WRITE;" $mysql_control $mysql_result); then
				# Fallback
				warn "failed to lock table \"$database.$table\", using global lock ($lock_msg)"
				global_lock="yes"
			
			else
				! flush_msg=$(backup-mysql-query  "FLUSH TABLE \`$database\`.\`$table\`;" $mysql_control $mysql_result) &&
				error "failed to flush table \"$database.$table\" ($flush_msg)" && return $ERR_MYSQL
			fi
		fi
		
		# Retry with global lock
		if [ -n "$global_lock" ]; then
			! flush_msg=$(backup-mysql-query "FLUSH TABLES WITH READ LOCK;" $mysql_control $mysql_result) &&
			error "failed to flush tables with read lock ($flush_msg)" && return $ERR_MYSQL
		fi
		
		local file
		for file_remote in $($ssh "ls \"${REMOTE_DIR}/var/lib/mysql/${database_dir}/${table_file}\".*"); do
			local filename="$(basename "$file_remote")"
			local file_local="${MYSQL_DIR}/$database_dir/$filename.${COMPRESS_EXT}"
			local file_repo="${MYSQL_STATIC_DIR}/$database_dir/$filename.${COMPRESS_EXT}"
			
			# Skip innodb data files
			if [ "${file_remote%.ibd}" != "${file_remote}" ]; then
				info "  skipping InnoDB data file \"$database_dir/$filename\""
				continue
			fi
			
			local date_remote=$($ssh "stat --format=%y \"$file_remote\"")
			mkdir --parent "$(dirname "$file_local")" "$(dirname "$file_repo")"
		
			# Look into static repository
			if [ -r "$file_repo" ]; then
				local date_repo="$(stat --format=%y "$file_repo")"
				
				# Use file from repo, no downloading
				if [ "$date_remote" == "$date_repo" ]; then
					cp -l "$file_repo" "$file_local"
					info "  using file from repo for \"$database_dir/$filename\""
					continue
				fi
				
				rm -f "$file_repo"
			fi
		
			info "  transfering \"$database_dir/$filename\""
			$ssh "${COMPRESS_BIN} ${COMPRESS_PARAMS} --stdout "$file_remote"" > "$file_local"
			touch --date="$date_remote" "$file_local"
			cp -l "$file_local" "$file_repo"
		done
		
		local unlock_msg
		! unlock_msg=$(backup-mysql-query "UNLOCK TABLES;" $mysql_control $mysql_result) &&
		error "failed to unlock table \"$database.$table\" ($unlock_msg)" && return $ERR_MYSQL
	done
	
	backup-mysql-cleanup $HOST $BACKEND
	
	return 0
}
