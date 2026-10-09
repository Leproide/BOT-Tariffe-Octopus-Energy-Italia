# 🐙 OctoCheck

Monitor automatico delle tariffe **Octopus Energy a prezzo fisso (Luce + Gas)** con notifiche Telegram.

Lo script riconosce da solo l'offerta fissa del momento, che sia **Fissa 12M**, **Fissa 24M** o qualsiasi altra durata. Se sulla pagina ce n'è più di una, le mostra tutte.

Disponibile in due versioni con le stesse funzioni:
- `OctoCheck.ps1` — Windows (PowerShell)
- `octocheck.sh` — Linux (Bash)

🐙 Non sei ancora un cliente Octopus Energy?
Per sostenermi utilizza [questo link](https://muninn.ovh/octobot), 30€ in sconto a entrambi sulla prima bolletta.

---

## 🤖 Istanza pubblica

Per chi volesse esiste la mia istanza pubblica con la funzione base di notifica al cambio prezzo

https://t.me/OctopusEnergy_Italia

Per tutte le altre funzioni dovete necessariamente avviare una vostra istanza privata.

---

## 📋 Funzionalità

- **Riconoscimento automatico dell'offerta fissa** dalla pagina ufficiale ([le-nostre-tariffe](https://octopusenergy.it/le-nostre-tariffe)), indipendente dalla durata
- **Più offerte contemporanee** (es. 12M e 24M) mostrate tutte nello stesso messaggio
- **Data di validità** dell'offerta ("sottoscrivibile fino al …"), se pubblicata da Octopus
- **Notifiche Telegram** con formattazione HTML
- **Modalità di invio** configurabili: variazione prezzo oppure soglie
- **Storico prezzi** in `lastprice.json` con confronto tra run, frecce 📉📈👍🏻 e differenza in €
- **Cambio offerta** segnalato (es. `🔄 Offerta cambiata: Fissa 12M → Fissa 24M`), con confronto dei nuovi prezzi rispetto alla vecchia offerta
- **Avviso rinnovo contratto** quando la tariffa coincide esattamente con la soglia
- **Riferimenti di mercato all'ingrosso**: PUN Index GME (luce) e PSV (gas, indicativo)
- **Segreti fuori dal codice**: token e chat ID nel file `.env`

### Come viene riconosciuta l'offerta fissa

Lo script legge i dati strutturati della pagina (blocco `__NEXT_DATA__`):

| Criterio | Dettaglio |
|---|---|
| Primario | `params.productType` che inizia con `FIXED` (es. `FIXED_SINGLE_RATE`); le offerte Flex sono `VARIABLE` |
| Fallback | nome del prodotto contenente `Fissa`, se `productType` manca |
| Durata | dal nome (`Octopus Fissa 24M`) o, in mancanza, dal codice prodotto (`OCTOFIX24` / `OCTOFIXG24`) |

---

## 📲 Esempio messaggio Telegram

```
⚡ Tariffe Octopus Fissa 24M (Luce + Gas)

🔌 Luce monoraria
   Materia prima: 0,1595 €/kWh
   Commercializzazione: 6 €/mese
   IVA e imposte escluse, perdite incluse.

🔥 Gas
   Materia prima: 0,68 €/Smc
   Commercializzazione: 7 €/mese
   IVA e imposte escluse.

🗓 Offerta sottoscrivibile fino al 09/10/2026

💶 PUN Index GME (elettricità, mercato all'ingrosso)
   118,20 €/MWh  (0,118 €/kWh)
   Riferimento del 08/10/2026

💶 PSV gas (mercato all'ingrosso)
   Oggi: ~0,410 €/Smc  ·  9 ottobre 2026
   Media mensile: ~0,401 €/Smc  ·  ottobre 2026
   Dato indicativo (fonte Selectra su dati Snam/GME).
   Per le offerte indicizzate conta la media del mese.

📊 Confronto tariffe precedenti del 01/10/2026:

🔄 Offerta cambiata: Fissa 12M → Fissa 24M

Fissa 24M rispetto a Fissa 12M:
   📈 Luce: 0,135 €/kWh (+0,0245€)
   👍🏻 Commercializzazione Luce: 6 €/mese (invariato)

   📈 Gas: 0,55 €/Smc (+0,13€)
   👍🏻 Commercializzazione Gas: 7 €/mese (invariato)


📅 Aggiornato il 09/10/2026 14:00
```

Con più offerte fisse attive ogni offerta ha il suo blocco (`📌 Octopus Fissa 12M`, `📌 Octopus Fissa 24M`) e il titolo diventa `Tariffe Octopus Fissa 12M / Fissa 24M`.

---

## 🔐 Segreti (`.env`)

Token e chat ID **non** stanno negli script ma in un file `.env` nella stessa cartella:

```bash
cp .env.example .env      # Linux
copy .env.example .env    # Windows
```

```dotenv
TELEGRAM_BOT_TOKEN=123456789:ABCdefGhIJKlmNoPQRstuVWxyz
TELEGRAM_CHAT_ID=-1001234567890
```

- Il file `.env` è escluso da `.gitignore`: non finisce mai nel repository.
- Il file viene **letto**, non eseguito: sono ammesse solo le chiavi `TELEGRAM_BOT_TOKEN` e `TELEGRAM_CHAT_ID`, commenti `#`, prefisso `export ` e valori tra apici.
- Le **variabili d'ambiente** con lo stesso nome hanno la precedenza sul file (comodo per cron, servizi o container).
- Percorso alternativo del file: variabile d'ambiente `OCTOCHECK_ENV_FILE`.
- Se mancano token o chat ID lo script si ferma subito con un messaggio d'errore.

Su Linux conviene proteggerlo:

```bash
chmod 600 .env
```

---

## ⚙️ Configurazione

Il resto della configurazione è in cima a ciascuno script.

**PowerShell**
```powershell
# Soglie (punto o virgola come separatore decimale)
$SogliaLuce = "0.121"        # €/kWh – invia se luce <= questa soglia
$SogliaGas  = "0.430"        # €/Smc – invia se gas  <= questa soglia

$AbilitaSogliaLuce  = $true
$AbilitaSogliaGas   = $true
$AggiornaVariazioni = $true  # invia ad ogni variazione (soglie ignorate)
$NotificaRinnovo    = $true  # avviso quando prezzo = soglia

$AbilitaPun = $true          # PUN Index GME
$AbilitaPsv = $true          # PSV gas indicativo
```

**Bash**
```bash
SOGLIA_LUCE="0.121"
SOGLIA_GAS="0.430"

ABILITA_SOGLIA_LUCE=true
ABILITA_SOGLIA_GAS=true
AGGIORNA_VARIAZIONI=true
NOTIFICA_RINNOVO=true

ABILITA_PUN=true
ABILITA_PSV=true
```

### Modalità di invio

| Impostazione | Comportamento |
|---|---|
| Aggiorna variazioni = `true` | Invia **solo** quando cambia un prezzo della materia prima o l'insieme delle offerte fisse (nuova, rimossa, 12M → 24M). Le soglie vengono ignorate. |
| Aggiorna variazioni = `false` | Modalità soglie: invia se **almeno un'offerta** fissa rispetta **tutte** le soglie abilitate (prezzo **≤** soglia). Una soglia disabilitata conta come rispettata. |
| Notifica rinnovo = `true` | Aggiunge un avviso in cima al messaggio quando il prezzo di un'offerta è **uguale** a una soglia abilitata. |

> `--sendprice` forza sempre l'invio, indipendentemente da tutto.
> PUN e PSV sono solo informativi: non fanno mai partire una notifica.

### Avviso rinnovo contratto

```
⚠️ RINNOVA IL CONTRATTO - ENERGIA 0,121 €/kWh ⚠️   ← solo luce
⚠️ RINNOVA IL CONTRATTO - GAS 0,430 €/Smc ⚠️        ← solo gas
⚠️ RINNOVA IL CONTRATTO - TARIFFA UGUALE ⚠️          ← entrambi
```

Con più offerte attive l'avviso indica quale: `... ENERGIA 0,121 €/kWh (Fissa 12M) ⚠️`.

### Riferimenti di mercato

| Indice | Fonte | Note |
|---|---|---|
| PUN Index GME | API pubblica del sito GME, fallback sul JSON del progetto [pun-tracker](https://github.com/claudiopecere/pun-tracker) | Media giornaliera dell'ultimo giorno completo |
| PSV gas | Pagina pubblica [bolletta-energia.it](https://bolletta-energia.it/gas/psv) (dati Snam/GME) | Valore del giorno e media mensile, **indicativi** |

Se una fonte non risponde la relativa sezione viene semplicemente omessa.

---

## 🪟 Windows — PowerShell

### Requisiti

- Windows PowerShell 5.1+ o PowerShell 7+
- Connessione internet
- Lo script è salvato in **UTF-8 con BOM**: necessario perché emoji e `€` vengano letti correttamente da PowerShell 5.1. Se lo modifichi, mantieni questa codifica.

### Utilizzo

```powershell
# Esecuzione normale
.\OctoCheck.ps1

# Forza invio ignorando soglie (debug)
.\OctoCheck.ps1 --sendprice
```

### Automazione con Task Scheduler

1. Apri **Utilità di pianificazione** → *Crea attività*
2. **Trigger:** ogni giorno all'orario desiderato
3. **Azione:**
   - Programma: `cmd.exe`
   - Argomenti:
     ```
     /c powershell.exe -NonInteractive -ExecutionPolicy Bypass -File "D:\Script\OctopusEnergy\OctoCheck.ps1" >> "D:\Script\OctopusEnergy\log\octocheck_%date:~-4,4%%date:~-7,2%%date:~0,2%.log" 2>&1
     ```
4. Crea la cartella log prima di avviare:
   ```
   mkdir D:\Script\OctopusEnergy\log
   ```

Il file `.env` deve stare nella stessa cartella dello script.

---

## 🐧 Linux — Bash

### Requisiti

- bash 4 o superiore
- curl, jq, python3

```bash
apt install curl jq python3   # Debian/Ubuntu
# oppure
yum install curl jq python3   # RHEL/CentOS
```

### Utilizzo

```bash
chmod +x octocheck.sh

# Esecuzione normale
./octocheck.sh

# Forza invio ignorando soglie (debug)
./octocheck.sh --sendprice
```

### Automazione con cron

```bash
crontab -e
```

Aggiungi la riga (esempio: ogni giorno alle 14:00):

```
0 14 * * * /root/Script/OctoBot/octocheck.sh >> /root/Script/OctoBot/log/octocheck.log 2>&1
```

Verifica che cron stia girando:

```bash
systemctl status cron
grep CRON /var/log/syslog | tail -20
```

---

## 📁 File

| File | Descrizione |
|---|---|
| `.env.example` | Modello dei segreti da copiare in `.env` |
| `.env` | Token e chat ID Telegram. **Non versionato.** |
| `lastprice.json` | Ultimi prezzi rilevati, aggiornato ad ogni run. **Non versionato.** |

`lastprice.json` ha lo stesso formato per entrambe le versioni, con una voce per ogni durata di offerta fissa:

```json
{
  "offerte": {
    "24": {
      "luce": "0,1595",
      "gas": "0,68",
      "commLuce": "6",
      "commGas": "7",
      "validTo": "2026-10-09T22:00:00+00:00"
    }
  },
  "aggiornato": "2026-10-09T14:00:00",
  "pun": "118.2",
  "punData": "2026-10-08",
  "psv": "0,401",
  "psvData": "ottobre 2026",
  "psvOggi": "0,410",
  "psvOggiData": "9 ottobre 2026"
}
```

Il vecchio formato (solo Fissa 12M, con `luce`/`gas` in radice) viene letto automaticamente come offerta `12`, quindi lo storico non si perde con l'aggiornamento.

> Puoi modificare manualmente questo file per simulare una variazione di prezzo e testare le notifiche.

---

## 🤖 Creare un bot Telegram

1. Cerca **@BotFather** su Telegram
2. Invia `/newbot` e segui le istruzioni
3. Copia il token ricevuto in `TELEGRAM_BOT_TOKEN` nel file `.env`
4. Per ottenere il **Chat ID**:
   - Aggiungi il bot a un gruppo oppure scrivigli in privato
   - Visita `https://api.telegram.org/bot<TOKEN>/getUpdates`
   - Cerca il campo `"id"` dentro `"chat"` e copialo in `TELEGRAM_CHAT_ID`

---

## 📜 License

Distribuito sotto licenza **GNU General Public License v3.0** (GPL-3.0). Vedi il file [LICENSE](LICENSE).

---

## 👤 Author

[Leproide](https://github.com/Leproide)
