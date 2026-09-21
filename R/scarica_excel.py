"""
scarica_excel.py
================
Scarica il file Excel dei movimenti da BBVA usando Playwright con stealth.
Viene chiamato da run.R tramite system().

Variabili d'ambiente richieste (stesse di run.R):
    DB_PWD       - password Supabase (per il polling OTP)
    BBVA_USER    - username BBVA
    BBVA_PASSWORD- password BBVA

Dipendenze (installare con: pip install -r requirements.txt):
    playwright, playwright-stealth, psycopg2-binary
    + dopo l'installazione: python -m playwright install chromium
"""

import os
import sys
import time
import random
from pathlib import Path
import psycopg2
from playwright.sync_api import sync_playwright
from playwright_stealth import Stealth
from dotenv import load_dotenv

# Carica le variabili d'ambiente da .Renviron (stesso file usato da R)
load_dotenv(".Renviron")


# ---------------------------------------------------------------------------
# Configurazione
# ---------------------------------------------------------------------------

DB_CONFIG = {
    "dbname": "postgres",
    "host": "aws-1-eu-west-3.pooler.supabase.com",
    "port": 5432,
    "user": "postgres.pntkrsospmzbuyelbmac",
    "password": os.environ.get("DB_PWD", ""),
}

PROFILE_DIR = Path(os.environ.get("LOCALAPPDATA", Path.home())) / "bbva-scraper-profile"


# ---------------------------------------------------------------------------
# Polling OTP
# ---------------------------------------------------------------------------


def poll_otp(conn, after_timestamp, timeout_sec=120, interval_sec=5):
    """Attende e restituisce il codice OTP dalla tabella otp_relay su Supabase."""
    print("[OTP] In attesa del codice OTP...")
    start = time.time()
    attempt = 0

    while time.time() - start < timeout_sec:
        attempt += 1
        with conn.cursor() as cur:
            cur.execute(
                """
                SELECT id, otp_code FROM otp_relay
                WHERE created_at > %s
                ORDER BY created_at DESC
                LIMIT 1
                """,
                (after_timestamp,),
            )
            row = cur.fetchone()

        if row:
            record_id, otp_code = row
            with conn.cursor() as cur:
                cur.execute("DELETE FROM otp_relay WHERE id = %s", (record_id,))
                cur.execute(
                    "DELETE FROM otp_relay WHERE created_at < now() - interval '5 minutes'"
                )
            conn.commit()
            print(f"[OTP] Codice ricevuto dopo {attempt} tentativi.")
            return otp_code

        if attempt % 6 == 0:
            elapsed = round(time.time() - start)
            print(f"[OTP] Ancora in attesa... ({elapsed}s trascorsi)")

        time.sleep(interval_sec)

    raise TimeoutError(f"OTP non ricevuto entro {timeout_sec} secondi.")


# ---------------------------------------------------------------------------
# Interazioni umane
# ---------------------------------------------------------------------------


def human_move(page):
    """Simula un movimento del mouse verso coordinate casuali."""
    steps = random.randint(5, 12)
    target_x = random.uniform(100, 1800)
    target_y = random.uniform(100, 900)
    for i in range(1, steps + 1):
        page.mouse.move(
            target_x * i / steps + random.uniform(-10, 10),
            target_y * i / steps + random.uniform(-10, 10),
        )
        time.sleep(random.uniform(0.01, 0.05))


def human_type(page, selector, text):
    """Digita testo carattere per carattere con ritmo variabile."""
    page.focus(selector)
    for char in text:
        page.keyboard.type(char, delay=random.uniform(50, 200))


# ---------------------------------------------------------------------------
# Scraping principale
# ---------------------------------------------------------------------------


def scarica_excel():
    conn = psycopg2.connect(**DB_CONFIG)

    try:
        with sync_playwright() as pw:
            # Profilo persistente: mantiene cookie e localStorage tra le sessioni
            context = pw.chromium.launch_persistent_context(
                user_data_dir=str(PROFILE_DIR),
                headless=False,  # non-headless: meno rilevabile
                args=[
                    "--disable-blink-features=AutomationControlled",
                    "--window-size=1920,1080",
                    "--no-first-run",
                    "--disable-extensions",
                ],
                locale="it-IT",
                timezone_id="Europe/Rome",
                viewport={"width": 1920, "height": 1080},
                accept_downloads=True,
            )
            context.set_default_timeout(30_000)

            page = context.new_page()

            # Applica tutte le patch stealth (canvas, WebGL, navigator, ecc.)
            Stealth(
                navigator_languages_override=("it-IT", "it"),
                navigator_platform_override="Win32",
            ).apply_stealth_sync(page)

            # Naviga al sito
            page.goto("https://www.bbva.it")
            time.sleep(random.uniform(1, 2))

            # Banner cookie (opzionale)
            try:
                page.click("button.cookiesgdpr__rejectbtn", timeout=5000)
                time.sleep(random.uniform(0.5, 1.5))
            except Exception:
                print("[INFO] Banner cookie non trovato, procedo.")

            time.sleep(random.uniform(1, 2.5))

            # Apro la pagina di login
            page.click(
                "#header-persone-experience-fragment-master-jcr-content-header > "
                "div.header__main.container-header > nav > ul > "
                "li.header__actions__list.header__actions--tablet-left > div > "
                "div.header__access__wrapper.header__access__wrapper--tablet > a"
            )
            time.sleep(random.uniform(1.5, 3))

            # Inserisco le credenziali con ritmo umano
            human_move(page)
            human_type(page, "#input-user", os.environ["BBVA_USER"])
            time.sleep(random.uniform(0.5, 1.5))
            human_move(page)
            human_type(page, "#input-password", os.environ["BBVA_PASSWORD"])
            time.sleep(random.uniform(1, 2))

            # Segno il timestamp pre-login per il polling OTP
            from datetime import datetime, timezone

            login_time = datetime.now(timezone.utc)

            # Click sul pulsante di login
            page.click(
                "#index-router > signin-view > div > div > "
                "div.col-md-7.padding-left_0 > signin-form > form > "
                "div.flex.flex-align-center.margin-bottom-xsmall > haunted-button"
            )

            # Attendo che BBVA processi il login
            time.sleep(5)

            # Controllo se la banca ha mostrato un errore (blocco)
            error_el = page.query_selector("[id^='m-alert'] .m-alert__content > p")
            if error_el:
                error_text = error_el.inner_text().strip()
                if error_text:
                    raise RuntimeError(f"Blocco banca: {error_text}")

            # Attendo OTP da Tasker via Supabase
            otp = poll_otp(conn, login_time)

            # Inserisco OTP
            page.fill("#input-otpCode", otp)
            time.sleep(random.uniform(1, 3))

            # Confermo OTP
            page.click(
                "#index-router > two-factor-auth-view > div > div > div > "
                "two-factor-challenge-form > form > div > haunted-button"
            )
            time.sleep(random.uniform(6, 8))

            # Navigo ai movimenti del conto
            page.click(
                "#aria-product-name-ES9766002000000000000000000651177505XXXXXXXXX "
                "> haunted-link"
            )
            time.sleep(random.uniform(5, 7))

            # Apro il menu di download
            page.click(
                "#uid-5c2701d4 > "
                "accounts-es9766002000000000000000000651177505xxxxxxxxx > div > "
                "div.t-main-row__container.margin-top-xsmall > div > "
                "accounts-transactions > div > haunted-transactions > div > "
                "transactions-links > div > ul > li:nth-child(1) > haunted-link"
            )
            time.sleep(random.uniform(2, 3))

            # Scarico Excel e attendo il completamento del download
            print("[INFO] Avvio download Excel...")
            with page.expect_download(timeout=30_000) as download_info:
                page.click("#downloadTransactionsPDFDocument > haunted-button")

            download = download_info.value
            dest = Path.cwd() / download.suggested_filename
            download.save_as(dest)

            context.close()

        print(f"[INFO] Excel scaricato con successo: {dest.name}")
        return str(dest)

    finally:
        conn.close()


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    try:
        scarica_excel()
        sys.exit(0)
    except Exception as e:
        print(f"[ERROR] {e}", file=sys.stderr)
        sys.exit(1)
