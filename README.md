# Шило (Shilo)

Комплект нативни Win32/64 конзолни инструменти за Windows internals,
форензика и файлова работа — плюс двупанелен хъб, който ги обединява.

**Философия:** нула външни DLL извън системните (kernel32/ntdll/user32/
bcrypt/combase). Директни Win32/NT API-та. `WriteConsoleW` + UTF-8 fallback
за Unicode изход. Всеки тул е един самостоятелен `.pas` → един `.exe`.
Компилира се с FPC 3.2.x за `-Twin32` и `-Twin64` (повечето — и двете;
`fcopy` е само win64 заради 64-битов атомик).

Много от тулчетата четат директно суровия `$MFT` / volume handle-и →
изискват **admin**. Отбелязано е при всеки.

---

## Хъб

### shilo — двупанелен MC-style лаунчър
Нативен конзолен файлов навигатор. Не реализира файлови операции сам —
делегира ги на тулчетата през потребителското меню (F2).

    shilo

Файлове до `shilo.exe`: `shilo.menu` (меню, MC-съвместимо), `shilo.ini`
(`[shilo] Editor=trpad.exe`).

**Клавиши:** Tab панел · стрелки/PgUp/PgDn/Home/End · Enter влизане ·
Ins маркиране · F2 меню · F4 редактор · F10/Esc изход.

Изходът на конзолен тул се прихваща в off-screen буфер и се показва в
scrollable overlay. GUI приложения (trpad, tinyPDFViewer) се пускат с
водещ `@` в менюто — без захват, хъбът чака затварянето на прозореца.

Макроси в менюто: `%f` тек. файл · `%d` тек. папка · `%s`/`%t` маркирани ·
`%F`/`%D` другият панел · `%{подкана}` пита · `%%` литерал.
Условия: `f <glob>` · `t r|d` · `d`, комбинирани с `&` / `|`.

---

## Файлови операции

### fcopy — паралелно копиране на дърво (robocopy /MT стил)
Бързо изброяване (FindFirstFileEx + LARGE_FETCH), CopyFileEx (ODX offload),
пул нишки, long-path (`\\?\`) aware. Папка се копира като поддиректория на
целта. *(само win64)*

    fcopy <източник> [<източник2> ...] <цел> [/MT[:N]] [/NB]
      /MT[:N]  N нишки (по подр. 8); за HDD ползвай 1
      /NB      COPY_FILE_NO_BUFFERING (за файлове > неск. стотин MB)

### fdel — паралелно рекурсивно триене (rd /s стил)
Пул нишки за файловете, папките bottom-up. Long-path aware. Reparse point
(junction/symlink) НЕ се обхожда — маха се линкът, не целта. Чисти
read-only/hidden/system преди триене. Отказва корен на диск без `/F`.

    fdel <път> [<път2> ...] [/MT[:N]] [/Q] [/F]
      /MT[:N]  N нишки (по подр. 8)
      /Q       тихо (без резюме)
      /F       позволи триене на корен на диск

### fcompact — bulk WOF прозрачна компресия  *(admin)*
Механизмът зад `compact /compactos`. За статични файлове (executables, .lib,
билд изходи) LZX свива 50-70%. Данните се четат прозрачно; запис връща
компресията. Декомпресия: `compact /u /s <папка>`.

    fcompact <папка> [/lzx|/x4|/x8|/x16] [/min N]
      /lzx        LZX, най-добра компресия (по подр.); бавно
      /x4/x8/x16  XPRESS 4K/8K/16K — по-бързо, по-малко
      /min N      пропусни файлове под N KB (по подр. 8)

---

## Дисково пространство и файлове (директен $MFT)

### fdu — disk usage по WizTree метода  *(admin)*
Чете директно `$MFT` вместо да обхожда дървото — един последователен прочит,
нула CreateFile. Порядъци по-бързо от du/tree/Explorer.

    fdu [C] [/n N]
      C     буква на дял (по подр. C)
      /n N  брой редове в класациите (по подр. 30)

### fdupe — дублирани файлове  *(admin)*
MFT скан групира по размер, после хешва само еднакворазмерните (BCrypt
SHA-256, нула OpenSSL). Показва пропиляното място.

    fdupe [/d X] [/min N]
      /d X    буква на дял (по подр. C)
      /min N  минимален размер в MB (по подр. 4)

### ffind — моментално търсене по име (Everything клас)  *(admin)*
Директно четене на `$MFT` — порядъци по-бързо от `dir /s` или `where`.

    ffind <текст> [/d X]
      <текст>  подниз от името (case-insensitive)
      /d X     буква на дял (по подр. C)

### ftree — истинско дърво, нищо скрито
За разлика от вградения `tree`: показва hidden + system и слиза в тях;
reparse точки маркира и резолвва target-а вместо да рекурсира (loop safety);
long-path safe.

    ftree [път] [/f] [/d N]
      път   корен (по подр. текущата папка)
      /f    включи и файловете (по подр. само папки)
      /d N  максимална дълбочина
    Флагове до името: [H]idden [S]ystem [L]reparse [E]ncrypted

---

## NTFS форензика

### fmft — суров dump на MFT запис + timestomp детекция  *(admin)*
Взима записа през FSCTL_GET_NTFS_FILE_RECORD по file reference number — не
сканира целия MFT. Сравнява `$STANDARD_INFORMATION` срещу `$FILE_NAME`
времената; разминаване (или закръглени $SI) = флаг за timestomp.

    fmft <път_до_файл>

### fusn — tail на USN журнала  *(admin)*
Всяка промяна на файл, която NTFS логва. Volume handle +
FSCTL_QUERY/READ_USN_JOURNAL.

    fusn [C] [/tail] [/n N]
      C      буква на дял (по подр. C)
      /tail  следи на живо (като tail -f); без него изхвърля текущия журнал
      /n N   спри след N записа

### fads — NTFS alternate data streams
Където Zone.Identifier (mark-of-the-web) и понякога скрит код се крият —
Explorer не ги показва. Прочети после с `more < "файл:streamname"`.

    fads <път> [/r]
      път  файл или папка
      /r   рекурсивно

---

## Процеси и handle-и

### fhandle — кой държи заключен файл/папка  *(admin)*
Изброява всички handle-и в системата (NtQuerySystemInformation), дублира ги,
сравнява File имената с целта. Дава PID, процес, handle стойност и обектно
име — подай ги на fclose.

    fhandle <път>

### fclose — затвори насила чужд handle  *(admin, ОПАСНО)*
Дублира handle-а с DUPLICATE_CLOSE_SOURCE — затваря оригинала в притежателя.
Процесът не знае, че handle-ът му изчезва; може да забие. Само за заглушени
приложения, не за системни handle-и.

    fclose <PID> <handle>       (handle: 0x4F8 или десетично)

---

## Registry / object namespace / артефакти

### freg — скрити registry ключове  *(частично admin)*
Имена с вграден `\0` или control chars — regedit стъпва на null-terminated
стрингове и е сляп за тях. Nt* фамилията с counted UNICODE_STRING ги вижда.
Класически malware трик (Poweliks). Чист ntdll.

    freg [корен] [/all]
      корен  HKLM\... | HKU\... | native \Registry\... (по подр. HKLM\SOFTWARE)
      /all   покажи всичко, не само скритото

### fobj — браузър за NT object namespace
Дървото, което Explorer крие: \Device, \BaseNamedObjects, \GLOBAL??,
\Sessions — devices, sections, mutants, events, symlinks. Чист ntdll.

    fobj [път] [/r]
      път  стартова директория (по подр. \)
      /r   рекурсивно

### fshim — ShimCache (AppCompatCache) парсер  *(admin)*
Артефактът, в който Windows тихо записва кои екзета е виждала. Формат
Win10/11. ВАЖНО: на Win10 това е "видян/наличен", НЕ доказателство за
изпълнение; времето е last-modified на файла; записва се на shutdown.

    fshim [/path X]
      /path X  запиши суровия блоб във файл X за офлайн анализ

### forphan — сираци в C:\Windows\Installer  *(admin)*
Кеширани .msi/.msp, на които вече никой продукт/patch не реферира (логиката
на PatchCleaner). Питаме Installer API за LocalPackage на всеки продукт.

    forphan [/move ПАПКА] [/del]
      (без флаг)  само докладва, нищо не пипа (dry-run)
      /move D     мести сираците в D (обратимо — препоръчително)
      /del        изтрива (необратимо!)

---

## Подпис и бинарници

### fcert — Authenticode инспектор
Дали EXE/DLL/MSI е подписан, валиден ли е подписът, кой го е подписал.
WinVerifyTrust + CryptQueryObject/CertGetNameString. Offline (без revocation).

    fcert <файл>

### fobj вж. по-горе · fusn/fmft вж. NTFS форензика

### fcd — NCD (Norton Change Directory) клонинг
Пълноекранно дърво на папките; стрелки навигация, speed search (пиши за
скок), Enter = cd към избраната, Esc = отказ. Кеш: `<корен>\tree.tmp` се
зарежда моментално ако съществува, иначе се сканира и записва (като
TREEINFO.NCD). Reparse точки не се обхождат (loop safety). TUI върху
uScreen/uInput.

    fcd [корен] [/rescan] [/nocache]

Изборът се печата на stdout (за `fcd.cmd` wrapper — прави `cd`) и се записва
в `%TEMP%\fcd.dir` (чете го Шило хъбът). В хъба: **F9 Дърво**.

---

## GUI спътници (пускат се с `@` от хъба)

### trpad — TinyRetroPad, notepad-style редактор
Чист Win32 GUI (RichEdit50W). Порт на trpad.asm на Dave Plummer. F4 в хъба.

    trpad [файл]

### tinyPDFViewer — PDF преглед
WinRT рендер (Windows.Data.Pdf през combase), нула DLL зависимости. Стрелки/
PgUp/PgDn страници, +/- зум, R завъртане, 0 fit, drag за скрол.

    tinyPDFViewer [файл.pdf]
    
<Сорс не за сега!!!>     

---

## Внимание

`fdel`, `fclose`, `forphan /del`, `fcompact` върху активни файлове —
необратими или разрушителни. `fclose` и forcирано триене могат да съборят
процеси/данни. Инструментите за $MFT/volume четене искат admin, но само
**четат** (fdu, fdupe, ffind, fmft, fusn, fshim) — освен изрично посочените.
