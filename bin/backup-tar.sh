function backup-tar() {
	local fakeroot_cmd=( "env" )
	
	# Check fakeroot
	if [ "${FAKEROOT,,*}" == "yes" ]; then
		info "Enabling fakeroot"
		
		if ! fakeroot_bin="$(which fakeroot)" || [ ! -x "$fakeroot_bin" ]; then
			error "No fakeroot binary found or binary not executable (which returned: \"$fakeroot_bin\")!"
			exit $ERR_FAKEROOT
		fi
		
		fakeroot_cmd=( "$fakeroot_bin" -i "${FAKEROOT_STATUS}" -s "$FAKEROOT_STATUS" -- )
	fi
	
	local TAR_BIN=$(backup-conf TAR_BIN)
	local TAR_PARAMS=$(backup-conf TAR_PARAMS)
	local TAR_SNAPSHOT_FILE=$(backup-conf TAR_SNAPSHOT_FILE)
	local TAR_FILE=$(backup-conf TAR_FILE)
	local STATUS_DIR=$(backup-conf STATUS_DIR)
	local MIRROR_DIR=$(backup-conf MIRROR_DIR)
	local COMPRESS_BIN=$(backup-conf COMPRESS_BIN)
	local COMPRESS_PARAMS=$(backup-conf COMPRESS_PARAMS)
	
	# Tar
	if [ ! -x "$TAR_BIN" ]; then
		error "No tar binary found or binary not executable (binary to use: \"$TAR_BIN\")!"
		exit $ERR_TAR
	fi
	
	local tar_cmd=( "$TAR_BIN" --create $TAR_PARAMS "--listed-incremental=${TAR_SNAPSHOT_FILE}" "--index-file=${STATUS_DIR}/listing" "--directory=$(dirname "${MIRROR_DIR}")" )
	
	if [ -L "${STATUS_DIR}/reference" ]; then
		info "creating incremental backup, using reference \"$(readlink "${STATUS_DIR}/reference")\"."
		cp -a "${STATUS_DIR}"/reference/data/"$(basename "${TAR_SNAPSHOT_FILE}")" "${TAR_SNAPSHOT_FILE}" || ( error "failed to copy reference file!" ; exit $ERR_TAR )
	fi
	
	tar_cmd=( "${tar_cmd[@]}" "$HOST" )

	local size_file="${STATUS_DIR}/$(basename "${TAR_FILE}").size"
	local md5_file="${STATUS_DIR}/$(basename "${TAR_FILE}").md5sum"
	
	info "executing '${fakeroot_cmd[@]} ${tar_cmd[@]}'"
	"${fakeroot_cmd[@]}" "${tar_cmd[@]}" 2>"${STATUS_DIR}/tar-stderr.log" |
		"${COMPRESS_BIN}" $COMPRESS_PARAMS |
		tee >(wc --bytes > "$size_file") >(md5sum >"$md5_file") >"${TAR_FILE}"
	errno=$?
	
	if (( errno != 0 )); then
		error "tar failed: $errno"
		return $ERR_TAR
	fi
	
	info "verifying backup"
	backup-verify "${TAR_FILE}" "$size_file" "$md5_file" || return $ERR_TAR
	
	info "compressing log files"
	"${COMPRESS_BIN}" $COMPRESS_PARAMS "${STATUS_DIR}/rsync-stdout.log" "${STATUS_DIR}/rsync-stderr.log" "${STATUS_DIR}/tar-stderr.log" "${STATUS_DIR}/listing"
}
