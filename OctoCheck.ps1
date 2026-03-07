# ==============================================================================
#  OctoBot.ps1
#
#  Monitora le tariffe Octopus Fissa 12M (scheda Luce + Gas) e invia notifica
#  https://github.com/Leproide/BOT-Tariffe-Octopus-Energy-Italia
#  Rilasciato sotto GNU General Public License, version 2
#
#  Uso normale : .\OctoBot.ps1
#  Debug       : .\OctoBot.ps1 --sendprice
# ==============================================================================

param(
    [switch]$sendprice
)

# ------------------------------------------------------------------------------
# CONFIGURAZIONE – modifica questi valori prima di usare lo script
# ------------------------------------------------------------------------------

$TelegramBotToken = "CAMBIAMI"			# BOT Token
$TelegramChatId   = "CAMBIAMI"		# Chat ID destinatario

# Soglie di allerta
$SogliaLuce = 0.100          # €/kWh  – invia se luce <= questa soglia (usa il punto: 0.100)
$SogliaGas  = 0.350          # €/Smc  – invia se gas  <= questa soglia (usa il punto: 0.430)

# Abilita/disabilita le singole soglie
# $true  → la soglia viene controllata
# $false → invia sempre, indipendentemente dal valore della tariffa
$AbilitaSogliaLuce = $true
$AbilitaSogliaGas  = $true

# Se $true: invia notifica ogni volta che il prezzo cambia rispetto all'ultima
# rilevazione registrata in lastprice.json, indipendentemente dalle soglie.
$AggiornaVariazioni = $true

# Se $true: aggiunge avviso in cima al messaggio quando il prezzo attuale
# corrisponde esattamente alla soglia configurata (utile per rinnovi contrattuali).
$NotificaRinnovo = $true

# ------------------------------------------------------------------------------
# FINE CONFIGURAZIONE
# ------------------------------------------------------------------------------

$euro          = [char]0x20AC

# Normalizza le soglie: accetta sia virgola che punto come separatore decimale
$SogliaLuce = [double]("$SogliaLuce" -replace ',', '.')
$SogliaGas  = [double]("$SogliaGas"  -replace ',', '.')
$URL_TARIFFE   = "https://octopusenergy.it/le-nostre-tariffe"
$ScriptDir     = if ($PSScriptRoot) { $PSScriptRoot } else { $PWD.Path }
$LASTPRICE_FILE = Join-Path $ScriptDir "lastprice.json"

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
function Get-Freccia($nuovo, $vecchio) {
    if     ([double]$nuovo -lt [double]$vecchio) { return "📉" }
    elseif ([double]$nuovo -gt [double]$vecchio) { return "📈" }
    else                                         { return "👍🏻" }
}

# ------------------------------------------------------------------------------
# Funzione: riga storico con prezzo precedente e differenza
# ------------------------------------------------------------------------------
function Format-RigaStorico($label, $nuovo, $vecchio, $unit) {
    $f          = Get-Freccia $nuovo $vecchio
    $n          = [double]$nuovo
    $v          = [double]$vecchio
    $vecchioStr = $v.ToString("0.000").Replace('.', ',')
    $diff       = $n - $v
    if ($diff -eq 0) {
        return "   $f ${label}: $vecchioStr $euro/$unit (invariato)"
    }
    $segno    = if ($diff -gt 0) { "+" } else { "-" }
    $diffStr  = [math]::Abs($diff).ToString("0.000").Replace('.', ',')
    return "   $f ${label}: $vecchioStr $euro/$unit (${segno}${diffStr}$euro)"
}

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
    if ($escape)               { $escape = $false; continue }
    if ($c -eq '\' -and $inString) { $escape = $true; continue }
    if ($c -eq '"')            { $inString = -not $inString; continue }
    if (-not $inString) {
        if ($c -eq '{')        { $depth++ }
        elseif ($c -eq '}')   {
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
# Cerca i prodotti "Fissa 12M" nel JSON
# ------------------------------------------------------------------------------
$prodotti = $datiPagina.props.pageProps.products

if (-not $prodotti) { Write-Error "Nessun prodotto trovato nel JSON."; exit 1 }

$prodottoLuce = $prodotti | Where-Object {
    $_.__typename -eq "ElectricityProductType" -and $_.displayName -match "Fissa 12M"
} | Select-Object -First 1

$prodottoGas = $prodotti | Where-Object {
    $_.__typename -eq "GasProductType" -and $_.displayName -match "Fissa 12M"
} | Select-Object -First 1

if (-not $prodottoLuce) { Write-Error "Prodotto 'Octopus Fissa 12M' (luce) non trovato."; exit 1 }
if (-not $prodottoGas)  { Write-Error "Prodotto 'Octopus Fissa 12M Gas' non trovato."; exit 1 }

# Params può essere oggetto o array
function Get-Params($p) { if ($p.params -is [System.Array]) { return $p.params[0] } return $p.params }

$paramsLuce = Get-Params $prodottoLuce
$paramsGas  = Get-Params $prodottoGas

$tariffaLuceStr = $paramsLuce.consumptionCharge   # es. "0,121"
$tariffaGasStr  = $paramsGas.consumptionCharge    # es. "0,475"
$tariffaLuce    = [double]($tariffaLuceStr -replace ',', '.')
$tariffaGas     = [double]($tariffaGasStr  -replace ',', '.')

$commLuceStr = [string]([int]([int]$paramsLuce.annualStandingCharge / 12))
$commGasStr  = [string]([int]([int]$paramsGas.annualStandingCharge  / 12))

Write-Host ""
Write-Host "--- Tariffe rilevate ---" -ForegroundColor Yellow
Write-Host "  Luce monoraria : $tariffaLuceStr $euro/kWh  (comm. $commLuceStr $euro/mese)"
Write-Host "  Gas            : $tariffaGasStr $euro/Smc  (comm. $commGasStr $euro/mese)"
Write-Host ""

# ------------------------------------------------------------------------------
# Carica l'ultimo prezzo registrato da lastprice.json
# ------------------------------------------------------------------------------
$ultimoLuceStr    = $null
$ultimoGasStr     = $null
$ultimoCommLuce   = $null
$ultimoCommGas    = $null
$ultimoAggiornato = $null

if (Test-Path $LASTPRICE_FILE) {
    try {
        $u                = Get-Content $LASTPRICE_FILE -Raw | ConvertFrom-Json
        $ultimoLuceStr    = $u.luce
        $ultimoGasStr     = $u.gas
        $ultimoCommLuce   = $u.commLuce
        $ultimoCommGas    = $u.commGas
        $ultimoAggiornato = $u.aggiornato
        Write-Host "  Ultimo prezzo registrato → Luce: $ultimoLuceStr $euro/kWh  |  Gas: $ultimoGasStr $euro/Smc"
    }
    catch {
        Write-Warning "Impossibile leggere $LASTPRICE_FILE, verrà ricreato."
    }
}

# Determina se i prezzi sono variati
$prezzoVariato = ($ultimoLuceStr -ne $tariffaLuceStr) -or ($ultimoGasStr -ne $tariffaGasStr)

# Salva i prezzi correnti in lastprice.json
@{
    luce       = $tariffaLuceStr
    gas        = $tariffaGasStr
    commLuce   = $commLuceStr
    commGas    = $commGasStr
    aggiornato = (Get-Date -Format "yyyy-MM-ddTHH:mm:ss")
} | ConvertTo-Json | Set-Content -Path $LASTPRICE_FILE -Encoding UTF8
Write-Host "  Prezzi salvati in $LASTPRICE_FILE"

# ------------------------------------------------------------------------------
# Decide se inviare la notifica
# ------------------------------------------------------------------------------
$dataOra      = Get-Date -Format "dd/MM/yyyy HH:mm"
$motivoInvio  = $null
$motivoNoInvio = $null
$deveInviare  = $false

if ($sendprice) {
    Write-Host "[DEBUG --sendprice] Invio forzato indipendentemente dalle soglie." -ForegroundColor Magenta
    $deveInviare = $true
    $motivoInvio = "debug --sendprice"
}
elseif ($AggiornaVariazioni) {
    # Modalità variazioni: invia SOLO se il prezzo è cambiato, soglie ignorate
    if ($prezzoVariato) {
        Write-Host "  Variazione rilevata → invio notifica." -ForegroundColor Cyan
        $deveInviare = $true
        $motivoInvio = "variazione prezzi"
    } else {
        Write-Host "  Nessuna variazione rispetto all'ultima rilevazione." -ForegroundColor DarkYellow
        $motivoNoInvio = "nessuna variazione di prezzo"
    }
}
else {
    # Modalità soglie
    $condizioneL = $true
    $condizioneG = $true

    if ($AbilitaSogliaLuce) {
        $condizioneL = ($tariffaLuce -lt $SogliaLuce)
        $stato = if ($condizioneL) { "OK ✔" } else { "NO (attuale $tariffaLuceStr > soglia $($SogliaLuce.ToString('0.000')))" }
        Write-Host "  Soglia luce ($($SogliaLuce.ToString('0.000')) $euro/kWh): $stato"
    } else {
        Write-Host "  Soglia luce: DISABILITATA"
    }

    if ($AbilitaSogliaGas) {
        $condizioneG = ($tariffaGas -lt $SogliaGas)
        $stato = if ($condizioneG) { "OK ✔" } else { "NO (attuale $tariffaGasStr > soglia $($SogliaGas.ToString('0.000')))" }
        Write-Host "  Soglia gas  ($($SogliaGas.ToString('0.000')) $euro/Smc): $stato"
    } else {
        Write-Host "  Soglia gas: DISABILITATA"
    }

    if ($condizioneL -or $condizioneG) {
        $deveInviare  = $true
        $motivoInvio  = "soglie raggiunte"
    } else {
        # Soglie non raggiunte con <, ma controlla se uguali e NotificaRinnovo è attivo
        $lucePariSoglia = ($AbilitaSogliaLuce -and ($tariffaLuce -eq $SogliaLuce))
        $gasPariSoglia  = ($AbilitaSogliaGas  -and ($tariffaGas  -eq $SogliaGas))
        if ($NotificaRinnovo -and ($lucePariSoglia -or $gasPariSoglia)) {
            $deveInviare  = $true
            $motivoInvio  = "rinnovo contratto"
        } else {
            $motivoNoInvio = "soglie non raggiunte"
        }
    }
}

Write-Host ""

# ------------------------------------------------------------------------------
# Componi e invia il messaggio Telegram
# ------------------------------------------------------------------------------
if ($deveInviare) {

    # Sezione "Variazione tariffe" — solo se esiste uno storico
    $sezioneAndamento = ""
    if ($null -ne $ultimoLuceStr) {

        $ultimoLuceVal     = [double]($ultimoLuceStr -replace ',', '.')
        $ultimoGasVal      = [double]($ultimoGasStr  -replace ',', '.')
        $ultimoCommLuceVal = if ($ultimoCommLuce) { [double]$ultimoCommLuce } else { [double]$commLuceStr }
        $ultimoCommGasVal  = if ($ultimoCommGas)  { [double]$ultimoCommGas  } else { [double]$commGasStr  }

        $r1 = Format-RigaStorico "Luce"                     $tariffaLuce    $ultimoLuceVal     "kWh"
        $r2 = Format-RigaStorico "Commercializzazione Luce" $commLuceStr    $ultimoCommLuceVal "mese"
        $r3 = Format-RigaStorico "Gas"                      $tariffaGas     $ultimoGasVal      "Smc"
        $r4 = Format-RigaStorico "Commercializzazione Gas"  $commGasStr     $ultimoCommGasVal  "mese"

        # Data ultima run in formato italiano
        $ultimoDataStr = ""
        if ($ultimoAggiornato) {
            try { $ultimoDataStr = " " + [datetime]::Parse($ultimoAggiornato).ToString("dd/MM/yyyy") } catch {}
        }

        $sezioneAndamento = @"

📊 <b>Variazione tariffe dal${ultimoDataStr}:</b>

$r1
$r2

$r3
$r4
"@
    }

    # Intestazione rinnovo: se il prezzo attuale coincide esattamente con la soglia
    $rigaRinnovo = ""
    if ($NotificaRinnovo) {
        $lucePariSoglia = ($AbilitaSogliaLuce -and ($tariffaLuce -eq $SogliaLuce))
        $gasPariSoglia  = ($AbilitaSogliaGas  -and ($tariffaGas  -eq $SogliaGas))
        if ($lucePariSoglia -and $gasPariSoglia) {
            $rigaRinnovo = "⚠️ RINNOVA IL CONTRATTO - TARIFFA UGUALE ⚠️`n`n"
        } elseif ($lucePariSoglia) {
            $sogliaLuceStr = $SogliaLuce.ToString("0.000").Replace('.', ',')
            $rigaRinnovo = "⚠️ RINNOVA IL CONTRATTO - ENERGIA $sogliaLuceStr $euro/kWh ⚠️`n`n"
        } elseif ($gasPariSoglia) {
            $sogliaGasStr = $SogliaGas.ToString("0.000").Replace('.', ',')
            $rigaRinnovo = "⚠️ RINNOVA IL CONTRATTO - GAS $sogliaGasStr $euro/Smc ⚠️`n`n"
        }
    }

    $messaggio = @"
${rigaRinnovo}⚡ <b>Tariffe Octopus Fissa 12M (Luce + Gas)</b>

🔌 <b>Luce monoraria</b>
   Materia prima: <b>$tariffaLuceStr $euro/kWh</b>
   Commercializzazione: $commLuceStr $euro/mese
   IVA e imposte escluse, perdite incluse.

🔥 <b>Gas</b>
   Materia prima: <b>$tariffaGasStr $euro/Smc</b>
   Commercializzazione: $commGasStr $euro/mese
   IVA e imposte escluse.
$sezioneAndamento

📅 Aggiornato il $dataOra
"@

    Write-Host "Invio notifica Telegram ($motivoInvio)..." -ForegroundColor Cyan
    Send-Telegram -Messaggio $messaggio

} else {
    Write-Host "Nessuna notifica inviata: $motivoNoInvio." -ForegroundColor DarkYellow

}
