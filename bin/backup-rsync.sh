#
# 
#
function backup-rsync() {
	local HOST="$1"
	local BACKEND="$2"
	
	local fakeroot_cmd=( "env" )

	# Check fakeroot
	if [ "${BACKUP_FAKEROOT,,*}" == "yes" ]; then
		info "Enabling fakeroot"
		local fakeroot_bin
		
		if ! fakeroot_bin="$(which fakeroot)" || [ ! -x "$fakeroot_bin" ]; then
			error "No fakeroot binary found or binary not executable (which returned: \"$fakeroot_bin\")!"
			exit $ERR_FAKEROOT
		fi
		
		fakeroot_cmd=( "$fakeroot_bin" -i "${BACKUP_FAKEROOT_STATUS}" -s "$BACKUP_FAKEROOT_STATUS" -- )
	fi
	
	local RSYNC_BIN="$(backup-conf RSYNC_BIN)"
	local RSYNC_PARAMS="$(backup-conf RSYNC_PARAMS)"
	local RSYNC_EXCLUDE_DEFAULT="$(backup-conf RSYNC_EXCLUDE_DEFAULT)"
	local RSYNC_EXCLUDE_HOST="$(backup-conf RSYNC_EXCLUDE_HOST)"
	
	# Check rsync
	if [ ! -x "$RSYNC_BIN" ]; then
		error "No rsync binary found or binary not executable (binary to use: \"$RSYNC_BIN\")!"
		exit $ERR_RSYNC
	fi
	
	local rsync_cmd=( "$RSYNC_BIN" ${RSYNC_PARAMS} )
	
	# Check exclude list
	if [ -r "${RSYNC_EXCLUDE_DEFAULT}" ]; then
		info "using exclude file \"${RSYNC_EXCLUDE_DEFAULT}\"."
		rsync_cmd=( "${rsync_cmd[@]}" "--exclude-from=${RSYNC_EXCLUDE_DEFAULT}" )
	else
		info "exclude file \"${RSYNC_EXCLUDE_DEFAULT}\" not found/readable!"
	fi
	
	if [ -r "${RSYNC_EXCLUDE_HOST}" ]; then
		info "using exclude file \"${RSYNC_EXCLUDE_HOST}\"."
		rsync_cmd=( "${rsync_cmd[@]}" "--exclude-from=${RSYNC_EXCLUDE_HOST}" )
	else
		info "exclude file \"${RSYNC_EXCLUDE_HOST}\" not found/readable!"
	fi
	
	local REMOTE_DIR="$(backup-conf REMOTE_DIR)"
	local MIRROR_DIR="$(backup-conf MIRROR_DIR)"
	local STATUS_DIR="$(backup-conf STATUS_DIR)"
	
	rsync_cmd=( "${rsync_cmd[@]}" "--rsh=ssh -F $HOME/.ssh/config-backup" "$BACKEND:${REMOTE_DIR}" "${MIRROR_DIR}" )

	info "executing '${fakeroot_cmd[@]} ${rsync_cmd[@]}'"
	"${fakeroot_cmd[@]}" "${rsync_cmd[@]}" >"${STATUS_DIR}/rsync-stdout.log" 2>"${STATUS_DIR}/rsync-stderr.log"
	errno=$?
	
	if (( errno == 24 )); then
		warn "rsync could not transfer all files as some seem to have vanished (return code 24)"
	
	elif (( errno != 0 )); then
		error "rsync failed: $errno"
		return $ERR_RSYNC
	fi
	
	return 0
}
