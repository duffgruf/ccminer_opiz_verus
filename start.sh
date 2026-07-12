#!/bin/bash

# Останавливать выполнение скрипта при любой ошибке
set -e

echo "=============================================================================="
echo " ЗАПУСК АВТОМАТИЧЕСКОЙ НАСТРОЙКИ МАЙНИНГА И ОТКЛЮЧЕНИЯ ЛОГОВ"
echo "=============================================================================="

# 0. Установка режима производительности
sudo cpufreq-set -g performance

# 1. Обновление системы и установка необходимых пакетов
echo ">>> Шаг 1: Обновление репозиториев и установка зависимостей..."
sudo apt update && sudo apt upgrade -y
sudo apt install libcurl4-openssl-dev libssl-dev libjansson-dev automake autotools-dev build-essential libomp5 git -y

# 2. Клонирование и компиляция ccminer
echo ">>> Шаг 2: Скачивание и компиляция ccminer"
cd ~
rm -rf ccminer

git clone --recursive --single-branch -b ARM https://github.com/monkins1010/ccminer.git

cd ccminer

ln -sf verus/sse2neon sse2neon

# Исправление GCC 9
sed -i 's/__GNUC__ <= 9/__GNUC__ < 9/' SSE2NEON.h

echo ">>> Оптимизация build.sh для Cortex-A53..."

# Заменяем стандартные CFLAGS на оптимизированные
sed -i 's|CFLAGS="-O3" ./configure.sh|CFLAGS="-O3 -pipe -mcpu=cortex-a53 -mtune=cortex-a53 -fomit-frame-pointer -funroll-loops -frename-registers -flto" CXXFLAGS="-O3 -pipe -mcpu=cortex-a53 -mtune=cortex-a53 -fomit-frame-pointer -funroll-loops -frename-registers -flto" LDFLAGS="-flto" ./configure.sh|' build.sh

# Используем все ядра при сборке
sed -i 's/^make$/make -j$(nproc)/' build.sh

chmod +x autogen.sh configure.sh build.sh

./build.sh

echo performance | sudo tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor >/dev/null

sudo swapoff -a
sudo sed -i '/ swap / s/^/#/' /etc/fstab

cat <<EOF | sudo tee /etc/sysctl.d/99-verus.conf
net.core.rmem_max=4194304
net.core.wmem_max=4194304
net.ipv4.tcp_rmem=4096 87380 4194304
net.ipv4.tcp_wmem=4096 65536 4194304
net.core.netdev_max_backlog=2500
EOF

sudo sysctl --system

# Выдача прав и запуск сборки
chmod +x build.sh configure.sh autogen.sh
./build.sh
echo performance | sudo tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor >/dev/null

# 3. Отключение системного логирования (Journald)
echo ">>> Шаг 3: Перевод Systemd Journald в оперативную память..."
# Заменяем параметры в конфигурационном файле
sudo sed -i 's/#Storage=auto/Storage=volatile/g' /etc/systemd/journald.conf
sudo sed -i 's/Storage=auto/Storage=volatile/g' /etc/systemd/journald.conf

# Ограничиваем размер логов в ОЗУ до 16 Мегабайт
if grep -q "RuntimeMaxUse=" /etc/systemd/journald.conf; then
    sudo sed -i 's/RuntimeMaxUse=.*/RuntimeMaxUse=16M/g' /etc/systemd/journald.conf
else
    echo "RuntimeMaxUse=16M" | sudo tee -a /etc/systemd/journald.conf
fi
sudo systemctl restart systemd-journald

# 4. Полное удаление rsyslog
echo ">>> Шаг 4: Полная блокировка и удаление службы rsyslog..."
sudo systemctl stop syslog.socket || true
sudo systemctl disable syslog.socket || true
sudo systemctl stop rsyslog || true
sudo systemctl disable rsyslog || true
sudo systemctl mask rsyslog || true
sudo apt purge rsyslog -y

# 5. Отключение и удаление Swap-файла подкачки
echo ">>> Шаг 5: Отключение SWAP для защиты ячеек SD-карты..."
sudo swapoff -a || true
sudo apt purge dphys-swapfile -y || true
sudo rm -f /var/swap || true
# Чистим fstab от упоминаний swap, если они там есть
sudo sed -i '/swap/d' /etc/fstab

# 6. Создание и настройка демона автозапуска
echo ">>> Шаг 6: Создание конфигурации службы автозапуска ccminer..."
sudo tee /etc/systemd/system/ccminer.service > /dev/null <<EOF
[Unit]
Description=CCMiner VerusCoin Daemon
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=/home/orangepi/ccminer
ExecStartPre=/bin/sleep 15
ExecStart=/home/orangepi/ccminer/ccminer -a verus -o stratum+tcp://ru.vipor.net:5040 -u RQvK8B67qX4Na9jx3cvCduZVDpjF5JyWwo.opiz -p x -t 4
Restart=always
RestartSec=10
CPUSchedulingPolicy=other
Nice=19

[Install]
WantedBy=multi-user.target
EOF

# 7. Активация служб и запуск автозагрузки
echo ">>> Шаг 7: Регистрация службы в системе и включение ожидания сети..."
sudo systemctl enable systemd-networkd-wait-online.service || true
sudo systemctl daemon-reload
sudo systemctl enable ccminer.service

echo "=============================================================================="
echo " НАСТРОЙКА ЗАВЕРШЕНА. СИСТЕМА ОТПРАВЛЯЕТСЯ В ПЕРЕЗАГРУЗКУ..."
echo " После ребута майнер запустится сам в фоне через 15 секунд."
echo "=============================================================================="

# Перезагрузка системы
sudo reboot
