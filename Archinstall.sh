#!/bin/bash

# Arch Linux UEFI Install Script with Cyrillic Support
# Полноценная поддержка кириллицы в консоли установщика

# Настройка шрифта консоли перед началом работы
setfont cyr-sun16 2>/dev/null

# Проверка прав root
if [ "$(id -u)" -ne 0 ]; then
    echo -e "\n\033[1;31mЭтот скрипт должен запускаться от root!\033[0m" >&2
    exit 1
fi

### Выбор диска ###
echo -e "\n\033[1;32m=== ВЫБОР ДИСКА ===\033[0m"
echo -e "\033[1;33mДоступные диски:\033[0m"
lsblk -d -p -o NAME,SIZE,MODEL | grep -v "ROM\|loop\|sr0"
echo -e "\n\033[1;33mВведите полный путь к диску (например, /dev/sda или /dev/nvme0n1):\033[0m"
read -p "> " DISK

### Проверка ввода диска ###
while [ ! -b "$DISK" ]; do
    echo -e "\033[1;31mОшибка: Устройство $DISK не найдено!\033[0m"
    read -p "Пожалуйста, введите корректный путь: " DISK
done

### Определение разделов ###
if [[ $DISK =~ "nvme" ]]; then
    EFI_PART="${DISK}p1"
    ROOT_PART="${DISK}p2"
else
    EFI_PART="${DISK}1"
    ROOT_PART="${DISK}2"
fi

### Выбор часового пояса ###
echo -e "\n\033[1;32m=== ВЫБОР ЧАСОВОГО ПОЯСА ===\033[0m"
echo -e "\033[1;33mВыберите регион:\033[0m"
PS3="> "
REGIONS=($(timedatectl list-timezones | cut -d'/' -f1 | sort -u))
select REGION in "${REGIONS[@]}"; do
    [[ -n $REGION ]] && break || echo -e "\033[1;31mНеверный выбор!\033[0m"
done

echo -e "\n\033[1;33mВыберите город:\033[0m"
CITIES=($(timedatectl list-timezones | grep "^$REGION/" | cut -d'/' -f2))
select CITY in "${CITIES[@]}"; do
    [[ -n $CITY ]] && break || echo -e "\033[1;31mНеверный выбор!\033[0m"
done

TIMEZONE="$REGION/$CITY"
echo -e "\n\033[1;32mВыбран часовой пояс: \033[1;33m$TIMEZONE\033[0m"

### Настройки локализации ###
LOCALE="ru_RU.UTF-8"
KEYMAP="ru"
HOSTNAME="archlinux"

### Ввод пользователя ###
echo -e "\n\033[1;32m=== СОЗДАНИЕ ПОЛЬЗОВАТЕЛЯ ===\033[0m"
while true; do
    read -p "Введите имя пользователя (латинскими буквами): " USERNAME
    if [[ "$USERNAME" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
        break
    else
        echo -e "\033[1;31mОшибка: используйте только латинские буквы, цифры и подчеркивание!\033[0m"
    fi
done

### Разметка диска ###
echo -e "\n\033[1;32m=== РАЗМЕТКА ДИСКА ===\033[0m"
echo -e "\033[1;33mСоздание разделов на $DISK...\033[0m"
parted -s "$DISK" mklabel gpt
parted -s "$DISK" mkpart primary fat32 1MiB 513MiB
parted -s "$DISK" set 1 esp on
parted -s "$DISK" mkpart primary btrfs 513MiB 100%

### Форматирование ###
echo -e "\n\033[1;33mФорматирование разделов...\033[0m"
mkfs.fat -F32 "$EFI_PART"
mkfs.btrfs -f "$ROOT_PART"

### Создание структуры Btrfs ###
echo -e "\n\033[1;33mСоздание Btrfs-субвьюмов...\033[0m"
mount "$ROOT_PART" /mnt
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@var
btrfs subvolume create /mnt/@.snapshots
btrfs subvolume create /mnt/@log
btrfs subvolume create /mnt/@pkg

### Монтирование ###
umount /mnt
echo -e "\n\033[1;33mМонтирование разделов...\033[0m"
mount -o noatime,compress=lzo,space_cache=v2,ssd,subvol=@ "$ROOT_PART" /mnt
mkdir -p /mnt/{boot/efi,home,var,.snapshots,var/log,var/cache/pacman/pkg}
mount "$EFI_PART" /mnt/boot/efi
mount -o noatime,compress=zstd,space_cache=v2,subvol=@home "$ROOT_PART" /mnt/home
mount -o noatime,compress=zstd,space_cache=v2,subvol=@var "$ROOT_PART" /mnt/var
mount -o noatime,compress=zstd,space_cache=v2,subvol=@.snapshots "$ROOT_PART" /mnt/.snapshots
mount -o noatime,compress=zstd,space_cache=v2,subvol=@log "$ROOT_PART" /mnt/var/log
mount -o noatime,compress=zstd,space_cache=v2,subvol=@pkg "$ROOT_PART" /mnt/var/cache/pacman/pkg

### Установка системы ###
echo -e "\n\033[1;32m=== УСТАНОВКА СИСТЕМЫ ===\033[0m"
echo -e "\033[1;33mУстановка базовых пакетов...\033[0m"
pacstrap /mnt base base-devel linux linux-firmware btrfs-progs grub efibootmgr networkmanager nano sudo terminus-font

### Fstab ###
echo -e "\n\033[1;33mГенерация fstab...\033[0m"
genfstab -U /mnt >> /mnt/etc/fstab

### Chroot-настройка ###
echo -e "\n\033[1;32m=== НАСТРОЙКА СИСТЕМЫ ===\033[0m"

arch-chroot /mnt
# Часовой пояс
ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
hwclock --systohc

# Русская локализация
echo "ru_RU.UTF-8 UTF-8" > /etc/locale.gen
echo "ru_RU ISO-8859-5" >> /etc/locale.gen
echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
echo "LANG=$LOCALE" > /etc/locale.conf
echo "KEYMAP=$KEYMAP" > /etc/vconsole.conf
echo "FONT=cyr-sun16" >> /etc/vconsole.conf
locale-gen

# Настройка консоли
echo "COLORTERM=truecolor" >> /etc/environment
echo "TERM=xterm-256color" >> /etc/environment

# Сеть
echo "$HOSTNAME" > /etc/hostname
echo "127.0.1.1 $HOSTNAME.localdomain $HOSTNAME" >> /etc/hosts

# Initramfs
sed -i 's/^HOOKS=.*/HOOKS=(base systemd autodetect modconf block filesystems keyboard fsck btrfs)/' /etc/mkinitcpio.conf
mkinitcpio -P

# Загрузчик
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB
grub-mkconfig -o /boot/grub/grub.cfg

# Пароль root
echo -e "\n\033[1;33mУстановка пароля для root:\033[0m"
passwd

# Пользователь
useradd -m -G wheel,storage,power -s /bin/bash "$USERNAME"
echo -e "\n\033[1;33mУстановка пароля для $USERNAME:\033[0m"
passwd "$USERNAME"

# Sudo
echo "%wheel ALL=(ALL) ALL" >> /etc/sudoers

# Дополнительные пакеты
pacman -S --noconfirm ntfs-3g firefox firefox-i18n-ru ttf-liberation noto-fonts-cjk noto-fonts-emoji

# Включение NetworkManager
systemctl enable NetworkManager

### Завершение ###
echo -e "\n\033[1;32m=== УСТАНОВКА ЗАВЕРШЕНА ===\033[0m"

echo -e "\033[1;33m1. Размонтируем разделы\033[0m"
umount -R /mnt

echo -e "\033[1;33m2. Перезагрузка\033[0m"
reboot
