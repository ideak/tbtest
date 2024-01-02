shopt -s extglob

COLOR_RED=
COLOR_GREEN=
COLOR_PURPLE=
COLOR_YELLOW=
COLOR_NONE=

ERR_INTR=130

MIN_BASH_MAJOR=4
MIN_BASH_MINOR=1

debug()
{
        echo -e "$@" >&2
}

pr_err()
{
        echo -e "$@" >&2
}

err_exit()
{
	pr_err -e "$@"
        exit 1
}

check_bash_version()
{
	local major minor trail

	major=${BASH_VERSION%%.*}
	trail=${BASH_VERSION#*.}
	minor=${trail%%.*}

	if [ "$major" -lt "$MIN_BASH_MAJOR" -o \
	     \( "$major" -eq "$MIN_BASH_MAJOR" -a "$minor" -lt "$MIN_BASH_MINOR" \) ]; then
		err_exit "Bash version too old:$BASH_VERSION (required at least $MIN_BASH_MAJOR.$MIN_BASH_MINOR)"
	fi
}

term_supports_colors()
{
	# is stdout a terminal?
	[ -t 1 ] || return 1

	if [ $(tput colors) -gt 1 ]; then
		return 0
	fi

	return 1
}

color_esc_seq()
{
	local color_code1=$1
	local color_code2=${2:-}

	echo "\033[$color_code1${2+;}${color_code2}m"
}

init_colors()
{
	if term_supports_colors; then
		COLOR_RED=$(color_esc_seq 0 31)
		COLOR_GREEN=$(color_esc_seq 0 32)
		COLOR_PURPLE=$(color_esc_seq 0 35)
		COLOR_LIGHT_GREY=$(color_esc_seq 37)
		COLOR_YELLOW=$(color_esc_seq 1 33)
		COLOR_GREY=$(color_esc_seq 0 90)
		COLOR_NONE=$(color_esc_seq 0)
	else
		COLOR_RED=""
		COLOR_GREEN=""
		COLOR_PURPLE=""
		COLOR_YELLOW=""
		COLOR_NONE=""
	fi
}

valid_number()
{
        local number=$1

        [ -z "${number}" -o -n "${number/#+([0-9])/}" ] && return 1

        return 0
}

sec_to_time()
{
	local seconds=$1

	date -u -d @"$seconds" +"%Hh %Mm %Ss"
}

get_duration()
{
	local start=$1
	local end=$2

	sec_to_time $(( end - start ))
}

sec_to_date_time()
{
	local seconds=$1

	date -d @"$seconds"
}

get_wall_time_sec()
{
	date +%s
}

get_uptime_sec()
{
	local uptime=$(< /proc/uptime)

	echo "${uptime%%.*}"
}

get_boot_time_sec()
{
	echo "$(($(get_wall_time_sec) - $(get_uptime_sec)))"
}

uptime_to_prefix()
{
	local uptime_sec=$1
	local test_time_sec=$((uptime_sec - test_start))
	local boot_time_sec=$(get_boot_time_sec)
	local wall_time_sec=$((boot_time_sec + uptime_sec))

	echo "$(sec_to_date_time $wall_time_sec) +$(sec_to_time "$test_time_sec") [${uptime_sec}]"
}

logger_process()
{
        local start_nl
        local end_nl
        local last_end_nl=true

	trap "" SIGINT

        while IFS= read -r line; do
                start_nl=false
		cond_print=false
                end_nl=false

                if [ "${line: -1}" = $'\r' ]; then
                       end_nl=true
                       line="${line%?}"
                fi

                if [ "${line:0:1}" = $'\r' ]; then
                       start_nl=true
                       line="${line:1}"
                fi

                if [ "${line:0:1}" = $'\r' ]; then
                       cond_print=true
                       line="${line:1}"
                fi

		if $cond_print && ! $last_end_nl; then
		       continue
		fi

                $start_nl && ! $last_end_nl && echo
                stdbuf -o0 echo -ne "$line" 
                $end_nl && echo

                last_end_nl=$end_nl
        done
}

init_logger()
{
	stty -echoctl
	exec {LOGGER_FD}> >(logger_process)
}

cleanup_logger()
{
	exec {LOGGER_FD}>&-
	wait
}

conv_nl()
{
	local str="$@"

	str="$(echo -e "$str")"

	echo "${str//$'\n'/$'\r\n'}"
}

log_no_prefix_cont()
{
	echo -e "$(conv_nl "$@")" >&"$LOGGER_FD"
}

log_no_prefix()
{
	echo -e "$(conv_nl "$@")\r" >&"$LOGGER_FD"
}

log_nl()
{
	echo -e "\r" >&"$LOGGER_FD"
}

log_at_cont()
{
	local time_sec=$1

	shift

	log_no_prefix_cont "\r${COLOR_GREY}$(uptime_to_prefix "$time_sec"):${COLOR_NONE} $@"
}

log_at_cond()
{
	local time_sec=$1

	shift

	log_no_prefix_cont "\r\r${COLOR_GREY}$(uptime_to_prefix "$time_sec"):${COLOR_NONE} $@"
}

log_cont()
{
	log_at_cont "$(get_uptime_sec)" "$@"
}

log_cond()
{
	log_at_cond "$(get_uptime_sec)" "$@"
}

log_at()
{
	local time_sec=$1

	shift

	log_at_cont "$time_sec" "$@\r"
}

log()
{
	log_at "$(get_uptime_sec)" "$@"
}

log_color()
{
	local color=$1

	shift

	log_at "$(get_uptime_sec)" "${color}$@${COLOR_NONE}"
}

log_err()
{
	log_color "${COLOR_RED}" "$@"
}

log_note()
{
	log_color "${COLOR_YELLOW}" "$@"
}

log_ecode()
{
	local err_code=$1

	shift

	case "$err_code" in
	$ERR_INTR)
		log_note "$@" "(interrupted)"
		;;
	0)
		log "$@"
		;;
	*)
		log_err "$@" "(error code:$err_code)"
		;;
	esac
}

log_success_fail()
{
	local err=$1

	shift

	if [ $err -ne 0 ]; then
		log_err "$@"
	else
		log_color "${COLOR_GREEN}" "$@"
	fi
}

get_ssh_server_address()
{
	local ip_address
	local ip_octet
	local ip_port
	local i
	local -r address_regex="^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3}) ([0-9]{1,6})\b"

	if ! [ -v SSH_CONNECTION ]; then
		pr_err "The SSH_CONNECTION environment variable is not set."
		return 1
	fi

	if ! [[ $SSH_CONNECTION =~ $address_regex ]]; then
		pr_err "Malformed IP address/port in SSH_CONNECTION variable"
		return 1
	fi

	for ((i=1; i<=4; i++)); do
		ip_octet=${BASH_REMATCH[i]}

		if [[ $ip_octet -gt 255 ]]; then
			pr_err "Invalid IP address octet \"$ip_octet\" in SSH_CONNECTION variable"
			return 1
		fi

		ip_address+="${ip_address:+.}$ip_octet"
	done

	ip_port=${BASH_REMATCH[5]}
	if [ $ip_port -lt 1024 ]; then
		pr_err "Invalid SSH client IP port \"$ip_port\""
		return 1
	fi

	echo "$ip_address:$ip_port"
}

cache_sudo_right()
{
	sudo true || return $?
}

init_utils()
{
	check_bash_version

	init_colors || return $?
	init_logger || return $?
}

cleanup_utils()
{
	cleanup_logger || return $?
}
