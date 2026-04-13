# Przydatne zasoby do diagnostyki instalacji i działania pluginu

Ten dokument jest praktyczną ściągą dla administratora Proxmox VE używającego
pluginu Open-E JovianDSS. Komendy zakładają pracę jako `root` na węźle Proxmox.
W klastrze większość sprawdzeń trzeba wykonać na każdym węźle.

## Szybka diagnostyka

Sprawdzenie, czy pakiet jest zainstalowany:

```bash
dpkg -l open-e-joviandss-proxmox-plugin
dpkg -s open-e-joviandss-proxmox-plugin
apt list --installed open-e-joviandss-proxmox-plugin
apt-cache policy open-e-joviandss-proxmox-plugin
```

Wypisanie samej wersji zainstalowanego pakietu:

```bash
dpkg-query -W -f='${Version}\n' open-e-joviandss-proxmox-plugin
```

Sprawdzenie, czy pliki pluginu są na miejscu:

```bash
ls -l /usr/share/perl5/PVE/Storage/Custom/OpenEJovianDSSPlugin.pm
ls -l /usr/share/perl5/PVE/Storage/Custom/OpenEJovianDSSNFSPlugin.pm
ls -l /usr/share/perl5/OpenEJovianDSS/
ls -l /usr/local/bin/jdssc
```

Sprawdzenie konfiguracji storage w Proxmox:

```bash
pvesm status
pvesm config
pvesm list <storage_id>
cat /etc/pve/storage.cfg
```

W przypadku pluginu iSCSI `pvesm status` oraz `pvesm list <storage_id>` są
najprostszym potwierdzeniem, że Proxmox potrafi załadować plugin, odczytać
konfigurację i wykonać podstawowe zapytanie do JovianDSS. Przykład:

```bash
pvesm list jdss-Pool-2
```

Sprawdzenie logów pluginu i Proxmox:

```bash
tail -n 200 /var/log/joviandss/joviandss.log
journalctl -u pvedaemon --since "1 hour ago"
journalctl -u pvestatd --since "1 hour ago"
journalctl -u iscsid --since "1 hour ago"
journalctl -u multipathd --since "1 hour ago"
```

Po instalacji lub aktualizacji pluginu zrestartuj usługę API Proxmox na każdym
węźle, na którym pakiet został zainstalowany:

```bash
systemctl restart pvedaemon
systemctl status pvedaemon
```

## Ważne lokalizacje

| Ścieżka | Znaczenie |
| --- | --- |
| `/etc/pve/storage.cfg` | Główna konfiguracja storage Proxmox. Tutaj definiuje się wpisy `joviandss` i `joviandss-nfs`. |
| `/etc/pve/priv/storage/joviandss/<storage_id>.pw` | Hasło REST dla pluginu iSCSI. Plik jest tworzony przez Proxmox jako sensitive property `user_password`. |
| `/etc/pve/priv/storage/joviandss-nfs/<storage_id>.pw` | Hasło REST dla pluginu NFS. |
| `/var/log/joviandss/joviandss.log` | Domyślny log pluginu i wywołań `jdssc`. Ścieżkę można zmienić przez opcję `log_file`. |
| `/etc/joviandss/state/<storage_id>/` | Lokalny stan aktywowanych wolumenów i LUN-ów na danym węźle. |
| `/etc/pve/priv/joviandss/state/` | Globalny stan przechowywany w pmxcfs dla konfiguracji współdzielonej. |
| `/etc/pve/priv/lock/` | Cluster-wide locki Proxmox/pmxcfs używane przez plugin dla operacji współdzielonych. |
| `/mnt/pve/<storage_id>/` | Typowy punkt montowania storage NFS lub katalog pomocniczy wskazany przez `path`. |
| `/mnt/pve/<storage_id>/private/mounts/<vmid>/<volname>/<snapname>/` | Tymczasowe mountpointy snapshotów NFS używane podczas rollbacku i dostępu do snapshotu. |
| `/etc/multipath/conf.d/open-e-joviandss.conf` | Konfiguracja multipath instalowana przez pakiet. |
| `/etc/joviandss/multipath-open-e-joviandss.conf.example` | Kopia przykładowej konfiguracji multipath. |
| `/etc/udev/rules.d/50-joviandss-scsi-skip-dm.rules` | Reguła udev ograniczająca kosztowne sondowanie urządzeń `dm-*`. |
| `/etc/lvm/lvm.conf` | Instalator dodaje `global_filter`, aby LVM nie skanował multipath device pluginu. |
| `/usr/local/bin/jdssc` | Narzędzie CLI używane przez plugin do komunikacji z REST API JovianDSS. |
| `/usr/lib/python3/dist-packages/jdssc/` | Pythonowy kod narzędzia `jdssc`. |
| `/usr/share/perl5/PVE/Storage/Custom/` | Miejsce instalacji klas pluginów Proxmox. |
| `/usr/share/perl5/OpenEJovianDSS/` | Wspólne moduły Perla używane przez pluginy. |

## Za co odpowiadają pliki w repozytorium

| Plik w repozytorium | Po instalacji | Odpowiedzialność |
| --- | --- | --- |
| `OpenEJovianDSSPlugin.pm` | `/usr/share/perl5/PVE/Storage/Custom/OpenEJovianDSSPlugin.pm` | Główny plugin iSCSI dla Proxmox: tworzenie, aktywacja, usuwanie, snapshoty, rollback, migracja i obsługa właściwości storage. |
| `OpenEJovianDSSNFSPlugin.pm` | `/usr/share/perl5/PVE/Storage/Custom/OpenEJovianDSSNFSPlugin.pm` | Plugin NFS dla Proxmox: obsługa udziałów NFS, snapshotów NAS i operacji na datasetach. |
| `OpenEJovianDSS/Common.pm` | `/usr/share/perl5/OpenEJovianDSS/Common.pm` | Wspólny kod iSCSI: konfiguracja, logowanie, `jdssc`, iSCSI, multipath, LUN records, snapshoty i helpery rollback. |
| `OpenEJovianDSS/NFSCommon.pm` | `/usr/share/perl5/OpenEJovianDSS/NFSCommon.pm` | Wspólny kod NFS: montowanie, odmontowanie, snapshoty NAS i hasła dla `joviandss-nfs`. |
| `OpenEJovianDSS/Lock.pm` | `/usr/share/perl5/OpenEJovianDSS/Lock.pm` | Locki per-VM i per-storage dla operacji w klastrze i na lokalnym węźle. |
| `jdssc/bin/jdssc` | `/usr/local/bin/jdssc` | Wrapper CLI uruchamiany przez plugin. |
| `jdssc/jdssc/` | `/usr/lib/python3/dist-packages/jdssc/` | Pythonowa implementacja klienta REST JovianDSS. |
| `configs/multipath/open-e-joviandss.conf` | `/etc/multipath/conf.d/open-e-joviandss.conf` | Konfiguracja multipath dla urządzeń JovianDSS. |
| `configs/udev/50-joviandss-scsi-skip-dm.rules` | `/etc/udev/rules.d/50-joviandss-scsi-skip-dm.rules` | Reguła udev związana ze skanowaniem SCSI i device mapper. |
| `debian/postinst` | Skrypt uruchamiany po instalacji pakietu | Tworzy katalogi, ustawia uprawnienia `jdssc`, aktualizuje LVM filter, przeładowuje udev i multipathd. |
| `debian/prerm` | Skrypt uruchamiany przed usunięciem pakietu | Czyści cache Pythona dla `jdssc`. |
| `install.pl` | Nie jest instalowany jako część pluginu | Skrypt pomocniczy do instalacji/aktualizacji pakietu lokalnie lub na wielu węzłach. |

## Jak działa plugin w skrócie

Plugin Perla jest wywoływany przez framework storage Proxmox. Dla większości
operacji plugin wywołuje `/usr/local/bin/jdssc`, a `jdssc` komunikuje się z REST
API JovianDSS.

Dla wolumenów iSCSI typowy przepływ wygląda tak:

1. Proxmox wywołuje metodę pluginu, np. start VM, create disk, snapshot, rollback.
2. Plugin czyta `/etc/pve/storage.cfg` oraz hasło z pliku sensitive property.
3. Plugin używa `jdssc` do utworzenia lub odszukania wolumenu, targetu i LUN-u.
4. Plugin loguje się do iSCSI przez `iscsiadm`.
5. Przy `multipath 1` plugin czeka na ścieżki i tworzy urządzenie `/dev/mapper/...`.
6. Lokalny stan LUN jest zapisywany pod `/etc/joviandss/state/<storage_id>/`.
7. Plugin zwraca Proxmoxowi ścieżkę urządzenia blokowego.

Dla NFS plugin pracuje na exportach NAS i montowaniach NFS. Hasło jest osobne i
znajduje się pod `/etc/pve/priv/storage/joviandss-nfs/`.

Dla pluginu NFS typowy przepływ wygląda tak:

1. Proxmox aktywuje storage `joviandss-nfs`.
2. Plugin montuje `server:export` pod katalogiem `path`.
3. Zwykłe dyski VM/CT są plikami w zamontowanym katalogu, podobnie jak w storage typu `dir`/`nfs`.
4. Snapshot VM tworzy snapshot NAS volume przez REST API JovianDSS.
5. Rollback snapshotu publikuje snapshot jako tymczasowy share, montuje go pod `private/mounts/...`, kopiuje dane z punktu snapshotu i sprząta mount/share.
6. Hasło REST jest używane do operacji snapshotów i publikowania tymczasowych share, nie do samego protokołu NFS.

## Sprawdzenie konfiguracji storage

Minimalne rzeczy do sprawdzenia w `/etc/pve/storage.cfg` dla pluginu iSCSI:

```text
joviandss: <storage_id>
        pool <pool_name>
        path /mnt/pve/<storage_id>
        data_addresses <vip_or_ip_list>
        user_name <rest_user>
        content images,rootdir
        shared 1
```

Najczęstsze problemy:

- Brak `pool`: plugin zgłasza błąd o wymaganej nazwie poola.
- Brak `path`: plugin zgłasza błąd o wymaganej właściwości `path`.
- Brak `data_addresses`: aktywacja wolumenów i iSCSI nie będą miały adresów danych.
- Niepoprawne `control_addresses`: `jdssc` nie połączy się z REST API.
- Niepoprawne `data_addresses`: REST może działać, ale iSCSI login lub multipath nie.
- `shared 0` w klastrze: storage nie jest traktowany jako współdzielony.
- `multipath 1`, ale brak działającego `multipathd`: aktywacja może kończyć się błędem albo zwracać nieoczekiwane ścieżki.
- Niepoprawny `target_prefix`: może powodować konflikty nazw targetów albo brak zgodności z oczekiwanym IQN.
- `ssl_cert_verify 1` przy niepoprawnym lub niezaufanym certyfikacie HTTPS: REST API może odrzucać połączenia klienta.

Minimalne rzeczy do sprawdzenia w `/etc/pve/storage.cfg` dla pluginu NFS:

```text
joviandss-nfs: <storage_id>
        server <nfs_data_vip_or_host>
        export /Pools/<pool_name>/<nas_volume_or_dataset>
        path /mnt/pve/<storage_id>
        user_name <rest_user>
        content images,rootdir
        shared 1
```

Najczęstsze problemy NFS:

- Brak `server`: Proxmox nie wie, z jakiego adresu montować export NFS.
- Zły `export`: plugin oczekuje formatu `/Pools/<pool>/<dataset>`.
- `export` nie odpowiada realnemu NAS volume na JovianDSS.
- `path` jest już mountpointem innego zasobu.
- NFS działa, ale REST nie działa: zwykły dostęp do plików może działać, ale snapshoty i rollback będą się wywalać.
- REST działa, ale NFS nie działa: `pvesm status` lub aktywacja storage zgłasza błąd montowania.
- Błędne opcje `options`: mount może odrzucić opcje albo użyć wersji NFS nieobsługiwanej przez serwer.

Do szybkiego podglądu pojedynczego wpisu:

```bash
pvesm config <storage_id>
```

Do sprawdzenia, czy Proxmox widzi storage:

```bash
pvesm status
pvesm list <storage_id>
```

Przykład dla storage `jdss-Pool-2`:

```bash
pvesm list jdss-Pool-2
```

Jeżeli ta komenda zwraca listę wolumenów lub pustą listę bez błędu, plugin
iSCSI jest załadowany, konfiguracja storage została odczytana, a podstawowa
komunikacja z backendem działa. Jeżeli komenda kończy się błędem, sprawdź
`user_name`, plik hasła, `control_addresses`, `data_addresses`,
`ssl_cert_verify` i log `/var/log/joviandss/joviandss.log`.

## Hasło, login i REST API

Hasło `user_password` jest sensitive property. Nie musi być widoczne w
`/etc/pve/storage.cfg`, ponieważ Proxmox zapisuje je w osobnym pliku pod
`/etc/pve/priv/storage/...`.

Sprawdzenie, czy plik hasła istnieje:

```bash
ls -l /etc/pve/priv/storage/joviandss/<storage_id>.pw
ls -l /etc/pve/priv/storage/joviandss-nfs/<storage_id>.pw
```

Sprawdzenie uprawnień bez wypisywania hasła:

```bash
stat /etc/pve/priv/storage/joviandss/<storage_id>.pw
stat /etc/pve/priv/storage/joviandss-nfs/<storage_id>.pw
```

Jeżeli podejrzewasz złe hasło, ustaw je ponownie przez Proxmox zamiast
edytować plik ręcznie:

```bash
read -r -s JDSS_PASSWORD
pvesm set <storage_id> --user_password "$JDSS_PASSWORD"
unset JDSS_PASSWORD
```

Po zmianie hasła sprawdź logi:

```bash
tail -n 100 /var/log/joviandss/joviandss.log
journalctl -u pvedaemon --since "10 minutes ago"
```

Typowe objawy:

- Zły login lub hasło: błędy autoryzacji REST, HTTP 401/403, komunikaty z `jdssc`.
- Brak pliku hasła: `JovianDSS REST user password is not provided`.
- Brak `user_name`: `JovianDSS REST user name is not provided`.
- Zły adres REST: timeout, connection refused, no route to host albo błędy DNS.
- Problem z certyfikatem: błędy SSL/certificate verify; sprawdź `ssl_cert_verify`.

## Ręczne testy `jdssc`

Najbezpieczniej uruchamiać testy przez `pvesm`, bo wtedy plugin sam używa tej
samej konfiguracji i hasła, których użyje Proxmox. Jeśli trzeba testować
`jdssc` ręcznie, nie wpisuj hasła w komendzie na wspólnym terminalu, bo może
trafić do historii shella.

Przykładowe testy z hasłem podanym przez zmienną tymczasową:

```bash
read -r -s JDSS_PASSWORD

/usr/local/bin/jdssc \
  --control-addresses <control_ip_or_dns> \
  --data-addresses <data_ip_or_vip> \
  --user-name <rest_user> \
  --user-password "$JDSS_PASSWORD" \
  --loglvl debug \
  pool <pool_name> get

/usr/local/bin/jdssc \
  --control-addresses <control_ip_or_dns> \
  --data-addresses <data_ip_or_vip> \
  --user-name <rest_user> \
  --user-password "$JDSS_PASSWORD" \
  hosts --iscsi

unset JDSS_PASSWORD
```

Jeżeli ręczny `jdssc` działa, a `pvesm` nie działa, problem jest zwykle w
`storage.cfg`, pliku hasła sensitive property, uprawnieniach, module Perla albo
w stanie lokalnym na węźle. Jeżeli ręczny `jdssc` też nie działa, zacznij od
REST API, loginu, hasła, certyfikatu i routingu do JovianDSS.

## iSCSI

Sprawdzenie usługi i sesji iSCSI:

```bash
systemctl status iscsid
journalctl -u iscsid --since "1 hour ago"
iscsiadm -m session
iscsiadm -m node
```

Sprawdzenie urządzeń po ścieżkach iSCSI:

```bash
ls -l /dev/disk/by-path/ | grep iscsi
find /dev/disk/by-path -maxdepth 1 -type l -name '*iscsi*' -ls
```

Typowe problemy:

- `data_addresses` wskazuje adres, który nie jest osiągalny z danego węzła.
- Firewall blokuje port iSCSI.
- JovianDSS nie wystawia targetu dla danego wolumenu.
- Stara sesja iSCSI została po nieudanej operacji i blokuje ponowną aktywację.

## NFS

Plugin NFS używa dwóch różnych kanałów:

- Ścieżka danych NFS: Proxmox montuje `server:export` i przechowuje tam pliki dysków, ISO, backupy lub inne typy contentu dopuszczone w konfiguracji.
- Ścieżka kontrolna REST: plugin używa `jdssc` do snapshotów, rollbacków oraz publikowania tymczasowych share snapshotów.

To rozróżnienie jest ważne diagnostycznie. Jeżeli montowanie NFS działa, ale
snapshoty nie działają, problem jest zwykle po stronie REST, loginu, hasła,
certyfikatu lub formatu `export`. Jeżeli REST działa, ale storage nie aktywuje
się w Proxmox, problem jest zwykle po stronie NFS, routingu, exportu lub opcji
montowania.

Sprawdzenie konfiguracji storage NFS:

```bash
pvesm config <storage_id>
pvesm status
findmnt -M /mnt/pve/<storage_id>
findmnt -T /mnt/pve/<storage_id>
cat /proc/mounts | grep "<storage_id>"
```

Sprawdzenie exportów widocznych z węzła Proxmox:

```bash
showmount --exports <nfs_server>
showmount -e <nfs_server>
rpcinfo -p <nfs_server>
```

Sprawdzenie komunikacji sieciowej:

```bash
ping -c 3 <nfs_server>
ip route get <nfs_server>
nc -vz <nfs_server> 2049
```

Ręczne sprawdzenie montowania do katalogu testowego:

```bash
mkdir -p /mnt/jdss-nfs-test
mount -t nfs <nfs_server>:/Pools/<pool_name>/<dataset> /mnt/jdss-nfs-test
findmnt -M /mnt/jdss-nfs-test
ls -la /mnt/jdss-nfs-test
umount /mnt/jdss-nfs-test
```

Jeżeli storage używa opcji `options`, testuj z tymi samymi opcjami:

```bash
mount -t nfs -o <options_from_storage_cfg> <nfs_server>:/Pools/<pool_name>/<dataset> /mnt/jdss-nfs-test
```

Sprawdzenie procesu montowania przez Proxmox:

```bash
pvesm set <storage_id> --disable 1
pvesm set <storage_id> --disable 0
pvesm status
journalctl -u pvedaemon --since "10 minutes ago"
tail -n 100 /var/log/joviandss/joviandss.log
```

Uwaga: `disable 1` tymczasowo wyłącza storage w Proxmox. Nie używaj tego na
produkcyjnym storage w trakcie działania VM/CT korzystających z tego zasobu.

### Snapshoty i rollback NFS

Snapshoty NFS nie są prostym lokalnym snapshotem pliku. Plugin tworzy snapshot
NAS volume przez REST API JovianDSS. Nazwa snapshotu po stronie JovianDSS
zawiera VMID, żeby plugin mógł odróżnić snapshoty wielu VM przechowywanych na
tym samym NAS volume.

Podczas rollbacku plugin:

1. Publikuje snapshot jako tymczasowy share NFS.
2. Montuje go pod `path/private/mounts/<vmid>/<volname>/<snapname>/`.
3. Odszukuje plik dysku w strukturze snapshotu.
4. Kopiuje dane z wersji snapshotowej do bieżącego pliku dysku.
5. Odmontowuje tymczasowy mountpoint.
6. Usuwa tymczasowy share/clone z JovianDSS.

Komendy diagnostyczne dla snapshotów NFS:

```bash
find /mnt/pve/<storage_id>/private/mounts -maxdepth 5 -type d -print
findmnt | grep "/mnt/pve/<storage_id>/private/mounts"
cat /proc/mounts | grep "private/mounts"
tail -n 200 /var/log/joviandss/joviandss.log | grep -i "snapshot\|rollback\|mount\|umount\|share"
```

Jeżeli rollback zgłasza błąd odmontowania, sprawdź procesy trzymające katalog:

```bash
lsof +f -- /mnt/pve/<storage_id>/private/mounts 2>/dev/null
fuser -vm /mnt/pve/<storage_id>/private/mounts 2>/dev/null
```

Nie usuwaj katalogów z `private/mounts` przed sprawdzeniem, czy nie są nadal
mountpointami. Najpierw sprawdź `findmnt` lub `mountpoint`:

```bash
mountpoint /mnt/pve/<storage_id>/private/mounts/<vmid>/<volname>/<snapname>
findmnt -M /mnt/pve/<storage_id>/private/mounts/<vmid>/<volname>/<snapname>
```

Jeżeli katalog jest nadal zamontowany i nie ma aktywnej operacji Proxmox, można
rozważyć ręczne odmontowanie:

```bash
umount /mnt/pve/<storage_id>/private/mounts/<vmid>/<volname>/<snapname>
```

Jeżeli zwykłe `umount` nie działa, najpierw ustal proces blokujący katalog.
Lazy unmount (`umount -l`) zostaw jako ostateczność, bo może ukryć problem
z aktywnym procesem.

### Typowe błędy NFS

`Invalid export path format. Expected /Pools/<pool>/<dataset>`:

- `export` nie ma formatu `/Pools/<pool>/<dataset>`.
- Popraw konfigurację przez `pvesm set <storage_id> --export /Pools/<pool>/<dataset>`.

`Unable to activate storage ... as other resource is mounted`:

- Katalog `path` jest już mountpointem, ale nie jest oczekiwanym NFS share.
- Sprawdź `findmnt -M <path>` i `/proc/mounts`.
- Ustaw inny `path` albo odmontuj błędnie zamontowany zasób.

`Storage '<storage_id>' is not mounted`:

- Główny export NFS nie jest zamontowany pod `path`.
- Sprawdź `server`, `export`, routing, firewall i `showmount`.

`Failed to attach ... snapshot` albo `Failed to publish ... snapshot`:

- REST API nie może utworzyć/publikować snapshotu.
- Sprawdź `user_name`, plik hasła `joviandss-nfs/<storage_id>.pw`, `control_addresses`, `ssl_cert_verify` i log `jdssc`.

`Failed to umount volume ... snapshot`:

- Tymczasowy mountpoint snapshotu jest nadal używany.
- Sprawdź `lsof`, `fuser`, `findmnt` i aktywne procesy Proxmox.

`Got no share path for dataset ... snapshot`:

- JovianDSS nie zwrócił poprawnej ścieżki share po publikacji snapshotu.
- Sprawdź, czy snapshot istnieje, czy dataset jest poprawny i czy REST API zwraca pełne dane.

### Ręczne testy REST dla NFS

Plugin NFS wyprowadza pool i dataset z `export`. Dla:

```text
export /Pools/Pool-1/datastore-pve-01
```

pool to `Pool-1`, a dataset to `datastore-pve-01`.

Przykładowe testy `jdssc`:

```bash
read -r -s JDSS_PASSWORD

/usr/local/bin/jdssc \
  --control-addresses <control_ip_or_dns> \
  --data-addresses <nfs_data_ip_or_vip> \
  --user-name <rest_user> \
  --user-password "$JDSS_PASSWORD" \
  --loglvl debug \
  pool <pool_name> nas_volume -d <dataset> snapshots list --creation

/usr/local/bin/jdssc \
  --control-addresses <control_ip_or_dns> \
  --data-addresses <nfs_data_ip_or_vip> \
  --user-name <rest_user> \
  --user-password "$JDSS_PASSWORD" \
  --loglvl debug \
  pool <pool_name> get

unset JDSS_PASSWORD
```

Jeżeli `snapshots list --creation` nie działa, snapshoty i rollback NFS nie
będą działały nawet wtedy, gdy zwykły mount NFS działa poprawnie.

## Multipath

Sprawdzenie usługi:

```bash
systemctl status multipathd
journalctl -u multipathd --since "1 hour ago"
multipath -ll
multipathd show maps
multipathd show paths
```

Sprawdzenie konfiguracji:

```bash
multipath -t
cat /etc/multipath/conf.d/open-e-joviandss.conf
grep -n "global_filter" /etc/lvm/lvm.conf
```

Jeżeli `multipath 1` jest ustawione w `storage.cfg`, ale nie ma map
`/dev/mapper/...`, sprawdź:

- Czy `multipathd` działa na tym węźle.
- Czy `data_addresses` zawiera wszystkie wymagane ścieżki.
- Czy konfiguracja multipath nie ma zbyt szerokiego blacklistu `wwid`.
- Czy LVM nie trzyma urządzeń otwartych przez `vgs`/`pvscan`.
- Czy udev rule `/etc/udev/rules.d/50-joviandss-scsi-skip-dm.rules` jest zainstalowana.

Po zmianach w udev lub multipath:

```bash
udevadm control --reload-rules
udevadm settle
multipathd reconfigure
```

## Stan lokalny i pozostałości po nieudanych operacjach

Plugin zapisuje rekordy LUN lokalnie na węźle. To pomaga odłączyć właściwe
urządzenia przy stopie VM, migracji lub sprzątaniu po błędzie.

Podgląd stanu:

```bash
find /etc/joviandss/state -maxdepth 5 -type f -print
find /etc/pve/priv/joviandss/state -maxdepth 5 -type f -print
```

Jeżeli VM nie startuje po nieudanej aktywacji, sprawdź:

```bash
tail -n 200 /var/log/joviandss/joviandss.log
iscsiadm -m session
multipath -ll
lsof /dev/mapper/* 2>/dev/null
```

Nie usuwaj plików stanu ręcznie jako pierwszy krok. Najpierw spróbuj zatrzymać
VM/CT, odświeżyć storage przez Proxmox i sprawdzić, czy plugin sam wykona
dezaktywację. Ręczne czyszczenie stanu może zostawić aktywne sesje iSCSI bez
rekordu, który plugin potrafi później znaleźć.

## Logowanie debug

Domyślny plik logu to:

```text
/var/log/joviandss/joviandss.log
```

W konfiguracji storage można ustawić:

```text
        log_level debug
        log_file /var/log/joviandss/joviandss.log
```

Po włączeniu debug logi będą bardziej szczegółowe. W logach warto szukać:

- `plugin` - logi z kodu Perla.
- `jdssc` - błędy REST API i odpowiedzi narzędzia CLI.
- `iscsiadm` - problemy z logowaniem iSCSI.
- `multipath` lub `dmsetup` - problemy z mapami multipath.
- `request-id` - identyfikator operacji pozwalający skorelować wpisy w logu.

Praktyczne komendy:

```bash
tail -f /var/log/joviandss/joviandss.log
grep -i "error\|warn\|timeout\|unauthorized\|forbidden\|ssl\|iscsi\|multipath" /var/log/joviandss/joviandss.log
```

## Typowe scenariusze błędów

### Zły login lub hasło

Objawy:

- `pvesm status` pokazuje storage jako niedostępny.
- W logu pojawia się błąd autoryzacji REST.
- `jdssc` kończy się błędem HTTP 401/403 albo komunikatem o braku autoryzacji.

Sprawdź:

```bash
pvesm config <storage_id>
ls -l /etc/pve/priv/storage/joviandss/<storage_id>.pw
tail -n 100 /var/log/joviandss/joviandss.log
```

Naprawa:

```bash
pvesm set <storage_id> --user_name <rest_user>
read -r -s JDSS_PASSWORD
pvesm set <storage_id> --user_password "$JDSS_PASSWORD"
unset JDSS_PASSWORD
systemctl restart pvedaemon
```

### Zły adres REST lub brak routingu

Objawy:

- Timeout w `jdssc`.
- `connection refused`, `no route to host`, `temporary failure in name resolution`.
- `pvesm status` długo czeka albo pokazuje błąd.

Sprawdź:

```bash
ping -c 3 <control_ip>
nc -vz <control_ip> <rest_port>
ip route get <control_ip>
pvesm config <storage_id>
```

Jeżeli REST działa przez HTTPS z własnym certyfikatem, sprawdź także
`ssl_cert_verify`.

### Zły adres danych iSCSI

Objawy:

- REST działa, ale start VM/CT kończy się błędem aktywacji dysku.
- `iscsiadm` nie tworzy sesji.
- Brak wpisów w `/dev/disk/by-path/*iscsi*`.

Sprawdź:

```bash
pvesm config <storage_id>
iscsiadm -m session
journalctl -u iscsid --since "30 minutes ago"
ip route get <data_ip_or_vip>
```

### Problem z multipath

Objawy:

- VM startuje tylko z `multipath 0`.
- Plugin nie znajduje `/dev/mapper/...`.
- Dezaktywacja trwa długo lub blokuje się na otwartym urządzeniu.

Sprawdź:

```bash
systemctl status multipathd
multipath -ll
multipathd show paths
multipath -t
grep -n "blacklist" /etc/multipath.conf /etc/multipath/conf.d/*.conf 2>/dev/null
grep -n "global_filter" /etc/lvm/lvm.conf
```

### Plugin nie jest widoczny w Proxmox po instalacji

Sprawdź:

```bash
dpkg -l open-e-joviandss-proxmox-plugin
ls -l /usr/share/perl5/PVE/Storage/Custom/OpenEJovianDSSPlugin.pm
ls -l /usr/share/perl5/PVE/Storage/Custom/OpenEJovianDSSNFSPlugin.pm
perl -c /usr/share/perl5/PVE/Storage/Custom/OpenEJovianDSSPlugin.pm
perl -c /usr/share/perl5/PVE/Storage/Custom/OpenEJovianDSSNFSPlugin.pm
systemctl restart pvedaemon
journalctl -u pvedaemon --since "10 minutes ago"
```

Jeżeli `perl -c` zgłasza brak modułu, sprawdź zależności pakietu i instalację
plików pod `/usr/share/perl5/OpenEJovianDSS/`.

### Operacje wiszą na locku

Plugin używa locków per-VM i per-storage, aby nie wykonywać sprzecznych operacji
na tych samych wolumenach. Przy długich operacjach może być widoczne oczekiwanie
na lock.

Sprawdź:

```bash
find /etc/pve/priv/lock -maxdepth 1 -name 'joviandss-*' -ls
journalctl -u pvedaemon --since "30 minutes ago" | grep -i lock
tail -n 200 /var/log/joviandss/joviandss.log | grep -i lock
```

Nie usuwaj locków ręcznie, jeżeli nie masz pewności, że powiązana operacja już
nie działa. Najpierw sprawdź aktywne zadania Proxmox i procesy:

```bash
ps aux | grep -E 'pvedaemon|qm|pct|jdssc|iscsiadm|multipath|sg_xcopy|dd' | grep -v grep
```

## Przydatne komendy do raportu błędu

Zbierz wynik tych komend z każdego węzła, którego dotyczy problem:

```bash
hostname -f
pveversion -v
dpkg -s open-e-joviandss-proxmox-plugin
pvesm status
pvesm config
findmnt
showmount -e <nfs_server>
systemctl status pvedaemon --no-pager
systemctl status iscsid --no-pager
systemctl status multipathd --no-pager
iscsiadm -m session
multipath -ll
tail -n 300 /var/log/joviandss/joviandss.log
journalctl -u pvedaemon --since "1 hour ago" --no-pager
journalctl -u iscsid --since "1 hour ago" --no-pager
journalctl -u multipathd --since "1 hour ago" --no-pager
```

### Pakowanie logów i danych diagnostycznych przez `tar`

Do zgłoszenia błędu warto przygotować katalog z logami i wynikami podstawowych
komend. Przykład:

```bash
OUT="/tmp/joviandss-debug-$(hostname)-$(date +%F-%H%M)"
mkdir -p "$OUT"

hostname -f > "$OUT/hostname.txt"
pveversion -v > "$OUT/pveversion.txt" 2>&1
dpkg -s open-e-joviandss-proxmox-plugin > "$OUT/package.txt" 2>&1
dpkg-query -W -f='${Version}\n' open-e-joviandss-proxmox-plugin > "$OUT/package-version.txt" 2>&1
pvesm status > "$OUT/pvesm-status.txt" 2>&1
pvesm config > "$OUT/pvesm-config.txt" 2>&1
findmnt > "$OUT/findmnt.txt" 2>&1
iscsiadm -m session > "$OUT/iscsi-sessions.txt" 2>&1
multipath -ll > "$OUT/multipath-ll.txt" 2>&1
journalctl -u pvedaemon --since "2 hours ago" --no-pager > "$OUT/journal-pvedaemon.txt" 2>&1
journalctl -u iscsid --since "2 hours ago" --no-pager > "$OUT/journal-iscsid.txt" 2>&1
journalctl -u multipathd --since "2 hours ago" --no-pager > "$OUT/journal-multipathd.txt" 2>&1
cp -a /var/log/joviandss "$OUT/" 2>/dev/null || true
cp -a /etc/joviandss/state "$OUT/joviandss-state-local" 2>/dev/null || true
cp -a /etc/pve/priv/joviandss/state "$OUT/joviandss-state-cluster" 2>/dev/null || true

tar -czf "${OUT}.tar.gz" -C /tmp "$(basename "$OUT")"
ls -lh "${OUT}.tar.gz"
```

Jeżeli problem dotyczy NFS, dodaj też wynik `showmount` dla serwera NFS:

```bash
showmount -e <nfs_server> > "$OUT/showmount.txt" 2>&1
rpcinfo -p <nfs_server> > "$OUT/rpcinfo.txt" 2>&1
tar -czf "${OUT}.tar.gz" -C /tmp "$(basename "$OUT")"
```

Jeżeli chcesz spakować wyłącznie istniejący katalog logów pluginu:

```bash
tar -czf /tmp/joviandss-logs-$(hostname)-$(date +%F-%H%M).tar.gz /var/log/joviandss
```

Nie dodawaj do archiwum plików z hasłami:

```text
/etc/pve/priv/storage/joviandss/*.pw
/etc/pve/priv/storage/joviandss-nfs/*.pw
```

Przed wysłaniem archiwum sprawdź, czy nie zawiera haseł ani danych, których nie
chcesz przekazywać:

```bash
tar -tzf /tmp/joviandss-debug-*.tar.gz
```

### Przesyłanie zebranych logów przez SSH/SCP

Jeżeli archiwum zostało utworzone na węźle Proxmox, można pobrać je na stację
administratora przez `scp`:

```bash
scp root@<pve_node>:/tmp/joviandss-debug-<node>-<date>.tar.gz .
```

Przykład z konkretną nazwą pliku:

```bash
scp root@pve-01:/tmp/joviandss-debug-pve-01-2026-04-13-1530.tar.gz .
```

Można też wysłać archiwum z węzła Proxmox na inny serwer, np. jump host lub
serwer do zbierania logów:

```bash
scp /tmp/joviandss-debug-<node>-<date>.tar.gz <user>@<target_host>:/tmp/
```

Jeżeli SSH działa na niestandardowym porcie:

```bash
scp -P <port> /tmp/joviandss-debug-<node>-<date>.tar.gz <user>@<target_host>:/tmp/
```

Jeżeli trzeba przesłać kilka archiwów z kilku węzłów, wygodny jest katalog
docelowy z nazwą klastra lub zgłoszenia:

```bash
ssh <user>@<target_host> "mkdir -p /tmp/joviandss-case-<case_id>"
scp /tmp/joviandss-debug-*.tar.gz <user>@<target_host>:/tmp/joviandss-case-<case_id>/
```

Alternatywnie można użyć `rsync`, który dobrze radzi sobie ze wznowieniem
transferu:

```bash
rsync -avP /tmp/joviandss-debug-*.tar.gz <user>@<target_host>:/tmp/joviandss-case-<case_id>/
```

Przed transferem sprawdź zawartość archiwum i upewnij się, że nie zawiera haseł:

```bash
tar -tzf /tmp/joviandss-debug-<node>-<date>.tar.gz
```

### Zbieranie danych narzędziem `sos`

Do szerszej diagnostyki systemu można użyć narzędzia `sos` (`sosreport`).
Zbiera ono informacje o systemie, usługach, logach, pakietach, sieci, storage,
iSCSI, multipath i konfiguracji Proxmox. Raport może zawierać dane wrażliwe,
dlatego przed wysłaniem trzeba go przejrzeć lub zanonimizować.

Instalacja narzędzia, jeśli nie jest dostępne:

```bash
apt update
apt install sosreport
```

Sprawdzenie dostępnej komendy:

```bash
command -v sos
command -v sosreport
```

Uruchomienie raportu w nowszych wersjach:

```bash
sos report --batch --tmp-dir /var/tmp
```

W praktyce dla diagnostyki pluginu JovianDSS warto ograniczyć kosztowne lub
mało istotne pluginy `sos`, podnieść timeout komend i włączyć debug:

```bash
sos report \
  --batch \
  --tmp-dir /var/tmp \
  --skip-plugins pcs,pacemaker,ceph,process,processor,kernel,pci \
  --cmd-timeout 300 \
  --debug
```

`sos` zwykle nie pozwala wygodnie wymusić dokładnej nazwy pliku wynikowego.
Można natomiast wskazać katalog roboczy/wyjściowy przez `--tmp-dir`, a potem
skopiować wygenerowany plik `sosreport-*` do własnego katalogu sprawy.

Spójny przykład, w którym `sos`, logi pluginu i dane dodatkowe trafiają do
jednego katalogu, a na końcu powstaje jedno archiwum:

```bash
CASE_ID="joviandss-case-001"
OUT="/var/tmp/${CASE_ID}-$(hostname)-$(date +%F-%H%M)"
SOS_DIR="${OUT}/sos"

mkdir -p "$OUT" "$SOS_DIR"

sos report \
  --batch \
  --tmp-dir "$SOS_DIR" \
  --skip-plugins pcs,pacemaker,ceph,process,processor,kernel,pci \
  --cmd-timeout 300 \
  --debug

hostname -f > "$OUT/hostname.txt"
pveversion -v > "$OUT/pveversion.txt" 2>&1
dpkg-query -W -f='${Version}\n' open-e-joviandss-proxmox-plugin > "$OUT/package-version.txt" 2>&1
pvesm status > "$OUT/pvesm-status.txt" 2>&1
pvesm config > "$OUT/pvesm-config.txt" 2>&1
findmnt > "$OUT/findmnt.txt" 2>&1
iscsiadm -m session > "$OUT/iscsi-sessions.txt" 2>&1
multipath -ll > "$OUT/multipath-ll.txt" 2>&1

cp -a /var/log/joviandss "$OUT/" 2>/dev/null || true
cp -a /etc/joviandss/state "$OUT/joviandss-state-local" 2>/dev/null || true
cp -a /etc/pve/priv/joviandss/state "$OUT/joviandss-state-cluster" 2>/dev/null || true
cp -a /etc/multipath/conf.d/open-e-joviandss.conf "$OUT/" 2>/dev/null || true
cp -a /etc/udev/rules.d/50-joviandss-scsi-skip-dm.rules "$OUT/" 2>/dev/null || true

tar -czf "${OUT}.tar.gz" -C "$(dirname "$OUT")" "$(basename "$OUT")"
ls -lh "${OUT}.tar.gz"
```

Jeżeli chcesz rozpoznać dokładną nazwę archiwum utworzonego przez `sos`:

```bash
find "$SOS_DIR" -maxdepth 1 -type f -name 'sosreport-*' -print
```

Uruchomienie raportu w starszych wersjach:

```bash
sosreport --batch --tmp-dir /var/tmp
```

Po zakończeniu narzędzie wypisze ścieżkę do archiwum, zwykle w `/var/tmp/`.
Do raportu `sos` warto dołączyć osobne archiwum z katalogiem stanu pluginu i
logami JovianDSS, bo `sos` nie zawsze zbierze niestandardowe ścieżki pluginu:

```bash
tar -czf /var/tmp/joviandss-extra-$(hostname)-$(date +%F-%H%M).tar.gz \
  /var/log/joviandss \
  /etc/joviandss/state \
  /etc/pve/priv/joviandss/state \
  /etc/multipath/conf.d/open-e-joviandss.conf \
  /etc/udev/rules.d/50-joviandss-scsi-skip-dm.rules
```

Nie dodawaj plików `*.pw` z `/etc/pve/priv/storage/` do raportu. Jeżeli raport
`sos` został wygenerowany na hoście produkcyjnym, sprawdź go przed wysłaniem:

```bash
tar -tzf /var/tmp/sosreport-*.tar.xz | grep -Ei 'joviandss|storage|iscsi|multipath|pve'
```

Przed wysłaniem logów usuń lub zamaskuj hasła, tokeny, adresy publiczne i inne
dane wrażliwe.
