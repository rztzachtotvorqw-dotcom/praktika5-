#!/usr/bin/env bash
# Настройка Nexus для практики через REST API (альтернатива ручной настройке в UI).
# Запускать на машине, где работает контейнер nexus.
#
# Что делает (каждый шаг пропускается, если уже сделан — скрипт можно запускать повторно):
#   1. ждёт готовности Nexus;
#   2. меняет стартовый пароль admin (из /nexus-data/admin.password) на ADMIN_PASSWORD;
#   3. включает анонимный доступ на чтение (чтобы apt в контейнере мог скачивать без логина);
#   4. создаёт hosted APT-репозиторий syspulse (distribution=stable, Allow redeploy, подпись GPG);
#   5. создаёт роль syspulse-deployer с правами только на этот репозиторий;
#   6. создаёт пользователя deployer с этой ролью (его логин/пароль → секреты GitHub).
#
# Использование:
#   ADMIN_PASSWORD='...' DEPLOYER_PASSWORD='...' GPG_PASSPHRASE='...' ./scripts/nexus-setup.sh
set -euo pipefail
cd "$(dirname "$0")/.."

NEXUS_URL="${NEXUS_URL:-http://localhost:8081}"
NEXUS_CONTAINER="${NEXUS_CONTAINER:-nexus}"
REPO="${REPO:-syspulse}"
APT_DIST="${APT_DIST:-stable}"
DEPLOYER_USER="${DEPLOYER_USER:-deployer}"
ROLE_ID="${ROLE_ID:-syspulse-deployer}"
GPG_PRIVATE_KEY_FILE="${GPG_PRIVATE_KEY_FILE:-syspulse-repo.private.asc}"
: "${ADMIN_PASSWORD:?задайте ADMIN_PASSWORD — новый пароль администратора}"
: "${DEPLOYER_PASSWORD:?задайте DEPLOYER_PASSWORD — пароль для пользователя ${DEPLOYER_USER}}"
: "${GPG_PASSPHRASE:?задайте GPG_PASSPHRASE — пароль приватного ключа}"
[ -f "${GPG_PRIVATE_KEY_FILE}" ] || { echo "Нет ${GPG_PRIVATE_KEY_FILE}. Сначала запустите ./scripts/gen-gpg-key.sh" >&2; exit 1; }
command -v python3 >/dev/null || { echo "Нужен python3 (для сборки JSON)" >&2; exit 1; }

OUT="$(mktemp)"; trap 'rm -f "${OUT}"' EXIT

# api <user:pass> <METHOD> <path> [доп. аргументы curl] → печатает HTTP-код, тело в ${OUT}
api() {
  local auth="$1" method="$2" path="$3"; shift 3
  curl -sS -o "${OUT}" -w '%{http_code}' -u "${auth}" -X "${method}" \
       "${NEXUS_URL}/service/rest${path}" "$@" || true
}
ok() { [[ "$1" == 2?? ]]; }   # любой 2xx — успех
fail() {
  echo "❌ $1 (HTTP $2)"; cat "${OUT}" 2>/dev/null; echo
  echo "Подсказка: зайдите в UI под admin — в новых версиях Nexus при первом входе"
  echo "нужно пройти мастер настройки/принять лицензию. Затем запустите скрипт снова."
  exit 1
}
ADMIN="admin:${ADMIN_PASSWORD}"
JSON=(-H "Content-Type: application/json")

echo "1/6 Ждём готовности Nexus на ${NEXUS_URL} ..."
for i in $(seq 1 60); do
  curl -fsS -o /dev/null "${NEXUS_URL}/service/rest/v1/status/writable" && break
  [ "$i" = 60 ] && { echo "Nexus не поднялся за 5 минут: docker logs ${NEXUS_CONTAINER}"; exit 1; }
  sleep 5
done
echo "    ✅ Nexus готов"

echo "2/6 Пароль администратора"
code=$(api "${ADMIN}" GET "/v1/security/users?userId=admin")
if [ "${code}" = 200 ]; then
  echo "    ✅ admin уже с новым паролем — пропускаем"
else
  INIT_PW="$(docker exec "${NEXUS_CONTAINER}" cat /nexus-data/admin.password 2>/dev/null || true)"
  [ -n "${INIT_PW}" ] || { echo "Не найден /nexus-data/admin.password, а ADMIN_PASSWORD не подходит"; exit 1; }
  code=$(api "admin:${INIT_PW}" PUT "/v1/security/users/admin/change-password" \
         -H "Content-Type: text/plain" --data-binary "${ADMIN_PASSWORD}")
  ok "${code}" || fail "Не удалось сменить пароль admin" "${code}"
  echo "    ✅ пароль admin изменён"
fi

echo "3/6 Анонимный доступ (чтение для apt-клиентов)"
code=$(api "${ADMIN}" PUT "/v1/security/anonymous" "${JSON[@]}" \
       -d '{"enabled": true, "userId": "anonymous", "realmName": "NexusAuthorizingRealm"}')
ok "${code}" || fail "Не удалось включить анонимный доступ" "${code}"
echo "    ✅ включён"

echo "4/6 Hosted APT-репозиторий '${REPO}'"
code=$(api "${ADMIN}" GET "/v1/repositories")
[ "${code}" = 200 ] || fail "Не удалось получить список репозиториев" "${code}"
if python3 -c 'import json,sys; sys.exit(0 if any(r["name"]==sys.argv[2] for r in json.load(open(sys.argv[1]))) else 1)' "${OUT}" "${REPO}"; then
  echo "    ✅ уже существует — пропускаем"
else
  BODY="$(REPO="${REPO}" APT_DIST="${APT_DIST}" KEYFILE="${GPG_PRIVATE_KEY_FILE}" python3 -c '
import json, os
print(json.dumps({
  "name": os.environ["REPO"],
  "online": True,
  "storage": {"blobStoreName": "default", "strictContentTypeValidation": True, "writePolicy": "allow"},
  "apt": {"distribution": os.environ["APT_DIST"]},
  "aptSigning": {"keypair": open(os.environ["KEYFILE"]).read(), "passphrase": os.environ["GPG_PASSPHRASE"]},
}))')"
  code=$(api "${ADMIN}" POST "/v1/repositories/apt/hosted" "${JSON[@]}" --data-binary @- <<<"${BODY}")
  ok "${code}" || fail "Не удалось создать репозиторий" "${code}"
  echo "    ✅ создан: ${NEXUS_URL}/repository/${REPO}/"
fi

echo "5/6 Роль '${ROLE_ID}'"
code=$(api "${ADMIN}" GET "/v1/security/roles/${ROLE_ID}")
if [ "${code}" = 200 ]; then
  echo "    ✅ уже существует — пропускаем"
else
  code=$(api "${ADMIN}" POST "/v1/security/roles" "${JSON[@]}" -d "{
    \"id\": \"${ROLE_ID}\", \"name\": \"${ROLE_ID}\",
    \"description\": \"Deploy/read APT packages to ${REPO}\",
    \"privileges\": [\"nx-repository-view-apt-${REPO}-*\"], \"roles\": []}")
  ok "${code}" || fail "Не удалось создать роль" "${code}"
  echo "    ✅ создана (привилегия nx-repository-view-apt-${REPO}-*)"
fi

echo "6/6 Пользователь '${DEPLOYER_USER}'"
code=$(api "${ADMIN}" GET "/v1/security/users?userId=${DEPLOYER_USER}")
if [ "${code}" = 200 ] && python3 -c 'import json,sys; sys.exit(0 if any(u["userId"]==sys.argv[2] for u in json.load(open(sys.argv[1]))) else 1)' "${OUT}" "${DEPLOYER_USER}"; then
  echo "    ✅ уже существует — пропускаем"
else
  BODY="$(U="${DEPLOYER_USER}" P="${DEPLOYER_PASSWORD}" R="${ROLE_ID}" python3 -c '
import json, os
print(json.dumps({"userId": os.environ["U"], "firstName": "CI", "lastName": "Deployer",
  "emailAddress": os.environ["U"] + "@example.com", "password": os.environ["P"],
  "status": "active", "roles": [os.environ["R"]]}))')"
  code=$(api "${ADMIN}" POST "/v1/security/users" "${JSON[@]}" --data-binary @- <<<"${BODY}")
  ok "${code}" || fail "Не удалось создать пользователя" "${code}"
  echo "    ✅ создан"
fi

echo
echo "🎉 Готово. APT-URL для клиентов: ${NEXUS_URL}/repository/${REPO}/  (${APT_DIST} main)"
echo "   Секреты GitHub: NEXUS_HOST=<IP этой машины>, NEXUS_USER=${DEPLOYER_USER}, NEXUS_PASSWORD=<DEPLOYER_PASSWORD>"
