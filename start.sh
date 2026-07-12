#!/bin/bash

# Останавливать выполнение скрипта при любой ошибке
set -e

echo "=============================================================================="
echo " ЗАПУСК АВТОМАТИЧЕСКОЙ НАСТРОЙКИ МАЙНИНГА И ОТКЛЮЧЕНИЯ ЛОГОВ"
echo "=============================================================================="

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

# Исправление для GCC 9
sed -i 's/__GNUC__ <= 9/__GNUC__ < 9/' /home/orangepi/ccminer/SSE2NEON.h

# Выдача прав и запуск сборки
sudo chmod +x build.sh configure.sh autogen.sh
sudo ./build.sh
sudo chmod +x ccminer

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
ExecStart=/usr/src/ccminer/ccminer -a verus -o stratum+tcp://ru.vipor.net:5040 -u RQvK8B67qX4Na9jx3cvCduZVDpjF5JyWwo.opiz -p x -t 4
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
