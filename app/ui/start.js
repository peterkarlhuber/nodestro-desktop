// The window's own page while the backend starts, and when it cannot start or stops.
// The shell opens it as index.html, or as index.html#error=<code>&detail=<text> after a failure.
const TEXTS = {
  en: {
    starting: "Nodestro is starting…",
    start_failed: "Nodestro could not start.",
    stopped: "Nodestro stopped unexpectedly. Close this window and start Nodestro again.",
    log: "Details are in the log file:",
  },
  de: {
    starting: "Nodestro wird gestartet …",
    start_failed: "Nodestro konnte nicht gestartet werden.",
    stopped: "Nodestro wurde unerwartet beendet. Schließen Sie dieses Fenster und starten Sie Nodestro erneut.",
    log: "Einzelheiten stehen in der Protokolldatei:",
  },
  es: {
    starting: "Nodestro se está iniciando…",
    start_failed: "No se pudo iniciar Nodestro.",
    stopped: "Nodestro se detuvo de forma inesperada. Cierre esta ventana e inicie Nodestro de nuevo.",
    log: "Los detalles están en el archivo de registro:",
  },
  fr: {
    starting: "Démarrage de Nodestro…",
    start_failed: "Nodestro n’a pas pu démarrer.",
    stopped: "Nodestro s’est arrêté de manière inattendue. Fermez cette fenêtre et redémarrez Nodestro.",
    log: "Les détails se trouvent dans le fichier journal :",
  },
  it: {
    starting: "Avvio di Nodestro…",
    start_failed: "Impossibile avviare Nodestro.",
    stopped: "Nodestro si è arrestato in modo imprevisto. Chiudere questa finestra e avviare di nuovo Nodestro.",
    log: "I dettagli sono nel file di log:",
  },
  "pt-BR": {
    starting: "O Nodestro está iniciando…",
    start_failed: "Não foi possível iniciar o Nodestro.",
    stopped: "O Nodestro parou inesperadamente. Feche esta janela e inicie o Nodestro novamente.",
    log: "Os detalhes estão no arquivo de log:",
  },
};

function language() {
  for (const wanted of navigator.languages || [navigator.language || "en"]) {
    if (TEXTS[wanted]) return wanted;
    const base = wanted.split("-")[0];
    if (base === "pt") return "pt-BR";
    if (TEXTS[base]) return base;
  }
  return "en";
}

function show() {
  const texts = TEXTS[language()];
  document.documentElement.lang = language();
  const params = new URLSearchParams(location.hash.slice(1));
  const error = params.get("error");
  document.getElementById("status").textContent = error ? texts[error] || texts.start_failed : texts.starting;
  const detail = document.getElementById("detail");
  const lines = [params.get("detail"), params.get("log") ? `${texts.log}\n${params.get("log")}` : null].filter(Boolean);
  detail.textContent = lines.join("\n\n");
  detail.hidden = lines.length === 0;
}

window.addEventListener("hashchange", show);
show();
