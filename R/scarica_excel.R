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
  # Cartella profilo Chrome persistente: mantiene cookie, localStorage e
  # cronologia tra un'esecuzione e l'altra, rendendo il browser
  # indistinguibile da un utente reale agli occhi di BBVA.
  profile_dir <- if (.Platform$OS.type == "windows") {
    file.path(Sys.getenv("LOCALAPPDATA"), "bbva-scraper-profile")
  } else {
    file.path(Sys.getenv("HOME"), ".bbva-scraper-profile")
  }

  args <- c(
    # Rimuove navigator.webdriver = true (principale segnale di bot detection)
    "--disable-blink-features=AutomationControlled",
    "--window-size=1920,1080",
    "--no-first-run",
    paste0("--user-data-dir=", profile_dir)
  )

  # Flag aggiuntivi necessari solo su Linux/Docker
  if (.Platform$OS.type != "windows") {
    args <- c(
      args,
      "--no-sandbox",
      "--disable-dev-shm-usage",
      "--disable-gpu",
      "--disable-software-rasterizer"
    )
  }

  ch <- tryCatch(
    chromote::Chromote$new(browser = chromote::Chrome$new(args = args)),
    error = function(e) {
      # Il profilo è probabilmente in uso da un'altra istanza Chrome.
      # Ritenta senza --user-data-dir.
      message(
        "[WARN] Chrome non avviato col profilo persistente (profilo in uso?). Ritento senza profilo."
      )
      args_no_profile <- args[!grepl("--user-data-dir", args)]
      chromote::Chromote$new(
        browser = chromote::Chrome$new(args = args_no_profile)
      )
    }
  )
  ch$default_timeout <- 30000
  chromote::set_default_chromote_object(ch)

  bbva <- read_html_live("https://www.bbva.it")

  # Inietta patch stealth prima di ogni caricamento di pagina.
  # Page.addScriptToEvaluateOnNewDocument garantisce che il codice
  # venga eseguito PRIMA degli script della pagina — incluso il codice
  # di bot detection di BBVA. È la stessa tecnica usata da playwright-stealth.
  stealth_js <- "
    // Rimuove il flag webdriver (belt-and-suspenders rispetto al flag CLI)
    Object.defineProperty(navigator, 'webdriver', { get: () => undefined });

    // Aggiunge l'oggetto chrome tipico di un browser reale
    if (!window.chrome) {
      window.chrome = {
        app: { isInstalled: false },
        runtime: {}
      };
    }

    // Plugin realistici (headless Chrome ne ha 0)
    Object.defineProperty(navigator, 'plugins', {
      get: () => [1, 2, 3, 4, 5]
    });

    // Lingue realistiche
    Object.defineProperty(navigator, 'languages', {
      get: () => ['it-IT', 'it', 'en-US', 'en']
    });

    // Valori hardware realistici
    Object.defineProperty(navigator, 'hardwareConcurrency', { get: () => 8 });
    Object.defineProperty(navigator, 'deviceMemory', { get: () => 8 });

    // Fix per la query dei permessi notifiche
    const _origQuery = window.navigator.permissions.query;
    window.navigator.permissions.query = (p) =>
      p.name === 'notifications'
        ? Promise.resolve({ state: Notification.permission })
        : _origQuery(p);
  "

  bbva$session$Page$addScriptToEvaluateOnNewDocument(source = stealth_js)

  # Ricarica la pagina perché le patch si applichino anche alla pagina attuale
  bbva$session$Page$reload()
  bbva$session$Page$loadEventFired(timeout = 30000)

  # Muove il mouse verso coordinate casuali prima di un click,
  # simulando il comportamento umano
  human_move <- function(
    target_x = runif(1, 100, 1800),
    target_y = runif(1, 100, 900)
  ) {
    steps <- sample(5:12, 1)
    for (i in seq_len(steps)) {
      bbva$session$Input$dispatchMouseEvent(
        type = "mouseMoved",
        x = target_x * i / steps + runif(1, -10, 10),
        y = target_y * i / steps + runif(1, -10, 10)
      )
      Sys.sleep(runif(1, 0.01, 0.05))
    }
  }

  # Digita testo carattere per carattere con ritmo variabile
  human_type <- function(selector, text) {
    bbva$session$Runtime$evaluate(
      sprintf("document.querySelector('%s').focus()", selector)
    )
    for (ch in strsplit(text, "")[[1]]) {
      bbva$session$Input$dispatchKeyEvent(type = "keyDown", text = ch)
      bbva$session$Input$dispatchKeyEvent(type = "keyUp", text = ch)
      Sys.sleep(runif(1, 0.05, 0.2))
    }
  }

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

  # Inserisco le credenziali con ritmo umano
  human_move()
  human_type("#input-user", Sys.getenv("BBVA_USER"))
  Sys.sleep(runif(1, 0.5, 1.5))
  human_move()
  human_type("#input-password", Sys.getenv("BBVA_PASSWORD"))

  Sys.sleep(runif(1, 1, 2))

  # Timestamp pre-login per il polling OTP
  login_time <- Sys.time()

  # Effettuo il login (questo triggera l'invio dell'SMS OTP)
  bbva$click(
    "#index-router > signin-view > div > div > div.col-md-7.padding-left_0 > signin-form > form > div.flex.flex-align-center.margin-bottom-xsmall > haunted-button"
  )

  # Attendo che BBVA processi il login e transiti alla pagina OTP
  Sys.sleep(5)

  error_msg <- bbva |>
    html_element("[id^='m-alert'] .m-alert__content > p") |>
    html_text2()

  if (isTRUE(nchar(trimws(error_msg)) > 0)) {
    stop("Blocco banca: ", error_msg)
  }

  # Attendo l'OTP da Tasker via Supabase
  otp <- poll_otp(con, after_time = login_time - 30)

  # Inserisco l'OTP nel campo
  bbva$type("#input-otpCode", otp)

  Sys.sleep(runif(1, 1, 3))

  bbva$click(
    "#index-router > two-factor-auth-view > div > div > div > two-factor-challenge-form > form > div > haunted-button"
  )

  # Attendo il caricamento della dashboard post-OTP
  Sys.sleep(runif(1, 6, 8))

  # Passo ai movimenti del mio conto
  bbva$click(
    "#aria-product-name-ES9766002000000000000000000651177505XXXXXXXXX > haunted-link"
  )

  # Attendo il caricamento della pagina movimenti
  Sys.sleep(runif(1, 5, 7))

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
