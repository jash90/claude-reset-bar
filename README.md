<img src="assets/icon_128.png" align="right" width="128" alt="">

# ClaudeResetBar

Ikona w pasku menu / zasobniku systemowym, która pokazuje zużycie limitów Claude i **powiadamia w momencie, gdy limit się zresetuje** — żebyś nie zgadywał, kiedy możesz wrócić do pracy.

- **Zero konfiguracji na start.** Czyta token, który Claude Code już zapisał na Twojej maszynie.
- **Kilka kont naraz.** Konto z Claude Code plus dowolna liczba dodatkowych, każde z własnym wierszem.
- **macOS, Windows, Linux.** Jedna binarka na system, bez runtime'u i bez instalatora.

```
● ty@example.com
   5h: 39% — reset za 15m (pon. 11:29)
   7d: 23% — reset za 5d 13h (niedz. 00:59)
```

## Instalacja

Pobierz paczkę dla swojego systemu z [Releases](../../releases).

**macOS** — rozpakuj i przeciągnij `ClaudeResetBar.app` do `/Applications`. Aplikacja nie jest podpisana certyfikatem Apple, więc przy pierwszym uruchomieniu Gatekeeper ją zablokuje: kliknij prawym → *Otwórz*, albo w *Ustawienia → Prywatność i ochrona* potwierdź *Otwórz mimo to*.

**Windows** — rozpakuj i uruchom `claude-reset-bar.exe`. SmartScreen pokaże ostrzeżenie o nieznanym wydawcy (brak podpisu): *Więcej informacji* → *Uruchom mimo to*.

**Linux** — rozpakuj i uruchom binarkę. W paczce jest `claude-reset-bar.desktop` i ikona; skopiuj je do `~/.local/share/applications/` i `~/.local/share/icons/`, jeśli chcesz mieć wpis w menu. Na GNOME zasobnik systemowy wymaga rozszerzenia [AppIndicator](https://extensions.gnome.org/extension/615/appindicator-support/).

### Autostart

- **macOS** — *Ustawienia systemowe → Ogólne → Elementy logowania* → dodaj aplikację.
- **Windows** — `Win+R`, `shell:startup`, wrzuć skrót do `.exe`.
- **Linux** — skopiuj `claude-reset-bar.desktop` do `~/.config/autostart/`.

## Skąd bierze dane

Kolejność jest taka:

1. **Token OAuth zapisany przez Claude Code.** Na Windows i Linuksie leży w `~/.claude/.credentials.json`, na macOS w Keychainie (`Claude Code-credentials`). Tym tokenem odpytywany jest `api.anthropic.com/api/oauth/usage`. Nic nie musisz podawać.
2. **Dodatkowe konta przez `sessionKey`** — opcjonalnie, dla kont, na które nie jesteś zalogowany w Claude Code.

Token jest tylko odczytywany. Aplikacja **nie używa refresh tokena** — samodzielne odświeżanie unieważniłoby sesję Claude Code. Jeśli token wygaśnie, wystarczy uruchomić Claude Code; nowy zostanie podchwycony przy następnym odpytaniu.

Nic nie wychodzi poza Twoją maszynę oprócz zapytań do `api.anthropic.com` i `claude.ai`.

## Kilka kont

Konto zalogowane w Claude Code pojawia się samo. Przełączenie konta przez `/login` podmienia je — poprzedniego nie widać, bo brakuje jego poświadczeń. Żeby widzieć **oba naraz**, dodaj to drugie przez `sessionKey`.

Konfiguracja leży w `~/.config/claude-reset/config.json` i ma format zgodny z CLI [claude-reset](https://github.com/nazarli-shabnam/claude-reset):

```json
{
  "accounts": [
    { "name": "drugie-konto", "session_key": "sk-ant-sid...", "org_id": "uuid" }
  ],
  "check_interval_minutes": 15
}
```

`sessionKey` znajdziesz w DevTools → *Application* → *Cookies* → `claude.ai` → `sessionKey`. Wersja macOS ma pozycję **Dodaj konto…**, która pyta o nazwę i klucz, a `org_id` wykrywa sama. W wersji przenośnej wpisujesz oba pola ręcznie — menu ma pozycję otwierającą plik.

Nie dodawaj przez `sessionKey` konta, na które jesteś zalogowany w Claude Code — pojawi się dwa razy.

## Jak wykrywa reset

Przy każdym odpytaniu porównywany jest znacznik `resets_at` z poprzednim. Przesunięcie do przodu o więcej niż godzinę znaczy, że okno się zresetowało — wtedy leci powiadomienie.

- Pierwszy odczyt po starcie tylko ustawia punkt odniesienia i nigdy nie powiadamia. Reset, który nastąpił przy wyłączonej aplikacji, nie wywoła więc powiadomienia — ale aktualny procent widać od razu.
- Data sprzed 2020 (API potrafi zwrócić epokę) jest odrzucana, żeby nie zatruła porównania.
- Odpytywanie co 15 minut; gdy zapamiętany czas resetu minie, aplikacja dopytuje w ciągu minuty. Każdy znacznik wyzwala to raz, więc nie ma odpytywania w kółko.

## Budowanie ze źródeł

Repozytorium ma dwie implementacje tej samej rzeczy:

| | `src/main.swift` | `cross/main.go` |
|---|---|---|
| Systemy | macOS | macOS, Windows, Linux |
| Zależności | brak (AppKit) | `fyne.io/systray`, `gen2brain/beeep` |
| Tekst obok ikony | tak | tylko macOS |
| Okno „Dodaj konto…" | tak | nie (edycja pliku) |

```bash
./build.sh              # macOS natywnie → build/ClaudeResetBar.app
cd cross && ./build.sh  # bieżący system
cd cross && ./build.sh --all   # + Windows i Linux
./release.sh            # paczki do wydania → dist/
```

Wymagania: Xcode Command Line Tools dla wersji Swift, Go 1.21+ dla przenośnej. macOS buduje się tylko natywnie (CGO/AppKit); Windows i Linux idą kompilacją krzyżową z dowolnego systemu.

Obie wersje mają self-check uruchamiany w trakcie budowania (`--test` w wersji Go): logika wykrywania resetu, formatowanie czasu, generowanie ikon, parsowanie konfiguracji. `--notify` sprawdza, czy powiadomienia przechodzą na danym systemie, bez czekania na prawdziwy reset.

## Podziękowania

Logika wykrywania resetu pochodzi z [claude-reset](https://github.com/nazarli-shabnam/claude-reset) — CLI robiącego to samo, tyle że z powiadomieniami na Slacka. Ten projekt to przeniesienie jej do paska menu i dołożenie ścieżki bez `sessionKey`.

## Licencja

MIT — patrz [LICENSE](LICENSE).

Projekt niezależny, niezwiązany z Anthropic. Korzysta z nieudokumentowanych endpointów, które mogą przestać działać bez zapowiedzi.
