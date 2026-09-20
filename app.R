library(shiny)
library(bslib)
library(bsicons)
library(tidyverse)
library(DBI)
library(RPostgres)
library(scales)
library(thematic)
library(lubridate)
library(tidyr)
library(DT)

source("R/db_connect.R")
source("R/guadagni_mese.R")
source("R/calcola_budgets.R")
source("R/budget_giornaliero.R")
source("R/grafico_saldo.R")

fmt_eur <- label_currency(
  prefix = "\u20ac ",
  big.mark = ".",
  decimal.mark = ",",
  accuracy = 0.01
)

mesi_italiani <- c(
  "1" = "Gennaio", "2" = "Febbraio",  "3" = "Marzo",
  "4" = "Aprile",  "5" = "Maggio",    "6" = "Giugno",
  "7" = "Luglio",  "8" = "Agosto",    "9" = "Settembre",
  "10" = "Ottobre","11" = "Novembre", "12" = "Dicembre"
)

tipo_label <- function(tipo, valore) {
  case_when(
    tipo == "fisso"         ~ paste0("Fisso (", fmt_eur(valore), ")"),
    tipo == "perc_guadagni" ~ paste0(valore, "% dei guadagni"),
    tipo == "perc_residuo"  ~ paste0(valore, "% del residuo"),
    .default = tipo
  )
}

# ---- Modal budget (add / edit) ----

modal_budget_dlg <- function() {
  modalDialog(
    title = "Budget",
    size = "m",
    easyClose = TRUE,
    textInput("budget_nome", "Nome"),
    numericInput("budget_ordine", "Ordine (sequenza di applicazione)", value = 99, min = 1, step = 1),
    selectInput("budget_tipo", "Tipo", choices = c(
      "Importo fisso (\u20ac)" = "fisso",
      "% dei guadagni lordi"   = "perc_guadagni",
      "% del residuo precedente" = "perc_residuo"
    )),
    numericInput("budget_valore", "Valore (importo in \u20ac oppure percentuale)", value = 0, min = 0, step = 0.01),
    checkboxInput("budget_accantonamento",
                  "Accantonamento \u2014 nessuna spesa da tracciare (es. risparmio)",
                  value = FALSE),
    footer = tagList(
      modalButton("Annulla"),
      actionButton("btn_salva_budget", "Salva", class = "btn-primary")
    )
  )
}

# ---- UI ----

dashboard_ui <- tagList(
  layout_column_wrap(
    width = 1 / 3,
    fill = FALSE,
    value_box(
      title = "Guadagni del mese",
      value = textOutput("guadagni"),
      theme = "success",
      showcase = bs_icon("graph-up-arrow")
    ),
    value_box(
      title = "Budget spese correnti",
      value = textOutput("budget_spendibile"),
      theme = "primary",
      showcase = bs_icon("wallet2")
    ),
    value_box(
      title = "Budget giornaliero",
      value = textOutput("budget_giorn"),
      theme = "info",
      showcase = bs_icon("calendar-day")
    )
  ),
  card(
    full_screen = TRUE,
    card_header("Andamento saldo"),
    plotOutput("grafico", height = "400px")
  )
)

budget_ui <- tagList(
  card(
    card_header("Ripartizione del mese corrente"),
    DTOutput("tbl_budget_mese")
  ),
  card(
    card_header(
      class = "d-flex align-items-center gap-2",
      "Configurazione budget",
      span(
        class = "ms-auto d-flex gap-2",
        actionButton("btn_add_budget", "Aggiungi",
                     icon = icon("plus"), class = "btn-sm btn-primary"),
        actionButton("btn_edit_budget", "Modifica",
                     icon = icon("pencil"), class = "btn-sm btn-secondary"),
        actionButton("btn_del_budget", "Elimina",
                     icon = icon("trash"), class = "btn-sm btn-danger")
      )
    ),
    DTOutput("tbl_budget_config")
  )
)

movimenti_ui <- layout_sidebar(
  sidebar = sidebar(
    width = 200,
    selectInput("anno", "Anno", choices = NULL),
    selectInput("mese", "Mese", choices = NULL)
  ),
  card(
    full_screen = TRUE,
    card_header("Movimenti"),
    DTOutput("tbl_movimenti")
  )
)

ui <- page_navbar(
  title = "Money Monitor",
  theme = bs_theme(version = 5, preset = "shiny"),
  nav_panel("Dashboard", dashboard_ui),
  nav_panel("Budget",    budget_ui),
  nav_panel("Movimenti", movimenti_ui),
  nav_spacer(),
  nav_item(uiOutput("info_aggiornamento"))
)

# ---- Server ----

server <- function(input, output, session) {
  thematic_shiny()

  con <- db_connect()
  onStop(function() dbDisconnect(con))

  refresh         <- reactiveVal(0)
  budgets_refresh <- reactiveVal(0)
  budget_editing  <- reactiveVal(NULL)  # NULL = add, list = budget row da modificare

  # ---- Info aggiornamento (navbar) ----

  scheduler_timer <- reactiveTimer(60000)

  info_scheduler <- reactive({
    scheduler_timer()
    tryCatch(
      dbGetQuery(con, "SELECT last_run, next_run FROM scheduler WHERE id = 1"),
      error = function(e) data.frame(last_run = NA, next_run = NA)
    )
  })

  fmt_dt <- function(x) {
    if (length(x) == 0 || is.na(x)) return("\u2014")
    format(with_tz(as.POSIXct(x), "Europe/Rome"), "%d/%m %H:%M")
  }

  output$info_aggiornamento <- renderUI({
    info <- info_scheduler()
    tags$small(
      class = "text-muted d-flex align-items-center gap-3 pe-2",
      tags$span(bs_icon("clock-history"), " ", fmt_dt(info$last_run[1])),
      tags$span(bs_icon("arrow-clockwise"), " ", fmt_dt(info$next_run[1]))
    )
  })

  # ---- Reactives budgets ----

  # Budgets attivi, usati per calcoli e dropdown movimenti
  budgets_data <- reactive({
    refresh()
    tbl(con, "budgets") |> filter(attivo) |> arrange(ordine) |> collect()
  })

  # Tutti i budgets per la tabella di configurazione (inclusi inattivi)
  budgets_config_data <- reactive({
    budgets_refresh()
    tbl(con, "budgets") |> arrange(ordine) |> collect()
  })

  # ---- Dashboard ----

  output$guadagni <- renderText({
    refresh()
    fmt_eur(guadagni_del_mese(con))
  })

  output$budget_spendibile <- renderText({
    refresh()
    guadagni <- guadagni_del_mese(con)
    calc     <- calcola_budgets(guadagni, budgets_data())
    spendibile <- if (nrow(calc) == 0) guadagni else last(calc$residuo_dopo)
    fmt_eur(spendibile)
  })

  output$budget_giorn <- renderText({
    refresh()
    fmt_eur(budget_giornaliero(con))
  })

  output$grafico <- renderPlot({
    refresh()
    grafico_saldo(con)
  })

  # ---- Pagina Budget: ripartizione del mese ----

  output$tbl_budget_mese <- renderDT({
    refresh()

    guadagni <- guadagni_del_mese(con)
    calc     <- calcola_budgets(guadagni, budgets_data())

    anno_c <- year(today())
    mese_c <- month(today())

    # Spese assegnate a ciascun budget nel mese corrente
    spese_per_budget <- dbGetQuery(con,
      "SELECT budget_id, SUM(-importo) AS speso
       FROM movimenti
       WHERE EXTRACT(YEAR  FROM data_valuta) = $1
         AND EXTRACT(MONTH FROM data_valuta) = $2
         AND importo < 0
         AND NOT ignora
         AND budget_id IS NOT NULL
       GROUP BY budget_id",
      params = list(anno_c, mese_c)
    )

    # Spese correnti (non assegnate)
    spese_correnti <- dbGetQuery(con,
      "SELECT COALESCE(SUM(-importo), 0) AS speso
       FROM movimenti
       WHERE EXTRACT(YEAR  FROM data_valuta) = $1
         AND EXTRACT(MONTH FROM data_valuta) = $2
         AND importo < 0
         AND NOT ignora
         AND budget_id IS NULL",
      params = list(anno_c, mese_c)
    )$speso

    budget_spendibile <- if (nrow(calc) == 0) guadagni else last(calc$residuo_dopo)

    # Riga per ogni budget configurato
    righe_budget <- calc |>
      left_join(spese_per_budget, by = c("id" = "budget_id")) |>
      mutate(
        Tipo      = tipo_label(tipo, valore),
        Allocato  = importo_calcolato,
        Speso     = if_else(accantonamento, NA_real_, coalesce(speso, 0)),
        Disponibile = if_else(accantonamento, NA_real_, importo_calcolato - coalesce(speso, 0))
      ) |>
      select(Budget = nome, Tipo, Allocato, Speso, Disponibile)

    # Riga spese correnti
    riga_correnti <- tibble(
      Budget      = "Spese correnti",
      Tipo        = "Residuo disponibile",
      Allocato    = budget_spendibile,
      Speso       = spese_correnti,
      Disponibile = budget_spendibile - spese_correnti
    )

    df_mese <- bind_rows(righe_budget, riga_correnti)

    datatable(
      df_mese,
      rownames  = FALSE,
      selection = "none",
      options   = list(dom = "t", pageLength = 100, ordering = FALSE),
      class     = "compact stripe"
    ) |>
      formatCurrency(
        columns  = c("Allocato", "Speso", "Disponibile"),
        currency = "\u20ac ", before = TRUE, digits = 2,
        mark = ".", dec.mark = ","
      ) |>
      formatStyle(
        "Disponibile",
        color = styleInterval(0, c("var(--bs-danger)", "inherit"))
      ) |>
      formatStyle(
        "Budget",
        target = "row",
        fontWeight = styleEqual("Spese correnti", "bold")
      )
  })

  # ---- Pagina Budget: configurazione ----

  output$tbl_budget_config <- renderDT({
    budgets_refresh()

    budgets_config_data() |>
      mutate(
        Tipo        = tipo_label(tipo, valore),
        Accantonamento = if_else(accantonamento, "S\u00ec", "No"),
        Attivo      = if_else(attivo, "S\u00ec", "No")
      ) |>
      select(
        Ordine = ordine, Nome = nome, Tipo,
        Accantonamento, Attivo
      ) |>
      datatable(
        rownames  = FALSE,
        selection = "single",
        options   = list(dom = "t", pageLength = 100, ordering = FALSE),
        class     = "compact stripe"
      )
  })

  # Add
  observeEvent(input$btn_add_budget, {
    budget_editing(NULL)
    showModal(modal_budget_dlg())
    updateTextInput(session,    "budget_nome",           value = "")
    updateNumericInput(session, "budget_ordine",         value = 99)
    updateSelectInput(session,  "budget_tipo",           selected = "fisso")
    updateNumericInput(session, "budget_valore",         value = 0)
    updateCheckboxInput(session,"budget_accantonamento", value = FALSE)
  })

  # Edit
  observeEvent(input$btn_edit_budget, {
    sel <- input$tbl_budget_config_rows_selected
    req(sel)
    b <- budgets_config_data()[sel, ]
    budget_editing(b)
    showModal(modal_budget_dlg())
    updateTextInput(session,    "budget_nome",           value = b$nome)
    updateNumericInput(session, "budget_ordine",         value = b$ordine)
    updateSelectInput(session,  "budget_tipo",           selected = b$tipo)
    updateNumericInput(session, "budget_valore",         value = b$valore)
    updateCheckboxInput(session,"budget_accantonamento", value = b$accantonamento)
  })

  # Delete
  observeEvent(input$btn_del_budget, {
    sel <- input$tbl_budget_config_rows_selected
    req(sel)
    b <- budgets_config_data()[sel, ]
    dbExecute(con, "DELETE FROM budgets WHERE id = $1", list(b$id))
    budgets_refresh(budgets_refresh() + 1)
    refresh(refresh() + 1)
  })

  # Save (insert o update)
  observeEvent(input$btn_salva_budget, {
    b    <- budget_editing()
    nome <- trimws(input$budget_nome)
    req(nchar(nome) > 0)

    if (is.null(b)) {
      dbExecute(con,
        "INSERT INTO budgets (nome, ordine, tipo, valore, accantonamento)
         VALUES ($1, $2, $3, $4, $5)",
        list(nome, input$budget_ordine, input$budget_tipo,
             input$budget_valore, input$budget_accantonamento)
      )
    } else {
      dbExecute(con,
        "UPDATE budgets
         SET nome=$1, ordine=$2, tipo=$3, valore=$4, accantonamento=$5
         WHERE id=$6",
        list(nome, input$budget_ordine, input$budget_tipo,
             input$budget_valore, input$budget_accantonamento, b$id)
      )
    }

    removeModal()
    budgets_refresh(budgets_refresh() + 1)
    refresh(refresh() + 1)
  })

  # ---- Tabella movimenti ----

  movimenti_data <- reactiveVal()

  observe({
    df <- tbl(con, "movimenti") |>
      arrange(desc(data_valuta), desc(id)) |>
      collect()
    movimenti_data(df)
  })

  observe({
    df <- movimenti_data()
    req(df)
    anni <- sort(unique(year(df$data_valuta)), decreasing = TRUE)
    updateSelectInput(session, "anno", choices = anni, selected = year(today()))
  })

  observe({
    df <- movimenti_data()
    req(df, input$anno)

    mesi_disp <- df |>
      filter(year(data_valuta) == as.integer(input$anno)) |>
      pull(data_valuta) |>
      month() |>
      unique() |>
      sort(decreasing = TRUE)

    scelte <- setNames(mesi_disp, mesi_italiani[as.character(mesi_disp)])
    sel    <- if (as.integer(input$anno) == year(today())) month(today()) else max(mesi_disp)
    updateSelectInput(session, "mese", choices = scelte, selected = sel)
  })

  output$tbl_movimenti <- renderDT({
    df      <- movimenti_data()
    budgets <- budgets_data() |> filter(!accantonamento)  # accantonamenti esclusi dal dropdown
    req(df, input$anno, input$mese)

    # Costruisce il <select> per l'assegnazione del budget
    build_budget_select <- function(row_id, current_bid) {
      opts <- paste0(
        sprintf('<option value=""%s>\u2014</option>',
                if (is.na(current_bid)) " selected" else ""),
        paste(
          sprintf('<option value="%d"%s>%s</option>',
                  budgets$id,
                  if_else(!is.na(current_bid) & budgets$id == current_bid,
                          " selected", ""),
                  budgets$nome),
          collapse = ""
        )
      )
      sprintf(
        '<select class="budget-sel form-select form-select-sm" data-id="%d" style="min-width:140px">%s</select>',
        row_id, opts
      )
    }

    df |>
      filter(
        year(data_valuta)  == as.integer(input$anno),
        month(data_valuta) == as.integer(input$mese)
      ) |>
      mutate(
        ignora = sprintf(
          '<input type="checkbox" class="ignora-cb" data-id="%d" %s>',
          id, ifelse(ignora, "checked", "")
        ),
        budget = pmap_chr(list(id, budget_id), build_budget_select)
      ) |>
      select(data_valuta, data, movimento, importo, disponibile,
             osservazioni, budget, ignora) |>
      datatable(
        escape    = FALSE,
        selection = "none",
        rownames  = FALSE,
        options   = list(pageLength = 25),
        callback  = JS("
          table.on('change', '.ignora-cb', function() {
            var id = parseInt($(this).data('id'));
            var checked = $(this).is(':checked');
            Shiny.setInputValue('toggle_ignora', {id: id, valore: checked}, {priority: 'event'});
          });
          table.on('change', '.budget-sel', function() {
            var id  = parseInt($(this).data('id'));
            var val = $(this).val();
            var budget_id = val === '' ? null : parseInt(val);
            Shiny.setInputValue('assegna_budget', {id: id, budget_id: budget_id}, {priority: 'event'});
          });
        ")
      ) |>
      formatCurrency(
        columns  = c("importo", "disponibile"),
        currency = "\u20ac ", before = TRUE,
        digits = 2, mark = ".", dec.mark = ","
      )
  })

  observeEvent(input$toggle_ignora, {
    info <- input$toggle_ignora
    dbExecute(con,
      "UPDATE movimenti SET ignora = $1 WHERE id = $2",
      list(info$valore, info$id)
    )
    refresh(refresh() + 1)
  })

  observeEvent(input$assegna_budget, {
    info <- input$assegna_budget
    if (is.null(info$budget_id)) {
      dbExecute(con, "UPDATE movimenti SET budget_id = NULL WHERE id = $1", list(info$id))
    } else {
      dbExecute(con, "UPDATE movimenti SET budget_id = $1 WHERE id = $2",
                list(info$budget_id, info$id))
    }
    refresh(refresh() + 1)
  })
}

shinyApp(ui, server)
