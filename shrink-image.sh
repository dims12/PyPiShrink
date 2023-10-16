#!/bin/bash

set -x

CURRENT_DIR="$(pwd)"
SCRIPTNAME="${0##*/}"
MYNAME="${SCRIPTNAME%.*}"
LOGFILE="${CURRENT_DIR}/${SCRIPTNAME%.*}.log"


function info() {
	echo "$SCRIPTNAME: $1 ..."
}

function error() {
	echo -n "$SCRIPTNAME: ERROR occurred in line $1: "
	shift
	echo "$@"
}

function move_binary_data() {
    src="$1"
    dst="$2"
    length="$3"

    tmp1=$(mktemp)

    #dd iflag=skip_bytes,count_bytes skip=$start count="$length" if="$src" of="$tmp" status=progress
    dd iflag=skip_bytes,count_bytes,seek_bytes count="$dst" if="$IMG" of="$tmp" status=progress
    dd iflag=skip_bytes,count_bytes,seek_bytes skip="$src" seek="$dst" count="$length" if="$IMG" of="$tmp" status=progress
    dd iflag=skip_bytes,count_bytes,seek_bytes skip=$((src+length)) seek=$((src+length)) if="$IMG" of="$tmp" status=progress

    echo $tmp1

}

function mount_fragment() {
    start="$1"
    length="$2"

    loopback="$(losetup -f --show -o "$start" --sizelimit "$length" "$IMG")"

}


function check_filesystem() {
	
    fs="$1"
    
    info "Checking filesystem"
    e2fsck -pf "$fs"
	(( $? < 4 )) && return

	info "Filesystem error detected!"

	info "Trying to recover corrupted filesystem"
	e2fsck -y "$fs"
	(( $? < 4 )) && return

	error $LINENO "Filesystem recoveries failed. Giving up..."
	return 1
}

function get_partition_location() {

    local partno="$1"

    parted_output="$(parted -ms "$IMG" unit B print)"
    rc=$?
    if (( $rc )); then
        error $LINENO "parted failed with rc $rc"
        info "Possibly invalid image. Run 'parted $IMG unit B print' manually to investigate"
        return 1
    fi

    partstart="$(echo "$parted_output" | grep "^$partno:" | cut -d ':' -f 2 | tr -d 'B')"
    if [ -z $partstart ]; then
        info "No partition $partno found"
        return 1
    fi

    partend="$(echo "$parted_output" | grep "^$partno:" | cut -d ':' -f 3 | tr -d 'B')"
    partsize="$(echo "$parted_output" | grep "^$partno:" | cut -d ':' -f 4 | tr -d 'B')"
    if [ -z "$(parted -s "$IMG" unit B print | grep "$partstart" | grep logical)" ]; then
        parttype="primary"
    else
        parttype="logical"
    fi
}

function shrink_filesystem() {

    info "Computing filesystem size"

    tune2fs_output="$(tune2fs -l "$loopback")"
    rc=$?
    if (( $rc )); then
        echo "$tune2fs_output"
        error $LINENO "tune2fs failed. Unable to shrink this type of image"
        return 1
    fi

    currentsize="$(echo "$tune2fs_output" | grep '^Block count:' | tr -d ' ' | cut -d ':' -f 2)"
    blocksize="$(echo "$tune2fs_output" | grep '^Block size:' | tr -d ' ' | cut -d ':' -f 2)"

    check_filesystem $loopback

    if ! minsize=$(resize2fs -P "$loopback"); then
        rc=$?
        error $LINENO "resize2fs failed with rc $rc"
        return 1
    fi
    minsize=$(cut -d ':' -f 2 <<< "$minsize" | tr -d ' ')

    if [[ $currentsize -eq $minsize ]]; then
        error $LINENO "Image already shrunk to smallest size"
        return 1
    fi

    #Add some free space to the end of the filesystem
    extra_space=$(($currentsize - $minsize))
    for space in 5000 1000 100; do
        if [[ $extra_space -gt $space ]]; then
            minsize=$(($minsize + $space))
            break
        fi
    done

    #Shrink filesystem
    info "Shrinking filesystem"
    resize2fs -p "$loopback" $minsize
    rc=$?
    if (( $rc )); then
        error $LINENO "resize2fs failed with rc $rc"
        return 1
    fi
    sleep 1

}

shrink_partition() {
    
    partno="$1"
    info "Shrinking partition $partno"

    get_partition_location $partno
    if (( $? )); then
        error $LINENO "was unable to get partition location"
        return 1
    fi
    

    mount_fragment "$partstart" "$partsize"
    
    shrink_filesystem

    #Shrink partition
    partnewsize=$(($minsize * $blocksize))
    newpartend=$(($partstart + $partnewsize))

    parted -s -a minimal "$IMG" rm "$partno"
    rc=$?
    if (( $rc )); then
        error $LINENO "parted failed with rc $rc"
        return 1
    fi

    parted -s "$IMG" unit B mkpart "$parttype" "$partstart" "$newpartend"
    rc=$?
    if (( $rc )); then
        error $LINENO "parted failed with rc $rc"
        return 1
    fi

}

move_partition_after_previous_one() {
    
    local partno="$1"
    info "Moving partition $partno"

    prevpartno=$(($partno - 1))

    get_partition_location $prevpartno
    if (( $? )); then
        error $LINENO "was unable to get partition location"
        return 1
    fi

    prevpartstart="$partstart"
    prevpartend="$partend"
    prevpartsize="$partsize"

    get_partition_location $partno
    if (( $? )); then
        error $LINENO "was unable to get partition location"
        return 1
    fi

    newpartstart=$((prevpartend + 1))
    newpartend=$((newpartstart + partsize - 1))
    newpartsize="$partsize"

    parted -s -a minimal "$IMG" rm "$partno"
    rc=$?
    if (( $rc )); then
        error $LINENO "parted failed with rc $rc"
        return 1
    fi

    parted -s "$IMG" unit B mkpart "$parttype" "$newpartstart" "$newpartend"
    rc=$?
    if (( $rc )); then
        error $LINENO "parted failed with rc $rc"
        return 1
    fi

    tmp1=$(mktemp)

    #dd iflag=skip_bytes,count_bytes skip=$start count="$length" if="$src" of="$tmp" status=progress
    dd iflag=skip_bytes,count_bytes oflag=seek_bytes count="$newpartstart" if="$IMG" of="$tmp1" status=progress
    dd iflag=skip_bytes,count_bytes oflag=seek_bytes skip="$partstart" seek="$(stat -c %s $tmp1)" if="$IMG" of="$tmp1" status=progress

    mv $tmp1 $IMG

}

truncate_after_partition() {

    local partno="$1"
    info "Truncating after partition $partno"

    get_partition_location $partno
    if (( $? )); then
        error $LINENO "was unable to get partition location"
        return 1
    fi

    newlength=$(("$partend"+1))

    truncate -s "$newlength" "$IMG"

}

IMG="$1"
shrink_partition 2
move_partition_after_previous_one 3
shrink_partition 3
truncate_after_partition 3
