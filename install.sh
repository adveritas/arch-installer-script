#!/bin/bash

# Check for proper permissions
if [ "$EUID" -ne 0 ]; then
	echo "This script must be run as root. Please use sudo or switch to the root user."
	exit 1
fi


# User input for disk
lsblk

read -p "Enter the disk to install Arch Linux on (e.g., /dev/sda or /dev/nvme0n1): " disk


# Check if drive exists
if [ ! -b "$disk" ]; then
	echo "Error: $disk does not exist. Please enter a valid disk."
	exit 1
fi


# Checker whether disk is NVME drive
if [[ "$disk" == *"nvme"* ]]; then
	part_prefix="p"
else
	part_prefix=""
fi


# Set partition variables
boot_partition="${disk}${part_prefix}1"

root_partition="${disk}${part_prefix}2"


# Confirm before wiping disk
read -p "WARNING: This will completely and irrevocably wipe the contents of $disk. Are you sure you want to continue? (y/n): " confirm

if [[ ! "$confirm" =~ ^[Yy](es)?$ ]]; then
	echo "Aborting. Disk will not be wiped."
	exit 1
fi

echo "Proceeding with installation to $disk..."


# Format selected disk
sgdisk -Z $disk

sgdisk -n1:0:+512M -t1:ef00 -c1:EFI -N2 -t2:8304 -c2:LINUXROOT $disk

mkfs.vfat -F32 -n EFI $boot_partition


# Begin BTRFS encryption setup
cryptsetup luksFormat --type luks2 $root_partition

cryptsetup luksOpen $root_partition linuxroot

mkfs.btrfs -f -L linuxroot /dev/mapper/linuxroot

mount /dev/mapper/linuxroot /mnt

btrfs subvolume create /mnt/@

btrfs subvolume create /mnt/@home

umount /mnt

mount -o subvol=@ /dev/mapper/linuxroot /mnt

mount --mkdir -o subvol=@home /dev/mapper/linuxroot /mnt/home

mount --mkdir $boot_partition /mnt/efi


# Begin installation with pacstrap
pacstrap -K /mnt base linux linux-firmware cryptsetup btrfs-progs networkmanager


# Get the UUID of the root partition (for LUKS decryption)
luks_uuid=$(blkid "$root_partition" | grep -oP 'UUID="\K[^"]+' | head -n 1)


# Get the UUID of the decrypted root partition
root_uuid=$(blkid /dev/mapper/linuxroot | grep -oP 'UUID="\K[^"]+')


# Check if both UUIDs were successfully retrieved
if [ -z "$luks_uuid" ] || [ -z "$root_uuid" ]; then
  echo "Error: Failed to retrieve UUIDs. Exiting."
  exit 1
fi


# Create the kernel command line
cmdline="luks.uuid=$luks_uuid root=UUID=$root_uuid rootflags=subvol=@ quiet rw"

echo "$cmdline" > /mnt/etc/kernel/cmdline


# Prepare EFI/UKI related settings
mkdir -p /mnt/efi/EFI/BOOT

sed -i 's/\budev\b/systemd/' /mnt/etc/mkinitcpio.conf

sed -i 's/keymap consolefont/sd-vconsole sd-encrypt/' /mnt/etc/mkinitcpio.conf

sed -i \
-e 's/^#ALL_config/ALL_config/' \
-e 's/^default_config/#default_config/' \
-e 's/^default_image/#default_image/' \
-e 's/^#default_options/default_options/' \
-e 's|^#default_uki.*|default_uki=/efi/EFI/BOOT/BOOTX64.EFI|' \
/mnt/etc/mkinitcpio.d/linux.preset

sed -i "s/'fallback'//" /mnt/etc/mkinitcpio.d/linux.preset


# Rebuild UKI
arch-chroot /mnt mkinitcpio -P


# Generate fstab
genfstab -U /mnt >> /mnt/etc/fstab


# Set root password
echo "Set root password: "

arch-chroot /mnt passwd


# Remove leftovers
rm /mnt/boot/initramfs-linux-fallback.img










