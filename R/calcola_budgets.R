#' Calcola l'importo di ciascun budget dato i guadagni del mese
#'
#' Applica sequenzialmente i budget configurati. Ogni budget può ridurre
#' il residuo disponibile per i successivi (in base al campo \code{ordine}).
#'
#' @param guadagni Numeric. Guadagni lordi del mese.
#' @param budgets_df Data frame con colonne: id, nome, ordine, tipo, valore, accantonamento.
#'   \code{tipo} può essere:
#'   \describe{
#'     \item{"fisso"}{Importo fisso in €}
#'     \item{"perc_guadagni"}{Percentuale dei guadagni lordi}
#'     \item{"perc_residuo"}{Percentuale del residuo dopo i budget precedenti}
#'   }
#'
#' @return Il data frame di input ordinato per \code{ordine}, con colonne aggiuntive:
#'   \describe{
#'     \item{importo_calcolato}{Importo allocato per questo budget (€)}
#'     \item{residuo_dopo}{Residuo spendibile dopo aver detratto questo budget}
#'   }

calcola_budgets <- function(guadagni, budgets_df) {
  df <- arrange(budgets_df, ordine)

  if (nrow(df) == 0 || is.na(guadagni) || guadagni <= 0) {
    return(mutate(df, importo_calcolato = 0, residuo_dopo = coalesce(guadagni, 0)))
  }

  residuo  <- guadagni
  importi  <- numeric(nrow(df))

  for (i in seq_len(nrow(df))) {
    imp <- switch(df$tipo[i],
      "fisso"         = df$valore[i],
      "perc_guadagni" = guadagni * df$valore[i] / 100,
      "perc_residuo"  = residuo  * df$valore[i] / 100,
      0
    )
    imp       <- max(0, min(imp, residuo))
    importi[i] <- imp
    residuo   <- residuo - imp
  }

  mutate(df,
    importo_calcolato = importi,
    residuo_dopo      = guadagni - cumsum(importi)
  )
}
