# Variabili d'Ambiente

## File `.Renviron` (locale e su Azure)

Aggiungi queste variabili al file `.Renviron` nella root del progetto.
Su Azure Container App, configurale come secrets/environment variables.

```env
# === Database (già esistente) ===
DB_PWD=la_tua_password_supabase

# === Credenziali BBVA ===
# N.B. rinominate da USER/PASSWORD per evitare conflitti
# con variabili di sistema (USER è una variabile di sistema su Linux)
BBVA_USER=il_tuo_username_bbva
BBVA_PASSWORD=la_tua_password_bbva
```

## Variabili rinominate

Nel vecchio `aggiorna_db.R` le credenziali BBVA usavano `USER` e `PASSWORD`.
Le ho rinominate in `BBVA_USER` e `BBVA_PASSWORD` perché:

- `USER` è una variabile di sistema su Linux/macOS (contiene il nome utente
  del sistema operativo) — su Azure Container App verrebbe sovrascritta
- Nomi più specifici evitano collisioni e rendono chiaro a cosa servono

Aggiorna il tuo `.Renviron` di conseguenza.

## Configurazione Tasker (sul telefono)

Queste non vanno nel `.Renviron` ma nella configurazione Tasker:

| Variabile            | Dove trovarla                                      |
|----------------------|----------------------------------------------------|
| Supabase URL         | Dashboard Supabase → Settings → API → Project URL  |
| Supabase Anon Key    | Dashboard Supabase → Settings → API → anon public  |
