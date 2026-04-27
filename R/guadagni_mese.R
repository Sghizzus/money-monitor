#' Calcola i guadagni degli ultimi 30 giorni
#'
#' Somma tutti i movimenti con importo positivo (entrate) registrati nel mese corrente.
#'
#' @param con Connessione al database (oggetto DBI connection).
#'
#' @return Un valore numerico che rappresenta la somma delle entrate del mese corrente.
#'
#' @examples
#' \dontrun
#' con <- db_connect()
#' guadagni_del_mese(con)
#' }
#'
#' @export
guadagni_del_mese <- function(con) {
  tbl(con, "movimenti") |>
    filter(
      importo > 0,
      month(data) == month(today())
    ) |>
    summarise(guadagni_del_mese = sum(importo, na.rm = TRUE)) |>
    pull(guadagni_del_mese)
}
