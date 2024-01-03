TBTOOLS_DIR=$HOME/tbtools
TBTOOLS_BIN_DIR=$TBTOOLS_DIR/target/release

declare -ra tools=(
	$TBTOOLS_BIN_DIR:TBGET,TBADAPTERS,TBLIST
	$HOME/bin:DMESG
	"":RM,MKTEMP,GREP,RTCWAKE,LSMOD,MODPROBE,RMMOD
)

tool_cmd()
{
	echo "$(basename "$1")"
}

find_tool()
{
	which "$1" || return 2
}

assign_tool_path()
{
	local tool_varname=$1
	local tool_path=$2

	[ -f "$tool_path" ] || return 2
	[ -x "$tool_path" ] || err_exit "Tool $tool_path is not executable"

	eval "$tool_varname=\"$tool_path\""
}

tool_name()
{
	echo "$(tool_cmd "${1,,}")"
}

find_and_assign_tool()
{
	local tool_varname=$1
	local tool_name=$(tool_name "$tool_varname")
	local tool_path
	local err

	tool_path=$(find_tool "$tool_name")
	err=$?
	[ $err -ne 0 ] && return $err

	assign_tool_path "$tool_varname" "$tool_path"
}

assign_tool()
{
	local tool_varname=$1
	local tool_name=$(tool_name "$tool_varname")
	local tool_dir=${2:-}
	local err=0

	if [ -n "$tool_dir" ]; then
		assign_tool_path "$tool_varname" "$tool_dir/$tool_name" || err=$?
		[ $err -ne 2 ] && return $err
	fi

	find_and_assign_tool "$tool_varname"
}

init_sudo()
{
	if [ "$(id -u)" -eq 0 ]; then
		SUDO=""
		return 0
	fi

	assign_tool SUDO "" && return 0

	pr_err "Cannot find tool sudo"

	return 1
}

init_tools()
{
	local tool_desc
	local tool_varname
	local tool_list
	local custom_dir
	local -a tool_varnames
	local tool_varname

	init_sudo || return 1

	for tool_desc in "${tools[@]}"; do
		custom_dir=${tool_desc%%:*}
		tool_list=${tool_desc#*:}

		IFS="," read -ra tool_varnames <<< "${tool_list}"

		for tool_varname in "${tool_varnames[@]}"; do
			assign_tool "$tool_varname" "$custom_dir" && continue

			pr_err "Cannot find tool \"$(tool_name $tool_varname)\""

			return 1
		done
	done

	export -f grep_no_err
	export GREP
}

grep_no_err()
{
	local err

	$GREP "$@"
	err=$?

	[ $err -eq 1 ] && return 0

	return $err
}

__test_cmd()
{
	local errout=$1
	local err_file
	local cmd_out
	local err

	shift

	err_file=$($MKTEMP)

	if $dry_run; then
		sleep 0.3
		return 0
	fi

	if $errout; then
		cmd_out=$("$@" 2>&1)
	else
		cmd_out=$("$@" 2> "$err_file")
	fi
	err=$?

	case "$err" in
	0)
		echo "$cmd_out"
		;;
	$ERR_INTR)
		log_note "Command \"$@\" was interrupted"
		;;
	*)
		log_err "Command \"$@\" failed with error code $err:"
		if $errout; then
			log_no_prefix "$cmd_out"
		else
			log_no_prefix "$(cat "$err_file")"
		fi
		;;
	esac

	$RM "$err_file"

	return $err
}

test_cmd()
{
	__test_cmd false "$@"
}

test_cmd_errout()
{
	__test_cmd true "$@"
}

test_cmd_no_out()
{
	test_cmd "$@" > /dev/null
}

test_cmd_retry()
{
	local first_err=0
	local err
	local i

	for ((i = 0; i < $MAX_TEST_CMD_RETRY_ATTEMPTS; i++)); do
		test_cmd "$@"
		err=$?

		[ $first_err -eq 0 ] && first_err=$err

		[ $err -ne 130 ] && break
	done

	return $first_err
}

test_cmd_retry_no_out()
{
	test_cmd_retry "$@" > /dev/null
}

