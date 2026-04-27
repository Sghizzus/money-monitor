#' Grafico dell'andamento del saldo disponibile
#'
#' Genera un grafico a linee che mostra l'evoluzione del saldo disponibile
#' nel tempo, con una linea di tendenza smoothed.
#'
#' @param con Connessione al database (oggetto DBI connection).
#'
#' @return Un oggetto ggplot che mostra l'andamento del saldo disponibile
#'   per data, con etichette in euro.
#'
#' @examples
#' \dontrun{
#' con <- db_connect()
#' grafico_saldo(con)
#' }

grafico_saldo <- function(con) {
  tbl(con, "movimenti") |>
    collect() |>
    arrange(data) |>
    group_by(data) |>
    summarise(disponibile = last(disponibile)) |>
    ggplot(aes(data, disponibile)) +
    geom_line() +
    geom_point() +
    scale_y_continuous(labels = scales::label_currency(prefix = "€")) +
    geom_smooth() +
    labs(x = "Data", y = "Saldo disponibile") +
    theme_minimal()
}
