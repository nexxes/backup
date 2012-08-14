#!/bin/bash

export LC_ALL=C

# Disallow unset variables
set -o nounset

if [ ! -w /dev/fd/3 ]; then
	exec 3>&2
fi

# Colorize error messages
if [ -t 2 ]; then
	ERROR_COLOR="\033[0;31m"
	ERROR_RESET="\033[0m"
	ERROR_WHITE="\033[1;30m"
fi

# Colorize warn and info messages
if [ -t 3 ]; then
	WARN_COLOR="\033[1;33m"
	WARN_RESET="\033[0m"
	WARN_WHITE="\033[1;30m"
	
	INFO_COLOR="\033[1;37m"
	INFO_RESET="\033[0m"
	INFO_WHITE="\033[1;30m"
fi


function info() {
	local args=""
	
	[ "$1" == "-e" ] && args+=" -e" && shift
	
	echo -n  "$(date +'%Y-%m-%d %H:%M:%S') "
	echo -en "${INFO_COLOR}INFO${INFO_RESET} "
	echo -en "${INFO_WHITE}${CALLER}${INFO_RESET}: "
	echo $args "$@"
} >&3

function warn() {
	local args=""
	
	[ "$1" == "-e" ] && args+=" -e" && shift
	
	echo -n  "$(date +'%Y-%m-%d %H:%M:%S') "
	echo -en "${WARN_COLOR}WARN${WARN_RESET} "
	echo -en "${WARN_WHITE}${CALLER}${WARN_RESET}: "
	echo $args "$@"
} >&3

function error() {
	local args=""
	
	[ "$1" == "-e" ] && args+=" -e" && shift
	
	echo -n  "$(date +'%Y-%m-%d %H:%M:%S') "
	echo -en "${ERROR_COLOR}ERR ${ERROR_RESET} "
	echo -en "${ERROR_WHITE}${CALLER}${ERROR_RESET}: "
	echo $args "$@"
} >&2

# Check if script is sourced in another bash script
if [ "$0" != "$BASH_SOURCE" ]; then
	CALLER=$(basename "$(basename "${BASH_SOURCE[$(( ${#BASH_SOURCE[*]} - 1 ))]}" .sh)" .pl)
elif [ -n "$1" ]; then
	CALLER=$(basename "$(basename "$1" .sh)" .pl)
	shift
fi
export CALLER

# Host is the first parameter if not supplied as env variable
if [ -z "${HOST:-""}" ]; then
	HOST="$1"
	shift
fi

# make variables available to config file
YEAR="${YEAR:-"$(date +'%Y')"}"
MONTH="${MONTH:-"$(date +'%m')"}"
DAY="${DAY:-"$(date +'%d')"}"
export YEAR MONTH DAY

CONFDIR=${CONFDIR:-"$HOME/.backup"}

# Load base config
[ -r "$CONFDIR"/backup.conf ] &&
	. "$CONFDIR"/backup.conf &&
	info "loaded config file \"$CONFDIR/backup.conf\""

# Load CALLER specific config
[ -n "$CALLER" ] &&
	[ -r "$CONFDIR"/"${CALLER}.conf" ] &&
	. "$CONFDIR"/"${CALLER}.conf" &&
	info "loaded config file \"$CONFDIR/${CALLER}.conf\""

# Load host specific base config
[ -r "$CONFDIR"/"$HOST"/backup.conf ] &&
	. "$CONFDIR"/"$HOST"/backup.conf &&
	info "loaded config file \"$CONFDIR/$HOST/default.conf\""

# Load host and CALLER specific config
[ -n "$CALLER" ] &&
	[ -r "$CONFDIR"/"$HOST"/"${CALLER}.conf" ] &&
	. "$CONFDIR"/"$HOST"/"${CALLER}.conf" &&
	info "loaded config file \"$CONFDIR/$HOST/${CALLER}.conf\""

# Load default config
[ -r "$CONFDIR"/default.conf ] &&
	. "$CONFDIR"/default.conf &&
	info "loaded config file \"$CONFDIR/default.conf\""

# Load default config
[ -r "$CONFDIR"/errors.conf ] &&
	. "$CONFDIR"/errors.conf &&
	info "loaded config file \"$CONFDIR/errors.conf\""

# Verify hostname is set
if [ -z "$HOST" ]; then
	error "no hostname set to backup"
	exit $ERR_HOST
fi

for var in HOST CONFDIR BACKENDS; do
	export "$var"
done


################################################################################
#
# BACKENDS
#
################################################################################

function backup-find-backend() {
	local server error errno backend
	
	# If we found a backend already we do not need to search for it again
	[ -n "${BACKEND:-""}" ] && return
	
	# Verify backends are set for host
	if [ -z "${BACKENDS:-""}" ]; then
		error "No storage backends awailable!"
		exit $ERR_BACKENDS
	fi
	
	# Check on which storage backend the server is currently located
	for server in ${BACKENDS}; do
		if ! error=$(ssh "$server" "test -d \"${REMOTE_DIR}\"" 2>&1); then
			errno=$?
			info "server \"$server\" is no valid storage server, message: \"$(echo "${error}" | tr -d '\r')\""
			
		else
			backend="$server"
			break
		fi
	done
	
	if [ -z "$backend" ]; then
		error "could not find a storage backend that hosts \"$HOST\"!"
		exit $ERR_BACKENDS
	else
		info "found storage server \"$backend\""
		export BACKEND="$backend"
	fi
}


################################################################################
#
# FOLDERS
#
################################################################################

function backup-create-folders() {
	if ! err=$(mkdir --parent "$MIRROR_DIR" 2>&1); then
		error "failed to create mirror dir \"$MIRROR_DIR\": error \"$err\"!"
		exit $ERR_STORAGE
	fi
	
	if ! err=$(mkdir --parent "$LOG_DIR" 2>&1); then
		error "failed to create logdir \"$LOG_DIR\": error \"$err\"!"
		exit $ERR_STORAGE
	fi
	
	if ! err=$(mkdir --parent "$BACKUP_DIR" 2>&1); then
		error "failed to create backupdir \"$BACKUP_DIR\": error \"$err\"!"
		exit $ERR_STORAGE
	fi
	
	if ! err=$(mkdir --parent "$MYSQL_DIR" 2>&1); then
		error "failed to create mysql data dirr \"$MYSQL_DIR\": error \"$err\"!"
		exit $ERR_STORAGE
	fi
	 
	# A lot of symlinks to make navigation more comfortable
	[ ! -L "${LOG_DIR}/data" ] && ln -s "${BACKUP_DIR}" "${LOG_DIR}/data"
	[ ! -L "${LOG_DIR}/mirror" ] && ln -s "${MIRROR_DIR}" "${LOG_DIR}/mirror"
	[ ! -L "${LOG_DIR}/mysql" ] && ln -s "${MYSQL_DIR}" "${LOG_DIR}/mysql"
	
	[ ! -L "${BACKUP_DIR}/logs" ] && ln -s "${LOG_DIR}" "${BACKUP_DIR}/logs"
}


################################################################################
#
# MySQL helper
#
################################################################################

# Translate encoded mysql database files to originating name (=table name)
function backup-mysql-fix-name() {
	local name="$1"
	
	# Ignore names without special chars
	[ "${name/@/}" == "$name" ] && echo $name && return
	
	# Translate basic ascii special chars
	#name="$(echo "$name" | sed 's/@\([0-9a-f]\{2\}\)\([0-9a-f]\{2\}\)/\\x\1\\x\2/g')"
	name="$(echo "$name" | sed 's/@\(00\)\([0-9a-f]\{2\}\)/\\x\1\\x\2/g')"
	
	# FIXME: translate all the other crap from http://dev.mysql.com/doc/refman/5.1/en/identifier-mapping.html
	# See also: http://www.skysql.com/blogs/kolbe/demystifying-identifier-mapping
	[ "${name/@/}" != "$name" ] && warn "database/table name \"$name\" stil contains untranslatable characters"
	
	echo -e "$name"
}

#
# Execute a query by using the background mysql connection
# Use this to execute queries that return nothing and may block until they are finished
#  like "FLUSH TABLES WITH READ LOCK", "LOCK TABLE", etc
# If the query fails, 1 is returned and an error is issued to stdout
#
# @param query String: Query to execute
# @param fd_to Int: Numeric file descriptor to write data to
# @param fd_from Int: Numeric file descriptor to read mysql answer from
#
function backup-mysql-query() {
	local query="$1"
	local fd_to="$2"
	local fd_from="$3"
	local data
	local str="backupMySQLQuerySuccessToken"
	
	echo "$query" >&$fd_to
	echo "SELECT \"$str\";" >&$fd_to
	
	read -u $fd_from data
	while read -u $fd_from -t 0; do
		read -u $fd_from
		data+="$REPLY"
	done
	
	if [ "$data" != "$str" ]; then
		echo "${data/$str/}"
		return 1
	else
		return 0
	fi
}


#
# Verify a file 
# ref_size and ref_md5 can also be a file containing that information
#
# @param file String: File to verify
# @param ref_size Int: Size the file should have
# @param ref_md5 String: MD5 hash to check file against
#
function backup-verify() {
	local file="$1"
	local ref_size="$2"
	local ref_md5="$3"
	
	info "Verifying file \"$file\""
	
	# Check size
	[ -r "$ref_size" ] && ref_size=$(< "$ref_size")
	
	local is_size=$(stat --format="%s" "$file")
	
	if (( ref_size == is_size )); then
		info "  size OK"
	else
		error "  size mismatch: is $is_size, should be $ref_size"
		return 1
	fi
	
	[ -r "$ref_md5" ] && ref_md5=$(< "$ref_md5")
	
	local is_md5=$(md5sum "$file" 2>/dev/null)
	
	if [ "${ref_md5:0:32}" == "${is_md5:0:32}" ]; then
		info "  md5sum OK"
	else
		error "  md5sum mismatch, file seems to be corrupt"
		return 2
	fi
	
	return 0
}

