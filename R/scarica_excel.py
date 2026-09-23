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


def js_click_text(page, text, partial=False):
    """Trova il primo elemento foglia con il testo dato attraverso
    tutti i shadow DOM annidati e lo clicca.
    Se partial=True, cerca testo che contiene la stringa (utile per IBAN)."""
    match_fn = (
        "e.textContent.includes('" + text + "')"
        if partial
        else "e.textContent.trim() === '" + text + "'"
    )
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
            e => {match_fn} && e.children.length === 0
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

    downloads_dir = Path.home() / "Downloads"
    download_start = None

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
                downloads_path=str(Path.cwd()),
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
            cdp.send("DOM.enable")

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

            def cdp_viewport_click(node_id):
                """Scrolla l'elemento in vista, ottiene coordinate viewport
                e usa page.mouse.click() che è più trusted di Input.dispatchMouseEvent."""
                remote = cdp.send("DOM.resolveNode", {"nodeId": node_id})
                result = cdp.send(
                    "Runtime.callFunctionOn",
                    {
                        "objectId": remote["object"]["objectId"],
                        "functionDeclaration": """function() {
                        this.scrollIntoView({block:'center', inline:'center'});
                        const rect = this.getBoundingClientRect();
                        return {x: rect.left + rect.width / 2, y: rect.top + rect.height / 2};
                    }""",
                        "returnByValue": True,
                    },
                )
                coords = result["result"]["value"]
                cx, cy = coords["x"], coords["y"]
                # page.mouse.click() è più trusted di Input.dispatchMouseEvent —
                # esegue move + down + up e i browser lo accettano per download
                page.mouse.click(cx, cy)
                return cx, cy

            def cdp_mouse_click(selector, timeout=20):
                """Trova un elemento via CDP e fa click con coordinate viewport."""
                node_id = cdp_find(selector, timeout)
                cx, cy = cdp_viewport_click(node_id)
                print(f"[INFO] cdp_mouse_click '{selector}' @ ({cx:.0f}, {cy:.0f})")

            # Step 1: click sulla card del conto
            cdp_mouse_click(
                "#aria-product-name-ES9766002000000000000000000651177505XXXXXXXXX > haunted-link span.c-link"
            )
            time.sleep(random.uniform(5, 7))

            # Step 2: click sull'IBAN per arrivare alla lista movimenti
            clicked_iban = False
            for attempt in range(20):
                search = cdp.send(
                    "DOM.performSearch",
                    {"query": "IT56", "includeUserAgentShadowDOM": True},
                )
                count = search.get("resultCount", 0)
                if count > 0:
                    nodes = cdp.send(
                        "DOM.getSearchResults",
                        {
                            "searchId": search["searchId"],
                            "fromIndex": 0,
                            "toIndex": count,
                        },
                    )
                    for nid in nodes["nodeIds"]:
                        try:
                            remote = cdp.send("DOM.resolveNode", {"nodeId": nid})
                            obj_id = remote["object"]["objectId"]
                            # Scrolla in vista e clicca via JS (funziona anche fuori viewport)
                            cdp.send(
                                "Runtime.callFunctionOn",
                                {
                                    "objectId": obj_id,
                                    "functionDeclaration": "function() { let el = this; if (el.nodeType === 3) el = el.parentElement; while (el && typeof el.click !== 'function') el = el.parentElement; if (el) { el.scrollIntoView({block:'center'}); el.click(); } }",
                                },
                            )
                            print("[INFO] Cliccato IBAN via scrollIntoView+click")
                            clicked_iban = True
                        except Exception:
                            continue
                cdp.send("DOM.discardSearchResults", {"searchId": search["searchId"]})
                if clicked_iban:
                    break
                time.sleep(1)
            if not clicked_iban:
                raise RuntimeError("IBAN non trovato o non cliccabile entro 20s")

            # Attendo caricamento pagina movimenti
            time.sleep(random.uniform(8, 12))

            # Cerco e clicco il pulsante "
            #
            #
            # " con CDP DOM.performSearch
            def cdp_search_click(query, last=False):
                """Cerca testo nel DOM e clicca il parent element via scrollIntoView+click."""
                s = cdp.send(
                    "DOM.performSearch",
                    {"query": query, "includeUserAgentShadowDOM": True},
                )
                if s.get("resultCount", 0) == 0:
                    raise RuntimeError(f"'{query}' non trovato nel DOM")
                ns = cdp.send(
                    "DOM.getSearchResults",
                    {
                        "searchId": s["searchId"],
                        "fromIndex": 0,
                        "toIndex": s["resultCount"],
                    },
                )
                node_ids = list(reversed(ns["nodeIds"])) if last else ns["nodeIds"]
                for nid in node_ids:
                    try:
                        remote = cdp.send("DOM.resolveNode", {"nodeId": nid})
                        result = cdp.send(
                            "Runtime.callFunctionOn",
                            {
                                "objectId": remote["object"]["objectId"],
                                "functionDeclaration": """function() {
                                let el = this;
                                if (el.nodeType === 3) el = el.parentElement;
                                if (!el) return null;
                                el.scrollIntoView({block:'center', inline:'center'});
                                const rect = el.getBoundingClientRect();
                                return {x: rect.left + rect.width/2, y: rect.top + rect.height/2};
                            }""",
                                "returnByValue": True,
                            },
                        )
                        coords = result["result"].get("value")
                        if coords and coords["x"] > 0 and 0 < coords["y"] < 1080:
                            cx, cy = coords["x"], coords["y"]
                            for evt in ["mousePressed", "mouseReleased"]:
                                cdp.send(
                                    "Input.dispatchMouseEvent",
                                    {
                                        "type": evt,
                                        "x": cx,
                                        "y": cy,
                                        "button": "left",
                                        "clickCount": 1,
                                    },
                                )
                            print(f"[INFO] Cliccato '{query}' @ ({cx:.0f}, {cy:.0f})")
                            cdp.send(
                                "DOM.discardSearchResults", {"searchId": s["searchId"]}
                            )
                            return
                    except Exception:
                        continue
                cdp.send("DOM.discardSearchResults", {"searchId": s["searchId"]})
                raise RuntimeError(f"'{query}' trovato ma non cliccabile")

            # Primo click "Scarica in Excel": apre la modale
            print("[INFO] Apro modale download...")
            for attempt in range(15):
                try:
                    cdp_search_click("Scarica in Excel")
                    break
                except RuntimeError:
                    if attempt == 14:
                        raise
                    time.sleep(2)

            # Attendo che la modale sia visibile
            time.sleep(random.uniform(3, 5))

            # Handler download registrato su TUTTE le pagine del context
            # (BBVA apre il download su una nuova tab web.bbva.it)
            dest = Path.cwd() / "movimenti.xlsx"
            download_done = [False]

            def on_download(download):
                try:
                    download.save_as(str(dest))
                    download_done[0] = True
                    print(f"[INFO] Download salvato: {dest.name}")
                except Exception as e:
                    print(f"[WARN] Errore salvataggio: {e}")

            page.on("download", on_download)
            context.on("page", lambda p: p.on("download", on_download))

            # Secondo click: avvia il download
            print("[INFO] Avvio download Excel...")
            download_start = time.time()

            # Diagnostica: mostra coordinate del pulsante prima di cliccare
            try:
                nid = cdp_find(
                    "#downloadTransactionsPDFDocument > haunted-button", timeout=5
                )
                remote = cdp.send("DOM.resolveNode", {"nodeId": nid})
                diag = cdp.send(
                    "Runtime.callFunctionOn",
                    {
                        "objectId": remote["object"]["objectId"],
                        "functionDeclaration": """function() {
                        this.scrollIntoView({block:'center'});
                        const r = this.getBoundingClientRect();
                        return {x: r.left + r.width/2, y: r.top + r.height/2, w: r.width, h: r.height};
                    }""",
                        "returnByValue": True,
                    },
                )
                print(f"[DEBUG] Posizione pulsante: {diag['result']['value']}")
            except Exception as e:
                print(f"[DEBUG] Pulsante non trovato: {e}")

            try:
                cdp_mouse_click("#downloadTransactionsPDFDocument > haunted-button")
                print(
                    "[INFO] Click su #downloadTransactionsPDFDocument > haunted-button"
                )
            except Exception:
                pass

            # Attende il download — controlla handler e qualsiasi file nuovo in cwd
            print("[INFO] Attendo completamento download...")
            cwd = Path.cwd()
            IGNORE_EXT = {
                ".py",
                ".R",
                ".bat",
                ".lock",
                ".json",
                ".md",
                ".txt",
                ".log",
                ".sql",
                ".Rproj",
            }
            new_file = None
            for _ in range(60):
                if download_done[0]:
                    new_file = dest
                    break
                # Playwright salva con UUID in cwd (downloads_path) — cerca qualsiasi file nuovo
                candidates = [
                    f
                    for f in cwd.iterdir()
                    if f.is_file()
                    and f.stat().st_mtime > download_start
                    and f.suffix not in IGNORE_EXT
                    and not f.name.startswith(".")
                ]
                if candidates:
                    new_file = max(candidates, key=lambda f: f.stat().st_mtime)
                    print(f"[INFO] File trovato: {new_file.name}")
                    time.sleep(2)
                    break
                time.sleep(1)

    except Exception as e:
        if download_start is None:
            raise
        print(f"[INFO] Playwright chiuso: {type(e).__name__}")

    if not new_file or not new_file.exists():
        raise RuntimeError("Timeout: nessun file scaricato entro 60 secondi")

    # Rinomina in movimenti.xlsx se ha un nome UUID o un'estensione diversa
    dest = Path.cwd() / "movimenti.xlsx"
    if new_file != dest:
        import shutil

        shutil.copy2(str(new_file), str(dest))
        new_file.unlink(missing_ok=True)

    print(f"[INFO] Excel scaricato con successo: {dest.name}")
    conn.close()
    return str(dest)


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
