# syspulse — Практика №5: .deb → Nexus (APT) → apt install

Полный цикл **build → package → publish → install → verify** в GitHub Actions на self-hosted раннере.

```
.
├── main.go                         # утилита syspulse (const Version — источник версии пакета)
├── go.mod
├── .github/workflows/publish-deb.yml   # пайплайн (запуск: push в ветку release или вручную)
├── keys/syspulse-repo.asc          # публичный GPG-ключ репозитория (появится после gen-gpg-key.sh)
└── scripts/
    ├── gen-gpg-key.sh              # генерация ключа подписи для Nexus
    └── nexus-setup.sh              # настройка Nexus через REST API (альтернатива UI)
```

## Раннер на macOS (Intel или Apple Silicon)

```bash
brew install dpkg gnupg          # dpkg-deb для упаковки, gpg для ключа
# Docker Desktop: запущен; Settings → Resources → Memory ≥ 4 GB (Nexus прожорлив)
# Apple Silicon: Settings → General → "Use Rosetta for x86_64/amd64 emulation" — включить
```

* `NEXUS_HOST` = `localhost`: workflow сам подставит `host.docker.internal` внутри контейнера.
* Контейнер проверки запускается с `--platform linux/amd64` — пакет amd64 ставится и на M1/M2/M3.
* Если раннер запущен как сервис (`./svc.sh`), шаг `0a` добавит Homebrew и Docker в PATH.

## Быстрый старт

```bash
# 1. Nexus (на машине, доступной раннеру)
docker run -d --name nexus -p 8081:8081 -v nexus-data:/nexus-data sonatype/nexus3
docker exec nexus cat /nexus-data/admin.password     # стартовый пароль admin

# 2. Ключ подписи (Nexus требует его для hosted APT)
GPG_PASSPHRASE='пароль-ключа' ./scripts/gen-gpg-key.sh

# 3. Репозиторий, роль и пользователь в Nexus — через UI или одной командой:
ADMIN_PASSWORD='новый-пароль-admin' DEPLOYER_PASSWORD='пароль-deployer' \
GPG_PASSPHRASE='пароль-ключа' ./scripts/nexus-setup.sh

# 4. Секреты GitHub: Settings → Secrets and variables → Actions
#    NEXUS_HOST = IP машины с Nexus (не localhost, если Nexus на другой машине)
#    NEXUS_USER = deployer,  NEXUS_PASSWORD = пароль deployer

# 5. Запуск пайплайна
git add . && git commit -m "Practice 5: deb -> Nexus -> apt"
git push origin HEAD:release
```

## Проверка руками

```bash
curl http://<host>:8081/repository/syspulse/dists/stable/Release
curl http://<host>:8081/repository/syspulse/dists/stable/main/binary-amd64/Packages
```

## Новая версия

Поменяйте `const Version` в `main.go` и запушьте в `release` — версия .deb подтянется сама.
