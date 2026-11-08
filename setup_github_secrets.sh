#!/usr/bin/env bash
set -euo pipefail

REPO="pschaus/plume"
TMP_P12="$(mktemp -t plume_cert).p12"
rm -f "$TMP_P12"

# Generate a random password to protect the exported .p12 archive
P12_PASS="$(openssl rand -base64 24)"

echo "🔐 Exportation du certificat 'Developer ID Application: Pierre Schaus (QF3N37X8P7)' depuis votre Trousseau macOS..."
echo "👉 Une fenêtre macOS va vous demander le mot de passe de votre session Mac (cliquez sur 'Autoriser' / 'Toujours autoriser')."

security export \
  -k "$HOME/Library/Keychains/login.keychain-db" \
  -t identities \
  -f pkcs12 \
  -P "$P12_PASS" \
  -o "$TMP_P12"

if [ ! -s "$TMP_P12" ]; then
  echo "❌ Échec de l'exportation du fichier .p12."
  rm -f "$TMP_P12"
  exit 1
fi

echo "📤 Envoi de APPLE_CERTIFICATE_P12_BASE64 et APPLE_CERTIFICATE_PASSWORD sur GitHub ($REPO)..."
base64 < "$TMP_P12" | tr -d '\n' | gh secret set APPLE_CERTIFICATE_P12_BASE64 --repo "$REPO"
printf "%s" "$P12_PASS" | gh secret set APPLE_CERTIFICATE_PASSWORD --repo "$REPO"

rm -f "$TMP_P12"

echo "✅ Tous les secrets GitHub Actions sont maintenant configurés sur $REPO :"
gh secret list --repo "$REPO"
