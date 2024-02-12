#!/bin/bash
# v1.19a 
#Разработчик Алексей Томбасов, 1С-Рарус (Новосибирск) 2023г.
###Скрипт предназначен для архивации баз СУБД PostgreSQL.
#Поддерживаются следующие возможности:
# - Передача отчетов в Telegram.
# - Хранение логов в папке по выбору.
# - Отбор БД по части имени.
# - Исключение БД из отбора по части имени
# - Выбор количества потоков работы
# - Выбор режима работы: auto, handle
# - Выбор каталога для хранения копий БД
# - Выбор коэфицента сжатия БД
# - Возможность подключения к удаленным серверам PostgreSQL используя произвольные учетные данные
# - Выбор количества дампов находящихся на хранении

#Параметры: 
# режим -h handle - режим для принудительной архивации по требованию, отличается от автоматической способом хранения копий, при автоматической для каждой БД создается отдельный подкаталог для хранения копий, при режиме handle все копии хранятся в одном каталоге
# -d каталог хранения копий -d (путь)
# -n количество потоков -n (число), значение по умолчанию '0' (Вывод справки)
# -b шаблон имени БД  для отбора -b 'шаблон', значение по умолчанию ''
# -e шаблон имени БД  для исключения из отбора -e 'шаблон', значение по умолчанию ''
# -k Количество дампов БД находящихся на хранении -k, значение по умолчанию 0 (не удалять дампы/бесконечное количество), сначала удаляются самые старые
# -t токен телеграм -t '1234567890:AAAAAAAAAAAAAAAAAAAAAAAAAAAAA' , по умолчанию не задан
# -c номер канала телеграм -c '-0987654321', по умолчанию не задан
# -l каталог хранения логов permLogDir -l, , по умолчанию не задан
# -z коэфицент сжатия БД -z, значение по умолчанию 1
# -s строка подключения -s, по умолчанию не задана
# -u отключение сортировки БД по размеру от большей к меньшей, по умолчанию сортировка включена


#Инициализация переменных со значениями по умолчанию
#Задаем коэффицент сжатия дампов (0 -без сжатия, 1- минимальное, 9 - максимальное), 1 - минимальное сжатие (используется по умолчанию), оно существенно быстрее максимального 9 (в больших БД разница в скорости несколько раз), при 9 экономия места не более 10% зачастую около 3%.
CR=1
#Задаем переменную "Максимальное количество потоков", значение по умолчанию 0 (вывод справки)
maxStreams=0
#Задаем каталог хранения логов, вернее задаем пустое место и логи по умолчанию не храним
permLogDir=''
#Задаем количество хранимых дампов БД, по умолчанию 0 - не удалять
dumpsLimit=0
#Задаем переменную с параметрами сортировки БД
DBSort='ORDER BY pg_database_size(datname) DESC'

##Функция отправки сообщений в Telegram
#Проверяет наличие переменных ChatID и telToken, если заданы, отправляем сообщение в Телеграм
function sendToTelegram {
if [[ -n ${chatID} && -n ${telToken} ]]
  then
    /usr/bin/curl -s --header 'Content-Type: application/json' --request 'POST' --data "{\"chat_id\":\"${chatID}\",\"text\":\"${subj}\n${errorString}\"}" "https://api.telegram.org/bot${telToken}/sendMessage" > /dev/null 2>&1
  fi
}

#Разбор аргументов командной строки
while [ -n "$1" ]
do
  case "$1" in
#Режим - если указано, используется для ручной архивации (по требованию плользователя), по умолчанию используется режим для автоматической архивации
  -h) dumpMode='handle';;
#Отключение сортировки БД по размеру
  -u) DBSort='';;
#Количество потоков выполения, значение по умолчанию 0 (вывод справки)
  -n) maxStreams="$2"
    shift ;;
#Каталог хранения копий БД
  -d) mainDumpDir="$2"
    shift ;;
#Регулярное выражение для отбора БД по имени
  -b) DBNamePtrn="$2"
    shift ;;
#Регулярное выражение для исключения из отбора БД по имени
  -e) DBNameExcludePtrn=" AND datname !~* '$2'"
    shift ;;
#Токен телеграм-бота, если отсутствует, сообщения отправляться не будут
  -t) telToken="$2"
    shift ;;
#ID чата в телеграм, если отсутствует, сообщения отправляться не будут
  -c) chatID="$2"
    shift ;;
#Каталог для хранения лога операции, по умолчанию не указан, если недоступен лог не сохраняется
  -l) permLogDir="$2"
    shift ;;
#Коэфицент сжатия БД, 0 - без сжатия, 1 - минимальное ... 9 - максимальное
  -z) CR="$2"
    shift ;;
#Строка подключения к PostgreSQL
  -s) connString="$2/"
    shift ;;
#Количество неудаляемых дампов БД
  -k) dumpsLimit="$2"
    shift ;;
  esac
  shift
done

##Проверки передаваемых аргументов на корректность
#Проверяем соответствие аргумента, числа потоков типу число
if echo ${maxStreams} |grep -q '[^[:digit:]]'
then
  echo "Параметр число потоков, должен быть цифровым"
  echo "Для вывода справки запустите скрипт без параметров"
  subj="\uD83C\uDD98 !!! Ошибка выполнения резервного копирования на $(hostname), параметр число потоков, должен быть цифровым"
  sendToTelegram
  exit 1
fi

#Проверяем существование каталога хранения дампов и права на запись к нему
if [ -d ${mainDumpDir} ]
then
  if [ ! -w ${mainDumpDir} ]
  then
    echo -e "Отсутсвуют права на запись в каталог \"${mainDumpDir}\""
    echo "Для справки запустите скрипт без параметров"
    subj="\uD83C\uDD98 !!! Ошибка выполнения резервного копирования на $(hostname), отсутсвуют права на запись в каталог ${mainDumpDir}"
    sendToTelegram
    exit 1
  fi
else
  echo -e "Каталог \"${mainDumpDir}\" не существует"
  echo "Для справки запустите скрипт без параметров"
  subj="\uD83C\uDD98 !!! Ошибка выполнения резервного копирования на $(hostname), каталог ${mainDumpDir} не существует"
  sendToTelegram
  exit 1
fi

#Проверяем тип аргумента коэффициент сжатия, должен быть числовым
if echo ${CR} |grep -q '[^[:digit:]]'
then
  echo "Аргумент \"Коэфицент сжатия\" должен быть цифровым от 0 до 9"
  echo "Для справки запустите скрипт без параметров"
  subj="\uD83C\uDD98 !!! Ошибка выполнения резервного копирования на $(hostname), аргумент Коэфицент сжатия должен быть цифровым от 0 до 9"
  sendToTelegram
  exit 1
fi

#Проверяем диапазон числа переменной коэфицент сжатия, должно быть от 0 до 9
if [[ ${CR} -lt 0 ||  ${CR} -gt 9 ]]
then
  echo "Значение аргумента \"Коэфицент сжатия\" должно лежать в диапазоне от 0 до 9"
  echo "Для справки запустите скрипт без параметров"
  subj="\uD83C\uDD98 !!! Ошибка выполнения резервного копирования на $(hostname), значение аргумента Коэфицент сжатия должно лежать в диапазоне от 0 до 9"
  sendToTelegram
  exit 1
fi

#Проверяем тип аргумента "количество дампов", должен быть числовым
if echo ${dumpsLimit} |grep -q '[^[:digit:]]'
then
  echo "Аргумент \"Количество дампов\" должен быть числовым"
  echo "Для справки запустите скрипт без параметров"
  subj="\uD83C\uDD98 !!! Ошибка выполнения резервного копирования на $(hostname), аргумент Количество дампов должен быть числовым"
  sendToTelegram
  exit 1
fi

#Блок справки 
if [[ ${maxStreams} -eq 0 ]]
then
  echo "Скрипт предназначен для многопоточной архивации БД расположенных на СУБД PostgreSQL v1.18
  Пример ./pgsql_multi_stream_backup.sh -n количество_потоков -d путь [-h] [-b строка] [-e строка] [-t токен] [-c ЧатИД] [-l путь] [-z 0...9] [-k количество_копий]
  
  -n количество потоков выполнения, во избежание перегрузок лучше устанавливать количество потоков не большее чем количество ядер процессора на СУБД
  -h (handle) - режим ручной архивации, отличается от автоматической способом хранения копий, при автоматической для каждой БД создается отдельный каталог для хранения копий, при режиме handle все копии хранятся в одном каталоге, имя которого создается на основе даты_времени начала архивации
  -u отключить сортировку БД по размеру (включена по умолчанию)
  -d путь к каталогу хранения копий БД
  -b шаблон для отбора БД по имени (если содержит символы кроме букв и цифр, необходимо использовать кавычки '') 
  -e шаблон имени БД для исключения из отбора (если содержит символы кроме букв и цифр необходимо, использовать кавычки '')
  Подробнее о регулярных выражениях можно прочесть тут https://postgrespro.ru/docs/postgrespro/15/functions-matching
  -t токен телеграм-бота
  -k количество хранимых последних дампов БД (по умолчанию 0 - не удаляются)
  -c ИД канала-адреса сообщения в телеграм
  -l Путь к каталогу хранения логов (у пользователя от имени которого выполняется скрипт должны быть права на запись в этот каталог), если  не будет возможности записать в указанный каталог, лог не сохраняется
  -z Коэфицент сжатия БД 0 - без сжатия 1 -минимальное (используется по умолчанию) ... 9 - максимальное сжатие
  -s Строка подключения к СУБД postgresql://user:secret@localhost    Важно!!! не нужно указывать имя БД
  Подробнее о connection string можно прочесть тут, https://postgrespro.ru/docs/postgrespro/10/libpq-connect
  
  Скрипт необходимо запускать от имени пользователя службы PostgreSQL или указывать строку подключения к СУБД
  Пользователь СУБД должен обладать ролью supervisor."
  exit 2
fi

#Инициализируем переменную количества запущенных потоков значением 0
streamCounter=0
#Получаем PID главного процесса
myPID=$$
echo "Подготовка списка БД $(date +%Y%m%d)_$(date +%H%M)"
echo "Это может занять несколько минут"
#Получаем список БД, без шаблонов или заблокированных БД, с пользовательскими условиями отбора и отсортиванный по размеру БД, от больших баз к маленьким, при большом количестве БД это может занять несколько минут
DBList="$(psql --dbname=${connString}postgres -q -c '\timing off' -c "SELECT datname FROM pg_database WHERE datallowconn = 'true' AND datistemplate = false AND datname ~* '${DBNamePtrn}' ${DBNameExcludePtrn} ${DBSort};" -t)"

#Проверяем подключение к СУБД
if [ $? -ne 0 ]
then
  echo "Ошибка подключения к СУБД"
  subj="\uD83C\uDD98 $(hostname) Ошибка подключения к СУБД при выполнении резервного копирования"
  sendToTelegram
  exit 1
fi

#Получаем время начала процесса резервного копирования БД, формат ГГГГммдд_ЧЧММ
ST="$(date +%Y%m%d)_$(date +%H%M)"
#Сообщение в консоль
echo "Старт резервного копирования БД ${ST}"
#Задаем путь до временного каталога логов
logDir="/tmp/db_dump_log_${ST}"
#Задаем путь до временного каталога состояний выполнения pg_dump (успешно/нет)
dumpStateDir="/tmp/db_dump_state_${ST}"

#Инициалируем счетчик количества обработанных БД
dumpDBCounter=0

#Проверяем существование временного каталога для логов, если не существует создаем
  if [[ ! -d $logDir ]]
  then
    mkdir -p $logDir
    sleep 5
  fi
  
#Проверяем существование временного каталога для состояний выполнения pg_dump, если не существует создаем

  if [[ ! -d $dumpStateDir ]]
  then
    mkdir -p $dumpStateDir
    sleep 5
  fi

#Перебираем список БД
for DBName in $DBList
do
#Обработчик очереди выполнения, если количество потоков обработки достигло максимально разрешенного, ждем и проверяем каждые 2 секунды, если длина очереди сократилась запускаем следующий поток
  streamCounter=$((`ps ax -Ao ppid | grep $myPID | wc -l`))
  while [ $streamCounter -gt $maxStreams ]
  do
    sleep 2
    streamCounter=$((`ps ax -Ao ppid | grep $myPID | wc -l`))
  done
#Прибавляем единицу к счетчику БД
  let dumpDBCounter+=1

#Формируем путь к каталогу сохранения дампа в зависимости от распознанного режима: ручной, автоматический
  if [[ ${dumpMode} == 'handle' ]]
  then
    dumpDir="${mainDumpDir}/${ST}"
  else
    dumpDir="${mainDumpDir}/${DBName}"
  fi	
  
#Проверяем существование каталога для размещения дампа, если не существует создаем
  if [[ ! -d $dumpDir ]]
  then
    mkdir -p $dumpDir
    sleep 5
  fi

#Задаем путь до файла дампа БД
  dumpPath="${dumpDir}/${DBName}_$(date +%Y%m%d)_$(date +%H%M).dump"   
#Задаем путь до лог-файла БД
  logPath="${logDir}/${DBName}.log"
#Задаем путь до файла состояния выполнения pg_dump
  dumpStatePath="${dumpStateDir}/${DBName}.state"
  
#Запускаем резервное копирование в фоновом режиме, собираем отчеты о ходе выполнения во временную папку логов
  ( 
  pg_dump -w --compress=${CR} --encoding=UTF8 --format=custom --file="${dumpPath}" --dbname=${connString}${DBName} > ${logPath} 2>&1
#Проверяем код выполенния предыдущей команды (должно быть 0) и наличие файла дампа
  if [ $? -eq 0 ] && [ -f ${dumpPath} ]
#Если условие выполняеся удаляем старые дампы, осталяя заданное переменной dumpsLimit количество, если dumpsLimit равна 0, не удаляем дампы, пишем лог
  then 
    echo "${DBName} dump_ok"|tee ${dumpStatePath}|tee -a ${logPath}
    dumpsCounter=$((`ls -1t ${dumpDir}/*.dump | wc -l`))
    while [ ${dumpsCounter} -gt ${dumpsLimit} ] && [ ${dumpsLimit} -ne 0 ]
    do
      ls -1t ${dumpDir}/*.dump  | tail -n 1 | xargs rm -vf  2>&1 |tee -a ${logPath}
	  dumpsCounter=$((`ls -1t ${dumpDir}/*.dump | wc -l`))
    done
#Если условие не выполняется удаляем созданный файл дампа, если он конечно присутствует, пишем лог
  else
    echo "${DBName} dump_error"|tee ${dumpStatePath}|tee -a ${logPath}
	rm -vf ${dumpPath} 2>&1 |tee -a ${logPath}
  fi 
  ) & 
done

#Ожидание завершения потоков архивации, проверяем каждые 2 секунды, как только завершиться выполняем код дальше
streamCounter=$((`ps ax -Ao ppid | grep $myPID | wc -l`))
while [ $streamCounter -gt 1 ]
do
  streamCounter=$((`ps ax -Ao ppid | grep $myPID | wc -l`))
  sleep 2
done

##Проверка работы резервного копирования
#Инициализируем переменную количества ошибок создания дампов БД значением 0
dumpErrorCount=0
#Инициализируем переменную строки с ошибками для передачи в телеграм
errorString=''
#Инициализируем переменную строки с ошибками для сводного журнала
errorStateString=''
#Перебираем список БД
for DBName in ${DBList}
do
#Задаем путь до дайла состояния выполнения дампа БД
  dumpStatePath="${dumpStateDir}/${DBName}.state"
#Поверяем статус выполнения резервного копирования каждой базы
#Пишем ошибки в журнал и для передачи в Telegram
  if [[  -f ${dumpStatePath} ]]
  then
    if grep -q 'dump_error' ${dumpStatePath}
    then
      let dumpErrorCount+=1
      errorString+=" ${DBName} - Зарегистрирован сбой при резервном копировании БД\n"
      errorStateString+="${DBName} dump error\n"
    else
      if grep -q 'dump_ok' ${dumpStatePath}
      then
        errorStateString+="${DBName} dump ok\n"
      else
        let dumpErrorCount+=1
        errorString+=" ${DBName} - Отсутствует уведомление об успешном завершении резервного копирования БД\n"
        errorStateString+="${DBName} dump error (state file is empty)\n"
      fi
    fi	
  else
    let dumpErrorCount+=1
    errorString+=" ${DBName} - Файл лога резервного копирования БД отсутствует\n"
    errorStateString+="${DBName} (state file is missing)\n"
  fi
done


#Выбор иконки для успешного или не успешного завершения
if [[ ${dumpErrorCount} -gt 0 ]]
then
  icon='\uD83C\uDD98 '
else
  icon='\u2705'
fi

# Отправляем отчет о работе резервного копирования
subj="${icon}Резервное копирование ${ST} на СУБД $(hostname) завершено, обработано баз ${dumpDBCounter}, ошибок ${dumpErrorCount}\n"
sendToTelegram

#Создание отчета с состояними создания дампов БД
#Если целевой каталог существует и имеет права на запись для пользователя запустившего скрипт, создаем файл состояний выполнения дампов БД
  if [[ -w ${permLogDir} ]]
  then
    echo -e ${errorStateString} > ${permLogDir}/${ST}_dumps.state
  fi
#Удаляем файлы состояний из временного хранилища
rm -rf ${dumpStateDir}
#Перенос файлов лога на постоянное место хранения
#Если целевой каталог существует и имеет права на запись для пользователя запустившего скрипт, упаковываем и переносим логи на постоянное место хранения
#Если нет, удаляем логи
  if [[ -w ${permLogDir} && -d ${logDir} ]]
  then
    cd ${logDir}
	tar -czf ${permLogDir}/${ST}_dump_logs.tar.gz *.log
	rm -rf ${logDir}
  elif [[ -d ${logDir} ]]
  then
    rm -rf ${logDir}
  fi
#Сообщение в консоль
echo "Завершение резервного копирования БД $(date +%Y%m%d)_$(date +%H%M)"
