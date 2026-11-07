# Smart DNS

🧩 **Smart DNS** — DNS-сервер с возможностью проксирования выбранных сайтов через ваш VPS. Аналог Comms DNS.
Работает на связке **Adguard Home** и **Nginx**:

- **Adguard Home** обрабатывает DNS-запросы и подменяет IP для выбранных доменов.
- **Nginx** в режиме `stream` проксирует трафик к выбранным доменам на ваш VPS.

Вы указываете список доменов (например, `openai.com`, `claude.ai`, `google.com`),  
и DNS-сервер будет возвращать IP вашего VPS. Запросы пойдут в Nginx на VPS. Всё остальное работает напрямую.  
Это удобно для обхода геоблокировок сервисов. ⚠️ При блокировках на уровне провайдера или РКН метод не поможет.

---

## Структура проекта

```

smart-dns/
├── adguard/
│   ├── docker-compose.yml   # запуск Adguard Home
│   ├── domains.txt          # список доменов для проксирования
│   ├── gen_entries.sh       # генерация правил для Nginx и Adguard
│   ├── conf/                # конфигурация Adguard Home
│   └── work/                # рабочие файлы Adguard Home
└── nginx/
│   └── nginx.conf           # основной конфиг с SNI-proxy
└── AdGuardHome_start.yaml   # файл с первоначальной конфигурацией Adguard Home

````

---

## Как это работает

1. В `domains.txt` перечисляются домены для проксирования.
2. `gen_entries.sh` генерирует из них правила для Adguard Home и Nginx.
3. Adguard Home отвечает клиенту IP-адресом VPS.
4. Nginx принимает HTTPS-запросы и перенаправляет их дальше.

---

## Быстрый старт

1. Клонируйте репозиторий:
   ```bash
   git clone https://github.com/curserio/smart-dns.git
   cd smart-dns/adguard
   ```

2. Укажите домены в `domains.txt` для проксирования в AdGuard Home 

3. Запустите setup_smart_dns.sh:

   ```bash
   chmod +x setup_smart_dns.sh
   ./setup_smart_dns.sh domains.txt <YOU_VPS_IP> [domain] [email] [login] [password]
   ```
- [domain] - домен привязанный к VPS
- [email] - почта для выпуска ssl-сертификата (можно задать "-")
- [login] [password] - логин и пароль для админки AdGuard Home
 
4. После выполнения установки, доступ к админке AdGuard Home: `https://<domain>:9443`

5. Если необходимо добавить сайты в список проксируемых:
   - Добавить в `domains.txt` нужные для проксирования домены.
   - Выполнить:
     
   ```bash
   ./gen_entries.sh domains.txt <IP_VPS>
   ```

   - Вставить результаты: 
   * **Adguard rewrites** в `adguard/conf/AdGuardHome.yaml` → секция `filtering` (rewrites)
   * **NGINX map entries** в `/etc/nginx/nginx.conf` → секция `map`
   

