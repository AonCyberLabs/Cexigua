#!/bin/bash
shopt -s lastpipe # used for setting env vars in pipes to limit use of subshells
# https://en.wikipedia.org/wiki/Executable_and_Linkable_Format#File_header

PROGBITS=1
SYMTAB=2
STRTAB=3
DYNSYM=11

source utils.sh

readgeneric() {
	# file, offset, count, echo result
	file=""
	[[ "${1}" != "-" ]] && file="if=${1}"
	IFS=' ' data=($(dd ${file} skip=${2} count=${3} status=none bs=1 | tohex ${3}))

	# reverse to get the correct byte order
	rdata=""
	for ((x=${#data[@]}; x>=0; x--)); do
		rdata=${rdata}${data[${x}]}
	done

	if [[ ! -z ${4} ]]; then
		echo $((16#${rdata}))
	elif [[ ${3} -eq 2 ]]; then
		retshort=$((16#${rdata}))
	elif [[ ${3} -eq 4 ]]; then
		retint=$((16#${rdata}))
	elif [[ ${3} -eq 8 ]]; then
		retlong=$((16#${rdata}))
	else
		echo $((16#${rdata}))
	fi
}

readshort() {
	readgeneric ${1} ${2} 2 ${3}
}

readint() {
	readgeneric ${1} ${2} 4 ${3}
}

readlong() {
	readgeneric ${1} ${2} 8 ${3}
}

getsecstrtab() {
	# return a string from secstrtab
	skip=${1}
	secstr=(${shstrtab:${skip}})
	secstr=${secstr[0]}
}

getstrtab() {
	# return a string from strtab
	skip=${1}
	symstr=(${strtab:${skip}})
	symstr=${symstr[0]}
}

parsesect() {
	# return elements of section struct. name, type, offset and size
	# we are consuming now, so offsets are relevant to the start of the struct to begin
	# and then relative to wherever that element ends
	readint "-" 0
	sh_name=${retint}
	readint "-" 0
	sh_type=${retint}
	readlong "-" $((16#10))
	sh_offset=${retlong}
	readlong "-" 0
	sh_size=${retlong}
}

getsect() {
	LIB="${1}"
	# return offset and size from a section
	genlookup "${LIB}" false

	e_shoff=$(readlong ${LIB} $((16#28)) 1)      # start of the section header table
	e_shnum=$(readshort ${LIB} $((16#3C)) 1)     # number of section header entries
	e_shentsize=$(readshort ${LIB} $((16#3A)) 1) # section header table entry size
	e_shstrndx=$(readshort ${LIB} $((16#3E)) 1)  # index to section names section entry

	shstrtab_offset=$(readlong ${LIB} $((${e_shoff}+$((${e_shstrndx}*${e_shentsize}))+$((16#18)))) 1) # offset to shstrtab
	shstrtab_size=$(readlong ${LIB} $((${e_shoff}+$((${e_shstrndx}*${e_shentsize}))+$((16#20)))) 1) # size of shstrtab

	for ((i=0; i <= $((${e_shnum}-1)); i++)); do
		# read the whole struct in one so we thrash less
		dd if=${1} skip=$((${e_shoff}+$((${i}*${e_shentsize})))) count=$((16#28)) bs=1 status=none | parsesect

		if [[ ! -z "${3}" ]]; then # if a type is specified
			if [[ "${sh_type}" != "${3}" ]]; then # and it's not the same as the current sect
				continue # don't check the name
			fi
		fi

		getsecstrtab "$((${sh_name}+1))"
		if [[ "${secstr}" = "${2}" ]]; then
			echo "${sh_offset} ${sh_size}"
			break
		fi
	done
}

getstrsect() {
	unset strtab_offset strtab_size
	getsect "${1}" ".strtab" ${STRTAB} | read strtab_offset strtab_size
	if [[ ! -z "${strtab_offset}" && ! -z "${strtab_size}" ]]; then
		echo "${strtab_offset} ${strtab_size}"
	else
		getsect "${1}" ".dynstr" ${STRTAB}
	fi
}

getsymsect() {
	unset symtab_offset symtab_size
	getsect "${1}" ".symtab" ${SYMTAB} | read symtab_offset symtab_size
	if [[ ! -z "${symtab_offset}" && ! -z "${symtab_size}" ]]; then
		echo "${symtab_offset} ${symtab_size}"
	else
		getsect "${1}" ".dynsym" ${DYNSYM}
	fi
}

checksym() {
	# start at idx 0 for the first item
	readint "-" 0
	if [[ ${retint} -eq ${2} ]]; then
		symfound="0"
		return
	fi

	# then we jump to idx 20 for the rest of the items
	local i
	for ((i=0; i < $((${1}*24)); i+=24)); do
		readint "-" 20
		if [[ ${retint} -eq ${2} ]]; then
			# +1 for the read at idx 0
			symfound="$(($((${i}/24))+1))"
			break
		fi
	done
}

genlookup() {
	LIB=${1}

	e_shoff=$(readlong ${LIB} $((16#28)) 1)      # start of the section header table
	e_shnum=$(readshort ${LIB} $((16#3C)) 1)     # number of section header entries
	e_shentsize=$(readshort ${LIB} $((16#3A)) 1) # section header table entry size
	e_shstrndx=$(readshort ${LIB} $((16#3E)) 1)  # index to section names section entry

	shstrtab_offset=$(readlong ${LIB} $((${e_shoff}+$((${e_shstrndx}*${e_shentsize}))+$((16#18)))) 1) # offset to shstrtab
	shstrtab_size=$(readlong ${LIB} $((${e_shoff}+$((${e_shstrndx}*${e_shentsize}))+$((16#20)))) 1) # size of shstrtab

	# needs to be global
	shstrtab=
	while IFS= read -r -d '' sect; do
		shstrtab="${shstrtab} ${sect}"
	done < <(dd if=${LIB} skip=${shstrtab_offset} bs=1 count=${shstrtab_size} status=none)

	if [[ -z "${2}" ]]; then
		getstrsect "${LIB}" | IFS=' ' read strtab_offset strtab_size
		strtab=
		while IFS= read -r -d '' sect; do
			strtab="${strtab} ${sect}"
		done < <(dd if=${LIB} skip=${strtab_offset} bs=1 count=${strtab_size} status=none)
		strtab=${strtab:1} # remove the leading space
	fi
}

getsym() {
	# get the address of a symbol
	LIB="${1}"
	genlookup "${LIB}"

	getsymsect "${LIB}" | IFS=' ' read symtab_offset symtab_size
	poststrtab=${strtab%%${2} *}
	[[ "${poststrtab}" = "${strtab}" ]] && idx=-1 || idx=${#poststrtab}

	CHUNKSIZE=2048 # 2048*24 = 49,152 bytes

	# sizeof(elf64_sym) == 24
	for ((i=${symtab_offset}; i <= $((${symtab_offset}+${symtab_size})); i+=$((${CHUNKSIZE}*24)))); do
		dd if=${LIB} skip=${i} count=$((${CHUNKSIZE}*24)) bs=1 status=none | checksym ${CHUNKSIZE} ${idx}

		if [[ -n "${symfound}" ]]; then
			readint ${LIB} $((${i}+$((${symfound}*24))))
			getstrtab ${retint}
			if [[ "${symstr}" = "${2}" ]]; then
				readlong ${LIB}  $((${i}+$((${symfound}*24+8))))
				symaddr=$(printf '%x\n' ${retlong})
				break
			fi
		fi
	done
}
