# Автономный verify (отдельный сервер)

Каталог [`rw-backup-verify/`](../rw-backup-verify/) — отдельный продукт.

- Глубокий обход S3 (любая вложенность panel/bot архивов)
- Latest на каждый экземпляр; уже протестированные ключи пропускаются
- Глобальная частота проверок на все хранилища
- Bot restore как `custom-restore` (PROFILE + redis RDB + isolate)

См. [rw-backup-verify/README-RU.md](../rw-backup-verify/README-RU.md).
