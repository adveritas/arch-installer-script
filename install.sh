#!/bin/bash


# Check for proper permissions
if [ "$EUID" -ne 0 ]; then
	echo "This script must be run as root. Please use sudo or switch to the root user."
	exit 1
fi


# Read configuration file
read -p "Enter the path to the configuration file (e.g., config.json): " config_file

# Check if the file exists
if [ ! -f "$config_file" ]; then
    echo "Error: $config_file does not exist."
    exit 1
fi


# Install jq to parse configuration
pacman -Sy
pacman -S --needed --noconfirm jq


# Assign configuration variables
disk=$(jq -r '.disk' "$config_file")
hostname=$(jq -r '.hostname' "$config_file")
timezone=$(jq -r '.timezone' "$config_file")
locale=$(jq -r '.locale' "$config_file")
networking=$(jq -r '.networking' "$config_file")
root_pass_hash=$(jq -r '.root_pass_hash' "$config_file")
users=$(jq -r '.users' "$config_file")
pacman=$(jq -r '.pacman' "$config_file")
packages=$(jq -r '.packages[]' "$config_file")
services=$(jq -r '.services[]' "$config_file")


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
pacstrap -K /mnt base linux linux-firmware cryptsetup btrfs-progs


# Generate fstab
genfstab -U /mnt >> /mnt/etc/fstab


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


# Remove leftovers
rm /mnt/boot/initramfs-linux-fallback.img


# Set the hostname
echo "Setting the hostname to $hostname..."
arch-chroot /mnt echo "$hostname" > /etc/hostname


# Set the time zone
echo "Setting the time zone to $timezone..."
arch-chroot /mnt ln -sf /usr/share/zoneinfo/$timezone /etc/localtime
arch-chroot /mnt hwclock --systohc


# Set the locale
echo "Setting the locale to $locale..."
arch-chroot /mnt sed -i "s/^#$locale/$locale/" /etc/locale.gen
arch-chroot /mnt locale-gen
arch-chroot /mnt echo "LANG=$locale" > /etc/locale.conf


# Set root password
echo "root:$root_pass_hash" | arch-chroot /mnt chpasswd -e


# Create users from the JSON file
for user in $(echo "$users" | jq -r '.[] | @base64'); do
    _jq() {
        echo ${user} | base64 --decode | jq -r ${1}
    }

    username=$(_jq '.username')
    password_hash=$(_jq '.password_hash')
    sudo=$(_jq '.sudo')

    echo "Creating user $username..."
    arch-chroot /mnt useradd -m "$username"

    # Set the password using the hashed password from the JSON file
    arch-chroot /mnt echo "$username:$password_hash" | chpasswd -e

    # Grant sudo access if specified in the JSON
    if [ "$sudo" == "true" ]; then
        arch-chroot /mnt mkdir -p /etc/sudoers.d
		arch-chroot /mnt echo "%wheel ALL=(ALL) ALL" > /etc/sudoers.d/wheel

		arch-chroot /mnt pacman -S --needed --noconfirm sudo
        arch-chroot /mnt usermod -aG wheel $username
    fi
done


# Pacman configuration
if [ "$(echo "$pacman" | jq -r '.tweaks')" == "true" ]; then
    echo -e "Adding extra spice to pacman..."

    arch-chroot /mnt cp /etc/pacman.conf /etc/pacman.conf.back
    arch-chroot /mnt sed -i '/^#Color/c\Color\nILoveCandy' /etc/pacman.conf
    arch-chroot /mnt sed -i '/^#ParallelDownloads/c\ParallelDownloads = 5' /etc/pacman.conf
    arch-chroot /mnt sed -i '/^#\[multilib\]/,+1 s/^#//' /etc/pacman.conf

    arch-chroot /mnt pacman -Syyu
    arch-chroot /mnt pacman -Fy
fi


# Check if AUR is enabled and install helper
if [ "$(echo "$pacman" | jq -r '.aur')" == "true" ]; then
    aur_helper=$(echo "$pacman" | jq -r '.helper')
    pacman -S --needed --noconfirm base-devel

    if [[ -n "$aur_helper" && "$aur_helper" != "null" ]]; then
        echo "Installing AUR helper: $aur_helper"

     #install here

        echo "$aur_helper installation complete!"
    else
        echo "No AUR helper specified. Skipping..."
    fi
else
    echo "AUR is disabled. Skipping..."
fi


# Packages
if [[ -n "$packages" ]]; then
    echo "Installing packages: $packages"
    arch-chroot /mnt pacman -S --needed --noconfirm $packages
else
    echo "No packages to install."
fi


# Enable Services
if [[ -n "$services" ]]; then
    echo "Enabling services: $services"
    for service in $services; do
        arch-chroot /mnt systemctl enable "$service"
    done
else
    echo "No services to enable."
fi


# Networking
if [[ "$networking" == "iwd" ]]; then
    echo "Configuring iwd networking..."
    arch-chroot /mnt pacman -S --needed --noconfirm iwd
    arch-chroot /mnt systemctl enable iwd systemd-resolved
    arch-chroot /mnt systemctl mask systemd-networkd

elif [[ "$networking" == "nm" ]]; then
    echo "Configuring NetworkManager networking..."
    arch-chroot /mnt pacman -S --needed --noconfirm networkmanager
    arch-chroot /mnt systemctl enable NetworkManager systemd-resolved
    arch-chroot /mnt systemctl mask systemd-networkd

else
    echo "Default networking setup requested. No changes made."
fi














