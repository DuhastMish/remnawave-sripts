#!/bin/bash
#
# setup_swap.sh — настройка swap-файла на Ubuntu/Debian
# Запуск: sudo bash setup_swap.sh
#

set -e

# Проверка прав root
if [ "$(id -u)" -ne 0 ]; then
    echo "Ошибка: скрипт нужно запускать с правами root (sudo)."
    exit 1
fi

SWAPFILE="/swapfile"

echo "=== Настройка swap-файла ==="
echo

# Показать текущее состояние
echo "Текущий swap:"
swapon --show || echo "  (swap не настроен)"
echo

# Проверка, не существует ли уже swap-файл
if [ -f "$SWAPFILE" ]; then
    read -p "Файл $SWAPFILE уже существует. Удалить и пересоздать? (y/N): " ANSWER
    if [[ "$ANSWER" =~ ^[Yy]$ ]]; then
        swapoff "$SWAPFILE" 2>/dev/null || true
        rm -f "$SWAPFILE"
    else
        echo "Отмена."
        exit 0
    fi
fi

# Запрос размера swap
while true; do
    read -p "Введите размер swap в GB (целое число): " SWAP_SIZE
    if [[ "$SWAP_SIZE" =~ ^[1-9][0-9]*$ ]]; then
        break
    else
        echo "Ошибка: введите целое положительное число."
    fi
done

echo
echo "Создаю swap-файл размером ${SWAP_SIZE}GB..."

# Создание файла (fallocate с fallback на dd)
CREATE_OK=0

if command -v fallocate >/dev/null 2>&1; then
    if FALLOCATE_ERR=$(fallocate -l "${SWAP_SIZE}G" "$SWAPFILE" 2>&1); then
        CREATE_OK=1
    elif echo "$FALLOCATE_ERR" | grep -qi "No space left on device"; then
        echo "Ошибка: на диске недостаточно места для файла размером ${SWAP_SIZE}GB."
        echo "Доступное место:"
        df -h "$(dirname "$SWAPFILE")"
        rm -f "$SWAPFILE"
        exit 1
    else
        echo "fallocate не сработал ($FALLOCATE_ERR), пробую dd..."
    fi
fi

if [ "$CREATE_OK" -ne 1 ]; then
    if ! dd if=/dev/zero of="$SWAPFILE" bs=1M count=$((SWAP_SIZE * 1024)) status=progress; then
        echo "Ошибка: не удалось создать swap-файл (вероятно, не хватает места на диске)."
        echo "Доступное место:"
        df -h "$(dirname "$SWAPFILE")"
        rm -f "$SWAPFILE"
        exit 1
    fi
fi

# Права доступа
chmod 600 "$SWAPFILE"

# Разметка и включение
mkswap "$SWAPFILE"
swapon "$SWAPFILE"

# Добавление в fstab (если ещё не добавлено)
if ! grep -q "^$SWAPFILE " /etc/fstab 2>/dev/null; then
    echo "$SWAPFILE none swap sw 0 0" >> /etc/fstab
    echo "Добавлено в /etc/fstab для автозагрузки."
else
    echo "Запись в /etc/fstab уже существует."
fi

# Настройка swappiness (по умолчанию 10 — подходит для серверов)
SWAPPINESS=10
sysctl -w vm.swappiness=$SWAPPINESS >/dev/null
if grep -q "^vm.swappiness" /etc/sysctl.conf 2>/dev/null; then
    sed -i "s/^vm.swappiness.*/vm.swappiness=$SWAPPINESS/" /etc/sysctl.conf
else
    echo "vm.swappiness=$SWAPPINESS" >> /etc/sysctl.conf
fi

echo
echo "=== Готово ==="
free -h
echo
swapon --show