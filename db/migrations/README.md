# Migrări

## De ce există

`01_oltp_schema.sql` conține doar `CREATE`, iar `run_qa.ps1` aruncă și
recreează baza la fiecare rulare. E perfect pentru CI și pentru
dezvoltare — și e motivul pentru care un deploy automat ar fi fost
distructiv: nu exista nicio cale de a duce o bază care **are date** de la
o versiune la alta.

Deci sunt două drumuri către aceeași schemă, și amândouă rămân valabile:

| drum | comandă | pentru cine |
|---|---|---|
| de la zero | `psql -f 00_ 01_ 02_ 03_` | CI, dezvoltare, instalare nouă |
| prin migrare | `pwsh db/migrate.ps1` | o bază cu date reale în ea |

## Cum adaugi o schimbare

Trei lucruri, toate trei obligatorii:

1. **Scrie migrarea.** `db/migrations/NNNN_nume_scurt.sql`, cu numărul
   următor. Numele fișierului *este* versiunea înregistrată în bază, deci
   ordinea în care le vezi cu `ls` e ordinea în care rulează.

2. **Pune aceeași schimbare în fișierul de schemă potrivit.**
   `01_oltp_schema.sql` pentru domeniu, `00_app_schema.sql` pentru
   infrastructură. Fără asta, o bază construită de la zero nu primește
   schimbarea.

3. **Ștampilează-o în `00_app_schema.sql`**, în blocul `INSERT INTO
   app.schema_migrations` de la sfârșit. Fără asta, rulătorul ar încerca
   s-o aplice pe o bază care o are deja.

Dacă uiți oricare dintre 2 sau 3, `run_qa.ps1` se oprește înainte de
suite și spune care listă e desincronizată. Dacă schimbarea din migrare
nu e aceeași cu cea din fișierul de schemă, jobul `migrations` din CI o
prinde: el construiește schema commit-ului precedent, o migrează
înainte, și compară structura cu cea curentă, linie cu linie.

## Reguli

**O migrare aplicată nu se editează.** Rulătorul ține un SHA-256 al
fișierului aplicat și se oprește dacă s-a schimbat de atunci — fiindcă
baza a primit ce scria *atunci*, nu ce scrie *acum*. Repararea e o
migrare nouă, nu o editare.

**Fiecare migrare rulează într-o singură tranzacție**, împreună cu rândul
care o înregistrează. Jumătate de migrare plus nicio înregistrare e
starea despre care nimeni nu mai poate raționa după aceea.

**Scrie defensiv.** `CREATE TABLE IF NOT EXISTS`, `ADD COLUMN IF NOT
EXISTS`. Nu ca să poată rula de două ori — nu rulează de două ori — ci
fiindcă o bază poate ajunge la starea aceea și pe alt drum, iar o migrare
care se împiedică de asta blochează un deploy la 3 dimineața.

## Comenzi

```
pwsh db/migrate.ps1                    aplică tot ce e în așteptare
pwsh db/migrate.ps1 -DryRun            spune ce ar rula, nu rulează nimic
pwsh db/migrate.ps1 -Stamp 0002_x      marchează ca aplicată, FĂRĂ să ruleze
pwsh db/migrate.ps1 -Database altceva  altă bază decât $PGDATABASE
```

`-Stamp` e pentru o bază care are deja schimbarea pe alt drum — cel mai
des una construită din fișierele de schemă. Scrie un checksum, deci
raportul de mai târziu poate spune dacă fișierul s-a schimbat între timp.

## Ce te oprește rulătorul să faci

| situație | ce face |
|---|---|
| migrare deja aplicată, fișierul editat | se oprește, cere o migrare nouă |
| baza știe o versiune care nu e în checkout | se oprește — baza e mai nouă decât codul |
| o migrare eșuează | tranzacția dă înapoi; cele dinainte rămân aplicate |
| două deploy-uri simultan | un `pg_advisory_lock` ține al doilea să aștepte |

## Coloana `checksum`

`NULL` înseamnă *„a venit cu schema construită de la zero"*. Un checksum
real înseamnă *„rulătorul a aplicat exact acest fișier"*. Distincția
contează: prima nu e o afirmație despre un fișier care n-a fost citit
niciodată, iar `qa_migrations.sql` verifică faptul că o bază de la zero
nu pretinde altceva.
