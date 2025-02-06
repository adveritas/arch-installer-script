#!/bin/bash


# Check for proper permissions
if [ "$EUID" -ne 0 ]; then
    echo "This script must be run as root. Please use sudo or switch to the root user."
    exit 1
fi


# Check if jq is installed
if ! command -v jq &> /dev/null; then
    echo "jq is required to parse the JSON configuration file. Installing jq..."
    pacman -S --noconfirm jq
fi


# Read configuration file
read -p "Enter the path to the configuration file (e.g., config.json): " config_file

# Check if the file exists
if [ ! -f "$config_file" ]; then
    echo "Error: $config_file does not exist."
    exit 1
fi


# Read values from the JSON file
hostname=$(jq -r '.hostname' "$config_file")
timezone=$(jq -r '.timezone' "$config_file")
locale=$(jq -r '.locale' "$config_file")
users=$(jq -r '.users' "$config_file")
packages=$(jq -r '.packages' "$config_file")
services=$(jq -r '.services' "$config_file")
aur=$(jq -r '.aur' "$config_file")


# Set the hostname
echo "Setting the hostname to $hostname..."
echo "$hostname" > /etc/hostname


# Set the time zone
echo "Setting the time zone to $timezone..."
ln -sf /usr/share/zoneinfo/$timezone /etc/localtime
hwclock --systohc


# Set the locale
echo "Setting the locale to $locale..."
sed -i "s/^#$locale/$locale/" /etc/locale.gen
locale-gen
echo "LANG=$locale" > /etc/locale.conf


# Enable wheel permissions
mkdir /etc/sudoers.d
echo "%wheel ALL=(ALL) ALL" > /etc/sudoers.d/wheel

# Create users from the JSON file
for user in $(echo "$users" | jq -r '.[] | @base64'); do
    _jq() {
        echo ${user} | base64 --decode | jq -r ${1}
    }

    username=$(_jq '.username')
    password_hash=$(_jq '.password_hash')
    sudo=$(_jq '.sudo')

    echo "Creating user $username..."
    useradd -m "$username"

    # Set the password using the hashed password from the JSON file
    echo "$username:$password_hash" | chpasswd -e

    # Grant sudo access if specified in the JSON
    if [ "$sudo" == "true" ]; then
        pacman -S --needed --noconfirm sudo
        usermod -aG wheel $username
    fi
done


# Install packages from the JSON file
echo "Installing packages..."
packages_to_install=$(echo "$packages" | jq -r '.[]' | tr '\n' ' ')  # Join the packages into one string
pacman -S --needed --noconfirm $packages_to_install


# Enable services from the JSON file
echo "Enabling services..."
for service in $(echo "$services" | jq -r '.[]'); do
    systemctl enable "$service"
    systemctl start "$service"
done


# Pacman configuration
if [ -f /etc/pacman.conf ] && [ ! -f /etc/pacman.conf.t2.bkp ]; then
    echo -e "\033[0;32m[PACMAN]\033[0m adding extra spice to pacman..."

    cp /etc/pacman.conf /etc/pacman.conf.t2.bkp
    sed -i "/^#Color/c\Color\nILoveCandy
    /^#VerbosePkgLists/c\VerbosePkgLists
    /^#ParallelDownloads/c\ParallelDownloads = 5" /etc/pacman.conf
    sed -i '/^#\[multilib\]/,+1 s/^#//' /etc/pacman.conf

    pacman -Syyu
    pacman -Fy

else
    echo -e "\033[0;33m[SKIP]\033[0m pacman is already configured..."
fi
