#!/usr/bin/env bash
# Exporte le jeu en binaires autonomes dans export/.
#   ./export.sh            Linux et Windows
#   ./export.sh linux      Linux seulement
#   ./export.sh windows    Windows seulement
# Godot est cherché dans le PATH ; GODOT=/chemin/vers/godot ./export.sh pour un autre.
set -euo pipefail

cd "$(dirname "$0")"
GODOT="${GODOT:-godot}"

if ! command -v "$GODOT" >/dev/null; then
	echo "Godot introuvable : installe-le ou lance GODOT=/chemin/vers/godot ./export.sh" >&2
	exit 1
fi

# les modèles d'export doivent correspondre exactement à la version de Godot
version="$("$GODOT" --version | grep -oE '^[0-9]+\.[0-9]+(\.[0-9]+)?\.[a-z]+[0-9]*')"
templates="${XDG_DATA_HOME:-$HOME/.local/share}/godot/export_templates/$version"
if [ ! -d "$templates" ]; then
	echo "Modèles d'export $version introuvables dans $templates" >&2
	echo "Dans Godot : Éditeur → Gérer les modèles d'exportation → Télécharger et installer." >&2
	exit 1
fi

export_one() {
	local preset="$1" out="$2"
	mkdir -p "$(dirname "$out")"
	rm -f "$out"   # sinon un export raté laisserait l'ancien binaire en place
	echo "Export $preset → $out"
	"$GODOT" --headless --path . --export-release "$preset" "$out"
	if [ ! -f "$out" ]; then
		echo "Échec de l'export $preset" >&2
		exit 1
	fi
	echo "OK : $out ($(du -h "$out" | cut -f1))"
}

case "${1:-tout}" in
	linux)
		export_one "Linux" "export/linux/ChatPerche.x86_64"
		;;
	windows)
		export_one "Windows" "export/windows/ChatPerche.exe"
		;;
	tout)
		export_one "Linux" "export/linux/ChatPerche.x86_64"
		export_one "Windows" "export/windows/ChatPerche.exe"
		;;
	*)
		echo "Usage : ./export.sh [linux|windows]" >&2
		exit 1
		;;
esac
