#' Identifica il periodo finanziario corrente (mese di calendario)
#'
#' Restituisce l'inizio e la fine del mese di calendario corrente.
#'
#' @param con Connessione al database (non utilizzata, mantenuta per compatibilità).
#' @return Lista con elementi \code{da} (Date, primo giorno del mese corrente) e
#'   \code{a} (Date, primo giorno del mese successivo).

periodo_attuale <- function(con) {
  da <- floor_date(today(), "month")
  a <- ceiling_date(today(), "month")

  list(da = as.Date(da), a = as.Date(a))
}

#' Calcola la media mensile dei guadagni degli ultimi 3 mesi completi
#'
#' Per ogni mese considera solo il movimento positivo più grande (lo stipendio),
#' poi ne fa la media. Utilizzata come stima quando nel mese corrente non è
#' ancora stato registrato alcun guadagno.
#'
#' @param con Connessione al database.
#' @param includi_ignorati Se \code{TRUE}, include i record marcati come ignorati.
#' @return Valore numerico: media dei massimi movimenti positivi degli ultimi 3 mesi.

media_ultimi_3_mesi <- function(con, includi_ignorati = FALSE) {
  da <- as.Date(floor_date(today() %m-% months(3), "month"))
  a <- as.Date(floor_date(today(), "month"))

  tbl(con, "movimenti") |>
    filter(
      importo > 0,
      data_valuta >= !!da,
      data_valuta < !!a,
      includi_ignorati | !ignora
    ) |>
    select(data_valuta, importo) |>
    collect() |>
    mutate(mese = floor_date(data_valuta, "month")) |>
    group_by(mese) |>
    summarise(tot = max(importo), .groups = "drop") |>
    pull(tot) |>
    mean()
}

#' Calcola i guadagni del mese con metadato di stima
#'
#' Restituisce il movimento positivo più grande del mese corrente (lo stipendio).
#' Se non è ancora presente alcun guadagno (stipendio non ancora registrato),
#' ripieg sulla media dei massimi degli ultimi 3 mesi completi e segnala la stima.
#'
#' @param con Connessione al database.
#' @param includi_ignorati Se \code{TRUE}, include i record marcati come ignorati.
#' @return Lista con elementi:
#'   \describe{
#'     \item{valore}{Numeric. Importo guadagni (reale o stimato).}
#'     \item{stimato}{Logical. \code{TRUE} se il valore è una stima.}
#'   }
#' @seealso [guadagni_del_mese()], [media_ultimi_3_mesi()]

guadagni_info <- function(
  con,
  includi_ignorati = FALSE,
  solo_stipendio = TRUE
) {
  periodo <- periodo_attuale(con)
  da <- periodo$da
  a <- periodo$a

  tot <- tbl(con, "movimenti") |>
    filter(
      importo > 0,
      data_valuta >= !!da,
      data_valuta < !!a,
      includi_ignorati | !ignora
    )

  if (solo_stipendio) {
    tot <- tot |>
      summarise(tot = max(importo, na.rm = TRUE)) |>
      pull(tot)
  } else {
    tot <- tot |>
      summarise(tot = sum(importo, na.rm = TRUE)) |>
      pull(tot)
  }

  stimato <- is.na(tot) || tot == 0

  if (stimato) {
    tot <- media_ultimi_3_mesi(con, includi_ignorati)
  }

  list(valore = coalesce(tot, 0), stimato = stimato)
}

#' Calcola i guadagni del mese di calendario corrente
#'
#' Restituisce il movimento positivo più grande del mese corrente (lo stipendio).
#' Se non è ancora presente alcun guadagno, restituisce la media dei massimi
#' degli ultimi 3 mesi (vedi [guadagni_info()] per ottenere anche il flag di stima).
#'
#' @param con Connessione al database (oggetto DBI connection).
#' @param includi_ignorati Se \code{TRUE}, include i record marcati come ignorati.
#' @return Valore numerico: guadagni del mese (reali o stimati).
#' @seealso [guadagni_info()], [periodo_attuale()]

guadagni_del_mese <- function(
  con,
  includi_ignorati = FALSE,
  solo_stipendio = TRUE
) {
  guadagni_info(con, includi_ignorati, solo_stipendio)$valore
}
