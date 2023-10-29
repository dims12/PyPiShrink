# PyPiShrink

Python script to make Raspberry Pi (and other?) image files smaller

Inspired by [PiShrink](https://github.com/Drewsif/PiShrink) but written in Python

As an original shell script, this script just automates running commands like

* `parted`
* `e2fsck`
* `resize2fs`
* `tune2fs`
* `losetup`

These tools should be installed. User should have `sudo` permissions.

Not all features of an original script are implemented. But this script also can shrink image with more than two 
partitions. It can move resized partitions what original script can't do.  