#!/bin/bash

export LC_ALL=C

# Disallow unset variables
set -o nounset

# Redirect info messages/warnings to STDERR by default
if [ ! -w /dev/fd/3 ]; then
	exec 3>&2
fi

# Colorize error messages
if [ -t 2 ] || [ "${COLORS:-""}" == "yes" ]; then
	ERROR_COLOR="\033[0;31m"
	ERROR_RESET="\033[0m"
	ERROR_WHITE="\033[1;30m"
else
	ERROR_COLOR=""
	ERROR_RESET=""
	ERROR_WHITE=""
fi

# Colorize warn and info messages
if [ -t 3 ] || [ "${COLORS:-""}" == "yes" ]; then
	WARN_COLOR="\033[1;33m"
	WARN_RESET="\033[0m"
	WARN_WHITE="\033[1;30m"
	
	INFO_COLOR="\033[1;37m"
	INFO_RESET="\033[0m"
	INFO_WHITE="\033[1;30m"
else
	WARN_COLOR=""
	WARN_RESET=""
	WARN_WHITE=""
	
	INFO_COLOR=""
	INFO_RESET=""
	INFO_WHITE=""
fi

function ssh() {
#	info "SSH: $@"
	$(which ssh) -F ~/.ssh/config-backup "$@"
	return $?
}

function info() {
	local args=""
	local CALLER="${FUNCNAME[1]} (${BASH_SOURCE[1]}:${BASH_LINENO[0]})"
	[ "${FUNCNAME[1]}" == "main" ] && CALLER="$(readlink --canonicalize "$0"):${BASH_LINENO[0]}"
	
	[ "$1" == "-e" ] && args+=" -e" && shift
	
	echo -n  "$(date +'%Y-%m-%d %H:%M:%S') "
	echo -en "${INFO_COLOR}INFO${INFO_RESET} "
	echo -en "${INFO_WHITE}${CALLER}${INFO_RESET}: "
	echo $args "$@"
} >&3

function warn() {
	local args=""
	local CALLER="${FUNCNAME[1]} (${BASH_SOURCE[1]}:${BASH_LINENO[0]})"
	[ "${FUNCNAME[1]}" == "main" ] && CALLER="$(readlink --canonicalize "$0"):${BASH_LINENO[0]}"
	
	[ "$1" == "-e" ] && args+=" -e" && shift
	
	echo -n  "$(date +'%Y-%m-%d %H:%M:%S') "
	echo -en "${WARN_COLOR}WARN${WARN_RESET} "
	echo -en "${WARN_WHITE}${CALLER}${WARN_RESET}: "
	echo $args "$@"
} >&3

function error() {
	local args=""
	local CALLER="${FUNCNAME[1]} (${BASH_SOURCE[1]}:${BASH_LINENO[0]})"
	[ "${FUNCNAME[1]}" == "main" ] && CALLER="$(readlink --canonicalize "$0"):${BASH_LINENO[0]}"
	
	[ "$1" == "-e" ] && args+=" -e" && shift
	
	echo -n  "$(date +'%Y-%m-%d %H:%M:%S') "
	echo -en "${ERROR_COLOR}ERR ${ERROR_RESET} "
	echo -en "${ERROR_WHITE}${CALLER}${ERROR_RESET}: "
	echo $args "$@"
} >&2


################################################################################
#
# Handle configuration
#
################################################################################

#
# Load the configuration
#
function backup-load-conf() {
	# Check if script is sourced in another bash script
	if [ "$0" != "$BASH_SOURCE" ]; then
		CALLER=$(basename "$(basename "${BASH_SOURCE[$(( ${#BASH_SOURCE[*]} - 1 ))]}" .sh)" .pl)
	elif [ -n "$1" ]; then
		CALLER=$(basename "$(basename "$1" .sh)" .pl)
		shift
	fi
	export CALLER

	# Binary base dir
	BINDIR="$(dirname "$(readlink --canonicalize "$0")")"
	export BINDIR
	
	# make variables available to config file
	export YEAR="${YEAR:-"$(date +'%Y')"}"
	export MONTH="${MONTH:-"$(date +'%m')"}"
	export DAY="${DAY:-"$(date +'%d')"}"
	export BACKUP_CONFDIR=${BACKUP_CONFDIR:-"$HOME/.backup"}
	
	# Load base config
	[ -r "$BACKUP_CONFDIR"/backup.conf ] &&
		. "$BACKUP_CONFDIR"/backup.conf &&
		info "loaded config file \"$BACKUP_CONFDIR/backup.conf\""
	
	# Load CALLER specific config
	[ -n "${CALLER:-""}" ] &&
		[ -r "$BACKUP_CONFDIR"/"${CALLER}.conf" ] &&
		. "$BACKUP_CONFDIR"/"${CALLER}.conf" &&
		info "loaded config file \"$BACKUP_CONFDIR/${CALLER}.conf\""

	# Load host specific base config
	[ -n  "${HOST:-""}" ] &&
		[ -r "$BACKUP_CONFDIR"/"$HOST"/backup.conf ] &&
		. "$BACKUP_CONFDIR"/"$HOST"/backup.conf &&
		info "loaded config file \"$BACKUP_CONFDIR/$HOST/default.conf\""
	
	# Load host and CALLER specific config
	[ -n  "${HOST:-""}" ] &&
		[ -n "${CALLER:-""}" ] &&
		[ -r "$BACKUP_CONFDIR"/"$HOST"/"${CALLER}.conf" ] &&
		. "$BACKUP_CONFDIR"/"$HOST"/"${CALLER}.conf" &&
		info "loaded config file \"$BACKUP_CONFDIR/$HOST/${CALLER}.conf\""
	
	# Load default config
	[ -r "$BACKUP_CONFDIR"/default.conf ] &&
		. "$BACKUP_CONFDIR"/default.conf &&
		info "loaded config file \"$BACKUP_CONFDIR/default.conf\""
	
	# Load error config
	[ -r "$BACKUP_CONFDIR"/errors.conf ] &&
		. "$BACKUP_CONFDIR"/errors.conf &&
		info "loaded config file \"$BACKUP_CONFDIR/errors.conf\""
}


#
# Get a configuration variable, replace %VAR placeholder and print the variable
#
# @param varname String: Name of the config variable (without BACKUP_ prefix)
#
function backup-conf() {
	local varname="BACKUP_$1"
	
	if [ "${!varname:-""}" == "" ]; then
		error "Configuration variable '$varname' not set!"
		return 1
	fi
	
	local data=${!varname}
	local replace=""
	
	for replace in YEAR MONTH DAY HOST; do
		# Nothing to replace for variable
		[ "$data" == "${data/\%${replace}/""}" ] && continue
		
		# Requested replacement not set
		if [ "${!replace:-""}" == "" ]; then
			error "Try to access config variable '$varname' but could not replace %${replace}, required variable \$${replace} not set!"
			return 1
		fi
		
		data="${data//\%${replace}/${!replace}}"
	done
	
	echo "$data"
}


################################################################################
#
# BACKENDS
#
################################################################################

function backup-find-backend() {
	local HOST="$1"
	local BACKENDS="$(backup-conf BACKENDS)"
	local REMOTE_DIR="$(backup-conf REMOTE_DIR)"
	
	local server error errno backend
	
	# Verify backends are set for host
	if [ -z "${BACKENDS:-""}" ]; then
		error "No storage backends awailable!"
		exit $ERR_BACKENDS
	fi
	
	if [ "${BACKENDS}" == "-" ]; then
		info "using direct backup from server \"$HOST\""
		echo "$HOST"
		return 0
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
		return $ERR_BACKENDS
	fi
	
	info "found storage server \"$backend\""
	echo "$backend"
	return 0
}


################################################################################
#
# FOLDERS
#
################################################################################

function backup-create-folders() {
	local HOST="$1"
	local MIRROR_DIR="$(backup-conf MIRROR_DIR)"
	local STATUS_DIR="$(backup-conf STATUS_DIR)"
	local DATA_DIR="$(backup-conf DATA_DIR)"
	local MYSQL_DIR="$(backup-conf MYSQL_DIR)"
	
	
	
	if ! err=$(mkdir --parent "$MIRROR_DIR" 2>&1); then
		error "failed to create mirror dir \"$MIRROR_DIR\": error \"$err\"!"
		exit $ERR_STORAGE
	fi
	
	if ! err=$(mkdir --parent "$STATUS_DIR" 2>&1); then
		error "failed to create status dir \"$STATUS_DIR\": error \"$err\"!"
		exit $ERR_STORAGE
	fi
	
	if ! err=$(mkdir --parent "$DATA_DIR" 2>&1); then
		error "failed to create data dir \"$DATA_DIR\": error \"$err\"!"
		exit $ERR_STORAGE
	fi
	
	if ! err=$(mkdir --parent "$MYSQL_DIR" 2>&1); then
		error "failed to create mysql data dir \"$MYSQL_DIR\": error \"$err\"!"
		exit $ERR_STORAGE
	fi
	 
	# A lot of symlinks to make navigation more comfortable
	[ ! -L "${STATUS_DIR}/data" ] && ln -s "${DATA_DIR}" "${STATUS_DIR}/data"
	[ ! -L "${STATUS_DIR}/mirror" ] && ln -s "${MIRROR_DIR}" "${STATUS_DIR}/mirror"
	[ ! -L "${STATUS_DIR}/mysql" ] && ln -s "${MYSQL_DIR}" "${STATUS_DIR}/mysql"
	
	[ ! -L "${DATA_DIR}/status" ] && ln -s "${STATUS_DIR}" "${DATA_DIR}/status"
	
	return 0
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
	
	info "Verifying file \"$file\" (ref: $ref_size/$ref_md5)"
	
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
		error "  md5sum mismatch, file seems to be corrupt (is: ${is_md5:0:32}, should be: ${ref_md5:0:32})"
		return 2
	fi
	
	return 0
}


################################################################################
#
# Other helper
#
################################################################################


#
# Get a configuration variable (for different settings as currently are used)
# e.g.
# > DAY=1 backup-get-config-var BACKUP_DIR
# will return the value that BACKUP_DIR would have if current day where 1
#
# WARNING: Only the requested variable is unset before reading the config.
#          If you request a variable A="B/foobar" and B="/$MONTH/$DAY"
#          than A will not change if you supply DAY because B is already fixed
#          You than must call it with
#          > DAY=1 B= backup-get-config-var A
#          so B is also recalculated
#
# @param PRINT_VARIABLE_NAME String: name of variable to get
#
function backup-get-config-var() {
	local PRINT_VARIABLE_NAME="$1"
	shift
	
	(
		unset $PRINT_VARIABLE_NAME
		. "$BINDIR"/backup-read-config.sh $PRINT_VARIABLE_NAME
		echo "${!PRINT_VARIABLE_NAME}"
	) 3>/dev/null
}


################################################################################
#
# Initialize
#
################################################################################

backup-load-conf
