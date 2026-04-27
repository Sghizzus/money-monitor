#' Calcola i guadagni degli ultimi 30 giorni
#'
#' Somma tutti i movimenti con importo positivo (entrate) registrati
#' negli ultimi 30 giorni.
#'
#' @param con Connessione al database (oggetto DBI connection).
#'
#' @return Un valore numerico che rappresenta la somma delle entrate
#'   degli ultimi 30 giorni.
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
      importo > 0
    ) |>
    collect() |>
    filter(data >= today() %m-% days(30)) |>
    summarise(guadagni_del_mese = sum(importo)) |>
    pull(guadagni_del_mese)
}
