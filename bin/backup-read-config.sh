#!/bin/bash

export LC_ALL=C

if [ ! -w /dev/fd/3 ]; then
	exec 3>&2
fi

function info() {
	local args
	
	[ "$1" == "-e" ] && args+=" -e" && shift
	echo $args "$CALLER (INFO): $@" >&3
}

function error() {
	local args
	
	[ "$1" == "-e" ] && args+=" -e" && shift
	echo $args "$CALLER (ERROR): $@" >&2
}

function warn() {
	local args
	
	[ "$1" == "-e" ] && args+=" -e" && shift
	echo $args "$CALLER (WARN): $@" >&3
}

# Check if script is sourced in another bash script
if [ "$0" != "$BASH_SOURCE" ]; then
	CALLER=$(basename "$(basename "${BASH_SOURCE[$(( ${#BASH_SOURCE[*]} - 1 ))]}" .sh)" .pl)
elif [ -n "$1" ]; then
	CALLER=$(basename "$(basename "$1" .sh)" .pl)
	shift
fi
export CALLER

# Host is the first parameter if not supplied as env variable
if [ -z "$HOST" ]; then
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
	[ -n "$BACKEND" ] && return
	
	# Verify backends are set for host
	if [ -z "${BACKENDS}" ]; then
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
