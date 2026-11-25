#!/usr/bin/env bash
# Генерирует GPG-ключ для подписи метаданных APT-репозитория в Nexus.
#
# Зачем: при создании hosted APT-репозитория Nexus ТРЕБУЕТ приватный ключ
# (поле Signing Key) — им он подписывает Release/InRelease.
#
# Результат:
#   keys/syspulse-repo.asc      — ПУБЛИЧНЫЙ ключ. Коммитим: им apt проверяет подпись (signed-by).
#   syspulse-repo.private.asc   — ПРИВАТНЫЙ ключ. Вставляем в Nexus → Signing Key. НЕ коммитим!
#
# Использование:
#   GPG_PASSPHRASE='придумайте-пароль' ./scripts/gen-gpg-key.sh
set -euo pipefail
cd "$(dirname "$0")/.."

KEY_UID="${KEY_UID:-syspulse APT repo <devops@example.com>}"
KEY_EXPIRE="${KEY_EXPIRE:-2y}"

if [ -z "${GPG_PASSPHRASE:-}" ]; then
  read -rsp "Пароль для приватного ключа: " GPG_PASSPHRASE; echo
fi
[ -n "${GPG_PASSPHRASE}" ] || { echo "Пароль не может быть пустым" >&2; exit 1; }

if [ -e syspulse-repo.private.asc ] || [ -e keys/syspulse-repo.asc ]; then
  echo "Ключи уже существуют — удалите их вручную, если хотите сгенерировать заново." >&2
  exit 1
fi

# Временный keyring, чтобы не засорять ваш ~/.gnupg
GNUPGHOME="$(mktemp -d)"; export GNUPGHOME
trap 'rm -rf "${GNUPGHOME}"' EXIT

# Пароль передаём через файловый дескриптор 3, а не аргументом (не светится в ps)
gpg --batch --pinentry-mode loopback --passphrase-fd 3 \
    --quick-generate-key "${KEY_UID}" rsa4096 sign "${KEY_EXPIRE}" 3<<<"${GPG_PASSPHRASE}"

FPR="$(gpg --batch --with-colons --list-keys | awk -F: '/^fpr:/ {print $10; exit}')"

mkdir -p keys
gpg --batch --armor --export "${FPR}" > keys/syspulse-repo.asc
umask 077
gpg --batch --pinentry-mode loopback --passphrase-fd 3 \
    --armor --export-secret-keys "${FPR}" > syspulse-repo.private.asc 3<<<"${GPG_PASSPHRASE}"

echo
echo "✅ Ключ создан, отпечаток: ${FPR}"
echo "   Публичный:  keys/syspulse-repo.asc      → git add + commit"
echo "   Приватный:  syspulse-repo.private.asc   → вставить в Nexus (Signing Key), в git НЕ добавлять"
