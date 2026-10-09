# ==============================================================================
#  OctoCheck.ps1
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
#  Uso normale : .\OctoCheck.ps1
#  Debug       : .\OctoCheck.ps1 --sendprice   (oppure -sendprice)
#
#  Requisiti   : Windows PowerShell 5.1+ o PowerShell 7+
#  Il file va salvato in UTF-8 con BOM (emoji e "€" su PowerShell 5.1).
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

param(
    [switch]$sendprice,
    # Raccoglie "--sendprice" quando lo script è invocato da una console PowerShell
    [Parameter(ValueFromRemainingArguments = $true)] $ArgomentiExtra
)
if ($ArgomentiExtra -contains '--sendprice') { $sendprice = $true }

$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { $PWD.Path }

# ------------------------------------------------------------------------------
# SEGRETI TELEGRAM – letti dal file .env nella cartella dello script
# (copia .env.example in .env e compila i valori). Percorso alternativo:
# variabile d'ambiente OCTOCHECK_ENV_FILE. Le variabili d'ambiente già
# impostate hanno la precedenza sul file .env.
# ------------------------------------------------------------------------------
$EnvFile = if ($env:OCTOCHECK_ENV_FILE) { $env:OCTOCHECK_ENV_FILE } else { Join-Path $ScriptDir ".env" }

# Legge KEY=VALUE dal file .env (righe vuote, commenti #, prefisso "export ",
# valori tra apici). Restituisce solo le chiavi ammesse.
function Read-EnvFile([string]$Path) {
    $ammesse = @('TELEGRAM_BOT_TOKEN', 'TELEGRAM_CHAT_ID')
    $out = @{}
    if (-not (Test-Path -LiteralPath $Path)) { return $out }
    foreach ($riga in [IO.File]::ReadAllLines($Path)) {
        if ($riga -match '^\s*(#|$)') { continue }
        if ($riga -notmatch '^\s*(export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$') { continue }
        $key = $Matches[2]
        $val = $Matches[3]
        if ($val -match '^"(.*)"$' -or $val -match "^'(.*)'$") { $val = $Matches[1] }
        if ($ammesse -contains $key) { $out[$key] = $val }
    }
    return $out
}

$envDaFile = Read-EnvFile $EnvFile
$TelegramBotToken = if ($env:TELEGRAM_BOT_TOKEN) { $env:TELEGRAM_BOT_TOKEN } else { $envDaFile['TELEGRAM_BOT_TOKEN'] }
$TelegramChatId   = if ($env:TELEGRAM_CHAT_ID)   { $env:TELEGRAM_CHAT_ID }   else { $envDaFile['TELEGRAM_CHAT_ID'] }

if (-not $TelegramBotToken -or -not $TelegramChatId) {
    Write-Error "TELEGRAM_BOT_TOKEN e/o TELEGRAM_CHAT_ID mancanti. Crea $EnvFile partendo da .env.example oppure imposta le variabili d'ambiente."
    exit 1
}

# ------------------------------------------------------------------------------
# CONFIGURAZIONE – modifica questi valori prima di usare lo script
# ------------------------------------------------------------------------------

# Soglie di allerta (valgono per ciascuna offerta fissa trovata).
# Punto o virgola come separatore decimale: "0.121" oppure "0,121"
$SogliaLuce = "0.121"        # €/kWh  – invia se luce <= questa soglia
$SogliaGas  = "0.430"        # €/Smc  – invia se gas  <= questa soglia

# Abilita/disabilita le singole soglie
# $true  → la soglia viene controllata
# $false → soglia ignorata (considerata sempre rispettata)
$AbilitaSogliaLuce = $true
$AbilitaSogliaGas  = $true

# Se $true: invia notifica ogni volta che il prezzo (o l'insieme delle offerte
# fisse disponibili) cambia rispetto all'ultima rilevazione registrata in
# lastprice.json. In questa modalità le soglie vengono ignorate.
$AggiornaVariazioni = $true

# Se $true: aggiunge in cima al messaggio un avviso quando il prezzo di
# un'offerta coincide esattamente con una soglia abilitata (utile per i rinnovi).
$NotificaRinnovo = $true

# --- PUN Index GME (elettricità) --------------------------------------------
# Se $true: recupera e mostra nel messaggio il PUN Index GME del giorno.
# Fetch non-bloccante: se fallisce, la sezione viene omessa.
$AbilitaPun = $true

# --- PSV gas (giornaliero + media mensile, indicativo, senza credenziali) ----
# Valore INDICATIVO del PSV (gas all'ingrosso) in €/Smc, estratto dalla pagina
# Selectra (dati Snam/GME). Vengono estratti il valore GIORNALIERO e la MEDIA
# MENSILE in corso. Entrambi indicativi e dichiarati come tali nel messaggio.
# Blocco non-bloccante.
$AbilitaPsv = $true
$UrlPsv     = "https://bolletta-energia.it/gas/psv"

# ------------------------------------------------------------------------------
# FINE CONFIGURAZIONE
# ------------------------------------------------------------------------------

$euro           = [char]0x20AC
$Inv            = [Globalization.CultureInfo]::InvariantCulture
$URL_TARIFFE    = "https://octopusenergy.it/le-nostre-tariffe"
$LASTPRICE_FILE = Join-Path $ScriptDir "lastprice.json"
$REFERRAL       = "🐙 Se ti va, supportami a questo link e ricevi uno sconto`nhttps://muninn.ovh/octobot"
$UA             = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36"

# TLS 1.2 per Windows PowerShell 5.1 su sistemi più vecchi
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}

# ------------------------------------------------------------------------------
# Funzioni di supporto numeriche/formattazione
# ------------------------------------------------------------------------------

# Stringa con virgola o punto → double (cultura invariante). $null se non valida.
function ConvertTo-Num($s) {
    if ($null -eq $s -or "$s" -eq "") { return $null }
    $d = 0.0
    if ([double]::TryParse(("$s" -replace ',', '.'), [Globalization.NumberStyles]::Float, $Inv, [ref]$d)) { return $d }
    return $null
}

# double → stringa con virgola (formato .NET, es. "0.####")
function Format-Num([double]$v, [string]$fmt = "0.####") {
    return $v.ToString($fmt, $Inv).Replace('.', ',')
}

# Etichetta leggibile dell'offerta. Durata "0" = non ricavabile → "Fissa".
function Get-LabelOfferta([string]$d) {
    if ($d -eq "0") { return "Fissa" } else { return "Fissa ${d}M" }
}

# Commercializzazione mensile da quota annua: intero se divisibile, altrimenti 2 decimali.
function Get-CommMese($annuale) {
    $a = ConvertTo-Num $annuale
    if ($null -eq $a) { return "" }
    $m = $a / 12
    if ($m -eq [math]::Floor($m)) { return ([int64]$m).ToString($Inv) }
    return Format-Num $m "0.00"
}

# validTo (stringa ISO o DateTime già convertito da ConvertFrom-Json) → DateTimeOffset
function ConvertTo-Dto($v) {
    if ($null -eq $v -or "$v" -eq "") { return $null }
    if ($v -is [datetime])       { return [DateTimeOffset]$v }
    if ($v -is [DateTimeOffset]) { return $v }
    $dto = [DateTimeOffset]::MinValue
    if ([DateTimeOffset]::TryParse([string]$v, $Inv, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$dto)) { return $dto }
    return $null
}

# DateTimeOffset → stringa ISO UTC stabile (stesso formato del sito / della versione bash)
function Format-Iso($dto) {
    if ($null -eq $dto) { return "" }
    return $dto.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'+00:00'", $Inv)
}

# Data di validità leggibile. validTo è l'istante di scadenza (mezzanotte ora
# italiana): si converte in ora italiana e si sottrae 1 secondo, così coincide
# con "Fino al gg/mm/aaaa" mostrato sul sito.
function Format-ValidTo($dto) {
    if ($null -eq $dto) { return "" }
    $tz = $null
    foreach ($id in @('Europe/Rome', 'W. Europe Standard Time')) {
        try { $tz = [TimeZoneInfo]::FindSystemTimeZoneById($id); break } catch {}
    }
    $locale = if ($tz) { [TimeZoneInfo]::ConvertTime($dto, $tz) } else { $dto.ToLocalTime() }
    return $locale.AddSeconds(-1).ToString("dd/MM/yyyy", $Inv)
}

# ------------------------------------------------------------------------------
# Funzione: invia messaggio Telegram
# ------------------------------------------------------------------------------
function Send-Telegram {
    param([string]$Messaggio)
    $uri  = "https://api.telegram.org/bot$TelegramBotToken/sendMessage"
    $body = @{
        chat_id    = $TelegramChatId
        text       = $Messaggio
        parse_mode = "HTML"
    }
    try {
        $risposta = Invoke-RestMethod -Uri $uri -Method Post -Body $body
        if ($risposta.ok) {
            Write-Host "[OK] Messaggio Telegram inviato con successo." -ForegroundColor Green
        } else {
            Write-Warning "[ERRORE] Telegram ha risposto: $($risposta | ConvertTo-Json -Compress)"
        }
    }
    catch {
        Write-Error "[ERRORE] Impossibile inviare il messaggio Telegram: $_"
    }
}

# ------------------------------------------------------------------------------
# Funzione: freccia direzionale
# ------------------------------------------------------------------------------
function Get-Freccia([double]$nuovo, [double]$vecchio) {
    if     ($nuovo -lt $vecchio) { return "📉" }
    elseif ($nuovo -gt $vecchio) { return "📈" }
    else                         { return "👍🏻" }
}

# ------------------------------------------------------------------------------
# Funzione: riga storico con prezzo precedente e differenza
# ------------------------------------------------------------------------------
function Format-RigaStorico([string]$label, [double]$nuovo, [double]$vecchio, [string]$unit) {
    $f          = Get-Freccia $nuovo $vecchio
    $vecchioStr = Format-Num $vecchio
    $diff       = $nuovo - $vecchio
    if ($diff -eq 0) {
        return "   $f ${label}: $vecchioStr $euro/$unit (invariato)"
    }
    $segno   = if ($diff -gt 0) { "+" } else { "-" }
    $diffStr = Format-Num ([math]::Abs($diff))
    return "   $f ${label}: $vecchioStr $euro/$unit (${segno}${diffStr}$euro)"
}

# Normalizza le soglie: accetta sia virgola che punto come separatore decimale
$SogliaLuceNum = ConvertTo-Num $SogliaLuce
$SogliaGasNum  = ConvertTo-Num $SogliaGas
$SogliaLuceStr = Format-Num $SogliaLuceNum "0.000"
$SogliaGasStr  = Format-Num $SogliaGasNum  "0.000"

# ------------------------------------------------------------------------------
# Scarica la pagina
# ------------------------------------------------------------------------------
Write-Host "Scaricamento della pagina tariffe..." -ForegroundColor Cyan

try {
    $risposta = Invoke-WebRequest -Uri $URL_TARIFFE -UseBasicParsing -TimeoutSec 30
}
catch {
    Write-Error "Impossibile raggiungere $URL_TARIFFE : $_"
    exit 1
}

$html = $risposta.Content

# ------------------------------------------------------------------------------
# Estrai il blocco JSON da <script id="__NEXT_DATA__">
# Usa brace-counting per gestire JSON troncati
# ------------------------------------------------------------------------------
$idx = $html.IndexOf('type="application/json">')
if ($idx -lt 0) {
    Write-Error "Impossibile trovare il blocco __NEXT_DATA__ nella pagina."
    exit 1
}

$jsonStart = $html.IndexOf('>', $idx) + 1
$depth     = 0
$inString  = $false
$escape    = $false
$endPos    = -1

for ($i = $jsonStart; $i -lt $html.Length; $i++) {
    $c = $html[$i]
    if ($escape)                   { $escape = $false; continue }
    if ($c -eq '\' -and $inString) { $escape = $true; continue }
    if ($c -eq '"')                { $inString = -not $inString; continue }
    if (-not $inString) {
        if ($c -eq '{')      { $depth++ }
        elseif ($c -eq '}') {
            $depth--
            if ($depth -eq 0) { $endPos = $i + 1; break }
        }
    }
}

if ($endPos -gt 0) {
    $jsonRaw = $html.Substring($jsonStart, $endPos - $jsonStart)
} else {
    # Fallback: prende fino a </script> e tenta riparazione troncamento
    $endScript = $html.IndexOf('</script>', $jsonStart)
    $jsonRaw   = $html.Substring($jsonStart, $endScript - $jsonStart).Trim()
    $jsonRaw   = $jsonRaw -replace '"__N_SSG"\s*$', '"__N_SSG":true}}'
}

try {
    $datiPagina = $jsonRaw | ConvertFrom-Json -ErrorAction Stop
}
catch {
    Write-Error "Impossibile decodificare il JSON della pagina: $_"
    exit 1
}

# ------------------------------------------------------------------------------
# Cerca TUTTE le offerte a prezzo fisso (luce e gas) nel JSON
# ------------------------------------------------------------------------------
$prodotti = $datiPagina.props.pageProps.products
if (-not $prodotti) { Write-Error "Nessun prodotto trovato nel JSON."; exit 1 }

# Params può essere oggetto o array
function Get-Params($p) { if ($p.params -is [System.Array]) { return $p.params[0] } return $p.params }

# Hashtable indicizzate per durata (mesi, stringa)
$O_Luce = @{}; $O_Gas = @{}; $O_AnnLuce = @{}; $O_AnnGas = @{}; $O_Valid = @{}

foreach ($p in $prodotti) {
    $tipo = [string]$p.__typename
    if ($tipo -ne "ElectricityProductType" -and $tipo -ne "GasProductType") { continue }

    $par = Get-Params $p
    $pt  = [string]$par.productType
    $nome = [string]$p.displayName
    if ($pt) {
        if (-not $pt.StartsWith("FIXED")) { continue }
    } elseif ($nome -notmatch 'Fissa') {
        continue
    }

    $dur = "0"
    if     ($nome -match '(\d+)\s*M\b')                 { $dur = $Matches[1] }
    elseif ([string]$p.code -match 'OCTOFIXG?(\d+)')   { $dur = $Matches[1] }

    $cons = [string]$par.consumptionCharge
    if (-not $cons) { continue }

    # Se più prodotti con stessa durata, tiene il primo
    if ($tipo -eq "ElectricityProductType") {
        if (-not $O_Luce.ContainsKey($dur)) { $O_Luce[$dur] = $cons; $O_AnnLuce[$dur] = [string]$par.annualStandingCharge }
    } else {
        if (-not $O_Gas.ContainsKey($dur))  { $O_Gas[$dur]  = $cons; $O_AnnGas[$dur]  = [string]$par.annualStandingCharge }
    }

    # Validità: tiene la scadenza più vicina tra luce e gas della stessa durata
    $dto = ConvertTo-Dto $p.validTo
    if ($dto -and (-not $O_Valid.ContainsKey($dur) -or $dto -lt $O_Valid[$dur])) { $O_Valid[$dur] = $dto }
}

# Elenco durate disponibili, ordinate numericamente (es. 12, 24)
$Durate = @(@($O_Luce.Keys) + @($O_Gas.Keys) | Select-Object -Unique | Sort-Object { [int]$_ })

if ($Durate.Count -eq 0) {
    Write-Error "Nessuna offerta Octopus a prezzo fisso (luce o gas) trovata nella pagina."
    exit 1
}

$O_CommLuce = @{}; $O_CommGas = @{}
foreach ($d in $Durate) {
    if ($O_AnnLuce.ContainsKey($d)) { $O_CommLuce[$d] = Get-CommMese $O_AnnLuce[$d] }
    if ($O_AnnGas.ContainsKey($d))  { $O_CommGas[$d]  = Get-CommMese $O_AnnGas[$d] }
}

function Get-Val($tab, $key, $default = "") { if ($tab.ContainsKey($key) -and "$($tab[$key])" -ne "") { return $tab[$key] } return $default }

Write-Host ""
Write-Host "--- Offerte fisse rilevate ---" -ForegroundColor Yellow
foreach ($d in $Durate) {
    $lab  = Get-LabelOfferta $d
    $vstr = Format-ValidTo $O_Valid[$d]
    $suff = if ($vstr) { "  valida fino al $vstr" } else { "" }
    Write-Host "  [$lab]$suff"
    Write-Host "    Luce monoraria : $(Get-Val $O_Luce $d 'n/d') $euro/kWh  (comm. $(Get-Val $O_CommLuce $d '?') $euro/mese)"
    Write-Host "    Gas            : $(Get-Val $O_Gas $d 'n/d') $euro/Smc  (comm. $(Get-Val $O_CommGas $d '?') $euro/mese)"
}
Write-Host ""

# ------------------------------------------------------------------------------
# PUN Index GME del giorno (elettricità)
#
# Fonte primaria : API pubblica non documentata del sito GME (pagina PUN Index).
# Fonte fallback : JSON pubblico del progetto pun-tracker (terza parte).
# Blocco non-bloccante.
# ------------------------------------------------------------------------------
function Get-PunGme([int]$giorni = 7) {
    $base = "https://gme.mercatoelettrico.org"
    $page = "$base/en-us/Home/Results/Electricity/MGP/Results/PUN/ResultsMGP"

    $r = Invoke-WebRequest -Uri $page -UseBasicParsing -UserAgent $UA -SessionVariable sess -TimeoutSec 30
    $h = $r.Content

    $tok = [regex]::Match($h, 'name="__RequestVerificationToken"[^>]*value="([^"]+)"')
    $tab = [regex]::Match($h, 'sf_tabId`:`(\d+)`')
    $mod = [regex]::Match($h, '"ModuleId":(\d+)[^<]*"routingWebAPI":"([^"]+)"')
    if (-not ($tok.Success -and $tab.Success -and $mod.Success)) { throw "token/TabId/ModuleId non ricavabili dalla pagina GME" }

    $api = $base + $mod.Groups[2].Value
    $hdr = @{
        "Referer"                  = $page
        "ModuleId"                 = $mod.Groups[1].Value
        "TabId"                    = $tab.Groups[1].Value
        "RequestVerificationToken" = $tok.Groups[1].Value
        "userid"                   = "-1"
    }

    $a   = Get-Date
    $da  = $a.AddDays(-$giorni)
    $url = "${api}item/GetMEPrezzi?DataInizio=$($da.ToString('yyyyMMdd'))&DataFine=$($a.ToString('yyyyMMdd'))&Granularita=h&Mercato=MGP&Zona=PUN&Tipologia=PUN"
    $dati = Invoke-RestMethod -Uri $url -WebSession $sess -UserAgent $UA -Headers $hdr -TimeoutSec 30

    # Media giornaliera dei prezzi orari, solo giorni completi (>= 23 ore)
    $out = @{}
    foreach ($g in ($dati | Group-Object { [string]$_.df })) {
        if ($g.Count -ge 23) {
            $k   = $g.Name
            $avg = ($g.Group | ForEach-Object { [double]$_.p } | Measure-Object -Average).Average
            $out["$($k.Substring(0,4))-$($k.Substring(4,2))-$($k.Substring(6,2))"] = [math]::Round($avg, 2)
        }
    }
    if ($out.Count -eq 0) { throw "nessun giorno GME valido" }
    $ultimo = $out.Keys | Sort-Object | Select-Object -Last 1
    return @($ultimo, [double]$out[$ultimo])
}

function Get-PunFallback {
    $dati = Invoke-RestMethod -Uri "https://raw.githubusercontent.com/claudiopecere/pun-tracker/main/data/pun.json" -TimeoutSec 30
    $dati = @($dati | Where-Object { $null -ne $_.pun -and "$($_.pun)" -ne "" })
    if ($dati.Count -eq 0) { throw "fallback vuoto" }
    $r = $dati | Sort-Object { [string]$_.data } | Select-Object -Last 1
    return @([string]$r.data, [math]::Round([double]$r.pun, 2))
}

$PunDisponibile = $false
$PunMwh = $null; $PunKwh = $null; $PunDataIso = ""
$PunMwhStr = ""; $PunKwhStr = ""; $PunDataStr = ""

if ($AbilitaPun) {
    $pun = $null
    try { $pun = Get-PunGme } catch {
        try { $pun = Get-PunFallback } catch { $pun = $null }
    }
    if ($pun) {
        $PunDataIso = [string]$pun[0]
        $PunMwh     = [double]$pun[1]
        $PunKwh     = $PunMwh / 1000
        $PunMwhStr  = Format-Num $PunMwh "0.00"
        $PunKwhStr  = Format-Num $PunKwh "0.000"
        try { $PunDataStr = [datetime]::ParseExact($PunDataIso.Substring(0, 10), "yyyy-MM-dd", $Inv).ToString("dd/MM/yyyy", $Inv) } catch { $PunDataStr = $PunDataIso }
        $PunDisponibile = $true
        Write-Host "  PUN Index GME  : $PunMwhStr $euro/MWh  ($PunKwhStr $euro/kWh)  del $PunDataStr"
    } else {
        Write-Host "  PUN Index GME  : non disponibile (fetch fallito, sezione omessa)"
    }
}

# ------------------------------------------------------------------------------
# PSV gas — giornaliero + media mensile (indicativo)
#
# Un solo download della pagina Selectra (dati Snam/GME), da cui si estraggono:
#   - GIORNALIERO : dai meta tag, formato "PSV gas oggi <data>: <valore> €/Smc";
#   - MEDIA MENSILE : dal corpo, "media mensile di <valore> €/Smc a <mese> <anno>"
#     (i tag HTML vengono rimossi per robustezza).
# Il simbolo "€" è reso tollerante ([^\s/]{0,3}) per eventuali problemi di
# decodifica della pagina su Windows PowerShell 5.1.
# Dati INDICATIVI: nel messaggio sono dichiarati come tali. Blocco non-bloccante.
# ------------------------------------------------------------------------------
$PsvOggiDisponibile = $false; $PsvOggiStr = ""; $PsvOggiData = ""
$PsvDisponibile     = $false; $PsvSmcStr  = ""; $PsvDataStr  = ""   # media mensile

if ($AbilitaPsv) {
    $psvHtml = ""
    try { $psvHtml = (Invoke-WebRequest -Uri $UrlPsv -UseBasicParsing -UserAgent "Mozilla/5.0" -TimeoutSec 30).Content } catch {}

    if ($psvHtml) {
        # Giornaliero (dai meta tag, HTML grezzo)
        $m = [regex]::Match($psvHtml, '(?i)PSV gas oggi[^<"]*/Smc')
        if ($m.Success) {
            $v = [regex]::Match($m.Value, '\d+,\d+')
            $g = [regex]::Match($m.Value, '(?i)\d{1,2} [a-zàèéìòù]+ \d{4}')
            if ($v.Success) { $PsvOggiStr = $v.Value; $PsvOggiDisponibile = $true }
            if ($g.Success) { $PsvOggiData = $g.Value }
        }

        # Media mensile (dal corpo, testo senza tag)
        $testo = $psvHtml -replace '<[^>]*>', ' '
        $m = [regex]::Match($testo, '(?i)media mensile di\s+(\d+,\d+)\s*[^\s/]{0,3}/Smc\s+a\s+([a-zàèéìòù]+\s+\d{4})')
        if ($m.Success) {
            $PsvSmcStr = $m.Groups[1].Value; $PsvDataStr = $m.Groups[2].Value; $PsvDisponibile = $true
        } else {
            $m = [regex]::Match($testo, '(?i)media mensile di\s+(\d+,\d+)')
            if ($m.Success) { $PsvSmcStr = $m.Groups[1].Value; $PsvDisponibile = $true }
        }
    }

    if ($PsvOggiDisponibile -or $PsvDisponibile) {
        $o1 = if ($PsvOggiStr)  { $PsvOggiStr }  else { "?" }
        $o2 = if ($PsvOggiData) { $PsvOggiData } else { "?" }
        $m1 = if ($PsvSmcStr)   { $PsvSmcStr }   else { "?" }
        $m2 = if ($PsvDataStr)  { $PsvDataStr }  else { "?" }
        Write-Host "  PSV gas (ind.) : oggi $o1 $euro/Smc ($o2)  |  media $m1 $euro/Smc ($m2)"
    } else {
        Write-Host "  PSV gas (ind.) : non disponibile (estrazione fallita, sezione omessa)"
    }
}

Write-Host ""

# ------------------------------------------------------------------------------
# Carica lo storico da lastprice.json
#
# Formato nuovo : { "offerte": { "<durata>": {luce, gas, commLuce, commGas, validTo} }, ... }
# Formato vecchio (solo Fissa 12M, campi luce/gas in radice) viene migrato
# automaticamente come offerta "12". Formato identico alla versione bash.
# ------------------------------------------------------------------------------
$P_Luce = @{}; $P_Gas = @{}; $P_CommLuce = @{}; $P_CommGas = @{}
$ultimoAggiornato = $null
$ultimoPunMwh = ""; $ultimoPunData = ""
$ultimoPsvStr = ""; $ultimoPsvData = ""
$ultimoPsvOggiStr = ""; $ultimoPsvOggiData = ""

if (Test-Path -LiteralPath $LASTPRICE_FILE) {
    try {
        $u = [IO.File]::ReadAllText($LASTPRICE_FILE) | ConvertFrom-Json -ErrorAction Stop

        $voci = @()
        if ($u.PSObject.Properties.Name -contains 'offerte') {
            if ($u.offerte) { $voci = @($u.offerte.PSObject.Properties | ForEach-Object { @{ d = $_.Name; v = $_.Value } }) }
        } elseif ("$($u.luce)" -ne "") {
            $voci = @(@{ d = "12"; v = $u })
        }
        foreach ($x in $voci) {
            if ("$($x.v.luce)" -ne "") { $P_Luce[$x.d] = [string]$x.v.luce }
            if ("$($x.v.gas)"  -ne "") { $P_Gas[$x.d]  = [string]$x.v.gas }
            $P_CommLuce[$x.d] = [string]$x.v.commLuce
            $P_CommGas[$x.d]  = [string]$x.v.commGas
        }

        $ultimoAggiornato  = $u.aggiornato
        $ultimoPunMwh      = [string]$u.pun
        $ultimoPunData     = [string]$u.punData
        $ultimoPsvStr      = [string]$u.psv
        $ultimoPsvData     = [string]$u.psvData
        $ultimoPsvOggiStr  = [string]$u.psvOggi
        $ultimoPsvOggiData = [string]$u.psvOggiData
    }
    catch {
        Write-Warning "Impossibile leggere $LASTPRICE_FILE, verrà ricreato."
    }
}

$PrevDurate = @(@($P_Luce.Keys) + @($P_Gas.Keys) | Select-Object -Unique | Sort-Object { [int]$_ })

foreach ($d in $PrevDurate) {
    Write-Host "  Ultimo registrato [$(Get-LabelOfferta $d)] → Luce: $(Get-Val $P_Luce $d 'n/d') $euro/kWh  |  Gas: $(Get-Val $P_Gas $d 'n/d') $euro/Smc"
}

# Offerte nuove (presenti ora, assenti nello storico) e rimosse (viceversa)
$Nuove   = @($Durate     | Where-Object { -not $P_Luce.ContainsKey($_) -and -not $P_Gas.ContainsKey($_) })
$Rimosse = @($PrevDurate | Where-Object { -not $O_Luce.ContainsKey($_) -and -not $O_Gas.ContainsKey($_) })

# Variazione: confronto di una "firma" (durate + prezzi materia prima luce/gas).
# Gli indici di mercato sono informativi, non fanno da trigger.
$sigNow  = ($Durate     | ForEach-Object { "${_}:$(Get-Val $O_Luce $_):$(Get-Val $O_Gas $_);" }) -join ""
$sigPrev = ($PrevDurate | ForEach-Object { "${_}:$(Get-Val $P_Luce $_):$(Get-Val $P_Gas $_);" }) -join ""
$prezzoVariato = ($sigNow -ne $sigPrev)

# Salva lo stato corrente in lastprice.json (indici inclusi se disponibili,
# altrimenti mantiene il valore precedente).
$offerteSave = [ordered]@{}
foreach ($d in $Durate) {
    $offerteSave[$d] = [ordered]@{
        luce     = Get-Val $O_Luce $d
        gas      = Get-Val $O_Gas $d
        commLuce = Get-Val $O_CommLuce $d
        commGas  = Get-Val $O_CommGas $d
        validTo  = Format-Iso $O_Valid[$d]
    }
}
$stato = [ordered]@{
    offerte     = $offerteSave
    aggiornato  = (Get-Date).ToString("yyyy-MM-dd'T'HH:mm:ss", $Inv)
    pun         = if ($PunDisponibile)     { $PunMwh.ToString($Inv) } else { $ultimoPunMwh }
    punData     = if ($PunDisponibile)     { $PunDataIso }            else { $ultimoPunData }
    psv         = if ($PsvDisponibile)     { $PsvSmcStr }             else { $ultimoPsvStr }
    psvData     = if ($PsvDisponibile)     { $PsvDataStr }            else { $ultimoPsvData }
    psvOggi     = if ($PsvOggiDisponibile) { $PsvOggiStr }            else { $ultimoPsvOggiStr }
    psvOggiData = if ($PsvOggiDisponibile) { $PsvOggiData }           else { $ultimoPsvOggiData }
}
# UTF-8 senza BOM, leggibile anche da jq/versione bash
[IO.File]::WriteAllText($LASTPRICE_FILE, ($stato | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding($false)))
Write-Host "  Prezzi salvati in $LASTPRICE_FILE"

# ------------------------------------------------------------------------------
# Decide se inviare la notifica
# ------------------------------------------------------------------------------
$dataOra       = (Get-Date).ToString("dd/MM/yyyy HH:mm", $Inv)
$motivoInvio   = $null
$motivoNoInvio = $null
$deveInviare   = $false

if ($sendprice) {
    Write-Host "[DEBUG --sendprice] Invio forzato indipendentemente dalle soglie." -ForegroundColor Magenta
    $deveInviare = $true
    $motivoInvio = "debug --sendprice"
}
elseif ($AggiornaVariazioni) {
    # Modalità variazioni: invia SOLO se prezzi/offerte sono cambiati, soglie ignorate
    if ($prezzoVariato) {
        Write-Host "  Variazione rilevata → invio notifica." -ForegroundColor Cyan
        $deveInviare = $true
        $motivoInvio = "variazione prezzi/offerte"
    } else {
        Write-Host "  Nessuna variazione rispetto all'ultima rilevazione." -ForegroundColor DarkYellow
        $motivoNoInvio = "nessuna variazione di prezzo"
    }
}
else {
    # Modalità soglie: invia se ALMENO UNA offerta fissa rispetta le soglie abilitate
    $offerteOk = @()
    foreach ($d in $Durate) {
        $lab = Get-LabelOfferta $d
        $condL = $true
        $condG = $true

        if ($AbilitaSogliaLuce) {
            $v = ConvertTo-Num (Get-Val $O_Luce $d)
            if ($null -eq $v) {
                $condL = $false
                Write-Host "  [$lab] Soglia luce: NO (prezzo luce non disponibile)"
            } else {
                $condL = ($v -le $SogliaLuceNum)
                $esito = if ($condL) { "OK ✔" } else { "NO (attuale $($O_Luce[$d]) > soglia $SogliaLuceStr)" }
                Write-Host "  [$lab] Soglia luce ($SogliaLuceStr $euro/kWh): $esito"
            }
        } else {
            Write-Host "  [$lab] Soglia luce: DISABILITATA"
        }

        if ($AbilitaSogliaGas) {
            $v = ConvertTo-Num (Get-Val $O_Gas $d)
            if ($null -eq $v) {
                $condG = $false
                Write-Host "  [$lab] Soglia gas: NO (prezzo gas non disponibile)"
            } else {
                $condG = ($v -le $SogliaGasNum)
                $esito = if ($condG) { "OK ✔" } else { "NO (attuale $($O_Gas[$d]) > soglia $SogliaGasStr)" }
                Write-Host "  [$lab] Soglia gas  ($SogliaGasStr $euro/Smc): $esito"
            }
        } else {
            Write-Host "  [$lab] Soglia gas: DISABILITATA"
        }

        if ($condL -and $condG) { $offerteOk += $lab }
    }

    if ($offerteOk.Count -gt 0) {
        $deveInviare = $true
        $motivoInvio = "soglie raggiunte ($($offerteOk -join ', '))"
    } else {
        $motivoNoInvio = "soglie non raggiunte"
    }
}

Write-Host ""

# ------------------------------------------------------------------------------
# Componi e invia il messaggio Telegram
# ------------------------------------------------------------------------------
if ($deveInviare) {

    $multi = ($Durate.Count -gt 1)

    # Caso "scambio": una sola offerta sparita e una sola comparsa (es. 12M → 24M).
    # In quel caso la nuova viene confrontata con i prezzi della vecchia.
    $swapDa = $null; $swapA = $null
    if ($Nuove.Count -eq 1 -and $Rimosse.Count -eq 1) { $swapDa = $Rimosse[0]; $swapA = $Nuove[0] }

    # Titolo: elenco offerte fisse presenti (es. "Fissa 24M" o "Fissa 12M / Fissa 24M")
    $titoloOfferte = ($Durate | ForEach-Object { Get-LabelOfferta $_ }) -join " / "

    # --- Sezione offerte correnti -------------------------------------------
    $sezioneOfferte = ""
    foreach ($d in $Durate) {
        $lab  = Get-LabelOfferta $d
        $vstr = Format-ValidTo $O_Valid[$d]
        $blocco = ""
        if ($multi) { $blocco += "`n📌 <b>Octopus $lab</b>`n" }
        if ($O_Luce.ContainsKey($d)) {
            $blocco += "`n🔌 <b>Luce monoraria</b>`n   Materia prima: <b>$($O_Luce[$d]) $euro/kWh</b>`n   Commercializzazione: $(Get-Val $O_CommLuce $d '?') $euro/mese`n   IVA e imposte escluse, perdite incluse.`n"
        }
        if ($O_Gas.ContainsKey($d)) {
            $blocco += "`n🔥 <b>Gas</b>`n   Materia prima: <b>$($O_Gas[$d]) $euro/Smc</b>`n   Commercializzazione: $(Get-Val $O_CommGas $d '?') $euro/mese`n   IVA e imposte escluse.`n"
        }
        if ($vstr) { $blocco += "`n🗓 Offerta sottoscrivibile fino al $vstr`n" }
        $sezioneOfferte += $blocco
    }

    # --- Sezione confronto con lo storico (solo se esiste uno storico) -------
    $sezioneAndamento = ""
    if ($PrevDurate.Count -gt 0) {

        $corpo = ""

        # Cambio offerta / offerte non più disponibili
        if ($swapDa) {
            $corpo += "`n🔄 Offerta cambiata: <b>$(Get-LabelOfferta $swapDa)</b> → <b>$(Get-LabelOfferta $swapA)</b>`n"
        } else {
            foreach ($d in $Rimosse) { $corpo += "`n❌ <b>$(Get-LabelOfferta $d)</b> non più disponibile.`n" }
        }

        foreach ($d in $Durate) {
            $lab = Get-LabelOfferta $d

            # Offerta di riferimento per il confronto
            $baseD = $null
            if ($P_Luce.ContainsKey($d) -or $P_Gas.ContainsKey($d)) { $baseD = $d }
            elseif ($d -eq $swapA) { $baseD = $swapDa }

            if (-not $baseD) {
                $corpo += "`n🆕 <b>$lab</b>: nuova offerta, nessuno storico.`n"
                continue
            }

            # Intestazione per offerta: con più offerte o con confronto su durata diversa
            if ($baseD -ne $d) {
                $corpo += "`n<b>$lab</b> rispetto a $(Get-LabelOfferta $baseD):"
            } elseif ($multi) {
                $corpo += "`n<b>$lab</b>:"
            }

            $righeL = ""
            $nL = ConvertTo-Num (Get-Val $O_Luce $d); $vL = ConvertTo-Num (Get-Val $P_Luce $baseD)
            if ($null -ne $nL -and $null -ne $vL) {
                $righeL += "`n" + (Format-RigaStorico "Luce" $nL $vL "kWh")
                $cNow = ConvertTo-Num (Get-Val $O_CommLuce $d)
                $cOld = ConvertTo-Num (Get-Val $P_CommLuce $baseD (Get-Val $O_CommLuce $d))
                if ($null -ne $cNow -and $null -ne $cOld) { $righeL += "`n" + (Format-RigaStorico "Commercializzazione Luce" $cNow $cOld "mese") }
            }

            $righeG = ""
            $nG = ConvertTo-Num (Get-Val $O_Gas $d); $vG = ConvertTo-Num (Get-Val $P_Gas $baseD)
            if ($null -ne $nG -and $null -ne $vG) {
                $righeG += "`n" + (Format-RigaStorico "Gas" $nG $vG "Smc")
                $cNow = ConvertTo-Num (Get-Val $O_CommGas $d)
                $cOld = ConvertTo-Num (Get-Val $P_CommGas $baseD (Get-Val $O_CommGas $d))
                if ($null -ne $cNow -and $null -ne $cOld) { $righeG += "`n" + (Format-RigaStorico "Commercializzazione Gas" $cNow $cOld "mese") }
            }

            $corpo += $righeL
            if ($righeL -and $righeG) { $corpo += "`n" }
            $corpo += $righeG + "`n"
        }
        $corpo = $corpo.TrimEnd("`n")

        # Righe indici di mercato: solo con valore attuale + storico
        $righeMercato = @()
        $vPun = ConvertTo-Num $ultimoPunMwh
        if ($PunDisponibile -and $null -ne $vPun) { $righeMercato += Format-RigaStorico "PUN" $PunKwh ($vPun / 1000) "kWh" }
        $nP = ConvertTo-Num $PsvOggiStr; $vP = ConvertTo-Num $ultimoPsvOggiStr
        if ($PsvOggiDisponibile -and $null -ne $nP -and $null -ne $vP) { $righeMercato += Format-RigaStorico "PSV gas (oggi)" $nP $vP "Smc" }
        $nP = ConvertTo-Num $PsvSmcStr; $vP = ConvertTo-Num $ultimoPsvStr
        if ($PsvDisponibile -and $null -ne $nP -and $null -ne $vP) { $righeMercato += Format-RigaStorico "PSV gas (media mese)" $nP $vP "Smc" }

        # Data ultima run in formato italiano
        $ultimoDataStr = ""
        if ($ultimoAggiornato) {
            if ($ultimoAggiornato -is [datetime]) { $ultimoDataStr = " " + $ultimoAggiornato.ToString("dd/MM/yyyy", $Inv) }
            else { try { $ultimoDataStr = " " + [datetime]::Parse([string]$ultimoAggiornato, $Inv).ToString("dd/MM/yyyy", $Inv) } catch {} }
        }

        $sezioneAndamento = "`n📊 <b>Confronto tariffe precedenti del${ultimoDataStr}:</b>`n$corpo"
        if ($righeMercato.Count -gt 0) { $sezioneAndamento += "`n`n" + ($righeMercato -join "`n") }
    }

    # --- Sezione riferimenti di mercato — solo se disponibili ----------------
    $sezioneIndici = ""
    if ($PunDisponibile) {
        $sezioneIndici += "`n💶 <b>PUN Index GME</b> (elettricità, mercato all'ingrosso)`n   <b>$PunMwhStr $euro/MWh</b>  ($PunKwhStr $euro/kWh)`n   Riferimento del $PunDataStr`n"
    }
    if ($PsvOggiDisponibile -or $PsvDisponibile) {
        $rigaOggi  = if ($PsvOggiDisponibile) { "`n   Oggi: <b>~$PsvOggiStr $euro/Smc</b>  ·  $PsvOggiData" } else { "" }
        $rigaMedia = if ($PsvDisponibile)     { "`n   Media mensile: <b>~$PsvSmcStr $euro/Smc</b>  ·  $PsvDataStr" } else { "" }
        $sezioneIndici += "`n💶 <b>PSV gas</b> (mercato all'ingrosso)$rigaOggi$rigaMedia`n   Dato indicativo (fonte Selectra su dati Snam/GME).`n   Per le offerte indicizzate conta la media del mese.`n"
    }

    # --- Avviso rinnovo: prezzo di un'offerta uguale a una soglia abilitata --
    $rigaRinnovo = ""
    if ($NotificaRinnovo) {
        foreach ($d in $Durate) {
            $vL = ConvertTo-Num (Get-Val $O_Luce $d)
            $vG = ConvertTo-Num (Get-Val $O_Gas $d)
            $lucePari = ($AbilitaSogliaLuce -and $null -ne $vL -and $vL -eq $SogliaLuceNum)
            $gasPari  = ($AbilitaSogliaGas  -and $null -ne $vG -and $vG -eq $SogliaGasNum)
            $suff = if ($multi) { " ($(Get-LabelOfferta $d))" } else { "" }
            if     ($lucePari -and $gasPari) { $rigaRinnovo += "⚠️ RINNOVA IL CONTRATTO - TARIFFA UGUALE$suff ⚠️`n" }
            elseif ($lucePari)               { $rigaRinnovo += "⚠️ RINNOVA IL CONTRATTO - ENERGIA $SogliaLuceStr $euro/kWh$suff ⚠️`n" }
            elseif ($gasPari)                { $rigaRinnovo += "⚠️ RINNOVA IL CONTRATTO - GAS $SogliaGasStr $euro/Smc$suff ⚠️`n" }
        }
        if ($rigaRinnovo) { $rigaRinnovo += "`n" }
    }

    $messaggio = "${rigaRinnovo}⚡ <b>Tariffe Octopus $titoloOfferte (Luce + Gas)</b>`n" +
                 $sezioneOfferte + $sezioneIndici + $sezioneAndamento +
                 "`n`n`n📅 Aggiornato il $dataOra`n`n$REFERRAL`n`n" +
                 "Attenzione:`nServizio gratuito senza garanzia sulla correttezza del dato.`n" +
                 "Prima di sottoscrivere contratti controllare i costi sul sito ufficiale.`n"

    Write-Host "Invio notifica Telegram ($motivoInvio)..." -ForegroundColor Cyan
    Send-Telegram -Messaggio $messaggio

} else {
    Write-Host "Nessuna notifica inviata: $motivoNoInvio." -ForegroundColor DarkYellow
}
