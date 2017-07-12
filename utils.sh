declare -A hex
for ((j=1; j < 256; j++)); do
	# we can't set \0 or \x0a in an array, so skip those, and we can check for them later. all other bytes are ok
	[[ $j -eq 10 ]] && continue
	hex[$(echo -ne "\\x$(printf '%x' ${j})")]=${j}
done

tohex() {
	# basically 'od', convert \x01\x02\x03 to 01 02 03
	local i
	for ((i=${1}; i > 0; i--)); do
		# above maybe 7b? we accidentally read 2 bytes, so disable unicode
		LC_ALL=C IFS= read -n 1 -d '' -r c
		if [[ -z "$c" ]]; then
			# null byte
			echo -n "00 "
		else
			hexc=${hex[${c}]}
			if [[ ! -z "${hexc}" ]]; then
					printf '%02x ' "${hexc}"
			else
					printf '%02x ' 10
			fi
		fi
	done
}

hexlify() {
	x=$(printf "%016x" ${1})
	echo -n "\\x${x:14:2}\\x${x:12:2}\\x${x:10:2}\\x${x:8:2}\\x${x:6:2}\\x${x:4:2}\\x${x:2:2}\\x${x:0:2}"
}

write() {
	printf -- $1 >> $2
}

filesize() {
	IFS=+ FILESIZE=($(dd if=${1} of=/dev/null bs=1 2>&1))
	FILESIZE=${FILESIZE[0]}
	IFS=
}

getbase() {
	IFS=- read -a addrs <<< $1
	echo ${addrs[0]}
}

findregion() {
	IFS=$'\n ' MAPFILE=($(<${MAPS}))
	# start at 4 because 0 wont be equal to the region name
	# so we can just skip it
	for ((i=4; i<${#MAPFILE[@]}; i++)); do
		[[ ${MAPFILE[${i}]} = *${1}* && ${MAPFILE[$((${i}-4))]} ]] && break
	done
	BASE=$(getbase ${MAPFILE[$((${i}-5))]})
}

getlibs() {
	IFS=$'\n' MAPFILE=($(<${MAPS}))
	LIBS=()
	for MAP in ${MAPFILE[@]}; do
		IFS=' ' MAPLINE=(${MAP})
		if [[ "${MAPLINE[1]}" = "r-xp" && "${MAPLINE[5]}" = /* ]]; then
			LIBS+=("${MAPLINE[5]}")
		fi
	done
	echo ${LIBS[@]}
}

getlibc() {
	getlibs | IFS=' ' read -a LIBS
	for ((i=0; i < ${#LIBS[@]}; i++)); do
		if [[ "${LIBS[${i}]}" = */libc-* ]]; then
			echo "${LIBS[${i}]}"
			return
		fi
	done
}

findgadget() {
	getlibs | read -a LIBS

	# eval splits up the LIBS as args
	# if we don't find one, try to find something in /usr/lib/* and LD_PRELOAD

	# unfortunately, this doesn't account for sections in the binary
	# we need to, because right now i'm getting gadgets in .data which isn't exec'able
	# we can easily get the offset/size of .text using getsect, but grep doesn't have an option for it

	matches=()
	match=()
	eval grep -Fao --byte-offset "$1" ${LIBS[@]} | grep -o "^[^:]*:[^:]*" | IFS=$'\n' read -a matches
	for match in ${matches[@]}; do
		IFS=: match=(${match})
		getsect "${match[0]}" ".text" ${PROGBITS} | IFS=' ' read textaddr textsize

		if [[ ${match[1]} -gt ${textaddr} && ${match[1]} -lt $((${textaddr}+${textsize})) ]]; then
			break
		fi
	done

	# 0 is file
	# 1 is offset
	if [[ -z "${match[0]}" || -z "${match[1]}" ]]; then
		matches=()
		match=()
		eval grep -Fao --byte-offset "$1" /usr/lib/* 2>/dev/null | grep -o "^[^:]*:[^:]*" | while read match; do
			IFS=: match=(${match})
			getsect "${match[0]}" ".text" ${PROGBITS} | IFS=' ' read textaddr textsize

			if [[ ${match[1]} -gt ${textaddr} && ${match[1]} -lt $((${textaddr}+${textsize})) ]]; then
				break
			fi
		done
		if [[ -z "${match[0]}" ]]; then
			exit 1
		else
			[[ "${PRELOAD[@]}" = *${match[0]}* ]] || PRELOAD+=("${match[0]}")
		fi

		return
	fi

	findregion ${match[0]}
	gadgetaddr=$(hexlify $(($((16#${BASE}))+${match[1]})))
}

relocatelibc() {
	findregion "libc-"
	hexlify $(($((16#${BASE}))+$((16#${1}))))
}


fnargs() {
	SYSCALLSIZE=0
	SYSCALL=

	findgadget "$(printf "\x58\xc3")"                    # pop rax ; ret
	SYSCALL=${SYSCALL}${gadgetaddr}
	# when we're called from pltcall, this is already a valid address string
	# otherwise we need to encode it, because it's a syscall id
	if [[ ${1} = \\x* ]]; then
		SYSCALL=${SYSCALL}${1}
	else
		SYSCALL=${SYSCALL}$(hexlify ${1})
	fi
	shift
	SYSCALLSIZE=$((${SYSCALLSIZE}+2))
	[[ -z ${1} ]] && return

	findgadget "$(printf "\x5f\xc3")"                    # pop rdi ; ret
	SYSCALL=${SYSCALL}${gadgetaddr}
	SYSCALL=${SYSCALL}$(hexlify ${1})
	shift
	SYSCALLSIZE=$((${SYSCALLSIZE}+2))
	[[ -z ${1} ]] && return

	findgadget "$(printf "\x5e\xc3")"                    # pop rsi ; ret
	SYSCALL=${SYSCALL}${gadgetaddr}
	SYSCALL=${SYSCALL}$(hexlify ${1})
	shift
	SYSCALLSIZE=$((${SYSCALLSIZE}+2))
	[[ -z ${1} ]] && return

	findgadget "$(printf "\x5a\xc3")"                    # pop rdx ; ret
	SYSCALL=${SYSCALL}${gadgetaddr}
	SYSCALL=${SYSCALL}$(hexlify ${1})
	shift
	SYSCALLSIZE=$((${SYSCALLSIZE}+2))
	[[ -z ${1} ]] && return

	findgadget "$(printf "\x59\xc3")"                    # pop rcx ; ret
	SYSCALL=${SYSCALL}${gadgetaddr}
	SYSCALL=${SYSCALL}$(hexlify ${1})
	shift
	SYSCALLSIZE=$((${SYSCALLSIZE}+2))
	[[ -z ${1} ]] && return

	findgadget "$(printf "\xff\xd0\xc3")"                # pop r8 ; ret
	SYSCALL=${SYSCALL}${gadgetaddr}
	SYSCALL=${SYSCALL}$(hexlify ${1})
	shift
	SYSCALLSIZE=$((${SYSCALLSIZE}+2))
	[[ -z ${1} ]] && return

	findgadget "$(printf "\xff\xd1\xc3")"                # pop r9 ; ret
	SYSCALL=${SYSCALL}${gadgetaddr}
	SYSCALL=${SYSCALL}$(hexlify ${1})
	shift
	SYSCALLSIZE=$((${SYSCALLSIZE}+2))
	[[ -z ${1} ]] && return
}

# execute a syscall in the ROPChain, with all arguments setup appropriately
syscall() {
	fnargs $@
	findgadget "$(printf "\x0f\x05\xc3")"                # syscall ; ret
	SYSCALL=${SYSCALL}${gadgetaddr}
	SYSCALLSIZE=$((${SYSCALLSIZE}+1))

	# global management
	SLEDLEN=$((${SLEDLEN}-${SYSCALLSIZE}))
	SYSCALLS+=(${SYSCALL})
}

# execute a libc call in the ROPChain, with all arguments setup appropriately
pltcall() {
	[[ -z ${LIBC} ]] && getlibc | read LIBC
	ARGS=($@)
	# if we're preparing, we don't want to search for a function which is SLOW
	# we know libc functions will be present
	if [[ "${PREPARE}" = "PREPARE" ]]; then
		SYM=0
	else
		getsym ${LIBC} ${ARGS[0]}
		SYM=$(relocatelibc ${symaddr})
	fi
	fnargs ${SYM} ${ARGS[@]:1}

	findgadget "$(printf "\xff\xe0")"                   # jmp rax
	SYSCALL=${SYSCALL}${gadgetaddr}
	SYSCALLSIZE=$((${SYSCALLSIZE}+1))

	# global management
	SLEDLEN=$((${SLEDLEN}-${SYSCALLSIZE}))
	SYSCALLS+=(${SYSCALL})
}
