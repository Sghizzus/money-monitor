library(tidyverse)
library(rvest)

source("R/otp_polling.R")

#' Scarica il file Excel dei movimenti da BBVA
#'
#' Automatizza il login sul sito di BBVA tramite un browser headless (chromote),
#' gestisce l'autenticazione MFA ricevendo il codice OTP via Supabase (inviato
#' da Tasker al momento della ricezione dell'SMS), naviga all'area movimenti e
#' scarica il file Excel delle transazioni.
#'
#' Il file viene scaricato nella cartella di default di Chrome e poi spostato
#' nella directory di lavoro corrente ([getwd()]). In caso di errore, l'oggetto
#' sessione `bbva` viene esportato nel global environment per permettere
#' l'ispezione manuale con `bbva$view()`.
#'
#' @param con connessione al database (pool o DBI), passata a [poll_otp()] per
#'   recuperare l'OTP inviato da Tasker via Supabase.
#'
#' @details
#' Il flusso è:
#' \enumerate{
#'   \item Avvia browser headless e naviga su bbva.it
#'   \item Rifiuta il banner cookie (se presente)
#'   \item Inserisce le credenziali lette da `BBVA_USER` e `BBVA_PASSWORD`
#'   \item Effettua il login, triggera l'invio dell'SMS OTP
#'   \item Attende l'OTP tramite polling su Supabase (inviato da Tasker)
#'   \item Inserisce l'OTP e completa il login MFA
#'   \item Naviga ai movimenti del conto e avvia il download Excel
#'   \item Attende che il file appaia nella cartella Downloads di sistema
#'   \item Sposta il file nella directory di lavoro corrente
#' }
#'
#' @section Variabili d'ambiente:
#' \describe{
#'   \item{`BBVA_USER`}{Username per il login BBVA}
#'   \item{`BBVA_PASSWORD`}{Password per il login BBVA}
#' }
#'
#' @return Invisibilmente, il path di destinazione del file Excel scaricato.
#'
#' @seealso [poll_otp()] per il meccanismo di ricezione OTP, [aggiorna_db()]
#'   per l'importazione del file scaricato nel database.
#'
#' @examples
#' \dontrun{
#' con <- db_connect()
#' scarica_excel(con)
#' aggiorna_db()
#' }

scarica_excel <- function(con) {
  # Su Linux (es. Docker) Chrome richiede --no-sandbox perché il container
  # non ha le capabilities kernel necessarie per la sandbox di Chrome.
  # --disable-dev-shm-usage evita crash per /dev/shm troppo piccolo.
  if (.Platform$OS.type != "windows") {
    ch <- chromote::Chromote$new(
      browser = chromote::Chrome$new(
        args = c(
          "--no-sandbox",
          "--disable-dev-shm-usage"
        )
      )
    )
    chromote::set_default_chromote_object(ch)
  }

  bbva <- read_html_live("https://www.bbva.it")

  # Esporta bbva nel global environment solo in caso di errore
  .success <- FALSE
  on.exit(
    {
      if (!.success) {
        bbva <<- bbva
        message(
          "[DEBUG] bbva esportato nel global environment. Usa bbva$view() per ispezionare."
        )
      }
    },
    add = TRUE
  )

  Sys.sleep(runif(1, 1, 2))

  # Rifiuto i cookies (opzionale: non sempre presente)
  tryCatch(
    bbva$click("button.cookiesgdpr__rejectbtn"),
    error = function(e) message("[INFO] Banner cookie non trovato, procedo.")
  )

  Sys.sleep(runif(1, 1, 2.5))

  # Passo alla pagina di login
  bbva$click(
    "#header-persone-experience-fragment-master-jcr-content-header > div.header__main.container-header > nav > ul > li.header__actions__list.header__actions--tablet-left > div > div.header__access__wrapper.header__access__wrapper--tablet > a"
  )

  Sys.sleep(runif(1, 1.5, 3))

  # Inserisco le credenziali
  bbva$type("#input-user", Sys.getenv("BBVA_USER"))
  Sys.sleep(runif(1, 0.5, 1.5))
  bbva$type("#input-password", Sys.getenv("BBVA_PASSWORD"))

  Sys.sleep(runif(1, 1, 2))

  # Timestamp pre-login per il polling OTP
  login_time <- Sys.time()

  # Effettuo il login (questo triggera l'invio dell'SMS OTP)
  bbva$click(
    "#index-router > signin-view > div > div > div.col-md-7.padding-left_0 > signin-form > form > div.flex.flex-align-center.margin-bottom-xsmall > haunted-button"
  )

  # Attendo l'OTP da Tasker via Supabase
  otp <- poll_otp(con, after_time = login_time - 30)

  # Inserisco l'OTP nel campo
  bbva$type("#input-otpCode", otp)

  bbva$click(
    "#index-router > two-factor-auth-view > div > div > div > two-factor-challenge-form > form > div > haunted-button"
  )

  # Attendo il caricamento della dashboard post-OTP
  Sys.sleep(runif(1, 5, 7))

  # Passo ai movimenti del mio conto
  bbva$click(
    "#aria-product-name-ES9766002000000000000000000651177505XXXXXXXXX > haunted-link"
  )

  # Attendo il caricamento della pagina movimenti
  Sys.sleep(runif(1, 4, 6))

  # Apro il menu di download
  bbva$click(
    "#uid-5c2701d4 > accounts-es9766002000000000000000000651177505xxxxxxxxx > div > div.t-main-row__container.margin-top-xsmall > div > accounts-transactions > div > haunted-transactions > div > transactions-links > div > ul > li:nth-child(1) > haunted-link"
  )

  Sys.sleep(runif(1, 2, 3))

  # Scarico Excel
  bbva$click("#downloadTransactionsPDFDocument > haunted-button")

  # Cartella di download di default di Chrome (cross-platform)
  downloads_dir <- if (.Platform$OS.type == "windows") {
    file.path(Sys.getenv("USERPROFILE"), "Downloads")
  } else {
    file.path(Sys.getenv("HOME"), "Downloads")
  }

  # Attendo che un nuovo xlsx appaia nella cartella Downloads di sistema
  message("[INFO] Attendo completamento download...")
  download_timeout <- 30
  start <- Sys.time()
  repeat {
    xlsx_files <- list.files(
      downloads_dir,
      pattern = "\\.xlsx$",
      full.names = TRUE
    )
    if (length(xlsx_files) > 0) {
      break
    }
    if (difftime(Sys.time(), start, units = "secs") > download_timeout) {
      stop(
        "Timeout: file Excel non scaricato entro ",
        download_timeout,
        " secondi."
      )
    }
    Sys.sleep(1)
  }

  bbva$session$Browser$close()

  # Sposto il file più recente in getwd()
  newest <- xlsx_files[which.max(file.mtime(xlsx_files))]
  dest <- file.path(getwd(), basename(newest))
  file.rename(newest, dest)

  .success <- TRUE
  message("[INFO] Excel scaricato con successo.")
  invisible(dest)
}
