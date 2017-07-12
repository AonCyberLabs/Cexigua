#!/bin/bash
source utils.sh
source readsyms.sh

PID=$1
PREPARE=${3}
PRELOAD=()
MAPS=/proc/${PID}/maps

MAPFILE=($(<${MAPS}))
for ((i=0; i<${#MAPFILE[@]}; i++)); do
	[[ ${MAPFILE[${i}]} = "[stack]" ]] && break
done
STACKRANGE=${MAPFILE[$((${i}-5))]}

IFS="-" read -r -a STACK <<< "${STACKRANGE}"
PAYLOADSIZE=$(($((16#${STACK[1]}))-$((16#${STACK[0]}))))

# all constant looking things are opcodes from here
# we get an offset and add it to the ASLR base in findgadget above
# we use two lines so we don't shell out, it lets us modify global variables

findgadget "$(printf "\x90\xc3")"
NOP=${gadgetaddr}

echo "NOP FOUND" >&2

source memfdcreate.sh
