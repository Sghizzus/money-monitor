FROM rocker/r-ver:4.6.1

# Dipendenze di sistema:
# - libpq-dev: per RPostgres
# - chromium: browser headless per rvest/chromote
# - ca-certificates, fonts: necessari per navigazione HTTPS e rendering
RUN apt-get update && apt-get install -y software-properties-common \
    && add-apt-repository -y ppa:xtradeb/apps \
    && apt-get update \
    && apt install -y chromium libpq-dev \
    && rm -rf /var/lib/apt/lists/*

# Indica a chromote dove trovare Chrome
ENV CHROMOTE_CHROME=/usr/bin/chromium

# Crea la cartella Downloads (usata come destinazione temporanea del file Excel)
RUN mkdir -p /root/Downloads

# initialize application project directory
WORKDIR /project
RUN mkdir -p renv

# copy renv infrastructure
COPY renv.lock renv.lock
COPY .Rprofile .Rprofile
COPY renv/activate.R renv/activate.R
COPY renv/settings.json renv/settings.json

# restore R project library
RUN R -s -e "renv::restore()"

# copy application files into image
COPY . .

CMD ["Rscript", "run.R"]
