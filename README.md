# pgsql_multi_stream_backup

Многопоточная архивация баз PostgreSQL (Multistream backups for PostgreSQL)

Разработчик Алексей Томбасов, 1С-Рарус (Новосибирск) 2024г.

Скрипт предназначен для многопоточной архивации баз СУБД PostgreSQL.

Поддерживаются следующие возможности:
- Передача отчетов в Telegram.
- Хранение логов в папке по выбору.
- Отбор БД по части имени.
- Исключение БД из отбора по части имени
- Выбор количества потоков работы
- Выбор режима работы: auto, handle
- Выбор каталога для хранения копий БД
- Выбор коэфицента сжатия БД
- Подключение к удаленным серверам PostgreSQL используя произвольные учетные данные
- Выбор количества дампов находящихся на хранении
- Сортировка БД по размеру

  Пример ./pgsql_multi_stream_backup.sh -n количество_потоков -d путь [-h] [-o] [-u] [-b строка] [-e строка] [-t токен] [-c ЧатИД] [-l путь] [-z 0...9] [-k количество_копий]
  
 - -n количество потоков выполнения, во избежание перегрузок лучше устанавливать количество потоков не большее чем количество ядер процессора на СУБД
 - -h (handle) - режим ручной архивации, отличается от автоматической способом хранения копий, при автоматической для каждой БД создается отдельный каталог для хранения копий, при режиме handle копии хранятся в одном каталоге, имя которого создается на основе даты_времени начала архивации
 - -o передать в Телеграм архив с отчетами о выполнении резервного копирования
  -u отключить сортировку БД по размеру (включена по умолчанию)
  -d путь к каталогу хранения копий БД
  -b шаблон для отбора БД по имени (если содержит символы кроме букв и цифр, необходимо использовать кавычки '') 
  -e шаблон имени БД для исключения из отбора (если содержит символы кроме букв и цифр необходимо, использовать кавычки '')
  Подробнее о регулярных выражениях можно прочесть тут https://postgrespro.ru/docs/postgrespro/15/functions-matching
  -k количество хранимых последних дампов БД, после выполнения резервного копирования удалит самые старые дампы оставив указнное количество дампов (по умолчанию 0 - не удаляются)
  -t токен телеграм-бота (по умолчанию не задан, работает совместно с -c)
  -c ИД канала-адреса сообщения в телеграм (по умолчанию не задан, работает совместно с -t)
  -l Путь к каталогу хранения логов (у пользователя от имени которого выполняется скрипт должны быть права на запись в этот каталог), если  не будет возможности записать в указанный каталог, лог не сохраняется
  -z Коэфицент сжатия БД 0 - без сжатия 1 -минимальное (используется по умолчанию) ... 9 - максимальное сжатие
  -s Строка подключения к СУБД postgresql://user:secret@localhost    Важно!!! не нужно указывать имя БД
  Подробнее о connection string можно прочесть тут, https://postgrespro.ru/docs/postgrespro/15/libpq-connect
  
  Скрипт необходимо запускать от имени пользователя службы PostgreSQL (sudo -u postgres имя_скрипта параметры) или указывать строку подключения к СУБД
  Пользователь СУБД должен обладать ролью supervisor.
