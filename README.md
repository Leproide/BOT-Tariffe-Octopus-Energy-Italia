# 🐙 OctoCheck

Monitor automatico delle tariffe **Octopus Fissa 12M (Luce + Gas)** con notifiche Telegram.

Disponibile in due versioni identiche:
- `OctoCheck.ps1` — Windows (PowerShell)
- `octocheck.sh` — Linux (Bash)

🐙 Non sei ancora un cliente Octopus Energy?
Per sostenermi utilizza [questo link](https://muninn.ovh/octopus.php), 30€ in sconto a entrambi sulla prima bolletta.

---

## 🤖 Istanza pubblica

Per chi volesse esiste la mia istanza pubblica con la funzione base di notifica al cambio prezzo

https://t.me/OctopusEnergy_Italia 

Per tutte le altre funzioni dovete necessariamente avviare una vostra istanza privata.

## 📋 Funzionalità

- **Scraping automatico** delle tariffe Octopus Fissa 12M dalla pagina ufficiale
- **Notifiche Telegram** con formattazione HTML
- **Tre modalità di invio** configurabili e combinabili
- **Storico prezzi** salvato in `lastprice.json` con confronto tra run
- **Sezione andamento** nel messaggio con frecce 📉📈👍🏻 e differenza in €
- **Avviso rinnovo contratto** quando la tariffa raggiunge esattamente la soglia

---

## 📲 Esempio messaggio Telegram

```
⚡ Tariffe Octopus Fissa 12M (Luce + Gas)

🔌 Luce monoraria
   Materia prima: 0,099 €/kWh
   Commercializzazione: 6 €/mese
   IVA e imposte escluse, perdite incluse.

🔥 Gas
   Materia prima: 0,425 €/Smc
   Commercializzazione: 7 €/mese
   IVA e imposte escluse.

📊 Variazione tariffe dal 06/03/2026:

   📉 Luce: 0,121 €/kWh (-0,022€)
   👍🏻 Commercializzazione Luce: 6 €/mese (invariato)

   📉 Gas: 0,475 €/Smc (-0,050€)
   👍🏻 Commercializzazione Gas: 7 €/mese (invariato)

📅 Aggiornato il 07/03/2026 14:00
```

---

## ⚙️ Configurazione

Apri lo script e modifica la sezione in cima:

```powershell
# Token del bot Telegram
$TelegramBotToken = "IL_TUO_TOKEN"
$TelegramChatId   = "IL_TUO_CHAT_ID"

# Soglie di allerta (usa punto o virgola come separatore decimale)
$SogliaLuce = 0.100       # €/kWh – invia se luce < questa soglia
$SogliaGas  = 0.430       # €/Smc – invia se gas  < questa soglia

# Abilita/disabilita le singole soglie
$AbilitaSogliaLuce = $true
$AbilitaSogliaGas  = $true

# Invia ad ogni variazione di prezzo rispetto all'ultima run
$AggiornaVariazioni = $true

# Avvisa quando il prezzo corrisponde esattamente alla soglia (rinnovo contratto)
$NotificaRinnovo = $true
```

### Modalità di invio

| Variabile | Comportamento |
|---|---|
| `$AggiornaVariazioni = $true` | Invia **solo** quando il prezzo cambia rispetto all'ultima run. Le soglie vengono ignorate. |
| `$AggiornaVariazioni = $false` | Controlla le soglie. Invia se almeno una soglia abilitata è **strettamente inferiore** (`<`) al prezzo attuale. |
| `$NotificaRinnovo = $true` | Invia un avviso speciale quando il prezzo è **uguale** alla soglia. Utile per sapere quando rinnovare il contratto alle stesse condizioni. |

> Le tre modalità sono indipendenti. `--sendprice` forza sempre l'invio indipendentemente da tutto.

### Avviso rinnovo contratto

Quando `$NotificaRinnovo = $true` e il prezzo coincide con la soglia, il messaggio inizia con:

```
⚠️ RINNOVA IL CONTRATTO - ENERGIA 0,121 €/kWh ⚠️   ← solo luce
⚠️ RINNOVA IL CONTRATTO - GAS 0,430 €/Smc ⚠️        ← solo gas
⚠️ RINNOVA IL CONTRATTO - TARIFFA UGUALE ⚠️          ← entrambi
```

---

## 🪟 Windows — PowerShell

### Requisiti

- Windows PowerShell 5.1+ o PowerShell 7+
- Connessione internet

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
     /c powershell.exe -NonInteractive -File "D:\Script\OctopusEnergy\OctoCheck.ps1" >> "D:\Script\OctopusEnergy\log\octocheck_%date:~-4,4%%date:~-7,2%%date:~0,2%.log" 2>&1
     ```
4. Crea la cartella log prima di avviare:
   ```
   mkdir D:\Script\OctopusEnergy\log
   ```

---

## 🐧 Linux — Bash

### Requisiti

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

## 📁 File generati

| File | Descrizione |
|---|---|
| `lastprice.json` | Ultimo prezzo rilevato. Viene aggiornato ad ogni run. |

Esempio contenuto:
```json
{
  "luce": "0,121",
  "gas": "0,475",
  "commLuce": "6",
  "commGas": "7",
  "aggiornato": "2026-03-07T14:00:00"
}
```

> Puoi modificare manualmente questo file per simulare una variazione di prezzo e testare le notifiche.

---

## 🤖 Creare un bot Telegram

1. Cerca **@BotFather** su Telegram
2. Invia `/newbot` e segui le istruzioni
3. Copia il token ricevuto in `$TelegramBotToken`
4. Per ottenere il **Chat ID**:
   - Aggiungi il bot a un gruppo oppure scrivgli in privato
   - Visita `https://api.telegram.org/bot<TOKEN>/getUpdates`
   - Cerca il campo `"id"` dentro `"chat"`

---

## 📜 Licenza

GNU General Public License v2.0
