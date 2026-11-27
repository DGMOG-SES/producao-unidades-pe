#!/usr/bin/env bash
# Publica as planilhas em Releases (área de downloads do GitHub) como planilhas.zip,
# para baixar todas de uma vez. Link fixo da versão mais recente:
#   https://github.com/DGMOG-SES/producao-unidades-pe/releases/latest/download/planilhas.zip
# Só cria uma release nova quando a pasta planilhas/ mudou desde a última.
# Uso (GitHub Actions, com GH_TOKEN definido): bash publicar_release.sh
set -euo pipefail
git pull -q --rebase origin main || true
arvore=$(git rev-parse HEAD:planilhas)
ultima=$(gh release view --json body -q .body 2>/dev/null | grep -o 'planilhas-tree: [0-9a-f]*' | cut -d' ' -f2 || true)
if [ "$arvore" = "${ultima:-}" ]; then
  echo "Planilhas sem mudança desde a última release; nada a publicar."
  exit 0
fi
ultimo_mes=$(awk -F';' 'NR>1 && $1=="SIA"{print $2}' planilhas/atualizacao.csv)
mes_txt=$(echo "$ultimo_mes" | sed -E 's/([0-9]{4})([0-9]{2})/\2\/\1/')
gerado=$(TZ=America/Recife date +%d/%m/%Y\ %H:%M)
tag="planilhas-$(TZ=America/Recife date +%Y%m%d-%H%M)"
rm -f planilhas.zip
(cd planilhas && zip -q -9 ../planilhas.zip *.xlsx)
gh release create "$tag" planilhas.zip --latest \
  --title "Planilhas – dados até $mes_txt (geradas em $gerado)" \
  --notes "Todas as planilhas (.xlsx) de produção e leitos por unidade de PE.

Produção (SIA/SIH) até $mes_txt; leitos e estabelecimentos (CNES) no último mês publicado.
Versão mais recente sempre em: https://github.com/${GITHUB_REPOSITORY}/releases/latest/download/planilhas.zip

planilhas-tree: $arvore"
echo "Release $tag publicada."
