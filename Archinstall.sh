#!/bin/bash

# Проверка на root
if [ "$(id -u)" -ne 0 ]; then
  echo "Этот скрипт должен запускаться от root!" >&2
  exit 1
fi

# Функция для отображения прогресс-бара
progress_bar() {
    local duration=${1}
    local columns=$(tput cols)
    local space=$(( columns - 20 ))
    local increment=$(( duration / space ))
    
    for (( i=0; i<=space; i++ )); do
        printf "["
        for (( j=0; j<i; j++ )); do printf "#"; done
        for (( j=i; j<space; j++ )); do printf " "; done
        printf "] %d%%\r" $(( (i * 100) / space ))
        sleep $increment
    done
    printf "\n"
}

# Получаем имя диска для установки
echo "Доступные диски:"
lsblk -d -o NAME,SIZE,MODEL
read -p "Введите имя диска для установки (например, nvme0n1 или sda): " DISK

# Проверка на валидность имени диска
if [ ! -b "/dev/${DISK}" ]; then
  echo "Ошибка: /dev/${DISK} не существует или не является блочным устройством!" >&2
  exit 1
fi

# Разметка диска
echo "Разметка диска /dev/${DISK}..."
(
  echo g      # Создаем новую GPT таблицу
  echo n      # Раздел EFI
  echo 1
  echo
  echo +512M
  echo t      # Тип раздела
  echo 1      # EFI System
  echo n      # Корневой раздел (Btrfs)
  echo 2
  echo
  echo
  echo w
) | fdisk "/dev/${DISK}" &> /dev/null

progress_bar 5

# Форматирование разделов
echo "Форматирование разделов..."
EFI_PART="/dev/${DISK}p1"
ROOT_PART="/dev/${DISK}p2"

mkfs.fat -F32 "$EFI_PART" &> /dev/null
mkfs.btrfs -f "$ROOT_PART" &> /dev/null

progress_bar 3

# Монтирование Btrfs и создание сабволюмов
echo "Настройка Btrfs и сабволюмов..."
mount "$ROOT_PART" /mnt

# Создание сабволюмов
btrfs subvolume create /mnt/@ &> /dev/null
btrfs subvolume create /mnt/@home &> /dev/null
btrfs subvolume create /mnt/@var &> /dev/null
btrfs subvolume create /mnt/@log &> /dev/null
btrfs subvolume create /mnt/@pkg &> /dev/null
btrfs subvolume create /mnt/@.snapshots &> /dev/null

# Размонтируем для правильного монтирования с опциями
umount /mnt

# Монтируем с правильными опциями
mount -o noatime,compress=zstd,space_cache=v2,subvol=@ "$ROOT_PART" /mnt
mkdir -p /mnt/{boot/efi,home,var,var/log,var/cache/pacman/pkg,.snapshots}

mount -o noatime,compress=zstd,space_cache=v2,subvol=@home "$ROOT_PART" /mnt/home
mount -o noatime,compress=zstd,space_cache=v2,subvol=@var "$ROOT_PART" /mnt/var
mount -o noatime,compress=zstd,space_cache=v2,subvol=@log "$ROOT_PART" /mnt/var/log
mount -o noatime,compress=zstd,space_cache=v2,subvol=@pkg "$ROOT_PART" /mnt/var/cache/pacman/pkg
mount -o noatime,compress=zstd,space_cache=v2,subvol=@.snapshots "$ROOT_PART" /mnt/.snapshots

mount "$EFI_PART" /mnt/boot/efi

echo "Пароль root"
read -p "Введите пароль :  " password
clear

echo "Логин пользователя"
read -p "Введите имя :  " username
clear

echo "Пароль пользователя"
read -p "Введите пароль :  " userpassword
clear

progress_bar 5

# Установка базовой системы
echo "Установка базовой системы (это может занять некоторое время)..."
pacstrap /mnt base base-devel linux linux-firmware btrfs-progs &> /dev/null &

# Прогресс-бар для имитации процесса установки
while kill -0 $! 2>/dev/null; do
  progress_bar 30
done

progress_bar 5

# Генерация fstab с правильными опциями Btrfs
echo "Генерация fstab..."
genfstab -U /mnt > /mnt/etc/fstab
sed -i 's/subvolid=.*,subvol=\/@/subvol=\/@,noatime,compress=zstd,space_cache=v2/' /mnt/etc/fstab

# Chroot и настройка системы
echo "Настройка системы..."
arch-chroot /mnt /bin/bash <<EOF

# Настройка pacman.conf
echo "Настройка pacman.conf..."
#sed -i 's/^#Color/Color/' /etc/pacman.conf
sed -i 's/^#VerbosePkgLists/VerbosePkgLists/' /etc/pacman.conf
sed -i 's/^#ParallelDownloads = 5/ParallelDownloads = 5/' /etc/pacman.conf
#echo -e "\n# Дополнительные настройки\nILoveCandy" >> /etc/pacman.conf

# Разблокировка multilib
echo "Разблокировка multilib..."
sed -i '/^#\[multilib\]/,/^#Include/ s/^#//' /etc/pacman.conf
pacman -Sy --noconfirm &> /dev/null


# Настройка sudo
echo "Настройка sudo..."
echo "%wheel ALL=(ALL) ALL" >> /etc/sudoers
useradd -m -G wheel,storage,power,network,video,audio,input -s /bin/bash "$username"


# Установка и настройка GRUB
echo "Установка GRUB..."
pacman -S --noconfirm grub efibootmgr &> /dev/null
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=ARCH --no-nvram --removable &> /dev/null
grub-mkconfig -o /boot/grub/grub.cfg &> /dev/null

# Настройка локали и времени
echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
echo "ru_RU.UTF-8 UTF-8" >> /etc/locale.gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf
locale-gen &> /dev/null

# Установка часового пояса (пример для Москвы)
ln -sf /usr/share/zoneinfo/Europe/Moscow /etc/localtime
hwclock --systohc

# Установка сетевых утилит
pacman -S --noconfirm networkmanager &> /dev/null
systemctl enable NetworkManager &> /dev/null

# Установка Xorg и KDE Plasma
echo "Установка KDE Plasma..."
pacman -S --noconfirm plasma sddm sddm-kcm plasma-nm &> /dev/null

# Включение SDDM (менеджер входа KDE)
systemctl enable sddm &> /dev/null

# Установка дополнительных полезных пакетов
pacman -S --noconfirm konsole dolphin firefox ark kate gwenview spectacle
          pipewire pipewire-pulse pipewire-alsa wireplumber
          ffmpegthumbs
          ntfs-3g exfat-utils bash-completion &> /dev/null

# Установка драйверов (опционально)
pacman -S --noconfirm mesa amd-ucode &> /dev/null


# Обновление системы
echo "Обновление системы..."
pacman -Syu --noconfirm &> /dev/null
EOF

progress_bar 15

# Завершение установки
umount -R /mnt
echo "Установка завершена!"
echo "----------------------------------------"
echo "Имя пользователя: $username"
echo "----------------------------------------"
reboot