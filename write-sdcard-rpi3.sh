#!/bin/bash

function version_gt() { test "$(echo "$@" | tr " " "\n" | sort -V | head -n 1)" != "$1"; }

# Format an SD card for AOSP on RPi3
KERNELDIR=kernel/rpi
# KERNELDIR=android_kernel_brcm_rpi3

if [ -z ${ANDROID_PRODUCT_OUT} ]; then
	echo "You must run lunch first"
	exit 1
fi

if [ $# -ne 1 ]; then
        echo "Usage: $0 [drive]"
        echo "       drive is 'sdb', 'mmcblk0'"
        exit 1
fi

DRIVE=$1

if [ -z ${TARGET_PRODUCT} ]; then
	echo "Please run 'lunch' first"
	exit
fi

# Check the drive exists in /sys/block
if [ ! -e /sys/block/${DRIVE}/size ]; then
	echo "Drive does not exist"
	exit 1
fi

# Check it is a flash drive (size < 32MiB)
NUM_SECTORS=`cat /sys/block/${DRIVE}/size`
if [ $NUM_SECTORS -eq 0 -o $NUM_SECTORS -gt 64000000 ]; then
	echo "Does not look like an SD card, bailing out"
	exit 1
fi

# Unmount any partitions that have been automounted
if [ $DRIVE == "mmcblk0" ]; then
	sudo umount /dev/${DRIVE}*
	BOOT_PART=/dev/${DRIVE}p1
	SYSTEM_PART=/dev/${DRIVE}p3
	VENDOR_PART=/dev/${DRIVE}p4
	USER_PART=/dev/${DRIVE}p5
else
	sudo umount /dev/${DRIVE}[1-9]
	BOOT_PART=/dev/${DRIVE}1
	SYSTEM_PART=/dev/${DRIVE}3
	VENDOR_PART=/dev/${DRIVE}4
	USER_PART=/dev/${DRIVE}5
fi

sleep 2

echo "Zap existing partition tables"
sudo sgdisk --zap-all /dev/${DRIVE}
# Ignore errors here: sgdisk fails if the GPT is damaged *before* erasing it
# if [ $? -ne 0 ]; then echo "Error: sgdisk"; exit 1; fi

# Create 5 partitions
# 1   64 MiB  boot
# 2   64 MiB  frp
# 3 1024 MiB  system
# 4  256 MiB  vendor
# 5  512 MiB  userdata

echo "Writing GPT"
sudo gdisk /dev/${DRIVE} << EOF 2>&1 > /dev/null
n
1

+64M

c
boot
n
2

+64M

c
2
frp
n
3

+1024M

c
3
system
n
4

+256M

c
4
vendor
n
5

+512M

c
5
userdata
w
y
EOF
if [ $? -ne 0 ]; then echo "Error: gdisk"; exit 1; fi

echo "Writing MBR"
sudo gdisk /dev/${DRIVE} << EOF 2>&1 > /dev/null
r
h
1
N
06
Y
N
w
y
EOF
if [ $? -ne 0 ]; then echo "Error: gdisk"; exit 1; fi

# Format p1 with FAT32
sudo mkfs.vfat -F 16 -n boot ${BOOT_PART}
if [ $? -ne 0 ]; then echo "Error: mkfs.vfat"; exit 1; fi


# Copy boot files
echo "Mounting $BOOT_PART"
sudo mount ${BOOT_PART} /mnt
if [ $? != 0 ]; then echo "ERROR"; exit; fi

sudo mkimage -A arm -T script -O linux -d ${ANDROID_BUILD_TOP}/device/rpiorg/rpi3/boot/boot.scr.txt /mnt/boot.scr
if [ $? != 0 ]; then echo "ERROR"; exit; fi

sudo cp ${ANDROID_BUILD_TOP}/u-boot/u-boot.bin /mnt
if [ $? != 0 ]; then echo "ERROR"; exit; fi

sudo cp ${ANDROID_BUILD_TOP}/device/rpiorg/rpi3/boot/* /mnt
if [ $? != 0 ]; then echo "ERROR"; exit; fi

sudo cp ${ANDROID_PRODUCT_OUT}/boot.img /mnt
if [ $? != 0 ]; then echo "ERROR"; exit; fi

sudo cp ${ANDROID_BUILD_TOP}/${KERNELDIR}/arch/arm/boot/dts/*.dtb /mnt
if [ $? != 0 ]; then echo "ERROR"; exit; fi

sudo mkdir /mnt/overlays

sudo cp ${ANDROID_BUILD_TOP}/${KERNELDIR}/arch/arm/boot/dts/overlays/*.dtbo /mnt/overlays
if [ $? != 0 ]; then echo "ERROR"; exit; fi

sync
sudo umount /mnt

# Create bmap files
bmaptool create -o ${ANDROID_PRODUCT_OUT}/system.img.bmap ${ANDROID_PRODUCT_OUT}/system.img
bmaptool create -o ${ANDROID_PRODUCT_OUT}/userdata.img.bmap ${ANDROID_PRODUCT_OUT}/userdata.img
bmaptool create -o ${ANDROID_PRODUCT_OUT}/vendor.img.bmap ${ANDROID_PRODUCT_OUT}/vendor.img

# Copy disk images
echo "Writing system"
sudo bmaptool copy ${ANDROID_PRODUCT_OUT}/system.img ${SYSTEM_PART}
#sudo dd if=${ANDROID_PRODUCT_OUT}/system.img of=$SYSTEM_PART bs=1M
if [ $? != 0 ]; then echo "ERROR"; exit; fi
sudo e2label $SYSTEM_PART system
echo "Writing vendor"
sudo bmaptool copy ${ANDROID_PRODUCT_OUT}/vendor.img ${VENDOR_PART}
#sudo dd if=${ANDROID_PRODUCT_OUT}/vendor.img of=$VENDOR_PART bs=1M
if [ $? != 0 ]; then echo "ERROR"; exit; fi
sudo e2label $VENDOR_PART vendor
echo "Writing userdata"
sudo bmaptool copy ${ANDROID_PRODUCT_OUT}/userdata.img ${USER_PART}
#sudo dd if=${ANDROID_PRODUCT_OUT}/userdata.img of=$USER_PART bs=1M
if [ $? != 0 ]; then echo "ERROR"; exit; fi
sudo e2label $USER_PART userdata

echo "Copying updated ld.config"
sudo mount ${SYSTEM_PART} /mnt
sudo cp ${ANDROID_BUILD_TOP}/device/rpiorg/rpi3/ld.config.29.txt-hacked /mnt/system/etc/ld.config.29.txt
sync
sudo umount /mnt

# Also put a copy in $OUT so that adb sync doesn't overwrite it
cp ${ANDROID_BUILD_TOP}/device/rpiorg/rpi3/ld.config.29.txt-hacked $OUT/system/etc/ld.config.29.txt

echo "SUCCESS! Andrdoid4RPi installed on the uSD card. Enjoy"

exit 0

