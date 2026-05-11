#' Calcola i guadagni del mese corrente
#'
#' Somma tutti i movimenti con importo positivo (entrate) registrati nel mese corrente.
#'
#' @param con Connessione al database (oggetto DBI connection).
#' @param includi_ignorati Se `TRUE`, include anche i record marcati come ignorati.
#'   Default `FALSE`.
#'
#' @return Un valore numerico che rappresenta la somma delle entrate del mese corrente.
#'
#' @examples
#' \dontrun{
#' con <- db_connect()
#' guadagni_del_mese(con)
#' }
#'
#' @export
guadagni_del_mese <- function(con, includi_ignorati = FALSE) {
  tbl(con, "movimenti") |>
    filter(
      importo > 0,
      year(data) == year(today()),
      month(data) == month(today()),
      includi_ignorati | !ignora
    ) |>
    summarise(guadagni_del_mese = sum(importo, na.rm = TRUE)) |>
    pull(guadagni_del_mese)
}
