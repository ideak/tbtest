#!/bin/bash

set -ue

CONFIG_FILE=.config

TBTEST_DIR=$(dirname $0)

. $TBTEST_DIR/utils.sh
. $TBTEST_DIR/type-utils.sh
. $TBTEST_DIR/tbtool-db.sh
. $TBTEST_DIR/tools.sh

AUTORESUME_DELAY_SEC=20		# delay after a suspend until system is autoresumed
CYCLE_DELAY_SEC=20		# delay after resume until the next suspend/resume cycle

PROGRESS_PRINT_INTERVAL=20	# number of cycles after a progress indication is printed

MAX_TEST_CMD_RETRY_ATTEMPTS=10	# max number test commands are retried, in case they need this

FILTERED_DMESG_ERRORS=""	# error/warning messages filtered out

declare -r TBT_DP_IN_ADAPTERS_CONF_NAME=TBT_DP_IN_ADAPTERS
TBT_DP_IN_ADAPTERS=()		# list of preconfigured  (D:R:A [D:R:A ...]) enabled DP IN
				# adapters to test. If unset the adapters will be detected.

[ -f "$CONFIG_FILE" ] && . "$CONFIG_FILE"

modules="thunderbolt i915"

declare -a dp_in_adapters

test_start=
dry_run=false
adapters_got_detected=false

stop_test=false
reload_network=false

parse_options()
{
        OPTIONS="h"
        LONGOPTIONS="reload-network-module,help"

        # Using getopt to store the parsed options and arguments into $PARSED
        PARSED=$(getopt --options=$OPTIONS --longoptions=$LONGOPTIONS --name "$(basename $0)" -- "$@")

        # Checking for errors
        if [[ $? -ne 0 ]]; then
                exit 2
        fi

        # Setting the parsed options and arguments to $@
        eval set -- "$PARSED"

        usg=\
"Usage: $(basename $0) [OPTIONS]
OPTIONS:
        --reload-network-module          rmmod/modprobe network module across suspend/resume
        -h, --help                       print this help
"

        while true; do
                case "$1" in
                --reload-network-module)
                        reload_network=true
                        ;;
		-h|--help)
			echo "$usg"
			exit
			;;
                --)
                        shift
                        break
                        ;;
                *)
                        err_exit "Unexpected option \"$1\""
                        ;;
                esac
		                shift
        done

        if [ $# -gt 0 ]; then
                err_exit "unexpected arguments \"$@\"\n$usg"
        fi

	if $reload_network; then
		if [[ ! -v NETWORK_MODULE ]]; then
			err_exit "The NETWORK_MODULE variable must be set to reload the network module"
		fi

		which lsmod > /dev/null || err_exit "Can't find lsmod tool"
		
		if ! lsmod | grep "^\<$NETWORK_MODULE\>" > /dev/null ; then
			err_exit "The \"$NETWORK_MODULE\" network module is not loaded"
		fi
	fi
}

init_test_start()
{
	test_start=$(get_uptime_sec)
}

get_dp_in_adapters()
{
	local err
	local adps

	dp_in_adapters=()

	adps=$(get_configured_dp_in_adapters)
	err=$?
	if [ $err -eq 0 ]; then
		eval "dp_in_adapters=($adps)"
		return 0
	fi

	[ $err -ne 2 ] && return 1

	adps=$(find_enabled_dp_in_adapters)
	err=$?
	[ $err -ne 0 ] && return 1

	eval "dp_in_adapters=($adps)"

	if [ ${#dp_in_adapters[@]} -eq 0 ]; then
		log_err "Couldn't find any enabled DP IN adapters to test"
		return 2
	fi

	adapters_got_detected=true
}

init_dp_in_adapters()
{
	local config_detect_str
	local adapter_desc
	local err

	get_dp_in_adapters || return 1

	if $adapters_got_detected; then
		config_detect_str=detected
	else
		config_detect_str=configured
	fi

	log "Testing the following $config_detect_str DP IN adapters:"

	for adapter_desc in "${dp_in_adapters[@]}"; do
		local -A dr_adapter=()
		local dra

		dradapter_deserialize dr_adapter "$adapter_desc"
		dra=$(get_adapter_dra dr_adapter)
		log_no_prefix "DRA:$dra Dev:${dr_adapter[$DR_DEV]}"
	done
}

get_dpme()
{
	local -nr __gd_adapter=$1
	local __gd_dpme
	local __gd_err

	__gd_dpme=$(test_cmd $SUDO $TBGET \
		-d "${__gd_adapter[$DR_DOMAIN]}" \
		-r "${__gd_adapter[$DR_ROUTE]}" \
		-a "${__gd_adapter[$ADP_ID]}" \
		ADP_DP_CS_8.DPME)
	__gd_err=$?

	$dry_run && __gd_dpme=0x1

	if [ "$__gd_dpme" != 0x0 -a "$__gd_dpme" != 0x1 ]; then
		log_err "Invalid DPME state: \"$__gd_dpme\""
		__gd_err=1
	fi

	echo "$__gd_dpme"

	return $__gd_err
}

check_dpme_for_adapters()
{
	local dr_adapter_desc
	local err
	local ret=0

	for dr_adapter_desc in "${dp_in_adapters[@]}"; do
		local -A dr_adapter=()
		local dpme
		local dra

		dradapter_deserialize dr_adapter "$dr_adapter_desc"

		dra=$(get_adapter_dra dr_adapter)

		dpme=$(get_dpme dr_adapter)
		err=$?

		[ $ret -eq 0 ] && ret=$err
		if [ $err -ne 0 ]; then
			log_ecode $err "Cannot get DPME for DP IN adapter at DRA $dra"

			[ $err -eq $ERR_INTR ] && break

			continue
		fi

		if [ "$dpme" != "0x1" ]; then
			log_err "DPME for DP IN adapter at DRA $dra is not enabled"
			[ $ret -eq 0 ] && ret=1

		fi
	done

	return $ret
}

filter_dmesg()
{
	local line
	local pattern
	local match

	[ -z "$FILTERED_DMESG_ERRORS" ] && cat

	while IFS= read -r line; do
		match=false
		while IFS= read -r pattern; do
			if echo "$line" | $GREP "$pattern" > /dev/null; then
				match=true
				break
			fi
		done <<< "$FILTERED_DMESG_ERRORS"

		$match || echo "$line"
	done
}

check_dmesg_errors()
{
	local errors

	errors=$(test_cmd bash -c "$SUDO $DMESG -l err,warn | grep_no_err -v 'done.'") || return 1

	errors=$(filter_dmesg <<< "$errors")

	[ -z "$errors" ] && return 0

	log_err "Errors in dmesg:\n$errors"

	test_cmd_no_out $SUDO $DMESG -C || return $?

	return 1
}

suspend_and_autoresume()
{
	local modprobe_attempt=0
	local ret=0

	if $reload_network; then
		test_cmd_no_out $SUDO $RMMOD e1000e || ret=$?
	fi

	if [ $ret -eq 0 ]; then
		test_cmd_no_out $SUDO $RTCWAKE -m mem -s $AUTORESUME_DELAY_SEC || ret=$?
	fi

	if $reload_network; then
		# retry modprobe a few times if it gets interrupted
		test_cmd_retry_no_out $SUDO $MODPROBE e1000e || ret=$?
	fi

	return $ret
}

log_progress()
{
	local cycle=$1

	shift

	if [ $(( cycle % PROGRESS_PRINT_INTERVAL )) == 1 ]; then
		log_cont "Cycle $cycle:"
	else
		log_cond "Cycle $cycle:"
	fi

	log_no_prefix_cont "$@"
}

check_state()
{
	check_dmesg_errors || return $?
	check_dpme_for_adapters || return $?

	return 0
}

test_suspend_resume()
{
	local cycle=$1

	log_progress $cycle S

	suspend_and_autoresume || return $?

	log_no_prefix_cont R

	check_state || return $?

	return 0
}

run_test()
{
	local start=$(get_uptime_sec)
	local error_count=0
	local cycle=0
	local err

	log "Initial state check"
	if ! check_state; then
		log_err "Initial state check failed, abort"
		return 1
	fi

	log "Test started"

	while ! $stop_test; do
		cycle=$(( cycle + 1 ))

		err=0
		test_suspend_resume "$cycle" || err=$?

		if [ $err -ne 0 -a $err -ne 130 ]; then
			error_count=$(( error_count + 1 ))

			if $stop_test; then
				log_err "Test failed, error code:$err, total errors:$error_count"
			else
				log_err "Test failed, error code:$err, total errors:$error_count, continuing"
			fi
		fi

		if ! $stop_test; then
		       	sleep $CYCLE_DELAY_SEC || true
		fi
	done

	log_success_fail $error_count "Test ended, $cycle cycles, total errors:$error_count"
}

load_modules()
{
	local had_to_modprobe=false
	local module

	for module in $modules; do
		local ret=0
		local loaded_mode

		mod_list=$(test_cmd $LSMOD)
		[ $? -ne 0 ] && return 1

		log_cont "Loading module $module:"

		loaded_mod=$(test_cmd grep_no_err "\<i915\>" <<< "$mod_list") || return 1

		if [ -n "$loaded_mod" ]; then
			log_no_prefix " Already loaded"
		else
			test_cmd_no_out $SUDO $MODPROBE "$module" || return 1
			had_to_modprobe=true
			log_no_prefix " Loaded succesfully"
		fi
	done

	if ! $had_to_modprobe; then
		return 0
	fi

	sleep 3
}

init_test()
{
	init_test_start
	load_modules || return $?
	init_dp_in_adapters || return $?

	return 0
}

cleanup_test()
{
	cleanup_utils
}

parse_options "$@"

init_tools || err_exit "Initializiation of tools failed"
cache_sudo_right || err_exit "Can't get root permission"
init_utils || err_exit "Initialization of utilities failed"

trap "stop_test=true; log_note 'Test interrupted' " SIGINT

if ! init_test; then
	cleanup_utils
	err_exit "Initialization of test failed"
fi

run_test || true   # clean up still

cleanup_test || err_exit "Cleanup failed"
