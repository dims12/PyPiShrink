#!/bin/bash

version="v0.1.2 patched for Microart"

CURRENT_DIR="$(pwd)"
SCRIPTNAME="${0##*/}"
MYNAME="${SCRIPTNAME%.*}"
LOGFILE="${CURRENT_DIR}/${SCRIPTNAME%.*}.log"
REQUIRED_TOOLS="parted losetup tune2fs md5sum e2fsck resize2fs"
ZIPTOOLS=("gzip xz")
declare -A ZIP_PARALLEL_TOOL=( [gzip]="pigz" [xz]="xz" ) # parallel zip tool to use in parallel mode
declare -A ZIP_PARALLEL_OPTIONS=( [gzip]="-f9" [xz]="-T0" ) # options for zip tools in parallel mode
declare -A ZIPEXTENSIONS=( [gzip]="gz" [xz]="xz" ) # extensions of zipped files

function info() {
	echo "$SCRIPTNAME: $1 ..."
}

function error() {
	echo -n "$SCRIPTNAME: ERROR occurred in line $1: "
	shift
	echo "$@"
}

function cleanup() {
	if losetup "$loopback" &>/dev/null; then
		losetup -d "$loopback"
	fi
	if [ "$debug" = true ]; then
		local old_owner=$(stat -c %u:%g "$src")
		chown "$old_owner" "$LOGFILE"
	fi

}

function logVariables() {
	if [ "$debug" = true ]; then
		echo "Line $1" >> "$LOGFILE"
		shift
		local v var
		for var in "$@"; do
			eval "v=\$$var"
			echo "$var: $v" >> "$LOGFILE"
		done
	fi
}

function checkFilesystem() {
	info "Checking filesystem"
	e2fsck -pf "$loopback"
	(( $? < 4 )) && return

	info "Filesystem error detected!"

	info "Trying to recover corrupted filesystem"
	e2fsck -y "$loopback"
	(( $? < 4 )) && return

if [[ $repair == true ]]; then
	info "Trying to recover corrupted filesystem - Phase 2"
	e2fsck -fy -b 32768 "$loopback"
	(( $? < 4 )) && return
fi
	error $LINENO "Filesystem recoveries failed. Giving up..."
	exit 9

}

help() {
	local help
	read -r -d '' help << EOM
Usage: $0 [-adhrspvzZ] imagefile.img [newimagefile.img]

  -s         Don't expand filesystem when image is booted the first time
  -v         Be verbose
  -r         Use advanced filesystem repair option if the normal one fails
  -z         Compress image after shrinking with gzip
  -Z         Compress image after shrinking with xz
  -a         Compress image in parallel using multiple cores
  -p         Remove logs, apt archives, dhcp leases and ssh hostkeys
  -d         Write debug messages in a debug log file
EOM
	echo "$help"
	exit 1
}

debug=false
repair=false
parallel=false
verbose=false
prep=false
ziptool=""

while getopts ":adhprsvzZ" opt; do
  case "${opt}" in
    a) parallel=true;;
    d) debug=true;;
    h) help;;
    p) prep=true;;
    r) repair=true;;
    v) verbose=true;;
    z) ziptool="gzip";;
    Z) ziptool="xz";;
    *) help;;
  esac
done
shift $((OPTIND-1))

if [ "$debug" = true ]; then
	info "Creating log file $LOGFILE"
	rm "$LOGFILE" &>/dev/null
	exec 1> >(stdbuf -i0 -o0 -e0 tee -a "$LOGFILE" >&1)
	exec 2> >(stdbuf -i0 -o0 -e0 tee -a "$LOGFILE" >&2)
fi

echo "${0##*/} $version"

#Args
src="$1"
img="$1"

#Usage checks
if [[ -z "$img" ]]; then
  help
fi

if [[ ! -f "$img" ]]; then
  error $LINENO "$img is not a file..."
  exit 2
fi
if (( EUID != 0 )); then
  error $LINENO "You need to be running as root."
  exit 3
fi

# set locale to POSIX(English) temporarily
# these locale settings only affect the script and its sub processes

export LANGUAGE=POSIX
export LC_ALL=POSIX
export LANG=POSIX


# check selected compression tool is supported and installed
if [[ -n $ziptool ]]; then
	if [[ ! " ${ZIPTOOLS[@]} " =~ $ziptool ]]; then
		error $LINENO "$ziptool is an unsupported ziptool."
		exit 17
	else
		if [[ $parallel == true && $ziptool == "gzip" ]]; then
			REQUIRED_TOOLS="$REQUIRED_TOOLS pigz"
		else
			REQUIRED_TOOLS="$REQUIRED_TOOLS $ziptool"
		fi
	fi
fi

#Check that what we need is installed
for command in $REQUIRED_TOOLS; do
  command -v $command >/dev/null 2>&1
  if (( $? != 0 )); then
    error $LINENO "$command is not installed."
    exit 4
  fi
done

#Copy to new file if requested
if [ -n "$2" ]; then
  f="$2"
  if [[ -n $ziptool && "${f##*.}" == "${ZIPEXTENSIONS[$ziptool]}" ]]; then	# remove zip extension if zip requested because zip tool will complain about extension
    f="${f%.*}"
  fi
  info "Copying $1 to $f..."
  cp --reflink=auto --sparse=always "$1" "$f"
  if (( $? != 0 )); then
    error $LINENO "Could not copy file..."
    exit 5
  fi
  old_owner=$(stat -c %u:%g "$1")
  chown "$old_owner" "$f"
  img="$f"
fi

# cleanup at script exit
trap cleanup EXIT

#Gather info
info "Gathering data"
beforesize="$(ls -lh "$img" | cut -d ' ' -f 5)"
parted_output="$(parted -ms "$img" unit B print)"
rc=$?
if (( $rc )); then
	error $LINENO "parted failed with rc $rc"
	info "Possibly invalid image. Run 'parted $img unit B print' manually to investigate"
	exit 6
fi

partnum=2

partstart="$(echo "$parted_output" | grep "^$partnum:" | cut -d ':' -f 2 | tr -d 'B')"
oldpartend="$(echo "$parted_output" | grep "^$partnum:" | cut -d ':' -f 3 | tr -d 'B')"
partsize="$(echo "$parted_output" | grep "^$partnum:" | cut -d ':' -f 4 | tr -d 'B')"
if [ -z "$(parted -s "$img" unit B print | grep "$partstart" | grep logical)" ]; then
    parttype="primary"
else
    parttype="logical"
fi
loopback="$(losetup -f --show -o "$partstart" --sizelimit "$partsize" "$img")"
tune2fs_output="$(tune2fs -l "$loopback")"
rc=$?
if (( $rc )); then
    echo "$tune2fs_output"
    error $LINENO "tune2fs failed. Unable to shrink this type of image"
    exit 7
fi

currentsize="$(echo "$tune2fs_output" | grep '^Block count:' | tr -d ' ' | cut -d ':' -f 2)"
blocksize="$(echo "$tune2fs_output" | grep '^Block size:' | tr -d ' ' | cut -d ':' -f 2)"

logVariables $LINENO beforesize parted_output partnum partstart oldpartend parttype tune2fs_output currentsize blocksize

if [[ $prep == true ]]; then
  info "Syspreping: Removing logs, apt archives, dhcp leases and ssh hostkeys"
  mountdir=$(mktemp -d)
  mount "$loopback" "$mountdir"
  rm -rvf $mountdir/var/cache/apt/archives/* $mountdir/var/lib/dhcpcd5/* $mountdir/var/log/* $mountdir/var/tmp/* $mountdir/tmp/* $mountdir/etc/ssh/*_host_*
  umount "$mountdir"
fi


#Make sure filesystem is ok
checkFilesystem

if ! minsize=$(resize2fs -P "$loopback"); then
	rc=$?
	error $LINENO "resize2fs failed with rc $rc"
	exit 10
fi
minsize=$(cut -d ':' -f 2 <<< "$minsize" | tr -d ' ')
logVariables $LINENO currentsize minsize
if [[ $currentsize -eq $minsize ]]; then
  error $LINENO "Image already shrunk to smallest size"
  exit 11
fi

#Add some free space to the end of the filesystem
extra_space=$(($currentsize - $minsize))
logVariables $LINENO extra_space
for space in 5000 1000 100; do
  if [[ $extra_space -gt $space ]]; then
    minsize=$(($minsize + $space))
    break
  fi
done
logVariables $LINENO minsize

#Shrink filesystem
info "Shrinking filesystem"
resize2fs -p "$loopback" $minsize
rc=$?
if (( $rc )); then
  error $LINENO "resize2fs failed with rc $rc"
  mount "$loopback" "$mountdir"
  mv "$mountdir/etc/rc.local.bak" "$mountdir/etc/rc.local"
  umount "$mountdir"
  losetup -d "$loopback"
  exit 12
fi
sleep 1

#Shrink partition
partnewsize=$(($minsize * $blocksize))
newpartend=$(($partstart + $partnewsize))
logVariables $LINENO partnewsize newpartend
parted -s -a minimal "$img" rm "$partnum"
rc=$?
if (( $rc )); then
	error $LINENO "parted failed with rc $rc"
	exit 13
fi

parted -s "$img" unit B mkpart "$parttype" "$partstart" "$newpartend"
rc=$?
if (( $rc )); then
	error $LINENO "parted failed with rc $rc"
	exit 14
fi

#Truncate the file
info "Shrinking image"

endresult=$(parted -ms "$img" unit B print free)
rc=$?
if (( $rc )); then
	error $LINENO "parted failed with rc $rc"
	exit 15
fi
logVariables $LINENO endresult

exit 0


endresult=$(grep "^$partnum:" <<< "$endresult" | cut -d ':' -f 2 | tr -d 'B')
tailstart=$((oldpartend + 1))
logVariables $LINENO endresult tailstart
rm -f tail.bin
dd if="$img" of=tail.bin bs=$tailstart skip=1 status=progress
rc=$?
if (( $rc )); then
	error $LINENO "dd failed with rc $rc"
	exit 16
fi

truncate -s "$endresult" "$img"
rc=$?
if (( $rc )); then
	error $LINENO "trunate failed with rc $rc"
	exit 16
fi

cat tail.bin >> "$img"
rc=$?
if (( $rc )); then
	error $LINENO "cat failed with rc $rc"
	exit 16
fi

# handle compression
if [[ -n $ziptool ]]; then
	options=""
	envVarname="${MYNAME^^}_${ziptool^^}" # PISHRINK_GZIP or PISHRINK_XZ environment variables allow to override all options for gzip or xz
	[[ $parallel == true ]] && options="${ZIP_PARALLEL_OPTIONS[$ziptool]}"
	[[ -v $envVarname ]] && options="${!envVarname}" # if environment variable defined use these options
	[[ $verbose == true ]] && options="$options -v" # add verbose flag if requested

	if [[ $parallel == true ]]; then
		parallel_tool="${ZIP_PARALLEL_TOOL[$ziptool]}"
		info "Using $parallel_tool on the shrunk image"
		if ! $parallel_tool ${options} "$img"; then
			rc=$?
			error $LINENO "$parallel_tool failed with rc $rc"
			exit 18
		fi

	else # sequential
		info "Using $ziptool on the shrunk image"
		if ! $ziptool ${options} "$img"; then
			rc=$?
			error $LINENO "$ziptool failed with rc $rc"
			exit 19
		fi
	fi
	img=$img.${ZIPEXTENSIONS[$ziptool]}
fi

aftersize=$(ls -lh "$img" | cut -d ' ' -f 5)
logVariables $LINENO aftersize

info "Shrunk $img from $beforesize to $aftersize"