#' Grafico dell'andamento del saldo disponibile
#'
#' Genera un grafico a linee che mostra l'evoluzione del saldo disponibile
#' nel tempo, con una linea di tendenza smoothed.
#'
#' @param con Connessione al database (oggetto DBI connection).
#' @param includi_ignorati Se `TRUE`, include anche i record marcati come ignorati.
#'   Default `FALSE`.
#'
#' @return Un oggetto ggplot che mostra l'andamento del saldo disponibile
#'   per data, con etichette in euro.
#'
#' @examples
#' \dontrun{
#' con <- db_connect()
#' grafico_saldo(con)
#' }

grafico_saldo <- function(con, includi_ignorati = TRUE) {
  tbl(con, "movimenti") |>
    filter(includi_ignorati | !ignora) |>
    select(data_valuta, disponibile) |>
    arrange(data_valuta) |>
    collect() |>
    group_by(data_valuta) |>
    summarise(disponibile = last(disponibile)) |>
    ggplot(aes(data_valuta, disponibile)) +
    geom_line() +
    geom_point() +
    scale_y_continuous(labels = scales::label_currency(prefix = "€")) +
    geom_smooth() +
    labs(x = "Data", y = "Saldo disponibile")
}
