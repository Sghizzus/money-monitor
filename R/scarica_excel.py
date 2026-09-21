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

            # Navigo ai movimenti del conto — estrae l'href e naviga direttamente
            # (il click viene intercettato dal router SPA e non funziona)

            # Attendo che la card del conto sia presente nel DOM (max 20s)
            # Cerca haunted-link figlio diretto della card, poi l'<a> dentro il suo shadowRoot
            account_href = None
            for _ in range(20):
                account_href = page.evaluate("""(() => {
                    const deepQuery = (root, sel) => {
                        const el = root.querySelector(sel);
                        if (el) return el;
                        for (const child of root.querySelectorAll('*')) {
                            if (child.shadowRoot) {
                                const found = deepQuery(child.shadowRoot, sel);
                                if (found) return found;
                            }
                        }
                        return null;
                    };
                    // Trova haunted-link direttamente dal documento (deepQuery attraversa tutti i shadow root)
                    // Come fa il selettore R: #aria-product-name-... > haunted-link
                    const hauntedLink = deepQuery(document, 'haunted-link');
                    if (!hauntedLink) return null;
                    // haunted-link ha un <a> nel suo shadowRoot
                    const a = hauntedLink.shadowRoot
                        ? hauntedLink.shadowRoot.querySelector('a[href]')
                        : hauntedLink.querySelector('a[href]');
                    if (a) return a.href;
                    // Fallback: prova href dell'elemento stesso
                    return hauntedLink.getAttribute('href') || null;
                })()""")
                if account_href:
                    break
                time.sleep(1)

            if not account_href:
                # Diagnostica: mostra tutti gli id nel DOM
                ids = page.evaluate("""(() => {
                    const deepAll = (root) => {
                        const results = [];
                        root.querySelectorAll('[id]').forEach(el => results.push(el.id));
                        root.querySelectorAll('*').forEach(child => {
                            if (child.shadowRoot) results.push(...deepAll(child.shadowRoot));
                        });
                        return results;
                    };
                    return deepAll(document).filter(id => id.includes('product') || id.includes('account') || id.includes('aria'));
                })()""")
                print("[DEBUG] ID rilevanti nel DOM:", ids[:20])

                # Diagnostica: children dirette della card e del suo parent
                struttura = page.evaluate("""(() => {
                    const deepQuery = (root, sel) => {
                        const el = root.querySelector(sel);
                        if (el) return el;
                        for (const child of root.querySelectorAll('*')) {
                            if (child.shadowRoot) {
                                const found = deepQuery(child.shadowRoot, sel);
                                if (found) return found;
                            }
                        }
                        return null;
                    };
                    const card = deepQuery(document, '[id^="aria-product-name"]');
                    if (!card) return {error: 'card non trovata'};
                    const info = (el) => ({
                        tag: el.tagName, id: el.id || '',
                        href: el.getAttribute('href') || '',
                        hasShadow: !!el.shadowRoot,
                        childCount: el.children.length
                    });
                    return {
                        card: info(card),
                        parent: info(card.parentElement),
                        cardChildren: Array.from(card.children).map(info),
                        parentChildren: Array.from(card.parentElement.children).map(info)
                    };
                })()""")
                print("[DEBUG] Struttura DOM intorno alla card:", struttura)

                raise RuntimeError("Link al conto non trovato nella dashboard")

            print(f"[INFO] Navigo ai movimenti: {account_href}")
            page.goto(account_href)
            time.sleep(random.uniform(5, 7))

            # Apro il menu di download
            # Diagnostica: trova il testo dei link di download disponibili
            testi_download = page.evaluate("""(() => {
                const deepAll = (root) => {
                    const results = [];
                    root.querySelectorAll('*').forEach(el => {
                        if (el.children.length === 0 && el.textContent.trim())
                            results.push(el.textContent.trim());
                        if (el.shadowRoot) results.push(...deepAll(el.shadowRoot));
                    });
                    return results;
                };
                return deepAll(document).filter(t => t.length < 40);
            })()""")
            print("[DEBUG] Testi nella pagina movimenti:", testi_download[:20])

            js_click(page, "transactions-links haunted-link")
            time.sleep(random.uniform(2, 3))

            # Scarico Excel
            print("[INFO] Avvio download Excel...")
            with page.expect_download(timeout=30_000) as download_info:
                js_click_text(page, "Excel")

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
