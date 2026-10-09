#!/usr/bin/env bash
# ==============================================================================
#  octocheck.sh
#  https://github.com/Leproide/BOT-Tariffe-Octopus-Energy-Italia
#
#  Monitora le tariffe Octopus a prezzo FISSO (12M, 24M o qualsiasi durata
#  presente in pagina, scheda Luce + Gas) e invia notifica Telegram se le
#  soglie configurate sono rispettate o se i prezzi cambiano.
#  Include due riferimenti di mercato all'ingrosso: PUN Index GME (elettricità)
#  e PSV (gas, indicativo).
#
#  Riconoscimento offerta fissa:
#    - primario : params.productType che inizia con "FIXED" (es. FIXED_SINGLE_RATE)
#    - fallback : displayName contenente "Fissa" (se productType assente)
#  Durata ricavata da displayName ("Fissa 24M") o, in fallback, dal code
#  ("OCTOFIX24" / "OCTOFIXG24"). Se in pagina ci sono più offerte fisse
#  (es. 12M e 24M insieme) vengono mostrate tutte nel messaggio.
#
#  Uso normale : ./octocheck.sh
#  Debug       : ./octocheck.sh --sendprice
#
#  Dipendenze  : bash >= 4 (array associativi), curl, jq, python3
#
#  Author: https://github.com/Leproide
#
#  Copyright (C) 2026  https://github.com/Leproide
#
#  This program is free software: you can redistribute it and/or modify
#  it under the terms of the GNU General Public License as published by
#  the Free Software Foundation, either version 3 of the License, or
#  (at your option) any later version.
#
#  This program is distributed in the hope that it will be useful,
#  but WITHOUT ANY WARRANTY; without even the implied warranty of
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#  GNU General Public License for more details.
#
#  You should have received a copy of the GNU General Public License
#  along with this program.  If not, see <https://www.gnu.org/licenses/>.
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ------------------------------------------------------------------------------
# SEGRETI TELEGRAM – letti dal file .env nella cartella dello script
# (copia .env.example in .env e compila i valori). Percorso alternativo:
# variabile d'ambiente OCTOCHECK_ENV_FILE. Le variabili d'ambiente già
# impostate hanno la precedenza sul file .env.
# ------------------------------------------------------------------------------
ENV_FILE="${OCTOCHECK_ENV_FILE:-$SCRIPT_DIR/.env}"

# Legge KEY=VALUE dal file .env senza eseguirlo (niente `source`).
# Accetta righe vuote, commenti (#), prefisso "export " e valori tra apici.
# Vengono importate solo le chiavi ammesse.
load_env() {
    local file="$1" line key val
    local -a ammesse=(TELEGRAM_BOT_TOKEN TELEGRAM_CHAT_ID)
    [[ -f "$file" ]] || return 0
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"                               # tollera file CRLF
        [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
        [[ "$line" =~ ^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=[[:space:]]*(.*)$ ]] || continue
        key="${BASH_REMATCH[2]}"
        val="${BASH_REMATCH[3]}"
        val="${val%"${val##*[![:space:]]}"}"                # spazi finali
        if [[ "$val" =~ ^\"(.*)\"$ || "$val" =~ ^\'(.*)\'$ ]]; then
            val="${BASH_REMATCH[1]}"
        fi
        [[ " ${ammesse[*]} " == *" $key "* ]] || continue
        [[ -n "${!key:-}" ]] && continue                    # l'ambiente vince
        printf -v "$key" '%s' "$val"
    done < "$file"
}
load_env "$ENV_FILE"

if [[ -z "${TELEGRAM_BOT_TOKEN:-}" || -z "${TELEGRAM_CHAT_ID:-}" ]]; then
    echo "TELEGRAM_BOT_TOKEN e/o TELEGRAM_CHAT_ID mancanti." >&2
    echo "Crea $ENV_FILE partendo da .env.example oppure imposta le variabili d'ambiente." >&2
    exit 1
fi

# ------------------------------------------------------------------------------
# CONFIGURAZIONE – modifica questi valori prima di usare lo script
# ------------------------------------------------------------------------------

# Soglie di allerta (valgono per ciascuna offerta fissa trovata).
# Punto o virgola come separatore decimale: 0.121 oppure 0,121
SOGLIA_LUCE="0.121"          # €/kWh  – invia se luce <= questa soglia
SOGLIA_GAS="0.430"           # €/Smc  – invia se gas  <= questa soglia

# Abilita/disabilita le singole soglie
# true  → la soglia viene controllata
# false → soglia ignorata (considerata sempre rispettata)
ABILITA_SOGLIA_LUCE=true
ABILITA_SOGLIA_GAS=true

# Se true: invia notifica ogni volta che il prezzo (o l'insieme delle offerte
# fisse disponibili) cambia rispetto all'ultima rilevazione registrata in
# lastprice.json. In questa modalità le soglie vengono ignorate.
AGGIORNA_VARIAZIONI=true

# Se true: aggiunge in cima al messaggio un avviso quando il prezzo di
# un'offerta coincide esattamente con una soglia abilitata (utile per i rinnovi).
NOTIFICA_RINNOVO=true

# --- PUN Index GME (elettricità) --------------------------------------------
# Se true: recupera e mostra nel messaggio il PUN Index GME del giorno.
# Fetch non-bloccante: se fallisce, la sezione viene omessa.
ABILITA_PUN=true

# --- PSV gas (giornaliero + media mensile, indicativo, senza credenziali) ----
# Valore INDICATIVO del PSV (gas all'ingrosso) in €/Smc, estratto dalla pagina
# Selectra (dati Snam/GME) con solo curl+grep, nessuna credenziale.
# Vengono estratti DUE dati dalla stessa pagina:
#   - il valore GIORNALIERO ("PSV gas oggi ...");
#   - la MEDIA MENSILE in corso (il riferimento che conta per le indicizzate).
# Entrambi indicativi e dichiarati come tali nel messaggio. Blocco non-bloccante.
ABILITA_PSV=true
URL_PSV="https://bolletta-energia.it/gas/psv"

# ------------------------------------------------------------------------------
# FINE CONFIGURAZIONE
# ------------------------------------------------------------------------------

URL_TARIFFE="https://octopusenergy.it/le-nostre-tariffe"
LASTPRICE_FILE="$SCRIPT_DIR/lastprice.json"
REFERRAL="🐙 Se ti va, supportami a questo link e ricevi uno sconto
https://muninn.ovh/octobot"

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
# Funzioni di supporto per le offerte
# ------------------------------------------------------------------------------

# Etichetta leggibile di un'offerta a partire dalla durata in mesi.
# Durata "0" = durata non ricavabile → solo "Fissa".
label_offerta() {
    if [[ "$1" == "0" ]]; then echo "Fissa"; else echo "Fissa ${1}M"; fi
}

# Commercializzazione mensile da quota annua (accetta virgola o punto).
# Intero se divisibile, altrimenti 2 decimali con virgola. Vuoto se non valida.
fmt_comm_mese() {
    python3 - "$1" << 'PYEOF'
import sys
try:
    v = float(sys.argv[1].replace(',', '.')) / 12
    print(str(int(v)) if v == int(v) else f'{v:.2f}'.replace('.', ','))
except Exception:
    print('')
PYEOF
}

# Data di validità leggibile da validTo ISO (es. 2026-10-09T22:00:00+00:00).
# validTo è l'istante di scadenza (mezzanotte ora italiana): si converte in
# Europe/Rome e si sottrae 1 secondo, così coincide con "Fino al gg/mm/aaaa"
# mostrato sul sito.
fmt_valid_to() {
    python3 - "$1" << 'PYEOF'
import sys
from datetime import datetime, timedelta
s = sys.argv[1].strip()
if not s:
    sys.exit(0)
try:
    dt = datetime.fromisoformat(s.replace('Z', '+00:00'))
    try:
        from zoneinfo import ZoneInfo
        dt = dt.astimezone(ZoneInfo("Europe/Rome"))
    except Exception:
        pass
    print((dt - timedelta(seconds=1)).strftime('%d/%m/%Y'))
except Exception:
    print('')
PYEOF
}

# Confronto float esatto (exit 0 se uguali), per l'avviso rinnovo
py_eq() { python3 -c "import sys; sys.exit(0 if float(sys.argv[1]) == float(sys.argv[2]) else 1)" "$1" "$2"; }

# ------------------------------------------------------------------------------
# Scarica la pagina
# ------------------------------------------------------------------------------
echo "Scaricamento della pagina tariffe..."

TMP_HTML=$(mktemp)
TMP_PY=$(mktemp --suffix=.py)
TMP_PY_PUN=$(mktemp --suffix=.py)
# Pulizia automatica all'uscita (crash, errore, Ctrl+C — qualsiasi causa)
trap 'rm -f "$TMP_HTML" "$TMP_PY" "$TMP_PY_PUN"' EXIT

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
# Cerca TUTTE le offerte a prezzo fisso (luce e gas) nel JSON
#
# Output jq: una riga per prodotto, campi separati da "|" (separatore non
# whitespace, così i campi vuoti non vengono collassati da `read`):
#   tipo|durata|consumptionCharge|annualStandingCharge|validTo|displayName
# ------------------------------------------------------------------------------
OFFERTE_RAW=$(echo "$JSON_DATA" | jq -r '
    .props.pageProps.products[]
    | select(.__typename == "ElectricityProductType" or .__typename == "GasProductType")
    | (if (.params | type) == "array" then .params[0] else .params end) as $p
    | select(
        if (($p.productType // "") | length) > 0
        then ($p.productType | startswith("FIXED"))
        else ((.displayName // "") | test("Fissa"; "i"))
        end)
    | ( [ (.displayName // "") | capture("(?<n>[0-9]+)\\s*M\\b") | .n ][0]
        // [ (.code // "") | capture("OCTOFIXG?(?<n>[0-9]+)") | .n ][0]
        // "0" ) as $dur
    | [ (if .__typename == "ElectricityProductType" then "luce" else "gas" end),
        $dur,
        ($p.consumptionCharge // ""),
        ($p.annualStandingCharge // ""),
        (.validTo // ""),
        (.displayName // "") ]
    | map(tostring) | join("|")
' 2>/dev/null)

# Array associativi indicizzati per durata (mesi)
declare -A O_LUCE O_GAS O_ANN_LUCE O_ANN_GAS O_VALID O_COMM_LUCE O_COMM_GAS

while IFS='|' read -r tipo dur cons annual valid nome; do
    [[ -z "$tipo" || -z "$cons" ]] && continue
    if [[ "$tipo" == "luce" ]]; then
        # Se più prodotti con stessa durata, tiene il primo (come prima con head -1)
        if [[ -z "${O_LUCE[$dur]:-}" ]]; then
            O_LUCE[$dur]="$cons"; O_ANN_LUCE[$dur]="$annual"
        fi
    else
        if [[ -z "${O_GAS[$dur]:-}" ]]; then
            O_GAS[$dur]="$cons"; O_ANN_GAS[$dur]="$annual"
        fi
    fi
    # Validità: tiene la scadenza più vicina tra luce e gas della stessa durata
    if [[ -n "$valid" ]]; then
        if [[ -z "${O_VALID[$dur]:-}" || "$valid" < "${O_VALID[$dur]}" ]]; then
            O_VALID[$dur]="$valid"
        fi
    fi
done <<< "$OFFERTE_RAW"

# Elenco durate disponibili, ordinate (es. 12 24)
mapfile -t DURATE < <(printf '%s\n' "${!O_LUCE[@]}" "${!O_GAS[@]}" | grep -v '^$' | sort -nu)

if [[ ${#DURATE[@]} -eq 0 ]]; then
    echo "Nessuna offerta Octopus a prezzo fisso (luce o gas) trovata nella pagina." >&2
    exit 1
fi

# Commercializzazione mensile per ciascuna offerta
for d in "${DURATE[@]}"; do
    [[ -n "${O_ANN_LUCE[$d]:-}" ]] && O_COMM_LUCE[$d]=$(fmt_comm_mese "${O_ANN_LUCE[$d]}")
    [[ -n "${O_ANN_GAS[$d]:-}"  ]] && O_COMM_GAS[$d]=$(fmt_comm_mese "${O_ANN_GAS[$d]}")
done

echo ""
echo "--- Offerte fisse rilevate ---"
for d in "${DURATE[@]}"; do
    lab=$(label_offerta "$d")
    vstr=$(fmt_valid_to "${O_VALID[$d]:-}")
    echo "  [$lab]${vstr:+  valida fino al $vstr}"
    echo "    Luce monoraria : ${O_LUCE[$d]:-n/d} €/kWh  (comm. ${O_COMM_LUCE[$d]:-?} €/mese)"
    echo "    Gas            : ${O_GAS[$d]:-n/d} €/Smc  (comm. ${O_COMM_GAS[$d]:-?} €/mese)"
done
echo ""

# ------------------------------------------------------------------------------
# PUN Index GME del giorno (elettricità)
#
# Fonte primaria : API pubblica non documentata del sito GME (pagina PUN Index).
# Fonte fallback : JSON pubblico del progetto pun-tracker (terza parte).
# Blocco non-bloccante.
# ------------------------------------------------------------------------------
PUN_DISPONIBILE=false
PUN_MWH=""
PUN_DATA_ISO=""

if [[ "$ABILITA_PUN" == "true" ]]; then
    cat > "$TMP_PY_PUN" << 'PYEOF'
import sys, json, re, http.cookiejar, urllib.request
from collections import defaultdict
from datetime import date, timedelta

BASE = "https://gme.mercatoelettrico.org"
PAGE = BASE + "/en-us/Home/Results/Electricity/MGP/Results/PUN/ResultsMGP"
UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36")
FALLBACK = "https://raw.githubusercontent.com/claudiopecere/pun-tracker/main/data/pun.json"


def gme_pun(giorni=7):
    cj = http.cookiejar.CookieJar()
    op = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(cj))

    req = urllib.request.Request(PAGE, headers={"User-Agent": UA, "Accept": "text/html"})
    html = op.open(req, timeout=30).read().decode("utf-8", "replace")

    tok = re.search(r'name="__RequestVerificationToken"[^>]*value="([^"]+)"', html)
    tab = re.search(r"sf_tabId`:`(\d+)`", html)
    mod = re.search(r'"ModuleId":(\d+)[^<]*"routingWebAPI":"([^"]+)"', html)
    if not (tok and tab and mod):
        raise RuntimeError("token/TabId/ModuleId non ricavabili dalla pagina GME")

    api = BASE + mod.group(2)
    hdr = {
        "User-Agent": UA,
        "Accept": "application/json, text/plain, */*",
        "Referer": PAGE,
        "ModuleId": mod.group(1),
        "TabId": tab.group(1),
        "RequestVerificationToken": tok.group(1),
        "userid": "-1",
    }

    a = date.today()
    da = a - timedelta(days=giorni)
    url = (f"{api}item/GetMEPrezzi?DataInizio={da:%Y%m%d}&DataFine={a:%Y%m%d}"
           "&Granularita=h&Mercato=MGP&Zona=PUN&Tipologia=PUN")
    dati = json.loads(op.open(urllib.request.Request(url, headers=hdr), timeout=30)
                      .read().decode("utf-8"))

    per_giorno = defaultdict(list)
    for r in dati:
        per_giorno[str(r["df"])].append(float(r["p"]))

    out = {}
    for k, v in per_giorno.items():
        if len(v) >= 23:
            out[f"{k[:4]}-{k[4:6]}-{k[6:8]}"] = round(sum(v) / len(v), 2)
    if not out:
        raise RuntimeError("nessun giorno GME valido")

    g = max(out)
    return g, out[g]


def fallback_pun():
    dati = json.loads(urllib.request.urlopen(FALLBACK, timeout=30).read().decode("utf-8"))
    dati = [r for r in dati if r.get("pun") not in (None, "")]
    if not dati:
        raise RuntimeError("fallback vuoto")
    r = sorted(dati, key=lambda x: x["data"])[-1]
    return r["data"], round(float(r["pun"]), 2)


try:
    giorno, pun = gme_pun()
except Exception:
    try:
        giorno, pun = fallback_pun()
    except Exception:
        sys.exit(1)

print(f"{giorno}\t{pun}")
PYEOF

    PUN_RAW=$(python3 "$TMP_PY_PUN" 2>/dev/null)
    if [[ -n "$PUN_RAW" ]]; then
        PUN_DATA_ISO="${PUN_RAW%%$'\t'*}"
        PUN_MWH="${PUN_RAW##*$'\t'}"
        PUN_DISPONIBILE=true

        PUN_MWH_STR=$(python3 -c "print(f'{float(\"$PUN_MWH\"):.2f}'.replace('.',','))")
        PUN_KWH=$(python3      -c "print(float('$PUN_MWH') / 1000)")
        PUN_KWH_STR=$(python3  -c "v=float('$PUN_MWH')/1000; print(f'{v:.3f}'.replace('.',','))")
        PUN_DATA_STR=$(python3 -c "from datetime import date; print(date.fromisoformat('$PUN_DATA_ISO').strftime('%d/%m/%Y'))")

        echo "  PUN Index GME  : $PUN_MWH_STR €/MWh  ($PUN_KWH_STR €/kWh)  del $PUN_DATA_STR"
    else
        echo "  PUN Index GME  : non disponibile (fetch fallito, sezione omessa)"
    fi
fi

# ------------------------------------------------------------------------------
# PSV gas — giornaliero + media mensile (indicativo) — solo curl + grep
#
# Un solo download della pagina Selectra (dati Snam/GME), da cui si estraggono:
#   - GIORNALIERO : dai meta tag, formato "PSV gas oggi <data>: <valore> €/Smc";
#   - MEDIA MENSILE : dal corpo, "media mensile di <valore> €/Smc a <mese> <anno>"
#     (i tag HTML vengono rimossi con sed per robustezza).
# Dati INDICATIVI: nel messaggio sono dichiarati come tali. Blocco non-bloccante.
# ------------------------------------------------------------------------------
PSV_OGGI_DISPONIBILE=false
PSV_OGGI_STR=""
PSV_OGGI_DATA=""
PSV_DISPONIBILE=false          # media mensile
PSV_SMC_STR=""
PSV_DATA_STR=""

if [[ "$ABILITA_PSV" == "true" ]]; then
    PSV_HTML=$(curl -s --max-time 30 -A "Mozilla/5.0" "$URL_PSV")

    # --- Giornaliero (dai meta tag, HTML grezzo) ---
    PSV_OGGI_LINE=$(printf '%s' "$PSV_HTML" | grep -oiE 'PSV gas oggi[^<"]*/Smc' | head -1)
    PSV_OGGI_STR=$(printf '%s' "$PSV_OGGI_LINE" | grep -oE '[0-9]+,[0-9]+' | head -1)
    PSV_OGGI_DATA=$(printf '%s' "$PSV_OGGI_LINE" | grep -oiE '[0-9]{1,2} [a-zàèéìòù]+ [0-9]{4}' | head -1)
    [[ -n "$PSV_OGGI_STR" ]] && PSV_OGGI_DISPONIBILE=true

    # --- Media mensile (dal corpo, testo senza tag) ---
    PSV_TEXT=$(printf '%s' "$PSV_HTML" | sed 's/<[^>]*>/ /g')
    PSV_SMC_STR=$(printf '%s' "$PSV_TEXT" | grep -oiP 'media mensile di\s+\K[0-9]+,[0-9]+' | head -1)
    PSV_DATA_STR=$(printf '%s' "$PSV_TEXT" | grep -oiP 'media mensile di\s+[0-9]+,[0-9]+\s*€/Smc\s+a\s+\K[a-zàèéìòù]+\s+[0-9]{4}' | head -1)
    [[ -n "$PSV_SMC_STR" ]] && PSV_DISPONIBILE=true

    if [[ "$PSV_OGGI_DISPONIBILE" == "true" || "$PSV_DISPONIBILE" == "true" ]]; then
        echo "  PSV gas (ind.) : oggi ${PSV_OGGI_STR:-?} €/Smc (${PSV_OGGI_DATA:-?})  |  media ${PSV_SMC_STR:-?} €/Smc (${PSV_DATA_STR:-?})"
    else
        echo "  PSV gas (ind.) : non disponibile (estrazione fallita, sezione omessa)"
    fi
fi

echo ""

# ------------------------------------------------------------------------------
# Carica lo storico da lastprice.json
#
# Formato nuovo : { "offerte": { "<durata>": {luce, gas, commLuce, commGas, validTo} }, ... }
# Formato vecchio (solo Fissa 12M, campi luce/gas in radice) viene migrato
# automaticamente come offerta "12".
# ------------------------------------------------------------------------------
declare -A P_LUCE P_GAS P_COMM_LUCE P_COMM_GAS
ULTIMO_AGGIORNATO=""
ULTIMO_PUN_MWH=""
ULTIMO_PUN_DATA=""
ULTIMO_PSV_STR=""
ULTIMO_PSV_DATA=""
ULTIMO_PSV_OGGI_STR=""
ULTIMO_PSV_OGGI_DATA=""

if [[ -f "$LASTPRICE_FILE" ]]; then
    while IFS='|' read -r d l g cl cg; do
        [[ -z "$d" ]] && continue
        [[ -n "$l"  ]] && P_LUCE[$d]="$l"
        [[ -n "$g"  ]] && P_GAS[$d]="$g"
        P_COMM_LUCE[$d]="$cl"
        P_COMM_GAS[$d]="$cg"
    done < <(jq -r '
        (if has("offerte") then .offerte
         elif ((.luce // "") != "") then
            {"12": {luce: .luce, gas: (.gas // ""), commLuce: (.commLuce // ""), commGas: (.commGas // "")}}
         else {} end)
        | to_entries[]
        | [.key, (.value.luce // ""), (.value.gas // ""), (.value.commLuce // ""), (.value.commGas // "")]
        | map(tostring) | join("|")
    ' "$LASTPRICE_FILE" 2>/dev/null)

    ULTIMO_AGGIORNATO=$(jq -r '.aggiornato // ""' "$LASTPRICE_FILE" 2>/dev/null)
    ULTIMO_PUN_MWH=$(jq -r '.pun     // ""' "$LASTPRICE_FILE" 2>/dev/null)
    ULTIMO_PUN_DATA=$(jq -r '.punData // ""' "$LASTPRICE_FILE" 2>/dev/null)
    ULTIMO_PSV_STR=$(jq -r '.psv     // ""' "$LASTPRICE_FILE" 2>/dev/null)
    ULTIMO_PSV_DATA=$(jq -r '.psvData // ""' "$LASTPRICE_FILE" 2>/dev/null)
    ULTIMO_PSV_OGGI_STR=$(jq -r '.psvOggi     // ""' "$LASTPRICE_FILE" 2>/dev/null)
    ULTIMO_PSV_OGGI_DATA=$(jq -r '.psvOggiData // ""' "$LASTPRICE_FILE" 2>/dev/null)
fi

mapfile -t PREV_DURATE < <(printf '%s\n' "${!P_LUCE[@]}" "${!P_GAS[@]}" | grep -v '^$' | sort -nu)

for d in "${PREV_DURATE[@]}"; do
    echo "  Ultimo registrato [$(label_offerta "$d")] → Luce: ${P_LUCE[$d]:-n/d} €/kWh  |  Gas: ${P_GAS[$d]:-n/d} €/Smc"
done

# Offerte nuove (presenti ora, assenti nello storico) e rimosse (viceversa)
NUOVE=()
RIMOSSE=()
for d in "${DURATE[@]}"; do
    [[ -z "${P_LUCE[$d]+x}${P_GAS[$d]+x}" ]] && NUOVE+=("$d")
done
for d in "${PREV_DURATE[@]}"; do
    [[ -z "${O_LUCE[$d]+x}${O_GAS[$d]+x}" ]] && RIMOSSE+=("$d")
done

# Determina se le offerte Octopus sono variate: confronto di una "firma"
# (durate + prezzi materia prima luce/gas). Gli indici di mercato cambiano
# ogni giorno e sono informativi, non fanno da trigger.
SIG_NOW=""
for d in "${DURATE[@]}";      do SIG_NOW+="${d}:${O_LUCE[$d]:-}:${O_GAS[$d]:-};"; done
SIG_PREV=""
for d in "${PREV_DURATE[@]}"; do SIG_PREV+="${d}:${P_LUCE[$d]:-}:${P_GAS[$d]:-};"; done

if [[ "$SIG_NOW" != "$SIG_PREV" ]]; then
    PREZZO_VARIATO=true
else
    PREZZO_VARIATO=false
fi

# Salva lo stato corrente in lastprice.json (indici inclusi se disponibili,
# altrimenti mantiene il valore precedente).
NOW=$(date '+%Y-%m-%dT%H:%M:%S')
if [[ "$PUN_DISPONIBILE" == "true" ]]; then
    SAVE_PUN="$PUN_MWH";       SAVE_PUN_DATA="$PUN_DATA_ISO"
else
    SAVE_PUN="$ULTIMO_PUN_MWH"; SAVE_PUN_DATA="$ULTIMO_PUN_DATA"
fi
if [[ "$PSV_DISPONIBILE" == "true" ]]; then
    SAVE_PSV="$PSV_SMC_STR";   SAVE_PSV_DATA="$PSV_DATA_STR"
else
    SAVE_PSV="$ULTIMO_PSV_STR"; SAVE_PSV_DATA="$ULTIMO_PSV_DATA"
fi
if [[ "$PSV_OGGI_DISPONIBILE" == "true" ]]; then
    SAVE_PSV_OGGI="$PSV_OGGI_STR";   SAVE_PSV_OGGI_DATA="$PSV_OGGI_DATA"
else
    SAVE_PSV_OGGI="$ULTIMO_PSV_OGGI_STR"; SAVE_PSV_OGGI_DATA="$ULTIMO_PSV_OGGI_DATA"
fi

OFFERTE_JSON='{}'
for d in "${DURATE[@]}"; do
    OFFERTE_JSON=$(jq -c \
        --arg d        "$d" \
        --arg luce     "${O_LUCE[$d]:-}" \
        --arg gas      "${O_GAS[$d]:-}" \
        --arg commLuce "${O_COMM_LUCE[$d]:-}" \
        --arg commGas  "${O_COMM_GAS[$d]:-}" \
        --arg validTo  "${O_VALID[$d]:-}" \
        '. + {($d): {luce: $luce, gas: $gas, commLuce: $commLuce, commGas: $commGas, validTo: $validTo}}' \
        <<< "$OFFERTE_JSON")
done

jq -n \
    --argjson offerte "$OFFERTE_JSON" \
    --arg aggiornato  "$NOW" \
    --arg pun         "$SAVE_PUN" \
    --arg punData     "$SAVE_PUN_DATA" \
    --arg psv         "$SAVE_PSV" \
    --arg psvData     "$SAVE_PSV_DATA" \
    --arg psvOggi     "$SAVE_PSV_OGGI" \
    --arg psvOggiData "$SAVE_PSV_OGGI_DATA" \
    '{offerte: $offerte, aggiornato: $aggiornato, pun: $pun, punData: $punData, psv: $psv, psvData: $psvData, psvOggi: $psvOggi, psvOggiData: $psvOggiData}' \
    > "$LASTPRICE_FILE"
echo "  Prezzi salvati in $LASTPRICE_FILE"

# ------------------------------------------------------------------------------
# Decide se inviare la notifica
# ------------------------------------------------------------------------------
DATA_ORA=$(date '+%d/%m/%Y %H:%M')
MOTIVO_INVIO=""
DEVE_INVIARE=false
MOTIVO_NO_INVIO=""

if [[ "$SENDPRICE" == "true" ]]; then
    echo "[DEBUG --sendprice] Invio forzato indipendentemente dalle soglie."
    DEVE_INVIARE=true
    MOTIVO_INVIO="debug --sendprice"

elif [[ "$AGGIORNA_VARIAZIONI" == "true" ]]; then
    # Modalità variazioni: invia SOLO se prezzi/offerte sono cambiati, soglie ignorate
    if [[ "$PREZZO_VARIATO" == "true" ]]; then
        echo "  Variazione rilevata → invio notifica."
        DEVE_INVIARE=true
        MOTIVO_INVIO="variazione prezzi/offerte"
    else
        echo "  Nessuna variazione rispetto all'ultima rilevazione."
        MOTIVO_NO_INVIO="nessuna variazione di prezzo"
    fi

else
    # Modalità soglie: invia se ALMENO UNA offerta fissa rispetta le soglie abilitate
    OFFERTE_OK=""
    for d in "${DURATE[@]}"; do
        lab=$(label_offerta "$d")
        CONDIZIONE_L=true
        CONDIZIONE_G=true

        if [[ "$ABILITA_SOGLIA_LUCE" == "true" ]]; then
            if [[ -z "${O_LUCE[$d]:-}" ]]; then
                CONDIZIONE_L=false
                echo "  [$lab] Soglia luce: NO (prezzo luce non disponibile)"
            else
                CONDIZIONE_L=$(python3 -c "import sys; print('true' if float(sys.argv[1]) <= float(sys.argv[2]) else 'false')" "${O_LUCE[$d]//,/.}" "$SOGLIA_LUCE")
                if [[ "$CONDIZIONE_L" == "true" ]]; then
                    echo "  [$lab] Soglia luce ($SOGLIA_LUCE €/kWh): OK ✔"
                else
                    echo "  [$lab] Soglia luce ($SOGLIA_LUCE €/kWh): NO (attuale ${O_LUCE[$d]} > soglia $SOGLIA_LUCE)"
                fi
            fi
        else
            echo "  [$lab] Soglia luce: DISABILITATA"
        fi

        if [[ "$ABILITA_SOGLIA_GAS" == "true" ]]; then
            if [[ -z "${O_GAS[$d]:-}" ]]; then
                CONDIZIONE_G=false
                echo "  [$lab] Soglia gas: NO (prezzo gas non disponibile)"
            else
                CONDIZIONE_G=$(python3 -c "import sys; print('true' if float(sys.argv[1]) <= float(sys.argv[2]) else 'false')" "${O_GAS[$d]//,/.}" "$SOGLIA_GAS")
                if [[ "$CONDIZIONE_G" == "true" ]]; then
                    echo "  [$lab] Soglia gas  ($SOGLIA_GAS €/Smc): OK ✔"
                else
                    echo "  [$lab] Soglia gas  ($SOGLIA_GAS €/Smc): NO (attuale ${O_GAS[$d]} > soglia $SOGLIA_GAS)"
                fi
            fi
        else
            echo "  [$lab] Soglia gas: DISABILITATA"
        fi

        if [[ "$CONDIZIONE_L" == "true" && "$CONDIZIONE_G" == "true" ]]; then
            OFFERTE_OK+="${OFFERTE_OK:+, }$lab"
        fi
    done

    if [[ -n "$OFFERTE_OK" ]]; then
        DEVE_INVIARE=true
        MOTIVO_INVIO="soglie raggiunte ($OFFERTE_OK)"
    else
        MOTIVO_NO_INVIO="soglie non raggiunte"
    fi
fi

echo ""

# ------------------------------------------------------------------------------
# Componi e invia il messaggio Telegram
# ------------------------------------------------------------------------------
if [[ "$DEVE_INVIARE" == "true" ]]; then

    # Funzione freccia
    freccia() {
        local nuovo="$1" vecchio="$2"
        python3 -c "
n=float('$nuovo'); v=float('$vecchio')
if   n < v: print('📉')
elif n > v: print('📈')
else:        print('👍🏻')
"
    }

    # Funzione riga storico (valori in input con punto decimale)
    riga_storico() {
        local label="$1" nuovo="$2" vecchio="$3" unit="$4"
        local f invariato vecchio_str diff_str
        f=$(freccia "$nuovo" "$vecchio")
        vecchio_str=$(python3 -c "v=float('$vecchio'); s=f'{v:.4f}'.rstrip('0').rstrip('.'); print(s.replace('.',','))")
        diff_str=$(python3 -c "
n=float('$nuovo'); v=float('$vecchio')
d=n-v
if d==0: print('')
else:
    s=f'{abs(d):.4f}'.rstrip('0').rstrip('.').replace('.', ',')
    print(('+' if d>0 else '-')+s+chr(0x20AC))
")
        if python3 -c "import sys; sys.exit(0 if float('$nuovo')==float('$vecchio') else 1)"; then
            invariato=" (invariato)"
        else
            invariato=""
        fi
        if [[ -n "$diff_str" ]]; then
            echo "   $f ${label}: ${vecchio_str} €/${unit} (${diff_str})"
        else
            echo "   $f ${label}: ${vecchio_str} €/${unit}${invariato}"
        fi
    }

    MULTI=false
    [[ ${#DURATE[@]} -gt 1 ]] && MULTI=true

    # Caso "scambio": una sola offerta sparita e una sola comparsa (es. 12M → 24M).
    # In quel caso la nuova viene confrontata con i prezzi della vecchia.
    SWAP_DA=""
    SWAP_A=""
    if [[ ${#NUOVE[@]} -eq 1 && ${#RIMOSSE[@]} -eq 1 ]]; then
        SWAP_DA="${RIMOSSE[0]}"
        SWAP_A="${NUOVE[0]}"
    fi

    # Titolo: elenco offerte fisse presenti (es. "Fissa 24M" o "Fissa 12M / Fissa 24M")
    TITOLO_OFFERTE=""
    for d in "${DURATE[@]}"; do
        TITOLO_OFFERTE+="${TITOLO_OFFERTE:+ / }$(label_offerta "$d")"
    done

    # --- Sezione offerte correnti -------------------------------------------
    SEZIONE_OFFERTE=""
    for d in "${DURATE[@]}"; do
        lab=$(label_offerta "$d")
        vstr=$(fmt_valid_to "${O_VALID[$d]:-}")
        BLOCCO=""
        [[ "$MULTI" == "true" ]] && BLOCCO+="
📌 <b>Octopus ${lab}</b>
"
        if [[ -n "${O_LUCE[$d]:-}" ]]; then
            BLOCCO+="
🔌 <b>Luce monoraria</b>
   Materia prima: <b>${O_LUCE[$d]} €/kWh</b>
   Commercializzazione: ${O_COMM_LUCE[$d]:-?} €/mese
   IVA e imposte escluse, perdite incluse.
"
        fi
        if [[ -n "${O_GAS[$d]:-}" ]]; then
            BLOCCO+="
🔥 <b>Gas</b>
   Materia prima: <b>${O_GAS[$d]} €/Smc</b>
   Commercializzazione: ${O_COMM_GAS[$d]:-?} €/mese
   IVA e imposte escluse.
"
        fi
        [[ -n "$vstr" ]] && BLOCCO+="
🗓 Offerta sottoscrivibile fino al ${vstr}
"
        SEZIONE_OFFERTE+="$BLOCCO"
    done

    # --- Sezione confronto con lo storico (solo se esiste uno storico) -------
    SEZIONE_ANDAMENTO=""
    if [[ ${#PREV_DURATE[@]} -gt 0 ]]; then

        CORPO=""

        # Cambio offerta / offerte non più disponibili
        if [[ -n "$SWAP_DA" ]]; then
            CORPO+="
🔄 Offerta cambiata: <b>$(label_offerta "$SWAP_DA")</b> → <b>$(label_offerta "$SWAP_A")</b>
"
        else
            for d in "${RIMOSSE[@]}"; do
                CORPO+="
❌ <b>$(label_offerta "$d")</b> non più disponibile.
"
            done
        fi

        for d in "${DURATE[@]}"; do
            lab=$(label_offerta "$d")

            # Offerta di riferimento per il confronto
            BASE=""
            if [[ -n "${P_LUCE[$d]+x}${P_GAS[$d]+x}" ]]; then
                BASE="$d"
            elif [[ "$d" == "$SWAP_A" ]]; then
                BASE="$SWAP_DA"
            fi

            if [[ -z "$BASE" ]]; then
                CORPO+="
🆕 <b>${lab}</b>: nuova offerta, nessuno storico.
"
                continue
            fi

            # Intestazione per offerta: necessaria se ci sono più offerte
            # o se il confronto è con un'offerta di durata diversa
            if [[ "$MULTI" == "true" || "$BASE" != "$d" ]]; then
                if [[ "$BASE" != "$d" ]]; then
                    CORPO+="
<b>${lab}</b> rispetto a $(label_offerta "$BASE"):"
                else
                    CORPO+="
<b>${lab}</b>:"
                fi
            fi

            RIGHE_L=""
            if [[ -n "${O_LUCE[$d]:-}" && -n "${P_LUCE[$BASE]:-}" ]]; then
                CL_NOW="${O_COMM_LUCE[$d]:-}"
                CL_OLD="${P_COMM_LUCE[$BASE]:-$CL_NOW}"
                RIGHE_L+="
$(riga_storico "Luce" "${O_LUCE[$d]//,/.}" "${P_LUCE[$BASE]//,/.}" "kWh")"
                if [[ -n "$CL_NOW" && -n "$CL_OLD" ]]; then
                    RIGHE_L+="
$(riga_storico "Commercializzazione Luce" "${CL_NOW//,/.}" "${CL_OLD//,/.}" "mese")"
                fi
            fi

            RIGHE_G=""
            if [[ -n "${O_GAS[$d]:-}" && -n "${P_GAS[$BASE]:-}" ]]; then
                CG_NOW="${O_COMM_GAS[$d]:-}"
                CG_OLD="${P_COMM_GAS[$BASE]:-$CG_NOW}"
                RIGHE_G+="
$(riga_storico "Gas" "${O_GAS[$d]//,/.}" "${P_GAS[$BASE]//,/.}" "Smc")"
                if [[ -n "$CG_NOW" && -n "$CG_OLD" ]]; then
                    RIGHE_G+="
$(riga_storico "Commercializzazione Gas" "${CG_NOW//,/.}" "${CG_OLD//,/.}" "mese")"
                fi
            fi

            CORPO+="${RIGHE_L}"
            [[ -n "$RIGHE_L" && -n "$RIGHE_G" ]] && CORPO+="
"
            CORPO+="${RIGHE_G}
"
        done
        # Rimuove le righe vuote finali del blocco confronto
        CORPO="${CORPO%"${CORPO##*[!$'\n']}"}"


        # Riga PUN nel confronto: solo con valore attuale + storico
        R5=""
        if [[ "$PUN_DISPONIBILE" == "true" && -n "$ULTIMO_PUN_MWH" ]]; then
            ULTIMO_PUN_KWH=$(python3 -c "print(float('$ULTIMO_PUN_MWH') / 1000)")
            R5=$(riga_storico "PUN" "$PUN_KWH" "$ULTIMO_PUN_KWH" "kWh")
        fi

        # Riga PSV giornaliero nel confronto
        R6=""
        if [[ "$PSV_OGGI_DISPONIBILE" == "true" && -n "$ULTIMO_PSV_OGGI_STR" ]]; then
            R6=$(riga_storico "PSV gas (oggi)" "${PSV_OGGI_STR//,/.}" "${ULTIMO_PSV_OGGI_STR//,/.}" "Smc")
        fi

        # Riga PSV media mensile nel confronto
        R7=""
        if [[ "$PSV_DISPONIBILE" == "true" && -n "$ULTIMO_PSV_STR" ]]; then
            R7=$(riga_storico "PSV gas (media mese)" "${PSV_SMC_STR//,/.}" "${ULTIMO_PSV_STR//,/.}" "Smc")
        fi

        # Data ultima run in formato italiano
        ULTIMO_DATA_STR=""
        if [[ -n "$ULTIMO_AGGIORNATO" ]]; then
            ULTIMO_DATA_STR=$(python3 -c "
from datetime import datetime
try: print(' ' + datetime.fromisoformat('$ULTIMO_AGGIORNATO').strftime('%d/%m/%Y'))
except: pass
")
        fi

        SEZIONE_ANDAMENTO="
📊 <b>Confronto tariffe precedenti del${ULTIMO_DATA_STR}:</b>
${CORPO}"
        [[ -n "$R5$R6$R7" ]] && SEZIONE_ANDAMENTO="${SEZIONE_ANDAMENTO}
"
        [[ -n "$R5" ]] && SEZIONE_ANDAMENTO="${SEZIONE_ANDAMENTO}
${R5}"
        [[ -n "$R6" ]] && SEZIONE_ANDAMENTO="${SEZIONE_ANDAMENTO}
${R6}"
        [[ -n "$R7" ]] && SEZIONE_ANDAMENTO="${SEZIONE_ANDAMENTO}
${R7}"
    fi

    # Sezione riferimenti di mercato nel corpo principale — solo se disponibili
    SEZIONE_INDICI=""
    if [[ "$PUN_DISPONIBILE" == "true" ]]; then
        SEZIONE_INDICI="
💶 <b>PUN Index GME</b> (elettricità, mercato all'ingrosso)
   <b>${PUN_MWH_STR} €/MWh</b>  (${PUN_KWH_STR} €/kWh)
   Riferimento del ${PUN_DATA_STR}
"
    fi
    if [[ "$PSV_OGGI_DISPONIBILE" == "true" || "$PSV_DISPONIBILE" == "true" ]]; then
        RIGA_PSV_OGGI=""
        RIGA_PSV_MEDIA=""
        [[ "$PSV_OGGI_DISPONIBILE" == "true" ]] && RIGA_PSV_OGGI="
   Oggi: <b>~${PSV_OGGI_STR} €/Smc</b>  ·  ${PSV_OGGI_DATA}"
        [[ "$PSV_DISPONIBILE" == "true" ]] && RIGA_PSV_MEDIA="
   Media mensile: <b>~${PSV_SMC_STR} €/Smc</b>  ·  ${PSV_DATA_STR}"
        SEZIONE_INDICI="${SEZIONE_INDICI}
💶 <b>PSV gas</b> (mercato all'ingrosso)${RIGA_PSV_OGGI}${RIGA_PSV_MEDIA}
   Dato indicativo (fonte Selectra su dati Snam/GME).
   Per le offerte indicizzate conta la media del mese.
"
    fi

    # --- Avviso rinnovo: prezzo di un'offerta uguale a una soglia abilitata --
    RIGA_RINNOVO=""
    if [[ "$NOTIFICA_RINNOVO" == "true" ]]; then
        for d in "${DURATE[@]}"; do
            LUCE_PARI=false
            GAS_PARI=false
            [[ "$ABILITA_SOGLIA_LUCE" == "true" && -n "${O_LUCE[$d]:-}" ]] \
                && py_eq "${O_LUCE[$d]//,/.}" "$SOGLIA_LUCE" && LUCE_PARI=true
            [[ "$ABILITA_SOGLIA_GAS" == "true" && -n "${O_GAS[$d]:-}" ]] \
                && py_eq "${O_GAS[$d]//,/.}" "$SOGLIA_GAS" && GAS_PARI=true
            SUFFISSO=""
            [[ "$MULTI" == "true" ]] && SUFFISSO=" ($(label_offerta "$d"))"
            if [[ "$LUCE_PARI" == "true" && "$GAS_PARI" == "true" ]]; then
                RIGA_RINNOVO+="⚠️ RINNOVA IL CONTRATTO - TARIFFA UGUALE${SUFFISSO} ⚠️
"
            elif [[ "$LUCE_PARI" == "true" ]]; then
                RIGA_RINNOVO+="⚠️ RINNOVA IL CONTRATTO - ENERGIA ${SOGLIA_LUCE/./,} €/kWh${SUFFISSO} ⚠️
"
            elif [[ "$GAS_PARI" == "true" ]]; then
                RIGA_RINNOVO+="⚠️ RINNOVA IL CONTRATTO - GAS ${SOGLIA_GAS/./,} €/Smc${SUFFISSO} ⚠️
"
            fi
        done
        [[ -n "$RIGA_RINNOVO" ]] && RIGA_RINNOVO+="
"
    fi

    MESSAGGIO="${RIGA_RINNOVO}⚡ <b>Tariffe Octopus ${TITOLO_OFFERTE} (Luce + Gas)</b>
${SEZIONE_OFFERTE}${SEZIONE_INDICI}${SEZIONE_ANDAMENTO}


📅 Aggiornato il ${DATA_ORA}

${REFERRAL}

Attenzione:
Servizio gratuito senza garanzia sulla correttezza del dato.
Prima di sottoscrivere contratti controllare i costi sul sito ufficiale.
"

    echo "Invio notifica Telegram ($MOTIVO_INVIO)..."
    send_telegram "$MESSAGGIO"

else
    echo "Nessuna notifica inviata: $MOTIVO_NO_INVIO."
fi
