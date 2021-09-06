#!/bin/bash
set -euo pipefail

# Global variables
conf_file="arch-install.conf"
log_file="arch-install.log"
var_file="arch-install.var"

# Partition devices
efi_part=""
swap_part=""
root_part=""
home_part=""
data_part=""

# Format partitions?
format_efi="false"
format_swap="false"
format_root="false"
format_home="false"
format_data="false"

# User with sudo privileges
sudo_user=""

# Users
user_name=""
user_password=""

# VMware
vmware="false"

# Nvidia
nvidia_driver="false"

function init_log() {
    if [ "$log" == "true" ]; then
        if [ -f "$log_file" ]; then
            rm "$log_file"
        fi
        exec > >(tee -a $log_file)
        exec 2> >(tee -a $log_file >&2)
    fi
    set -o xtrace
}

function print_step() {
    local step="$1"
    echo "******************************"
    echo -e "${step}"
    echo "******************************"
}

function init() {
    # shellcheck source=./arch-install.conf
    source "$conf_file"
    print_step "init()"

    init_log

    loadkeys "$keyboard_layout"
    timedatectl set-ntp true

    if [[ "$disk" == *"nvme"* ]]; then
        part="p"
    else
        part=""
    fi

    efi_part="${disk}${part}1"
    swap_part="${disk}${part}2"
    root_part="${disk}${part}3"
    home_part="${disk}${part}4"
    data_part="${disk}${part}5"

    if [ "$(lspci | grep VMware)" != "" ]; then
        vmware="true"
    fi
}

function partition_auto() {
    sgdisk --clear "$disk"
    sgdisk --new=1:0:+512M --typecode=1:ef00 "$disk"
    sgdisk --new=3:0:0 --typecode=3:8300 "$disk"
    format_efi="true"
    format_root="true"

    partprobe "$disk"
}

function partition_custom() {
    if [ "$partition_custom_delete_all" = "true" ]; then
        sgdisk --clear "$disk"
    else
        sgdisk --delete 1 "$disk"
        sgdisk --delete 2 "$disk"
        sgdisk --delete 3 "$disk"
        if [ "$keep_home" = "false" ]; then
            sgdisk --delete 4 "$disk"
        fi
        if [ "$keep_data" = "false" ]; then
            sgdisk --delete 5 "$disk"
        fi
    fi

    sgdisk --new=1:0:"$efi_size" --typecode=1:ef00 "$disk"
    format_efi="true"

    if [ "$swap_size" != "" ]; then
        sgdisk --new=2:0:"$swap_size" --typecode=2:8200 "$disk"
        format_swap="true"
    fi

    sgdisk --new=3:0:"$root_size" --typecode=3:8300 "$disk"
    format_root="true"

    if [ "$keep_home" = "false" ] && [ "$home_size" != "" ]; then
        sgdisk --new=4:0:"$home_size" --typecode=4:8300 "$disk"
        format_home="true"
    fi

    if [ "$keep_data" = "false" ] && [ "$data_size" != "" ]; then
        sgdisk --new=5:0:"$data_size" --typecode=5:8300 "$disk"
        format_data="true"
    fi

    partprobe "$disk"
}

function do_partition() {
    print_step "do_partition()"

    if [ "$partition_scheme" = "auto" ]; then
        partition_auto
    elif [ "$partition_scheme" = "custom" ]; then
        partition_custom
    fi
}

function create_subvolumes() {
    mount -t btrfs "$root_part" /mnt
    btrfs subvolume create /mnt/@
    btrfs subvolume create /mnt/@.snapshots
    if [ "$1" = "true" ]; then
        btrfs subvolume create /mnt/@home
    fi
    btrfs subvolume create /mnt/@tmp
    btrfs subvolume create /mnt/@var_cache
    btrfs subvolume create /mnt/@var_log
    btrfs subvolume create /mnt/@var_tmp
    umount /mnt
}

function format_auto() {
    mkfs.fat -F32 -I -n "$efi_label" "$efi_part"
    mkfs.btrfs -f -L "$root_label" "$root_part"
    create_subvolumes "true"
}

function format_custom() {
    if [ "$format_efi" = "true" ]; then
        mkfs.fat -F32 -I -n "$efi_label" "$efi_part"
    fi

    if [ "$format_swap" = "true" ]; then
        mkswap -L "$swap_label" "$swap_part"
    fi

    if [ "$format_root" = "true" ]; then
        mkfs.btrfs -f -L "$root_label" "$root_part"
    fi

    if [ "$format_home" = "true" ]; then
        mkfs.ext4 -F -L "$home_label" "$home_part"
        create_subvolumes "false"
    else
        create_subvolumes "true"
    fi

    if [ "$format_data" = "true" ]; then
        mkfs.ext4 -F -L "$data_label" "$data_part"
    fi
}

function do_format() {
    print_step "do_format()"

    if [ "$partition_scheme" = "auto" ]; then
        format_auto
    elif [ "$partition_scheme" = "custom" ]; then
        format_custom
    fi
}

function mount_subvolumes() {
    mount -o subvol=@.snapshots "$root_part" /mnt/.snapshots
    mount -o subvol=@tmp "$root_part" /mnt/tmp
    mount -o subvol=@var_cache "$root_part" /mnt/var/cache
    mount -o subvol=@var_log "$root_part" /mnt/var/log
    mount -o subvol=@var_tmp "$root_part" /mnt/var/tmp
    if [ "$1" = "true" ]; then
        mount -o subvol=@home "$root_part" /mnt/home
    fi
}

function mount_common() {
    mount -o subvol=@ "$root_part" /mnt

    mkdir /mnt/{efi,.snapshots,home,mnt,tmp,var}
    mkdir /mnt/var/{cache,log,tmp}

    mount "$efi_part" /mnt/efi
}

function mount_auto() {
    mount_common
    mount_subvolumes "true"
}

function mount_custom() {
    mount_common

    if [ "$format_swap" = "true" ]; then
        swapon "$swap_part"
    fi

    if [ "$keep_home" = "true" ]; then
        mount "$home_part" /mnt/home
        mount_subvolumes "false"
    elif [ "$format_home" = "true" ]; then
        mount "$home_part" /mnt/home
        mount_subvolumes "false"
    else
        mount_subvolumes "true"
    fi

    if [ "$keep_data" = "true" ]; then
        mkdir /mnt/mnt/data
        mount "$data_part" /mnt/mnt/data
    elif [ "$format_data" = "true" ]; then
        mkdir /mnt/mnt/data
        mount "$data_part" /mnt/mnt/data
    fi
}

function do_mount() {
    print_step "do_mount()"

    if [ "$partition_scheme" = "auto" ]; then
        mount_auto
    elif [ "$partition_scheme" = "custom" ]; then
        mount_custom
    fi
}

function do_install() {
    print_step "do_install()"

    sed -i 's/#Color/Color/' /etc/pacman.conf
    sed -i 's/#ParallelDownloads/ParallelDownloads/' /etc/pacman.conf

    pacstrap /mnt base linux linux-firmware nano amd-ucode btrfs-progs sudo pacman-contrib

    sed -i 's/#Color/Color/' /mnt/etc/pacman.conf
    sed -i 's/#ParallelDownloads/ParallelDownloads/' /mnt/etc/pacman.conf

    genfstab -U /mnt >>/mnt/etc/fstab
}

function pacman_install() {
    local packages=()
    #IFS=" " 
    read -r -a packages <<<"$1"
    arch-chroot /mnt pacman -S --noconfirm --needed "${packages[@]}"
}

function configure_vmware() {
    pacman_install "open-vm-tools"
    arch-chroot /mnt systemctl enable vmtoolsd.service
}

function do_config() {
    print_step "do_config()"

    arch-chroot /mnt ln -s -f /usr/share/zoneinfo/"$timezone" /etc/localtime
    arch-chroot /mnt hwclock --systohc

    # Set locales
    echo "en_US.UTF-8 UTF-8" >>/mnt/etc/locale.gen
    echo "es_ES.UTF-8 UTF-8" >>/mnt/etc/locale.gen
    arch-chroot /mnt locale-gen
    echo "LANG=es_ES.UTF-8" >/mnt/etc/locale.conf
    echo "KEYMAP=es" >/mnt/etc/vconsole.conf

    # Configure network
    echo "$hostname" >/mnt/etc/hostname
    local hosts_content="127.0.0.1\tlocalhost\n"
    hosts_content="${hosts_content}::1\t\tlocalhost\n"
    hosts_content="${hosts_content}127.0.1.1\t${hostname}.localdomain\t${hostname}"
    echo -e "$hosts_content" >>/mnt/etc/hosts
    pacman_install "networkmanager"
    arch-chroot /mnt systemctl enable NetworkManager.service

    # NTP
    pacman_install "ntp"
    arch-chroot /mnt systemctl enable ntpd.service

    # Sudo
    sed -i 's/# %wheel ALL=(ALL) ALL/%wheel ALL=(ALL) ALL/' /mnt/etc/sudoers

    # VMware
    if [ "$vmware" == "true" ]; then
        configure_vmware
    fi

    # Clean pacman cache weekly
    arch-chroot /mnt systemctl enable paccache.timer
}

function ask_password() {
    local password
    local password_retype

    local typed="false"
    while [ "$typed" != "true" ]; do
        read -rsp "Type password for ${user_name}: " password
        echo ""
        read -rsp "Retype user password: " password_retype
        echo ""
        if [ "$password" == "$password_retype" ]; then
            typed="true"
            user_password="$password"
        else
            echo "Passwords don't match. Please, type again."
        fi
    done
}

function do_users() {
    print_step "do_users()"

    local user_array=()
    read -ra user_array <<<"$users"

    for i in "${!user_array[@]}"; do
        user_name="${user_array[i]}"
        ask_password
        if [ "$i" = "0" ]; then
            arch-chroot /mnt useradd -m -G wheel "$user_name"
            arch-chroot /mnt passwd -l root
            sudo_user="$user_name"
        else
            arch-chroot /mnt useradd -m "$user_name"
        fi
        printf "%s\n%s" "${user_password}" "${user_password}" | arch-chroot /mnt passwd "${user_name}"
    done
}

function install_video_driver() {
    case $1 in
    "nvidia")
        pacman_install "nvidia nvidia-utils"
        nvidia_driver="true"
        ;;
    "amdgpu")
        pacman_install "xf86-video-amdgpu"
        ;;
    "vmware")
        pacman_install "xf86-video-vmware"
        ;;
    esac
}

function do_xorg() {
    print_step "do_xorg()"

    if [ "$install_xorg" == "true" ]; then
        pacman_install "xorg-server"

        #IFS=' '
        for driver in $video_drivers; do
            install_video_driver $driver
        done

        local keyboard_conf="# Written by systemd-localed(8), read by systemd-localed and Xorg. It's\n"
        keyboard_conf="${keyboard_conf}# probably wise not to edit this file manually. Use localectl(1) to\n"
        keyboard_conf="${keyboard_conf}# instruct systemd-localed to update it.\n"
        keyboard_conf="${keyboard_conf}Section \"InputClass\"\n"
        keyboard_conf="${keyboard_conf}\tIdentifier \"system-keyboard\"\n"
        keyboard_conf="${keyboard_conf}\tMatchIsKeyboard \"on\"\n"
        keyboard_conf="${keyboard_conf}\tOption \"XkbLayout\" \"es\"\n"
        keyboard_conf="${keyboard_conf}\tOption \"XkbModel\" \"pc105\"\n"
        keyboard_conf="${keyboard_conf}\tOption \"XkbOptions\" \"terminate:ctrl_alt_bksp\"\n"
        keyboard_conf="${keyboard_conf}EndSection\n"

        echo -e "$keyboard_conf" >>/mnt/etc/X11/xorg.conf.d/00-keyboard.conf
    fi
}

function do_kde() {
    print_step "do_kde()"

    if [ "$install_kde" == "true" ]; then
        pacman_install "$kde_base"
        pacman_install "$kde_graphics"
        pacman_install "$kde_multimedia"
        pacman_install "$kde_system"
        pacman_install "$kde_utilities"

        sed -i 's/TEMPLATES=Templates/#TEMPLATES=Templates/' /mnt/etc/xdg/user-dirs.defaults
        sed -i 's/PUBLICSHARE=Public/#PUBLICSHARE=Public/' /mnt/etc/xdg/user-dirs.defaults

        mkdir /mnt/etc/sddm.conf.d
        local kde_settings="[Theme]\n"
        kde_settings="${kde_settings}Current=breeze\n"
        kde_settings="${kde_settings}CursorTheme=breeze_cursors\n"
        kde_settings="${kde_settings}Font=Noto Sans,11,-1,5,50,0,0,0,0,0\n"
        kde_settings="${kde_settings}\n[X11]\n"
        kde_settings="${kde_settings}ServerArguments=-dpi 120\n"
        echo -e "$kde_settings" >>/mnt/etc/sddm.conf.d/kde_settings.conf

        arch-chroot /mnt systemctl enable sddm.service
    fi
}

function do_packages() {
    print_step "do_packages()"

    if [ "$arch_packages" != "" ]; then
        pacman_install "$arch_packages"
    fi
}

function execute_aur() {
    local command="$1"
    arch-chroot /mnt sed -i 's/# %wheel ALL=(ALL) NOPASSWD: ALL$/%wheel ALL=(ALL) NOPASSWD: ALL/' /etc/sudoers
    arch-chroot /mnt bash -c "su ${sudo_user} -s /usr/bin/bash -c \"${command}\""
    arch-chroot /mnt sed -i 's/%wheel ALL=(ALL) NOPASSWD: ALL$/# %wheel ALL=(ALL) NOPASSWD: ALL/' /etc/sudoers
}

function yay_install() {
    execute_aur "yay -S --noconfirm --needed $1"
}

function install_aur_base() {
    pacman_install "base-devel git linux-headers"

    command="mkdir -p /home/${sudo_user}/.aur && cd /home/${sudo_user}/.aur && git clone https://aur.archlinux.org/yay.git && (cd yay && makepkg -si --noconfirm) && rm -rf /home/${sudo_user}/.aur/yay"
    execute_aur "$command"
}

function do_aur() {
    print_step "do_aur()"

    if [ "$install_aur" == "true" ]; then
        install_aur_base
        yay_install "$aur_packages"
    fi
}

function config_printer() {
    if [ "$config_printer" == "true" ]; then
        pacman_install "cups cups-pdf print-manager system-config-printer avahi nss-mdns sane-airscan"

        # shellcheck disable=SC2016
        sed -i 's|#Out /var/spool/cups-pdf/${USER}|Out ${HOME}|' /mnt/etc/cups/cups-pdf.conf
        sed -i 's/hosts: files mymachines myhostname resolve \[!UNAVAIL=return\] dns/hosts: files mymachines myhostname mdns_minimal \[NOTFOUND=return\] resolve \[!UNAVAIL=return\] dns/' /mnt/etc/nsswitch.conf

        arch-chroot /mnt systemctl enable cups.socket
        arch-chroot /mnt systemctl enable avahi-daemon.service
    fi
}

function config_optimus() {
    if [ "$config_optimus" == "true" ]; then
        if [ "$install_aur" != "true" ]; then
            install_aur_base
        fi
        yay_install "optimus-manager optimus-manager-qt"

        local nvidia_setup="mon1=HDMI-0\n"
        nvidia_setup="${nvidia_setup}mon2=eDP-1-1\n"
        nvidia_setup="${nvidia_setup}if xrandr | grep \"\$mon2 disconnected\"; then\n"
        nvidia_setup="${nvidia_setup}\txrandr --output \"\$mon2\" --off --output \"\$mon1\" --auto\n"
        nvidia_setup="${nvidia_setup}elif xrandr | grep \"\$mon1 disconnected\"; then\n"
        nvidia_setup="${nvidia_setup}\txrandr --output \"\$mon1\" --off --output \"\$mon2\" --auto\n"
        nvidia_setup="${nvidia_setup}else\n"
        nvidia_setup="${nvidia_setup}\txrandr --output \"\$mon1\" --auto --output \"\$mon2\" --right-of \"\$mon1\" --auto\n"
        nvidia_setup="${nvidia_setup}fi"

        echo -e "$nvidia_setup" >>/mnt/etc/optimus-manager/xsetup-nvidia.sh
    fi
}

function install_vmware() {
    if [ "$vmware" != "true" ] && [ "$install_vmware" == "true" ]; then
        if [ "$install_aur" != "true" ]; then
            install_aur_base
        fi
        yay_install "vmware-workstation"
        arch-chroot /mnt systemctl enable vmware-networks.service
        arch-chroot /mnt systemctl enable vmware-usbarbitrator.service
    fi
}

function install_snapper() {
    if [ "$install_snapper" == "true" ]; then
        pacman_install "snapper snap-pac"
        cp /mnt/etc/snapper/config-templates/default /mnt/etc/snapper/configs/root
        sed -i 's/SNAPPER_CONFIGS=\"\"/SNAPPER_CONFIGS=\"root\"/' /mnt/etc/conf.d/snapper
    fi
}

function do_customize() {
    print_step "do_customize()"

    config_printer
    config_optimus
    install_vmware
    install_snapper
}

function do_grub() {
    print_step "do_grub()"

    arch-chroot /mnt bash -c "SNAP_PAC_SKIP=y pacman -S --noconfirm --needed grub efibootmgr"
    arch-chroot /mnt grub-install --target=x86_64-efi --efi-directory=/efi --bootloader-id=GRUB

    if [ "$grub_removable" = "true" ]; then
        arch-chroot /mnt grub-install --target=x86_64-efi --efi-directory=/efi --removable
    fi

    if [ "$nvidia_driver" == "true" ]; then
        sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="loglevel=3 quiet"/GRUB_CMDLINE_LINUX_DEFAULT="loglevel=3 quiet nvidia-drm.modeset=1"/' /mnt/etc/default/grub
    fi
    arch-chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg
}

function do_cleanup() {
    print_step "do_cleanup()"

    umount -R /mnt
}

function save_variables() {
    # if [ -f "$var_file" ]; then
    #     rm "$var_file"
    # fi
    local variables="efi_part=${efi_part}\n"
    variables="${variables}swap_part=${swap_part}\n"
    variables="${variables}root_part=${root_part}\n"
    variables="${variables}home_part=${home_part}\n"
    variables="${variables}data_part=${data_part}\n"
    variables="${variables}format_efi=${format_efi}\n"
    variables="${variables}format_swap=${format_swap}\n"
    variables="${variables}format_root=${format_root}\n"
    variables="${variables}format_home=${format_home}\n"
    variables="${variables}format_data=${format_data}\n"
    variables="${variables}sudo_user=${sudo_user}\n"
    variables="${variables}user_name=${user_name}\n"
    variables="${variables}user_password=${user_password}\n"
    variables="${variables}vmware=${vmware}\n"
    variables="${variables}nvidia_driver=${nvidia_driver}\n"

    echo -e "$variables" >"$var_file"
}

function load_variables() {
    if [ -f "$var_file" ]; then
        # shellcheck disable=SC1090
        source "$var_file"
    fi
}

function do_step() {
    local step="$1"
    local steps="$2"

    if [[ " $steps " =~ $step ]]; then
        eval "$step"
        save_variables
    fi
}

function do_steps() {
    local steps="$1"
    local step_array=()
    read -ra step_array <<<"$steps"

    for step in "${step_array[@]}"; do
        do_step "$step" "$steps"
    done
}

function main() {
    local step=""
    local steps="do_partition do_format do_mount do_install do_config do_users do_xorg do_kde do_packages do_aur do_customize do_grub do_cleanup"
    
    if [ "$#" != 0 ]; then
        step="$1"
    fi

    init
    load_variables

    if [ "$step" != "" ]; then
        do_step "$step" "$steps"
    else
        do_steps "$steps"
    fi
}

main "$@"
