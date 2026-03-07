#!/usr/bin/env bash
# ==============================================================================
#  octocheck.sh
#  https://github.com/Leproide/BOT-Tariffe-Octopus-Energy-Italia
#  Rilasciato sotto GNU General Public License, version 2
#
#  Monitora le tariffe Octopus Fissa 12M (scheda Luce + Gas) e invia notifica
#
#  Uso normale : ./octocheck.sh
#  Debug       : ./octocheck.sh --sendprice
#
#  Dipendenze  : curl, jq, python3
# ==============================================================================

# ------------------------------------------------------------------------------
# CONFIGURAZIONE – modifica questi valori prima di usare lo script
# ------------------------------------------------------------------------------

$TelegramBotToken = "IL_TUO_TOKEN"			# BOT Token
$TelegramChatId   = "IL_TUO_CHAT_ID"		# Chat ID destinatario

# Soglie di allerta (usa punto o virgola: 0.121 oppure 0,121)
SOGLIA_LUCE="0.121"          # €/kWh  – invia se luce < questa soglia
SOGLIA_GAS="0.430"           # €/Smc  – invia se gas  < questa soglia

# Abilita/disabilita le singole soglie
# true  → la soglia viene controllata
# false → soglia ignorata
ABILITA_SOGLIA_LUCE=true
ABILITA_SOGLIA_GAS=true

# Se true: invia notifica ogni volta che il prezzo cambia rispetto all'ultima
# rilevazione registrata in lastprice.json, indipendentemente dalle soglie.
AGGIORNA_VARIAZIONI=true

# Se true: avvisa quando il prezzo attuale coincide esattamente con la soglia
# (utile per rinnovi contrattuali).
NOTIFICA_RINNOVO=true

# ------------------------------------------------------------------------------
# FINE CONFIGURAZIONE
# ------------------------------------------------------------------------------

URL_TARIFFE="https://octopusenergy.it/le-nostre-tariffe"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LASTPRICE_FILE="$SCRIPT_DIR/lastprice.json"

# Normalizza soglie: virgola → punto
SOGLIA_LUCE="${SOGLIA_LUCE//,/.}"
SOGLIA_GAS="${SOGLIA_GAS//,/.}"

# Parametro --sendprice
SENDPRICE=false
for arg in "$@"; do
    [[ "$arg" == "--sendprice" || "$arg" == "-sendprice" ]] && SENDPRICE=true
done

# ------------------------------------------------------------------------------
# Funzione: invia messaggio Telegram
# ------------------------------------------------------------------------------
send_telegram() {
    local messaggio="$1"
    local risposta
    risposta=$(curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
        --data-urlencode "text=${messaggio}" \
        --data-urlencode "parse_mode=HTML")
    if echo "$risposta" | jq -e '.ok == true' > /dev/null 2>&1; then
        echo "[OK] Messaggio Telegram inviato con successo."
    else
        echo "[ERRORE] Telegram ha risposto: $risposta" >&2
    fi
}

# ------------------------------------------------------------------------------
# Funzione: freccia direzionale
# ------------------------------------------------------------------------------
freccia() {
    python3 -c "
n=float('$1'); v=float('$2')
if   n < v: print('📉')
elif n > v: print('📈')
else:        print('👍🏻')
"
}

# ------------------------------------------------------------------------------
# Funzione: riga storico con prezzo precedente e differenza
# ------------------------------------------------------------------------------
riga_storico() {
    local label="$1" nuovo="$2" vecchio="$3" unit="$4"
    local f vecchio_str diff_str
    f=$(freccia "$nuovo" "$vecchio")
    vecchio_str=$(python3 -c "v=float('$vecchio'); print(f'{v:.3f}'.replace('.',','))")
    diff_str=$(python3 -c "
n=float('$nuovo'); v=float('$vecchio')
d=n-v
if d==0: print('')
else:
    s=f'{abs(d):.3f}'.replace('.', ',')
    print(('+' if d>0 else '-')+s+chr(0x20AC))
")
    if [[ -z "$diff_str" ]]; then
        echo "   $f ${label}: ${vecchio_str} €/${unit} (invariato)"
    else
        echo "   $f ${label}: ${vecchio_str} €/${unit} (${diff_str})"
    fi
}

# Helper comparazioni float
py_lt() { python3 -c "import sys; sys.exit(0 if float('$1') < float('$2') else 1)"; }
py_eq() { python3 -c "import sys; sys.exit(0 if float('$1') == float('$2') else 1)"; }

# ------------------------------------------------------------------------------
# Scarica la pagina
# ------------------------------------------------------------------------------
echo "Scaricamento della pagina tariffe..."

TMP_HTML=$(mktemp)
TMP_PY=$(mktemp --suffix=.py)
trap 'rm -f "$TMP_HTML" "$TMP_PY"' EXIT

curl -s --max-time 30 "$URL_TARIFFE" > "$TMP_HTML"
if [[ ! -s "$TMP_HTML" ]]; then
    echo "Impossibile raggiungere $URL_TARIFFE" >&2
    exit 1
fi

# ------------------------------------------------------------------------------
# Estrai il blocco JSON da <script id="__NEXT_DATA__">
# ------------------------------------------------------------------------------
cat > "$TMP_PY" << 'PYEOF'
import sys, re, json

with open(sys.argv[1], 'r', encoding='utf-8', errors='replace') as f:
    html = f.read()

idx = html.find('type="application/json">')
if idx == -1:
    sys.exit(1)

start = html.find('>', idx) + 1
depth = 0
in_string = False
escape = False
end_pos = None
for i, c in enumerate(html[start:]):
    if escape:
        escape = False
        continue
    if c == '\\' and in_string:
        escape = True
        continue
    if c == '"':
        in_string = not in_string
        continue
    if not in_string:
        if c == '{':
            depth += 1
        elif c == '}':
            depth -= 1
            if depth == 0:
                end_pos = start + i + 1
                break

if end_pos:
    raw = html[start:end_pos]
else:
    end_script = html.find('</script>', start)
    raw = html[start:end_script].strip()
    raw = re.sub(r'"__N_SSG"\s*$', '"__N_SSG":true}}', raw)

try:
    data = json.loads(raw)
    print(json.dumps(data))
except Exception:
    sys.exit(1)
PYEOF

JSON_DATA=$(python3 "$TMP_PY" "$TMP_HTML")

if [[ -z "$JSON_DATA" ]]; then
    echo "Impossibile trovare o decodificare il blocco __NEXT_DATA__ nella pagina." >&2
    exit 1
fi

# ------------------------------------------------------------------------------
# Cerca i prodotti "Fissa 12M" nel JSON
# ------------------------------------------------------------------------------
TARIFFA_LUCE_STR=$(echo "$JSON_DATA" | jq -r '
    .props.pageProps.products[]
    | select(.__typename == "ElectricityProductType" and (.displayName | test("Fissa 12M")))
    | if .params | type == "array" then .params[0].consumptionCharge
      else .params.consumptionCharge end
' | head -1)

TARIFFA_GAS_STR=$(echo "$JSON_DATA" | jq -r '
    .props.pageProps.products[]
    | select(.__typename == "GasProductType" and (.displayName | test("Fissa 12M")))
    | if .params | type == "array" then .params[0].consumptionCharge
      else .params.consumptionCharge end
' | head -1)

ANNUAL_LUCE=$(echo "$JSON_DATA" | jq -r '
    .props.pageProps.products[]
    | select(.__typename == "ElectricityProductType" and (.displayName | test("Fissa 12M")))
    | if .params | type == "array" then .params[0].annualStandingCharge
      else .params.annualStandingCharge end
' | head -1)

ANNUAL_GAS=$(echo "$JSON_DATA" | jq -r '
    .props.pageProps.products[]
    | select(.__typename == "GasProductType" and (.displayName | test("Fissa 12M")))
    | if .params | type == "array" then .params[0].annualStandingCharge
      else .params.annualStandingCharge end
' | head -1)

if [[ -z "$TARIFFA_LUCE_STR" ]]; then echo "Prodotto 'Octopus Fissa 12M' (luce) non trovato." >&2; exit 1; fi
if [[ -z "$TARIFFA_GAS_STR"  ]]; then echo "Prodotto 'Octopus Fissa 12M Gas' non trovato."    >&2; exit 1; fi

TARIFFA_LUCE="${TARIFFA_LUCE_STR//,/.}"
TARIFFA_GAS="${TARIFFA_GAS_STR//,/.}"

COMM_LUCE_STR=$(python3 -c "print(int(int('$ANNUAL_LUCE') / 12))")
COMM_GAS_STR=$(python3  -c "print(int(int('$ANNUAL_GAS')  / 12))")

echo ""
echo "--- Tariffe rilevate ---"
echo "  Luce monoraria : $TARIFFA_LUCE_STR €/kWh  (comm. $COMM_LUCE_STR €/mese)"
echo "  Gas            : $TARIFFA_GAS_STR €/Smc  (comm. $COMM_GAS_STR €/mese)"
echo ""

# ------------------------------------------------------------------------------
# Carica l'ultimo prezzo registrato da lastprice.json
# ------------------------------------------------------------------------------
ULTIMO_LUCE_STR=""
ULTIMO_GAS_STR=""
ULTIMO_COMM_LUCE=""
ULTIMO_COMM_GAS=""
ULTIMO_AGGIORNATO=""

if [[ -f "$LASTPRICE_FILE" ]]; then
    ULTIMO_LUCE_STR=$(jq  -r '.luce        // ""' "$LASTPRICE_FILE" 2>/dev/null)
    ULTIMO_GAS_STR=$(jq   -r '.gas         // ""' "$LASTPRICE_FILE" 2>/dev/null)
    ULTIMO_COMM_LUCE=$(jq -r '.commLuce    // ""' "$LASTPRICE_FILE" 2>/dev/null)
    ULTIMO_COMM_GAS=$(jq  -r '.commGas     // ""' "$LASTPRICE_FILE" 2>/dev/null)
    ULTIMO_AGGIORNATO=$(jq -r '.aggiornato // ""' "$LASTPRICE_FILE" 2>/dev/null)
    echo "  Ultimo prezzo registrato → Luce: $ULTIMO_LUCE_STR €/kWh  |  Gas: $ULTIMO_GAS_STR €/Smc"
fi

# Determina se i prezzi sono variati
if [[ "$ULTIMO_LUCE_STR" != "$TARIFFA_LUCE_STR" || "$ULTIMO_GAS_STR" != "$TARIFFA_GAS_STR" ]]; then
    PREZZO_VARIATO=true
else
    PREZZO_VARIATO=false
fi

# Salva i prezzi correnti in lastprice.json
NOW=$(date '+%Y-%m-%dT%H:%M:%S')
jq -n \
    --arg luce       "$TARIFFA_LUCE_STR" \
    --arg gas        "$TARIFFA_GAS_STR" \
    --arg commLuce   "$COMM_LUCE_STR" \
    --arg commGas    "$COMM_GAS_STR" \
    --arg aggiornato "$NOW" \
    '{luce: $luce, gas: $gas, commLuce: $commLuce, commGas: $commGas, aggiornato: $aggiornato}' \
    > "$LASTPRICE_FILE"
echo "  Prezzi salvati in $LASTPRICE_FILE"

# ------------------------------------------------------------------------------
# Decide se inviare la notifica
# ------------------------------------------------------------------------------
DATA_ORA=$(date '+%d/%m/%Y %H:%M')
MOTIVO_INVIO=""
MOTIVO_NO_INVIO=""
DEVE_INVIARE=false

if [[ "$SENDPRICE" == "true" ]]; then
    echo "[DEBUG --sendprice] Invio forzato indipendentemente dalle soglie."
    DEVE_INVIARE=true
    MOTIVO_INVIO="debug --sendprice"

elif [[ "$AGGIORNA_VARIAZIONI" == "true" ]]; then
    if [[ "$PREZZO_VARIATO" == "true" ]]; then
        echo "  Variazione rilevata → invio notifica."
        DEVE_INVIARE=true
        MOTIVO_INVIO="variazione prezzi"
    else
        echo "  Nessuna variazione rispetto all'ultima rilevazione."
        MOTIVO_NO_INVIO="nessuna variazione di prezzo"
    fi

else
    # Modalità soglie: invia se STRETTAMENTE inferiore (<)
    CONDIZIONE_L=false
    CONDIZIONE_G=false

    if [[ "$ABILITA_SOGLIA_LUCE" == "true" ]]; then
        if py_lt "$TARIFFA_LUCE" "$SOGLIA_LUCE"; then
            CONDIZIONE_L=true
            echo "  Soglia luce (${SOGLIA_LUCE/./,} €/kWh): OK ✔"
        else
            echo "  Soglia luce (${SOGLIA_LUCE/./,} €/kWh): NO (attuale $TARIFFA_LUCE_STR > soglia ${SOGLIA_LUCE/./,})"
        fi
    else
        CONDIZIONE_L=true
        echo "  Soglia luce: DISABILITATA"
    fi

    if [[ "$ABILITA_SOGLIA_GAS" == "true" ]]; then
        if py_lt "$TARIFFA_GAS" "$SOGLIA_GAS"; then
            CONDIZIONE_G=true
            echo "  Soglia gas  (${SOGLIA_GAS/./,} €/Smc): OK ✔"
        else
            echo "  Soglia gas  (${SOGLIA_GAS/./,} €/Smc): NO (attuale $TARIFFA_GAS_STR > soglia ${SOGLIA_GAS/./,})"
        fi
    else
        CONDIZIONE_G=true
        echo "  Soglia gas: DISABILITATA"
    fi

    # Calcola parità per NotificaRinnovo
    LUCE_PARI=false; GAS_PARI=false
    [[ "$ABILITA_SOGLIA_LUCE" == "true" ]] && py_eq "$TARIFFA_LUCE" "$SOGLIA_LUCE" && LUCE_PARI=true
    [[ "$ABILITA_SOGLIA_GAS"  == "true" ]] && py_eq "$TARIFFA_GAS"  "$SOGLIA_GAS"  && GAS_PARI=true

    if [[ "$CONDIZIONE_L" == "true" || "$CONDIZIONE_G" == "true" ]]; then
        DEVE_INVIARE=true
        MOTIVO_INVIO="soglie raggiunte"
    elif [[ "$NOTIFICA_RINNOVO" == "true" && ("$LUCE_PARI" == "true" || "$GAS_PARI" == "true") ]]; then
        DEVE_INVIARE=true
        MOTIVO_INVIO="rinnovo contratto"
    else
        MOTIVO_NO_INVIO="soglie non raggiunte"
    fi
fi

echo ""

# ------------------------------------------------------------------------------
# Componi e invia il messaggio Telegram
# ------------------------------------------------------------------------------
if [[ "$DEVE_INVIARE" == "true" ]]; then

    # Sezione storico — solo se esiste uno storico
    SEZIONE_ANDAMENTO=""
    if [[ -n "$ULTIMO_LUCE_STR" ]]; then

        ULTIMO_LUCE_F="${ULTIMO_LUCE_STR//,/.}"
        ULTIMO_GAS_F="${ULTIMO_GAS_STR//,/.}"
        ULTIMO_COMM_LUCE_F="${ULTIMO_COMM_LUCE:-$COMM_LUCE_STR}"
        ULTIMO_COMM_GAS_F="${ULTIMO_COMM_GAS:-$COMM_GAS_STR}"

        R1=$(riga_storico "Luce"                     "$TARIFFA_LUCE"  "$ULTIMO_LUCE_F"      "kWh")
        R2=$(riga_storico "Commercializzazione Luce" "$COMM_LUCE_STR" "$ULTIMO_COMM_LUCE_F" "mese")
        R3=$(riga_storico "Gas"                      "$TARIFFA_GAS"   "$ULTIMO_GAS_F"       "Smc")
        R4=$(riga_storico "Commercializzazione Gas"  "$COMM_GAS_STR"  "$ULTIMO_COMM_GAS_F"  "mese")

        ULTIMO_DATA_STR=""
        if [[ -n "$ULTIMO_AGGIORNATO" ]]; then
            ULTIMO_DATA_STR=$(python3 -c "
from datetime import datetime
try: print(' ' + datetime.fromisoformat('$ULTIMO_AGGIORNATO').strftime('%d/%m/%Y'))
except: pass
")
        fi

        SEZIONE_ANDAMENTO="
📊 <b>Variazione tariffe dal${ULTIMO_DATA_STR}:</b>

${R1}
${R2}

${R3}
${R4}"
    fi

    # Intestazione rinnovo
    RIGA_RINNOVO=""
    if [[ "$NOTIFICA_RINNOVO" == "true" ]]; then
        if [[ "$LUCE_PARI" == "true" && "$GAS_PARI" == "true" ]]; then
            RIGA_RINNOVO="⚠️ RINNOVA IL CONTRATTO - TARIFFA UGUALE ⚠️

"
        elif [[ "$LUCE_PARI" == "true" ]]; then
            SL="${SOGLIA_LUCE/./,}"
            RIGA_RINNOVO="⚠️ RINNOVA IL CONTRATTO - ENERGIA ${SL} €/kWh ⚠️

"
        elif [[ "$GAS_PARI" == "true" ]]; then
            SG="${SOGLIA_GAS/./,}"
            RIGA_RINNOVO="⚠️ RINNOVA IL CONTRATTO - GAS ${SG} €/Smc ⚠️

"
        fi
    fi

    MESSAGGIO="${RIGA_RINNOVO}⚡ <b>Tariffe Octopus Fissa 12M (Luce + Gas)</b>

🔌 <b>Luce monoraria</b>
   Materia prima: <b>${TARIFFA_LUCE_STR} €/kWh</b>
   Commercializzazione: ${COMM_LUCE_STR} €/mese
   IVA e imposte escluse, perdite incluse.

🔥 <b>Gas</b>
   Materia prima: <b>${TARIFFA_GAS_STR} €/Smc</b>
   Commercializzazione: ${COMM_GAS_STR} €/mese
   IVA e imposte escluse.
${SEZIONE_ANDAMENTO}

📅 Aggiornato il ${DATA_ORA}
"

    echo "Invio notifica Telegram ($MOTIVO_INVIO)..."
    send_telegram "$MESSAGGIO"

else
    echo "Nessuna notifica inviata: $MOTIVO_NO_INVIO."
fi
