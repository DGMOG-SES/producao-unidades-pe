#!/usr/bin/env bash
# Grava no repositório o que mudou em dados/ e planilhas/ (usado no GitHub Actions).
# Uso: bash publicar.sh "mensagem do commit"
set -u
git add dados planilhas 2>/dev/null
if git diff --cached --quiet; then
  echo "Sem mudanças para publicar."
  exit 0
fi
git commit -q -m "$1"
for tentativa in 1 2 3; do
  git pull -q --rebase origin main && git push -q && exit 0
  echo "Push falhou (tentativa $tentativa); tentando de novo"
  sleep $((tentativa * 10))
done
exit 1
