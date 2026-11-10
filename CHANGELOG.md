# Changelog

All notable changes to **Plume** will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.1.0] - 2026-11-10

### ✨ Improvements & Fixes (FR / EN)
- **FR** :
  - ✨ **Soulignements et bulle de correction en direct dans Apple Mail** : Souligne directement les fautes d'orthographe (rouge), de grammaire (bleu) et de style (ambre) dans la fenêtre de rédaction d'Apple Mail, avec une bulle de correction interactive au survol ou au clic sur le badge.
  - ✨ **Bouton d'activation/désactivation du surlignage sur la pastille flottante** : Nouveau bouton `highlighter` directement sur la pastille flottante pour activer ou masquer à la volée le surlignage dans l'e-mail courant.
  - 🐛 **Correction du remplacement de texte in-place (`AXReplaceRangeWithText`)** : Utilise l'attribut paramétré natif WebKit `AXReplaceRangeWithText` après sélection de la plage exacte afin d'éviter toute duplication de texte ou décalage de mot lors des corrections dans Apple Mail.
  - 🐛 **Correction du blocage du bouton « Envoyer » d'Apple Mail avec Antidote (`Anti-Oups!.appex`)** : Empêche l'extension MailKit `Antidote - Anti-Oups!.appex` de retenir indéfiniment le `completionHandler` d'envoi d'Apple Mail lorsqu'un courriel a été corrigé avec Plume.
  - ⚡ **Optimisation des performances d'Accessibilité** : Filtrage strict des fenêtres non-`AXWindow` et élagage des conteneurs lourds (`AXOutline`, `AXTable`, `AXToolbar`) pour éliminer tout ralentissement lors de la détection des brouillons.
- **EN**:
  - ✨ **Live Inline Underlines & Hover Popover Inside Apple Mail**: Draws color-coded spelling (red), grammar (blue), and style (amber) underlines directly inside Apple Mail's compose window with an interactive quick-fix popover on hover or badge click.
  - ✨ **Inline Highlight Toggle on the Floating Pill**: Added a dedicated `highlighter` toggle button on the floating pill to enable or disable inline underlines in the current email draft with one click.
  - 🐛 **Reliable In-Place Text Replacement (`AXReplaceRangeWithText`)**: Uses WebKit's native `AXReplaceRangeWithText` parameterized attribute on the exact marker range to prevent text duplication or offset drift when applying fixes in Apple Mail.
  - 🐛 **Fixed Apple Mail "Send" Button Freeze with Antidote (`Anti-Oups!.appex`)**: Prevents `Antidote - Anti-Oups!.appex` from holding Apple Mail's `allowMessageSendForSession:completionHandler:` callback indefinitely when an email is corrected with Plume.
  - ⚡ **Accessibility Performance Optimization**: Strictly filters non-`AXWindow` elements and prunes heavy UI containers (`AXOutline`, `AXTable`, `AXToolbar`) to eliminate UI hangs when scanning compose windows.

## [1.0.3] - 2026-11-08

### ✨ Improvements & Fixes (FR / EN)
- **FR** :
  - ✨ **Pastille flottante contextuelle** : La pastille flottante n'apparaît désormais que lorsqu'une fenêtre de rédaction (*Nouveau message* / *Répondre*) est ouverte au premier plan dans Apple Mail, et disparaît automatiquement le reste du temps.
- **EN**:
  - ✨ **Context-Aware Floating Pill**: The floating pill now only appears when an Apple Mail compose/reply window is active in the foreground, and automatically hides everywhere else.

## [1.0.2] - 2026-11-08

### ✨ Improvements & Fixes (FR / EN)
- **FR** :
  - ✨ **Préservation des réponses citées dans Apple Mail** : Ignore automatiquement l'historique cité et la signature lors de l'import (`⌘⇧R`), et conserve intacte la barre de citation (`<blockquote type="cite">`) lors de l'application des corrections (`⌘⇧A`).
  - 🎨 **Conservation du formatage riche (HTML & WebArchive)** : Préserve le gras, l'italique, le souligné, les liens, les listes et les images intégrées dans votre réponse grâce à un remplacement différentiel au niveau des nœuds texte HTML.
- **EN**:
  - ✨ **Quoted Email Reply Preservation**: Automatically ignores quoted thread history and signatures when pulling from Apple Mail (`⌘⇧R`), and keeps Apple Mail's quote bar status (`<blockquote type="cite">`) untouched when applying fixes (`⌘⇧A`).
  - 🎨 **Rich Text Formatting Preservation (HTML & WebArchive)**: Preserves bold, italic, underline, links, lists, and inline images in your reply via token-level HTML diff patching.

## [1.0.1] - 2026-11-08

### ✨ Improvements & Fixes (FR / EN)
- **FR** :
  - 🐛 Correction de l'affichage de l'icône de `Plume.app` et du volume `.dmg` dans le Finder, avec mise en page visuelle (`128x128`) et raccourci glisser-déposer vers `Applications`.
  - ✨ Exemple interactif pré-chargé au premier lancement et mise à jour du site web et du `README.md` avec les captures d'écran des deux modes d'édition.
- **EN**:
  - 🐛 Fixed `Plume.app` and `.dmg` volume icon display in Finder with a `128x128` icon layout and `Applications` drop link.
  - ✨ Added preloaded interactive sample on first launch and updated the website and `README.md` with screenshots of both editing modes.

## [1.0.0] - 2026-11-08

### ✨ Initial Release
- **Multi-Provider AI Spell, Grammar & Style Engine**:
  - **Google Gemini** (`gemini-3.8-flash`, `gemini-3.5-flash-lite`, `gemini-3.1-pro-preview`) via Gemini Interactions API (`/v1beta/interactions`) with structured JSON Schema output.
  - **Anthropic Claude** (`claude-3-5-haiku-latest`, `claude-3-7-sonnet-latest`).
  - **OpenAI** (`gpt-4o-mini`, `gpt-4o`).
  - **OpenRouter** (`google/gemini-3.8-flash`, `anthropic/claude-3.5-haiku`, `openai/gpt-4o-mini`, `meta-llama/llama-3.3-70b-instruct`).
  - **Ollama (Local, Zero API Key)** (`gemma4:latest`, `deepseek-r1:32b`, auto-discovered from `http://localhost:11434/api/tags`).
- **Automatic Language Recognition**: Automatically detects the language of your draft (`🇫🇷 Français`, `🇬🇧 English`, `🇪🇸 Español`, `🇩🇪 Deutsch`, `🇳🇱 Nederlands`, `🇮🇹 Italiano`, etc.).
- **Two Granular Modes**:
  - **Light Indicator Mode**: Color-coded inline underlines (**Red** = Spelling, **Blue** = Grammar, **Amber** = Style) with 1-click inline fix bar.
  - **Fine-Grained Split Editor Mode**: Full free-text editor + individual suggestion cards with **Accept**, **Accept & Update Mail**, **Ignore**, and custom replacement editing.
- **Native Apple Mail Integration**:
  - Floating HUD pill anchored to the active Apple Mail window.
  - Direct Compose Window body extraction (`Pull from Apple Mail`, `⌘⇧R`) and in-place replacement (`Apply to Apple Mail`, `⌘⇧A`) via macOS Accessibility (`AXUIElement` & language-independent `AXMenuItemCmdChar`).
  - Native macOS System Service (*Check Spelling & Grammar with Plume*, `⌘⇧;`).
- **Bilingual Interface (`🇫🇷 FR` / `🇬🇧 EN`)**: Instant UI language switching in the toolbar and Settings.
- **In-App Update Checker**: Notifies users with a top banner and interactive Changelog viewer when a new release is published.
