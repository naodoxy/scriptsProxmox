#!/bin/bash

# Chemin vers le dossier contenant les scripts
SCRIPTS_DIR="./script"

# Définir les services disponibles
services=(
  "Tous les services"
  "PowerDNS Authoritative"
  "PowerDNS Recursor"
  "Traefik"
  "LDAP"
  "VPN"
  "Bitwarden"
  "Gitea"
  "Quitter"
)

# Affichage du menu
while true; do
  echo "=============================="
  echo "Quel service voulez-vous installer ?"
  echo "/!\ Installez en priorité PowerDNS Authoritative, Recursor et Traefik"
  echo "=============================="
  for i in "${!services[@]}"; do
    echo "$((i+1)). ${services[$i]}"
  done

  read -p "Entrez le numéro du service : " choice

  # Vérifie que le choix est un nombre valide
  if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#services[@]}" ]; then
    echo " Choix invalide. Veuillez réessayer."
    continue
  fi

  selected_service="${services[$((choice-1))]}"

  if [ "$selected_service" == "Quitter" ]; then
    echo "Sortie du script."
    exit 0
  fi

  if [ "$selected_service" == "Tous les services" ]; then
    echo "Installation de tous les services..."
    for svc in "${services[@]}"; do
      if [[ "$svc" != "Quitter" && "$svc" != "Tous les services" ]]; then
        script_name=$(echo "$svc" | tr '[:upper:]' '[:lower:]' | tr -d ' ' | tr -d '-').sh
        full_path="$SCRIPTS_DIR/$script_name"

        if [ -f "$full_path" ]; then
          echo "-> Installation de $svc..."
          bash "$full_path"
        else
          echo "/!\ Script manquant pour $svc ($full_path)"
        fi
      fi
    done
    echo "Tous les services ont été traités."
    continue
  fi

  # Construire le nom du script à exécuter
  script_name=$(echo "$selected_service" | tr '[:upper:]' '[:lower:]' | tr -d ' ' | tr -d '-').sh
  full_path="$SCRIPTS_DIR/$script_name"

  # Exécuter le script s’il existe
  if [ -f "$full_path" ]; then
    echo "-> Lancement de l'installation de $selected_service..."
    bash "$full_path"
  else
    echo "/!\ Le script pour $selected_service est introuvable à l'emplacement : $full_path"
  fi
done
