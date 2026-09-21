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


def js_click_text(page, text):
    """Trova il primo elemento foglia con il testo esatto dato attraverso
    tutti i shadow DOM annidati e lo clicca.
    Usato per haunted-button il cui contenuto interno è uno <span>, non un <button>."""
    page.evaluate(f"""(() => {{
        const deepAll = (root) => {{
            const results = [];
            root.querySelectorAll('*').forEach(el => {{
                results.push(el);
                if (el.shadowRoot) results.push(...deepAll(el.shadowRoot));
            }});
            return results;
        }};
        const el = deepAll(document).find(
            e => e.textContent.trim() === '{text}' && e.children.length === 0
        );
        if (el) el.click();
        else throw new Error('Elemento con testo "{text}" non trovato');
    }})()""")


def js_click(page, selector):
    """Cerca un elemento CSS attraverso tutti i shadow DOM annidati e lo clicca."""
    page.evaluate(f"""(() => {{
        const deepQuery = (root, sel) => {{
            const el = root.querySelector(sel);
            if (el) return el;
            for (const child of root.querySelectorAll('*')) {{
                if (child.shadowRoot) {{
                    const found = deepQuery(child.shadowRoot, sel);
                    if (found) return found;
                }}
            }}
            return null;
        }};
        const el = deepQuery(document, '{selector}');
        if (el) el.click();
        else throw new Error('Elemento non trovato: {selector}');
    }})()""")


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
    """Digita testo carattere per carattere con ritmo variabile.
    Usa press_sequentially che triggera correttamente gli eventi input/change
    richiesti dai web component Lit/Haunted per aggiornare il loro stato interno."""
    page.locator(selector).press_sequentially(text, delay=random.uniform(80, 180))


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

            from datetime import datetime, timezone

            print("[INFO] Browser aperto — non interagire con la finestra.")

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

            # Controllo se il link di login è presente (timeout breve).
            # Se i cookie del profilo persistente sono ancora validi,
            # BBVA potrebbe non mostrare il login e andare direttamente
            # alla dashboard — in quel caso saltiamo tutto il flusso di login.
            # Se il campo username è già presente siamo già sulla pagina di login
            # (redirect automatico da cookie scaduti o primo accesso).
            # Altrimenti navighiamo direttamente all'URL di login.
            login_needed = page.locator("#input-user").count() == 0

            if login_needed:
                print("[INFO] Login necessario, navigo alla pagina di accesso...")
                page.goto("https://www.bbva.it/nimbus/signin.html")
                time.sleep(random.uniform(1.5, 3))

                # Credenziali con ritmo umano
                human_move(page)
                human_type(page, "#input-user", os.environ["BBVA_USER"])
                time.sleep(random.uniform(0.5, 1.5))
                human_move(page)
                human_type(page, "#input-password", os.environ["BBVA_PASSWORD"])

                # Tab triggera il blur sul campo password, necessario per
                # la validazione Lit che si attiva solo all'uscita dal campo
                page.keyboard.press("Tab")
                time.sleep(random.uniform(0.5, 1))

                login_time = datetime.now(timezone.utc)

                js_click_text(page, "Accedi")

                time.sleep(5)

                # Controllo blocco banca
                error_el = page.query_selector("[id^='m-alert'] .m-alert__content > p")
                if error_el:
                    error_text = error_el.inner_text().strip()
                    if error_text:
                        raise RuntimeError(f"Blocco banca: {error_text}")

                # OTP
                otp = poll_otp(conn, login_time)
                page.locator("#input-otpCode").press_sequentially(
                    otp, delay=random.uniform(80, 180)
                )
                page.keyboard.press("Tab")
                time.sleep(random.uniform(0.5, 1))

                js_click_text(page, "Conferma")
                time.sleep(random.uniform(6, 8))

            else:
                print("[INFO] Cookie validi, già loggato — salto il login.")

            # ---------------------------------------------------------------
            # Navigazione post-login tramite CDP (Chrome DevTools Protocol)
            # CDP con pierce:true è l'unico modo per attraversare shadow DOM
            # annidati in modo affidabile — è lo stesso metodo usato da chromote in R.
            # ---------------------------------------------------------------
            cdp = context.new_cdp_session(page)

            def cdp_find(selector, timeout=20):
                """Trova un elemento usando CDP con pierce:true e restituisce il nodeId."""
                for _ in range(timeout):
                    doc = cdp.send("DOM.getDocument", {"depth": -1, "pierce": True})
                    result = cdp.send(
                        "DOM.querySelector",
                        {
                            "nodeId": doc["root"]["nodeId"],
                            "selector": selector,
                        },
                    )
                    if result.get("nodeId", 0) != 0:
                        return result["nodeId"]
                    time.sleep(1)
                raise RuntimeError(
                    f"CDP: elemento '{selector}' non trovato entro {timeout}s"
                )

            def cdp_click(selector, timeout=20):
                """Clicca un elemento usando CDP, che perfora il shadow DOM con pierce:true."""
                node_id = cdp_find(selector, timeout)
                remote = cdp.send("DOM.resolveNode", {"nodeId": node_id})
                cdp.send(
                    "Runtime.callFunctionOn",
                    {
                        "objectId": remote["object"]["objectId"],
                        "functionDeclaration": "function() { this.click(); }",
                    },
                )

            def cdp_get_href(selector, timeout=20):
                """Estrae l'href di un elemento usando CDP con pierce:true.
                Prova tutto: attributo href, proprietà JS, <a> in shadowRoot/figli."""
                node_id = cdp_find(selector, timeout)
                remote = cdp.send("DOM.resolveNode", {"nodeId": node_id})
                result = cdp.send(
                    "Runtime.callFunctionOn",
                    {
                        "objectId": remote["object"]["objectId"],
                        "functionDeclaration": """function() {
                        return {
                            href: this.href,
                            attrHref: this.getAttribute('href'),
                            attrTarget: this.getAttribute('target'),
                            attrDataHref: this.getAttribute('data-href'),
                            shadowA: this.shadowRoot ? (this.shadowRoot.querySelector('a') || {}).href : null,
                            childA: (this.querySelector('a') || {}).href,
                            allAttrs: Array.from(this.attributes || []).map(a => a.name + '=' + a.value).join(', '),
                            tag: this.tagName,
                            hasShadow: !!this.shadowRoot,
                            innerHTMLPreview: (this.innerHTML || '').slice(0, 300)
                        };
                    }""",
                        "returnByValue": True,
                    },
                )
                info = result.get("result", {}).get("value", {})
                print(f"[DEBUG] haunted-link info: {info}")
                for key in [
                    "href",
                    "attrHref",
                    "attrDataHref",
                    "shadowA",
                    "childA",
                    "attrTarget",
                ]:
                    val = info.get(key)
                    if val and isinstance(val, str) and ("http" in val or "/" in val):
                        return (
                            val
                            if val.startswith("http")
                            else f"https://www.bbva.it{val}"
                        )
                return None

            # Navigo ai movimenti: estraggo href via CDP e navigo con page.goto()
            href = cdp_get_href(
                "#aria-product-name-ES9766002000000000000000000651177505XXXXXXXXX > haunted-link"
            )
            if not href:
                raise RuntimeError("href del conto non trovato (vedi [DEBUG] sopra)")
            print(f"[INFO] Navigo ai movimenti: {href}")
            page.goto(href)
            time.sleep(random.uniform(5, 7))

            # Apro il menu di download (selettore completo dallo script R originale)
            cdp_click(
                "#uid-5c2701d4 > accounts-es9766002000000000000000000651177505xxxxxxxxx > "
                "div > div.t-main-row__container.margin-top-xsmall > div > "
                "accounts-transactions > div > haunted-transactions > div > "
                "transactions-links > div > ul > li:nth-child(1) > haunted-link"
            )
            time.sleep(random.uniform(2, 3))

            # Scarico Excel
            print("[INFO] Avvio download Excel...")
            with page.expect_download(timeout=30_000) as download_info:
                cdp_click("#downloadTransactionsPDFDocument > haunted-button")

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
