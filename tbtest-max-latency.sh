#!/bin/bash

set -eu

raw_mode=false

parse_options()
{
        OPTIONS="rh"
        LONGOPTIONS="raw,help"

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
        -r, --raw                force outputing terminal control sequences
        -h, --help               print this help
"

        while true; do
                case "$1" in
                -r|--raw)
                        raw_mode=true
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
                        error "Unexpected option \"$1\""
                        ;;
                esac
		                shift
        done

        if [ $# -gt 0 ]; then
                error "unexpected arguments \"$@\"\n$usg"
        fi
}

cursor_move_supported()
{
	$raw_mode && return 0

	# is stdout a terminal?
	[ -t 1 ] || return 1

	tput cub1 &> /dev/null || return 1

	return 0
}

erase_back()
{
	local n=$1

	echo -ne "\033[${n}D"
}

last_entry=""

print_new_entry()
{
	local new_entry=$1

	if ! cursor_move_supported; then
		echo $new_entry
		return
	fi

# 	echo last_entry "$last_entry" erase back ${#last_entry} new_entry ${new_entry}
# 
# 	echo -n "${last_entry}"
# 
# 	erase_back ${#last_entry}
# 	echo -n $new_entry
# 
# 	last_entry="$new_entry"
# 
# 	echo
# 
# 	return

	erase_back ${#last_entry}
	echo -n $new_entry

	last_entry="$new_entry"
}

read_loop()
{
	max_latency=-1

	sed -n 's/.*delay=\([0-9]\+\).*/\1/p' | while IFS= read latency; do
		if [ $latency -gt $max_latency ]; then
			max_latency=$latency
			print_new_entry $max_latency
		fi
	done

	# new-line after last entry
	cursor_move_supported && echo
}

parse_options "$@"
read_loop

