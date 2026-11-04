#!/usr/bin/env bash
# ==============================================================================
# Скрипт удаления KernelSU-Next и установки BakaSU (ReSukiSU)
# Целевой репозиторий: https://github.com/davliks/samsung_kernel_exynos9820_lineageos
# Подходит для запуска в GitHub Codespaces, GitHub Actions или локальном клоне
# ==============================================================================

set -euo pipefail

echo "[*] Начинаем миграцию с KernelSU-Next на BakaSU..."

if [ ! -d ".git" ] || [ ! -d "drivers" ]; then
    echo "[!] Ошибка: запустите скрипт из корня репозитория samsung_kernel_exynos9820_lineageos."
    exit 1
fi

# ------------------------------------------------------------------------------
# 1. Удаление субмодуля KernelSU-Next и старого симлинка drivers/kernelsu
# ------------------------------------------------------------------------------
echo "[1/6] Удаление субмодуля KernelSU-Next..."
git submodule deinit -f KernelSU-Next 2>/dev/null || true
git rm -f KernelSU-Next 2>/dev/null || rm -rf KernelSU-Next
rm -rf .git/modules/KernelSU-Next

if [ -L "drivers/kernelsu" ] || [ -e "drivers/kernelsu" ]; then
    git rm -f drivers/kernelsu 2>/dev/null || rm -rf drivers/kernelsu
fi

# ------------------------------------------------------------------------------
# 2. Добавление субмодуля BakaSU и симлинка drivers/kernelsu
# ------------------------------------------------------------------------------
echo "[2/6] Добавление субмодуля Baka-SU/BakaSU в каталог KernelSU..."
if [ -e "KernelSU" ]; then
    git submodule deinit -f KernelSU 2>/dev/null || true
    git rm -f KernelSU 2>/dev/null || rm -rf KernelSU
    rm -rf .git/modules/KernelSU
fi

git submodule add -f -b main https://github.com/Baka-SU/BakaSU KernelSU
ln -s ../KernelSU/kernel drivers/kernelsu
git add .gitmodules KernelSU drivers/kernelsu

# Проверяем наличие записей в drivers/Makefile и drivers/Kconfig
if ! grep -q "CONFIG_KSU" drivers/Makefile; then
    echo 'obj-$(CONFIG_KSU) += kernelsu/' >> drivers/Makefile
    git add drivers/Makefile
fi

if ! grep -q 'drivers/kernelsu/Kconfig' drivers/Kconfig; then
    sed -i '/endmenu/i source "drivers/kernelsu/Kconfig"' drivers/Kconfig
    git add drivers/Kconfig
fi

# ------------------------------------------------------------------------------
# 3. Обновление конфигурации ядра (arch/arm64/configs/common.config)
# ------------------------------------------------------------------------------
echo "[3/6] Обновление arch/arm64/configs/common.config..."
CONFIG_FILE="arch/arm64/configs/common.config"
if [ -f "$CONFIG_FILE" ]; then
    sed -i 's/# KernelSU-Next/# BakaSU (ReSukiSU)/g' "$CONFIG_FILE"
    sed -i '/CONFIG_KSU_ALLOWLIST_WORKAROUND=y/d' "$CONFIG_FILE"

    if ! grep -q "^CONFIG_KSU=y" "$CONFIG_FILE"; then
        echo "CONFIG_KSU=y" >> "$CONFIG_FILE"
    fi
    if ! grep -q "^CONFIG_KSU_MANUAL_HOOK=y" "$CONFIG_FILE"; then
        echo "CONFIG_KSU_MANUAL_HOOK=y" >> "$CONFIG_FILE"
    fi
    if ! grep -q "^CONFIG_KALLSYMS_ALL=y" "$CONFIG_FILE"; then
        echo "CONFIG_KALLSYMS_ALL=y" >> "$CONFIG_FILE"
    fi
    git add "$CONFIG_FILE"
fi

# ------------------------------------------------------------------------------
# 4. Исправление хука чтения в fs/read_write.c (ksu_vfs_read_hook -> ksu_init_rc_hook)
# ------------------------------------------------------------------------------
echo "[4/6] Обновление хука sys_read в fs/read_write.c..."
if [ -f "fs/read_write.c" ]; then
    sed -i 's/ksu_vfs_read_hook/ksu_init_rc_hook/g' fs/read_write.c
    git add fs/read_write.c
fi

# ------------------------------------------------------------------------------
# 5. Обновление execve-хуков в fs/exec.c (добавление ksu_handle_post_execveat)
# ------------------------------------------------------------------------------
echo "[5/6] Обновление хуков execveat в fs/exec.c..."
python3 - << 'EOF'
from pathlib import Path
import re

exec_path = Path("fs/exec.c")
if exec_path.exists():
    content = exec_path.read_text(encoding="utf-8")

    # 1. Удаляем старые вызовы ksu_handle_execveat из do_execve и compat_do_execve,
    #    если они были добавлены патчем KernelSU-Next
    content = re.sub(
        r'#ifdef CONFIG_KSU\s*\n\s*__attribute__\(\(hot\)\)\s*\n\s*extern int ksu_handle_execveat\(int \*fd, struct filename \*\*filename_ptr,\s*\n\s*void \*argv, void \*envp, int \*flags\);\s*\n#endif\s*\n',
        '',
        content
    )
    content = re.sub(
        r'#ifdef CONFIG_KSU(?: // 32-bit ksud and 32-on-64 support)?\s*\n\s*ksu_handle_execveat\(\(int \*\)AT_FDCWD, &filename, &argv, &envp, 0\);\s*\n#endif\s*\n',
        '',
        content
    )

    # 2. Добавляем ksu_handle_execveat + ksu_handle_post_execveat в do_execveat_common
    target_fn = (
        "static int do_execveat_common(int fd, struct filename *filename,\n"
        "\t\t\t      struct user_arg_ptr argv,\n"
        "\t\t\t      struct user_arg_ptr envp,\n"
        "\t\t\t      int flags)\n"
        "{\n"
        "\treturn __do_execve_file(fd, filename, argv, envp, flags, NULL);\n"
        "}"
    )

    replacement_fn = (
        "#ifdef CONFIG_KSU\n"
        "__attribute__((hot))\n"
        "extern int ksu_handle_execveat(int *fd, struct filename **filename_ptr,\n"
        "\t\t\t       void *argv, void *envp, int *flags);\n"
        "__attribute__((hot))\n"
        "extern int ksu_handle_post_execveat(int *fd, struct filename **filename_ptr,\n"
        "\t\t\t\t    void *argv, void *envp, int *flags, int *retval);\n"
        "#endif\n\n"
        "static int do_execveat_common(int fd, struct filename *filename,\n"
        "\t\t\t      struct user_arg_ptr argv,\n"
        "\t\t\t      struct user_arg_ptr envp,\n"
        "\t\t\t      int flags)\n"
        "{\n"
        "#ifdef CONFIG_KSU\n"
        "\tint retval;\n"
        "\tksu_handle_execveat(&fd, &filename, &argv, &envp, &flags);\n"
        "\tretval = __do_execve_file(fd, filename, argv, envp, flags, NULL);\n"
        "\tksu_handle_post_execveat(&fd, &filename, &argv, &envp, &flags, &retval);\n"
        "\treturn retval;\n"
        "#else\n"
        "\treturn __do_execve_file(fd, filename, argv, envp, flags, NULL);\n"
        "#endif\n"
        "}"
    )

    if "ksu_handle_post_execveat" not in content and target_fn in content:
        content = content.replace(target_fn, replacement_fn, 1)

    exec_path.write_text(content, encoding="utf-8")
EOF
git add fs/exec.c

# ------------------------------------------------------------------------------
# 6. Обновление build.sh
# ------------------------------------------------------------------------------
echo "[6/6] Обновление build.sh..."
if [ -f "build.sh" ]; then
    sed -i 's/git submodule update --init --recursive --remote/git submodule update --init --recursive/g' build.sh
    sed -i 's/Droidspaces-KSUN-/Droidspaces-BakaSU-/g' build.sh
    git add build.sh
fi

echo ""
echo "[+] Готово! Статус изменений:"
git status -s
echo ""
echo "Для фиксации и отправки изменений в репозиторий выполните:"
echo "  git commit -m 'drivers: replace KernelSU-Next with BakaSU'"
echo "  git push origin main"
