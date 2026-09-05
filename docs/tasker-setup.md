# Configurazione Tasker per OTP Relay

## Prerequisiti

- Android con Tasker installato (Google Play Store, ~3.50€)
- Il numero di telefono associato al conto BBVA deve ricevere gli SMS OTP
- Le credenziali Supabase (URL del progetto e `anon` key)

## Informazioni Supabase necessarie

Trovi queste informazioni in **Supabase Dashboard > Settings > API**:

| Variabile         | Esempio                                              |
|-------------------|------------------------------------------------------|
| `SUPABASE_URL`    | `https://pntkrsospmzbuyelbmac.supabase.co`           |
| `SUPABASE_ANON_KEY` | `eyJhbGciOiJIUzI1NiIs...` (la chiave pubblica `anon`) |

## Configurazione Step-by-Step

### 1. Crea il Profilo (Trigger)

1. Apri Tasker → tab **PROFILI** → tocca **+**
2. Seleziona **Evento** → **Telefono** → **Received Text** (SMS Ricevuto)
3. Configura:
   - **Tipo**: SMS
   - **Mittente**: inserisci il numero/nome da cui BBVA invia gli SMS OTP
     (es. `BBVA` o il numero specifico — controlla nei tuoi SMS precedenti)
   - **Contenuto**: lascia vuoto (filtreremo nel task)
4. Tocca **← Indietro** per confermare

### 2. Crea il Task (Azione)

Quando Tasker chiede di associare un task, tocca **Nuovo Task** e chiamalo
`Invia OTP`.

#### Azione 1: Copia il testo dell'SMS in una variabile custom

Le variabili built-in di Tasker (come `%SMSRB`) sono in sola lettura.
Bisogna prima copiare il contenuto in una variabile custom.

1. Tocca **+** → **Variabili** → **Variable Set**
2. Configura:
   - **Nome**: `%sms_body`
   - **A**: `%SMSRB`
3. Tocca **← Indietro**

#### Azione 2: Estrai il codice OTP dal testo

1. Tocca **+** → **Variabili** → **Variable Search Replace**
2. Configura:
   - **Variabile**: `%sms_body`
   - **Cerca**: `(?s).*?(\d{6}).*` (matcha l'intero SMS e cattura le 6 cifre)
     - Il `(?s)` permette a `.` di matchare anche i newline
     - Se l'OTP di BBVA è di lunghezza diversa, adatta il numero
       (es. `(\d{8})` per 8 cifre)
   - **Sostituisci Abilitato**: ✓
   - **Sostituisci Con**: `$1`
3. Tocca **← Indietro**

Dopo questa azione, `%sms_body` contiene solo il codice OTP (le 6 cifre).

#### Azione 3: Apri loop di retry

1. Tocca **+** → **Flusso di controllo** → **For**
2. Configura:
   - **Variabile**: `%attempt`
   - **Da**: `1`
   - **A**: `3`
3. Tocca **← Indietro**

#### Azione 4: Invia l'OTP a Supabase via HTTP

1. Tocca **+** → **Rete** → **HTTP Request**
2. Configura:
   - **Metodo**: POST
   - **URL**: `https://pntkrsospmzbuyelbmac.supabase.co/rest/v1/otp_relay`
   - **Headers**:
     ```
     apikey: LA_TUA_ANON_KEY
     Authorization: Bearer LA_TUA_ANON_KEY
     Content-Type: application/json
     Prefer: return=minimal
     ```
   - **Body**:
     ```json
     {"otp_code": "%sms_body"}
     ```
   - **Response Code Variable**: `%http_code`
3. Tocca **← Indietro**

#### Azione 5: Esci dal loop se la chiamata ha avuto successo

1. Tocca **+** → **Flusso di controllo** → **If**
2. Condizione: `%http_code` **eq** `201`
3. Tocca **← Indietro**

Dentro il blocco If:

4. Tocca **+** → **Flusso di controllo** → **Break**
5. Tocca **← Indietro**

6. Tocca **+** → **Flusso di controllo** → **End If**
7. Tocca **← Indietro**

#### Azione 6: Attendi prima del prossimo tentativo

1. Tocca **+** → **Task** → **Wait**
2. **Secondi**: `5`
3. Tocca **← Indietro**

#### Azione 7: Chiudi il loop

1. Tocca **+** → **Flusso di controllo** → **End For**
2. Tocca **← Indietro**

#### Azione 8 (Opzionale): Notifica esito

1. Tocca **+** → **Avviso** → **Flash**
2. **Testo**: `OTP %sms_body inviato (tentativo %attempt)`
3. Tocca **← Indietro**

### 3. Testa il Profilo

1. Assicurati che Tasker sia attivo (icona verde nella barra di stato)
2. Inviati un SMS di test dal contenuto simile a un OTP BBVA
   (es. "Il tuo codice di verifica è 123456")
3. Verifica in Supabase Dashboard → **Table Editor** → `otp_relay`
   che il record sia stato inserito

## Troubleshooting

### Tasker non intercetta gli SMS

- **Android 13+**: vai in Impostazioni → App → Tasker → Permessi →
  assicurati che "SMS" e "Notifiche" siano abilitati
- **Risparmio batteria**: escludi Tasker dall'ottimizzazione batteria
  (Impostazioni → Batteria → Ottimizzazione batteria → Tasker → Non ottimizzare)
- **Alcuni dispositivi** (Xiaomi, Huawei, Samsung) bloccano le app in background.
  Cerca il tuo modello su [dontkillmyapp.com](https://dontkillmyapp.com/)

### L'HTTP Request fallisce

- Verifica che l'URL e la anon key siano corretti
- Controlla i log di Tasker (menu → Altro → Log in tempo reale)
- Testa l'endpoint manualmente con curl:
  ```bash
  curl -X POST \
    'https://pntkrsospmzbuyelbmac.supabase.co/rest/v1/otp_relay' \
    -H "apikey: LA_TUA_ANON_KEY" \
    -H "Authorization: Bearer LA_TUA_ANON_KEY" \
    -H "Content-Type: application/json" \
    -H "Prefer: return=minimal" \
    -d '{"otp_code": "123456"}'
  ```

### Il regex non cattura l'OTP

- Controlla il formato esatto dell'SMS di BBVA
- Adatta il pattern regex di conseguenza
  (es. se l'OTP contiene lettere: `([A-Z0-9]{6})`)

## Note di Sicurezza

- La `anon` key di Supabase è **pensata per l'uso client-side** — non è un segreto
  critico. La sicurezza è garantita dalle RLS policies che permettono solo INSERT.
- Tasker invia i dati su **HTTPS** — il traffico è cifrato.
- I codici OTP sono **effimeri** (validi pochi minuti) e vengono cancellati
  dallo scraper dopo l'uso.
- Non salvare mai la `service_role` key sul telefono.
