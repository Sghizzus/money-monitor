library(httr2)
library(chromote)

source("R/otp_polling.R")

#' Scarica i movimenti del conto BBVA (versione sperimentale httr2)
#'
#' Flusso ibrido: chromote gestisce solo il login MFA (necessario per superare
#' PerimeterX), intercettando il token `tsec` e i cookie di sessione direttamente
#' dalla risposta di rete. Il browser viene chiuso immediatamente dopo.
#' Tutte le chiamate dati usano httr2 con quei token.
#'
#' @param con Connessione al database, passata a [poll_otp()].
#'
#' @section Variabili d'ambiente richieste:
#' \describe{
#'   \item{`BBVA_USER`}{Username (es. `MRNVNI`)}
#'   \item{`BBVA_PASSWORD`}{Password}
#'   \item{`BBVA_CUSTOMER_ID`}{Customer ID completo (es. `ES9766064944729C`)}
#'   \item{`BBVA_ACCOUNT_ID`}{Contract ID dell'account (visibile nell'URL del browser)}
#' }
#'
#' @return Lista con `$transactions` (lista di movimenti) e `$raw` (ultima pagina grezza).

scarica_excel_httr2 <- function(con) {
  # ── Setup chromote ──────────────────────────────────────────────────────────
  profile_dir <- if (.Platform$OS.type == "windows") {
    file.path(Sys.getenv("LOCALAPPDATA"), "bbva-scraper-profile")
  } else {
    file.path(Sys.getenv("HOME"), ".bbva-scraper-profile")
  }

  args <- c(
    "--disable-blink-features=AutomationControlled",
    "--window-size=1920,1080",
    "--no-first-run",
    paste0("--user-data-dir=", profile_dir)
  )
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
    Chromote$new(browser = Chrome$new(args = args)),
    error = function(e) {
      message("[WARN] Profilo in uso, ritento senza --user-data-dir.")
      Chromote$new(
        browser = Chrome$new(
          args = args[!grepl("--user-data-dir", args)]
        )
      )
    }
  )
  set_default_chromote_object(ch)
  bbva <- rvest::read_html_live("https://www.bbva.it")

  on.exit(try(ch$close(), silent = TRUE), add = TRUE)

  # Patch stealth: eseguita prima di ogni script della pagina per evitare
  # che PerimeterX rilevi l'automazione tramite navigator.webdriver e affini
  bbva$session$Page$addScriptToEvaluateOnNewDocument(
    source = "
    Object.defineProperty(navigator, 'webdriver', { get: () => undefined });
    if (!window.chrome) window.chrome = { app: { isInstalled: false }, runtime: {} };
    Object.defineProperty(navigator, 'plugins', { get: () => [1, 2, 3, 4, 5] });
    Object.defineProperty(navigator, 'languages', { get: () => ['it-IT', 'it', 'en-US', 'en'] });
    Object.defineProperty(navigator, 'hardwareConcurrency', { get: () => 8 });
    Object.defineProperty(navigator, 'deviceMemory', { get: () => 8 });
    const _origQuery = window.navigator.permissions.query;
    window.navigator.permissions.query = (p) =>
      p.name === 'notifications'
        ? Promise.resolve({ state: Notification.permission })
        : _origQuery(p);
  "
  )
  bbva$session$Page$reload()
  bbva$session$Page$loadEventFired(timeout = 30000)

  # ── Intercetta tsec e contactid dalla rete ──────────────────────────────────
  tsec_captured <- NULL
  contact_id_captured <- NULL

  bbva$session$Network$enable()

  bbva$session$Network$responseReceived(function(params) {
    if (!grepl("grantingTickets", params$response$url, fixed = TRUE)) {
      return()
    }
    hdrs <- params$response$headers
    if (!is.null(hdrs[["tsec"]])) {
      tsec_captured <<- hdrs[["tsec"]]
      message("[INFO] tsec intercettato dalla rete.")
    }
  })

  bbva$session$Network$requestWillBeSent(function(params) {
    if (!grepl("grantingTickets", params$request$url, fixed = TRUE)) {
      return()
    }
    cid <- params$request$headers[["contactid"]]
    if (!is.null(cid)) contact_id_captured <<- cid
  })

  # ── Login ───────────────────────────────────────────────────────────────────
  Sys.sleep(runif(1, 1, 2))
  tryCatch(
    bbva$click("button.cookiesgdpr__rejectbtn"),
    error = function(e) message("[INFO] Banner cookie non trovato.")
  )
  Sys.sleep(runif(1, 1, 2))

  bbva$click(
    "#header-persone-experience-fragment-master-jcr-content-header > div.header__main.container-header > nav > ul > li.header__actions__list.header__actions--tablet-left > div > div.header__access__wrapper.header__access__wrapper--tablet > a"
  )
  Sys.sleep(runif(1, 1.5, 3))

  type_slowly <- function(sel, text) {
    bbva$session$Runtime$evaluate(
      sprintf("document.querySelector('%s').focus()", sel)
    )
    for (ch in strsplit(text, "")[[1]]) {
      bbva$session$Input$dispatchKeyEvent(type = "keyDown", text = ch)
      bbva$session$Input$dispatchKeyEvent(type = "keyUp", text = ch)
      Sys.sleep(runif(1, 0.05, 0.15))
    }
  }

  type_slowly("#input-user", Sys.getenv("BBVA_USER"))
  Sys.sleep(runif(1, 0.5, 1))
  type_slowly("#input-password", Sys.getenv("BBVA_PASSWORD"))
  Sys.sleep(runif(1, 0.5, 1))

  login_time <- Sys.time()
  bbva$click(
    "#index-router > signin-view > div > div > div.col-md-7.padding-left_0 > signin-form > form > div.flex.flex-align-center.margin-bottom-xsmall > haunted-button"
  )
  Sys.sleep(5)

  error_msg <- bbva |>
    rvest::html_element("[id^='m-alert'] .m-alert__content > p") |>
    rvest::html_text2()
  if (isTRUE(nchar(trimws(error_msg)) > 0)) {
    stop("Blocco banca: ", error_msg)
  }

  otp <- poll_otp(con, after_time = login_time - 30)
  bbva$type("#input-otpCode", otp)
  Sys.sleep(runif(1, 0.5, 1.5))
  bbva$click(
    "#index-router > two-factor-auth-view > div > div > div > two-factor-challenge-form > form > div > haunted-button"
  )

  message("[INFO] Attendo intercettazione tsec...")
  wait_start <- Sys.time()
  while (
    is.null(tsec_captured) &&
      as.numeric(difftime(Sys.time(), wait_start, units = "secs")) < 15
  ) {
    later::run_now(timeoutSecs = 0.3) # processa i WebSocket events di chromote
  }
  if (is.null(tsec_captured)) {
    stop("[ERRORE] tsec non intercettato entro 15 secondi.")
  }

  # Estrai i cookie di sessione (inclusi quelli PerimeterX: _px3, _pxvid, ecc.)
  raw_cookies <- bbva$session$Network$getCookies(
    urls = list(
      "https://w-services.bbva.it",
      "https://web.bbva.it",
      "https://www.bbva.it"
    )
  )
  cookie_str <- paste(
    vapply(
      raw_cookies$cookies,
      \(c) paste0(c$name, "=", c$value),
      character(1)
    ),
    collapse = "; "
  )
  message(sprintf(
    "[INFO] %d cookie estratti. Chiudo il browser.",
    length(raw_cookies$cookies)
  ))
  try(ch$close(), silent = TRUE)

  # ── Fetch movimenti via httr2 ───────────────────────────────────────────────
  customer_id <- Sys.getenv("BBVA_CUSTOMER_ID")
  account_id <- Sys.getenv("BBVA_ACCOUNT_ID")
  rcp_id <- paste0("00000287|", sub("[A-Z]$", "", customer_id))
  contact_id <- contact_id_captured %||% uuid_v4()

  bbva_data_req <- function(url) {
    request(url) |>
      req_headers(
        accept = "*/*",
        `accept-language` = "it-IT",
        contactid = contact_id,
        `content-type` = "application/json",
        cookie = cookie_str,
        origin = "https://web.bbva.it",
        referer = "https://web.bbva.it/",
        `rcp-id` = rcp_id,
        `sec-ch-ua` = '"Google Chrome";v="153", "Not_A Brand";v="8", "Chromium";v="153"',
        `sec-ch-ua-mobile` = "?0",
        `sec-ch-ua-platform` = '"Windows"',
        `sec-fetch-dest` = "empty",
        `sec-fetch-mode` = "cors",
        `sec-fetch-site` = "same-site",
        tsec = tsec_captured,
        `user-agent` = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/153.0.0.0 Safari/537.36"
      )
  }

  body_base <- list(
    accountContracts = list(list(
      contract = list(id = account_id),
      account = list(
        currentBalance = list(
          accountingBalance = list(
            amount = 0,
            currency = list(code = "", decimalNumber = 0L, id = "")
          ),
          availableBalance = list(
            amount = 0,
            currency = list(code = "", decimalNumber = 0L, id = "")
          )
        )
      )
    )),
    customer = list(id = customer_id),
    orderField = "DATE_FIELD",
    orderType = "DESC_ORDER",
    searchType = "SEARCH"
  )

  fetch_page <- function(pagination_key) {
    bbva_data_req(
      "https://w-services.bbva.it/accountTransactions/V02/accountTransactionsAdvancedSearch"
    ) |>
      req_url_query(pageSize = 40, paginationKey = pagination_key) |>
      req_body_json(body_base) |>
      req_perform() |>
      resp_body_json()
  }

  message("[INFO] Scarico movimenti...")
  all_transactions <- list()
  pagination_key <- 0
  page <- NULL

  repeat {
    page <- fetch_page(pagination_key)
    transactions <- page$accountTransactions %||% page$data %||% list()
    all_transactions <- c(all_transactions, transactions)
    message(sprintf(
      "[INFO] Pagina %d: %d movimenti (totale: %d)",
      pagination_key,
      length(transactions),
      length(all_transactions)
    ))
    next_key <- page$paginationKey %||% page$nextPaginationKey %||% NULL
    if (is.null(next_key) || length(transactions) == 0) {
      break
    }
    pagination_key <- next_key
  }

  message(sprintf(
    "[INFO] Download completato: %d movimenti totali.",
    length(all_transactions)
  ))
  invisible(list(transactions = all_transactions, raw = page))
}

# ── Helpers ──────────────────────────────────────────────────────────────────
`%||%` <- function(a, b) if (!is.null(a)) a else b

uuid_v4 <- function() {
  hex <- sample(c(0:9, letters[1:6]), 32, replace = TRUE)
  hex[13] <- "4"
  hex[17] <- sample(c("8", "9", "a", "b"), 1)
  paste0(
    paste(hex[1:8], collapse = ""),
    "-",
    paste(hex[9:12], collapse = ""),
    "-",
    paste(hex[13:16], collapse = ""),
    "-",
    paste(hex[17:20], collapse = ""),
    "-",
    paste(hex[21:32], collapse = "")
  )
}
