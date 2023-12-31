#!/bin/bash

declare -r DP_IN_ADAPTER_TYPE="DisplayPort IN"
declare -r DP_IN_ADAPTER_STATE_EN="Enabled"
declare -r DP_IN_ADAPTER_STATE_DIS="Disabled"

declare -r ADAPTER_NOT_IMPLEMENTED_TYPE="Not implemented"

declare -r DR_DOMAIN=domain
declare -r DR_ROUTE=route
declare -r DR_PCI_ID=pci_id
declare -r DR_DEV=dev
declare -ra DR_KEYS=("$DR_DOMAIN" "$DR_ROUTE" "$DR_PCI_ID" "$DR_DEV")

declare -r ADP_ID=id
declare -r ADP_TYPE=type
declare -r ADP_STATE=state
declare -ra ADP_KEYS=("$ADP_ID" "$ADP_TYPE" "$ADP_STATE")

declare -ra DR_ADP_KEYS=("${DR_KEYS[@]}" "${ADP_KEYS[@]}")

get_adapter_dra()
{
	local -nr __adp_ref=$1

	echo "${__adp_ref[$DR_DOMAIN]}:${__adp_ref[$DR_ROUTE]}:${__adp_ref[$ADP_ID]}"
}

__domain_route_deserialize()
{
	obj_init "$1" "$2" "$3"
	check_keys DR_KEYS "$1" "$2"
}

domain_route_deserialize()
{
	__domain_route_deserialize "$1" "$1" "$2"
}

domain_route_init()
{
	__domain_route_deserialize "$1" "$1" "( \
		[$DR_DOMAIN]=\"$2\" \
		[$DR_ROUTE]=\"$3\" \
		[$DR_PCI_ID]=\"$4\" \
		[$DR_DEV]=\"$5\" \
	)"
}

__adapter_deserialize()
{
	obj_init "$1" "$2" "$3"
	check_keys ADP_KEYS "$1" "$2"
}

adapter_deserialize()
{
	__adapter_deserialize "$1" "$1" "$2"
}

adapter_init()
{
	__adapter_deserialize "$1" "$1" "( \
		[$ADP_ID]=\"$2\" \
		[$ADP_STATE]=\"$3\" \
		[$ADP_TYPE]=\"$4\" \
	)"
}

__dradapter_deserialize()
{
	obj_init "$1" "$2" "$3"
	check_keys DR_ADP_KEYS "$1" "$2"
}

dradapter_deserialize()
{
	__dradapter_deserialize "$1" "$1" "$2"
}

valid_dr_field()
{
	local -r exp_name=$1
	local -r name=$2
	local -r value=$3
	local tblist_tool=$(tool_name $TBLIST)

	if [ "$name" != "$exp_name" ]; then
		log_err "Invalid $tblist_tool field name: \"$name\" (expected \"$exp_name\")"
		return 1
	fi

	if ! valid_number "$value"; then
		log_err "Invalid $tblist_tool \"$domain\" number: \"$value\""
		return 1
	fi
}

valid_pci_id()
{
	local -r pci_id=$1

	[[ $pci_id =~ ^[[:xdigit:]]{4}:[[:xdigit:]]{4}$ ]] && return 0

	log_err "Invalid PCI ID: \"$pci_id\""

	return 1
}

parse_domain_route_rec()
{
	local -r dr_rec=$1
	local -A dr=()
	local domain_label domain route_label route pci_id dev
	local tblist_tool=$(tool_name $TBLIST)

	IFS=" " read -r domain_label domain route_label \
			route pci_id dev <<< "$dr_rec"

	valid_dr_field "Domain" "$domain_label" "$domain" || return 1

	if [ "${route: -1}" != ":" ]; then
		log_err "Unexpected $tblist_tool route field: \"$route\""
		return 1
	fi
	route=${route%:}
	valid_dr_field "Route" "$route_label" "$route" || return 1

	valid_pci_id "$pci_id" || return 1

	domain_route_init dr "$domain" "$route" "$pci_id" "$dev"
	serialize_obj dr
}

get_domain_routes()
{
	local dr_table
	local dr_rec
	local -a dr_list=()
	local no_dev_regex="No.*devices found"

	dr_table=$(test_cmd $TBLIST)
	[ $? -ne 0 ] && return 1

	if [[ "$dr_table" =~ $no_dev_regex ]]; then
		log_err "$(tool_name $TBLIST): $dr_table"
		return 1
	fi

	while read -r dr_rec; do
		dr_list+=("$(parse_domain_route_rec "$dr_rec")") || return 1
	done <<< "${dr_table}"

	serialize_array dr_list
}

get_domain_route()
{
	local -r domain=$1
	local -r route=$2
	local -a dr_array
	local dr_desc
	local drs

	drs=$(get_domain_routes) || return 1
	array_init dr_array "($drs)" || return 1

	for dr_desc in "${dr_array[@]}"; do
		local -A dr=()

		domain_route_deserialize dr "($dr_desc)"

		if [ "${dr[$DR_DOMAIN]}" = "$domain" -a \
		     "${dr[$DR_ROUTE]}" = "$route" ]; then
			echo "$dr_desc"

			return 0
		fi
	done

	return 2
}

parse_adapter_rec()
{
	local -r adapter_rec=$1
	local -A adapter
	local adapter_id adapter_type_state
	local adapter_type
	local adapter_state

	IFS=" " read -r adapter_id adapter_type_state <<< "$adapter_rec"

	if [ "${adapter_id: -1}" != ":" ]; then
		log_err "Invalid $(tool_name $TBADAPTERS) adapter ID field: \"$adapter_id\""
		return 1
	fi

	adapter_id="${adapter_id%:}"
	if ! valid_number "$adapter_id"; then
		log_err "Invalid $(tool_name $TBADAPTERS) adapter ID: \"$adapter_id\""
		return 1
	fi

	if [ "${adapter_type_state}" = "$ADAPTER_NOT_IMPLEMENTED_TYPE" ]; then
		adapter_type="$ADAPTER_NOT_IMPLEMENTED_TYPE"
		adapter_state="NA"
	else
		local -a adapter_state_words

		read -ra type_state_words <<< "$adapter_type_state"

		if [ ${#type_state_words[@]} -lt 2 ]; then
			log_err "Invalid $(tool_name $TBADAPTERS) type/state field for adapter ID $adapter_id: \"${type_state_words[@]}'"
			return 1
		fi

		adapter_type=${type_state_words[@]:0:${#type_state_words[@]}-1}
		adapter_state=${type_state_words[-1]}
	fi

	adapter_init adapter "$adapter_id" "$adapter_state" "$adapter_type"
	serialize_obj adapter
}

get_adapters_for_domain_route()
{
	local -r domain=$1
	local -r route=$2
	local -a adapters
	local dr_desc
	local -A dr
	local adapter_table

	dr_desc="$(get_domain_route "$domain" "$route")" || return 1
	domain_route_deserialize dr "($dr_desc)" || return 1

	adapter_table=$(test_cmd_errout $SUDO $TBADAPTERS \
		-d "$domain" -r "$route") || return 1

	while read -r adapter_rec; do
		local -A adapter=()

		adapter_deserialize adapter \
			"($(parse_adapter_rec "$adapter_rec"))" || return 1

		adapters+=("$(concat_obj_values dr adapter)")
	done <<< "${adapter_table}"

	serialize_array adapters
}

find_enabled_dp_in_adapters()
{
	local -a adapters=()
	local -a dr_list
	local dr_desc
	local drs

	drs=$(get_domain_routes) || return 1
	array_init dr_list "($drs)" || return 1

	for dr_desc in "${dr_list[@]}"; do
		local -A dr=()
		local -a adapter_table=()
		local adapter_desc
		local -a adp_list=()
		local adapter_table

		domain_route_deserialize dr "($dr_desc)" || return 1

		adapter_table=$(get_adapters_for_domain_route \
			"${dr[$DR_DOMAIN]}" "${dr[$DR_ROUTE]}") || return 1

		array_init adp_list "($adapter_table)" || return 1

		for adapter_desc in "${adp_list[@]}"; do
			local -A adapter=()

			dradapter_deserialize adapter "$adapter_desc"

			[ "${adapter[$ADP_TYPE]}" != "$DP_IN_ADAPTER_TYPE" ] && continue
			[ "${adapter[$ADP_STATE]}" != "$DP_IN_ADAPTER_STATE_EN" ] && continue

			adapters+=("$(concat_obj_values dr adapter)")
		done
	done

	serialize_array adapters
}

validate_dra_part()
{
	local dra_part=$1
	local dra_value=$2

	valid_number "$dra_value" && return 0

	log_err "Invalid $dra_part in $TBT_DP_IN_ADAPTERS_CONF_NAME: \"$dra_value\" (expected an array of Domain:Route:AdapterID)"

	return 1
}

get_adapter()
{
	local domain=$1
	local route=$2
	local adapter_id=$3
	local -a adp_list
	local dradapter_desc

	array_init adp_list \
		"($(get_adapters_for_domain_route "$domain" "$route"))" || return 1

	for dradapter_desc in "${adp_list[@]}"; do
		local -A dradapter=()

		dradapter_deserialize dradapter "$dradapter_desc"

		if [ "${dradapter[$ADP_ID]}" = "$adapter_id" ]; then
			echo "$dradapter_desc"

			return 0
		fi
	done

	return 2
}

get_configured_dp_in_adapters()
{
	local -a adapters=()
	local adapter_rec

	[ ${#TBT_DP_IN_ADAPTERS[@]} -eq 0 ] && return 2

	for adapter_rec in "${TBT_DP_IN_ADAPTERS[@]}"; do
		local domain route adapter_id
		local adapter_desc
		local -A dr_adapter=()
		local dra
		local err=0

		IFS=: read -r domain route adapter_id <<< "$adapter_rec"

		validate_dra_part "domain" "$domain" || return 1
		validate_dra_part "route" "$route" || return 1
		validate_dra_part "adapter ID" "$adapter_id" || return 1

		dra="DRA:$domain:$route:$adapter_id"

		adapter_desc="$(get_adapter "$domain" "$route" "$adapter_id")" || err=$?
		if [ $err -eq 2 ]; then
			log_err "Can't find configured DP IN adapter at $dra"
			return 1
		elif [ $err -ne 0 ]; then
			return 1
		fi
		dradapter_deserialize dr_adapter "$adapter_desc"

		if [ "${dr_adapter[$ADP_TYPE]}" != "$DP_IN_ADAPTER_TYPE" ]; then
			log_err "The configured adapter at $dra is not a DP IN adapter"
			return 1
		fi

		if [ "${dr_adapter[$ADP_STATE]}" != "$DP_IN_ADAPTER_STATE_EN" ]; then
			log_err "The configured DP IN adapter at $dra is not enabled"
			return 1
		fi
		adapters+=("$(get_obj_values dr_adapter)")
	done

	[ ${#adapters[@]} -eq 0 ] && log_err "Parse error of $TBT_DP_IN_ADAPTERS_CONF"

	serialize_array adapters

	return 0
}
