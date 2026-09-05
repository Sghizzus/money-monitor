library(pool)

#' Attende e recupera un codice OTP dalla tabella otp_relay
#'
#' Dopo aver triggerato il login su BBVA, lo scraper chiama questa funzione
#' per attendere che Tasker invii l'OTP a Supabase. Esegue polling sulla
#' tabella `otp_relay` cercando record creati dopo `after_time`.
#'
#' @param con connessione al database (pool o DBI)
#' @param after_time POSIXct — cerca solo OTP inseriti dopo questo timestamp.
#'   Default: 30 secondi fa (per coprire latenza SMS).
#' @param timeout_sec secondi massimi di attesa prima di restituire errore
#' @param interval_sec secondi tra un poll e l'altro
#'
#' @return stringa con il codice OTP
#' @examples
#' \dontrun{
#' con <- db_connect()
#' # ... login su BBVA ...
#' login_time <- Sys.time()
#' otp <- poll_otp(con, after_time = login_time - 30)
#' # ... inserisci otp nel campo della pagina ...
#' }

poll_otp <- function(con,
                     after_time = Sys.time() - 30,
                     timeout_sec = 120,
                     interval_sec = 5) {

  # Converti in formato ISO 8601 per la query
  after_ts <- format(after_time, "%Y-%m-%d %H:%M:%S%z", tz = "UTC")

  message("[OTP] In attesa dell'OTP (timeout: ", timeout_sec, "s)...")

  start <- Sys.time()
  attempt <- 0L

  while (difftime(Sys.time(), start, units = "secs") < timeout_sec) {
    attempt <- attempt + 1L

    result <- dbGetQuery(con, "
      SELECT id, otp_code
      FROM otp_relay
      WHERE created_at > $1::timestamptz
      ORDER BY created_at DESC
      LIMIT 1
    ", params = list(after_ts))

    if (nrow(result) > 0) {
      otp <- result$otp_code[1]
      record_id <- result$id[1]

      # Cancella il record usato (pulizia)
      dbExecute(con, "DELETE FROM otp_relay WHERE id = $1", params = list(record_id))

      # Cancella anche eventuali record vecchi
      dbExecute(con, "DELETE FROM otp_relay WHERE created_at < now() - interval '5 minutes'")

      message("[OTP] Codice ricevuto dopo ", attempt, " tentativi.")
      return(otp)
    }

    if (attempt %% 6 == 0) {
      elapsed <- round(difftime(Sys.time(), start, units = "secs"))
      message("[OTP] Ancora in attesa... (", elapsed, "s trascorsi)")
    }

    Sys.sleep(interval_sec)
  }

  stop("[OTP] Timeout: nessun OTP ricevuto entro ", timeout_sec, " secondi.")
}
