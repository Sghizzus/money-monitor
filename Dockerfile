FROM rocker/r-ver:4.6.1

# Dipendenze di sistema:
# - libpq-dev: per RPostgres
# - chromium: browser headless per rvest/chromote
# - ca-certificates, fonts: necessari per navigazione HTTPS e rendering
RUN apt-get update && apt-get install -y --no-install-recommends \
    libpq-dev \
    chromium \
    ca-certificates \
    fonts-liberation \
    && rm -rf /var/lib/apt/lists/*

# Indica a chromote dove trovare Chrome
ENV CHROMOTE_CHROME=/usr/bin/chromium

# Crea la cartella Downloads (usata come destinazione temporanea del file Excel)
RUN mkdir -p /root/Downloads

WORKDIR /app

# Installa renv — layer separato, non cambia spesso
RUN R -e "install.packages('renv', repos = 'https://packagemanager.posit.co/cran/latest')"

# Ripristina i pacchetti dal lockfile.
# Copiando solo renv.lock + activate.R prima del resto del codice,
# Docker riutilizza questo layer finché il lockfile non cambia.
COPY renv.lock renv.lock
COPY renv/activate.R renv/activate.R
COPY renv/settings.json renv/settings.json
RUN R -e "renv::restore()"

# Copia il resto del progetto
COPY . .

CMD ["Rscript", "run.R"]
