#!/bin/bash
# -----------------------------------------------------------------------------
# Script:        fjdk.sh
# Descrição:     is a robust, interactive command-line interface tool for 
# managing multiple Java Development Kits (JDKs). It allows you to easily 
# install, switch, and manage isolated workspaces for different projects, 
# ensuring the right Java version is always available without polluting your 
# system globally.
#
# Autor:         Rodrigo Longueira
# Repository:    https://github.com/src-rdgo/FlavoursJDK   (public)
# Contact:       https://www.linkedin.com/in/rodrigolongueira/
# Creation Date: 21/11/2025
# Version:       1.0.0
# Licença:       MIT
# -----------------------------------------------------------------------------
# docs:          readme.md
# Dependencies:  curl,git,jq,fzf and tar.
# -----------------------------------------------------------

RESET="\e[0m"
BOLD="\e[1m"
RED="\e[0;31m"
GREEN="\e[0;32m"
YELLOW="\e[0;33m"
BLUE_LIGHT="\e[1;36m" 
PURPLE="\e[1;35m"     
CYAN="\e[0;36m"

# Icons
ICON_OK="✅"
ICON_ERROR="❌"
ICON_WARN="⚠️"
ICON_INFO="ℹ️"
ICON_ROCKET="🚀"
ICON_CLOUD="☁️"
ICON_GEAR="⚙️"
ICON_PROMPT="❯"
ICON_LIST="📦"
ICON_DOWNLOAD="📥"
ICON_SWITCH="🔄"
ICON_TRASH="🗑️"
ICON_IMPORT="➡️"
ICON_LOCK="🔒"
ICON_WS="🏗️" 
ICON_FOLDER="📂"
ICON_GLOBE="🌎"
ICON_TREE_BRANCH="├──"
ICON_TREE_END="└──"
ICON_TREE_V="│"

# Core Directories
: "${FJDK_DIR:="$HOME/.fjdk"}"
FJDK_VERSION="1.0.0"
FJDK_VERSIONS_DIR="$FJDK_DIR/versions"
FJDK_EXTERNAL_DIR="$FJDK_DIR/external"
FJDK_CURRENT_LINK="$FJDK_DIR/current"
FJDK_WORKSPACES_DIR="$FJDK_DIR/workspaces"
FJDK_CONFIG_FILE="$FJDK_DIR/config"
FJDK_GLOBAL_BACKUP="$FJDK_DIR/.global_backup_link"
FJDK_NULL_DIR="$FJDK_DIR/null_jdk"

# Config  for 'Null JDK' (Stub to block system's jdk fallback)
if [ ! -x "$FJDK_NULL_DIR/bin/java" ]; then
    mkdir -p "$FJDK_NULL_DIR/bin"
    cat <<EOF > "$FJDK_NULL_DIR/bin/java"
#!/bin/bash
echo -e "${RED}${ICON_ERROR} FJDK Critical: The JDK for this workspace is missing.${RESET}" >&2
exit 127
EOF
    chmod +x "$FJDK_NULL_DIR/bin/java"
fi

if [ -f "$FJDK_CONFIG_FILE" ]; then
    source "$FJDK_CONFIG_FILE"
fi

save_config_var() {
    local key=$1; local value=$2
    if [ -f "$FJDK_CONFIG_FILE" ]; then
        grep -v "^${key}=" "$FJDK_CONFIG_FILE" > "${FJDK_CONFIG_FILE}.tmp"
        mv "${FJDK_CONFIG_FILE}.tmp" "$FJDK_CONFIG_FILE"
    fi
    echo "${key}=${value}" >> "$FJDK_CONFIG_FILE"
}

remove_config_key() {
    local key=$1
    if [ -f "$FJDK_CONFIG_FILE" ]; then
        grep -v "^${key}=" "$FJDK_CONFIG_FILE" > "${FJDK_CONFIG_FILE}.tmp"
        mv "${FJDK_CONFIG_FILE}.tmp" "$FJDK_CONFIG_FILE"
    fi
}

get_config_var() {
    local key=$1
    if [ -f "$FJDK_CONFIG_FILE" ]; then
        grep "^${key}=" "$FJDK_CONFIG_FILE" | cut -d'=' -f2
    fi
}

remove_quarantine() {
    local target_path=$1
    if [[ "$OSTYPE" == "darwin"* ]]; then
        echo -e ""
        echo -e "${YELLOW}${ICON_WARN} macOS Security Alert (Gatekeeper)${RESET}"
        echo -e "The downloaded JDK is flagged with 'com.apple.quarantine' by macOS."
        echo -e "This may prevent Java from running unless you manually approve it in System Settings."
        echo -e "FJDK can remove this attribute to allow immediate execution."
        
        echo -n -e "${YELLOW}Do you want to remove the quarantine attribute? (y/N) ${RESET}"
        read -r -n 1 answer
        echo ""

        if [[ "$answer" =~ ^[Yy]$ ]]; then
            echo -e "${BLUE_LIGHT}Removing 'com.apple.quarantine' attribute...${RESET}"
            xattr -r -d com.apple.quarantine "$target_path" 2>/dev/null || true
            if [ $? -eq 0 ]; then
                echo -e "${GREEN}${ICON_OK} Attribute removed. Execution enabled.${RESET}"
            else
                echo -e "${RED}${ICON_ERROR} Failed to remove attribute.${RESET}"
            fi
        else
            echo -e "${YELLOW}Skipped. You may need to approve the binary manually in 'System Settings > Privacy & Security'.${RESET}"
        fi
        echo -e ""
    fi
}

verify_sha256() {
    local file_path=$1; local expected_hash=$2
    if [ -z "$expected_hash" ]; then return 0; fi 
    echo -e "${BLUE_LIGHT}${ICON_LOCK} Verifying integrity (SHA256)...${RESET}"
    local calculated_hash=""
    if command -v sha256sum >/dev/null; then calculated_hash=$(sha256sum "$file_path" | awk '{print $1}')
    elif command -v shasum >/dev/null; then calculated_hash=$(shasum -a 256 "$file_path" | awk '{print $1}')
    else echo -e "${YELLOW}${ICON_WARN} SHA256 tools not found. Skipping verification.${RESET}"; return 0; fi
    
    if [ "$calculated_hash" != "$expected_hash" ]; then
        echo -e "${RED}${ICON_ERROR} SECURITY ALERT: Checksum mismatch!${RESET}"; return 1
    else echo -e "${GREEN}${ICON_OK} Integrity verified.${RESET}"; return 0; fi
}

api_curl() {
    local url=$1
    curl -fL -s -A "Mozilla/5.0" "$url" | tr -d '\r'
    return ${PIPESTATUS[0]}
}

fetch_api_feature_versions() {
    local API_OS; local API_ARCH
    case $(uname -s) in "Linux") API_OS="linux" ;; "Darwin") API_OS="macos" ;; *) echo "ERROR_OS" >&2; return 1 ;; esac
    case $(uname -m) in "x86_64") API_ARCH="x86_64" ;; "aarch64"|"arm64") API_ARCH="arm_64" ;; *) echo "ERROR_ARCH" >&2; return 1 ;; esac
    local api_url="https://api.azul.com/metadata/v1/zulu/packages/?os=${API_OS}&arch=${API_ARCH}&archive_type=tar.gz&package_type=jdk&release_status=ga&page=1&page_size=100"
    local api_data; api_data=$(api_curl "$api_url")
    if [ $? -ne 0 ] || [ -z "$api_data" ] || [ "$api_data" = "[]" ]; then echo "ERROR_API" >&2; return 1; fi
    echo "$api_data" | jq -r '[ .[] | .java_version[0] ] | unique | sort | .[]'
}

fetch_latest_patch_info_azul() {
    local feature_version=$1; local API_OS; local API_ARCH
    case $(uname -s) in "Linux") API_OS="linux" ;; "Darwin") API_OS="macos" ;; *) echo "ERROR_OS" >&2; return 1 ;; esac
    case $(uname -m) in "x86_64") API_ARCH="x86_64" ;; "aarch64"|"arm64") API_ARCH="arm_64" ;; *) echo "ERROR_ARCH" >&2; return 1 ;; esac
    
    echo -e "${BLUE_LIGHT}${ICON_CLOUD} [Azul] Fetching patch for JDK ${feature_version}...${RESET}" >&2
    
    local api_url="https://api.azul.com/metadata/v1/zulu/packages/?java_version=${feature_version}&os=${API_OS}&arch=${API_ARCH}&archive_type=tar.gz&package_type=jdk&availability_types=st&release_status=ga&sort_by=java_version&sort_order=desc&page=1&page_size=100"
    
    local api_data; api_data=$(api_curl "$api_url")
    if [ $? -ne 0 ] || [ -z "$api_data" ] || [ "$api_data" = "[]" ]; then echo "ERROR_API_AZUL" >&2; return 1; fi
    
    echo "$api_data" | jq -r '.[] | select(.download_url != null) | select(.name | contains("jdk")) | select(.name | contains("jre") | not) | "zulu-jdk-" + (.java_version | .[0:3] | join(".")) + "|" + (.java_version | .[0:3] | join(".")) + "|" + .download_url + "|" + .sha256_hash' | head -n 1
}

compare_versions() { printf '%s\n' "$1" "$2" | sort -V | tail -n 1; }

fetch_remote_version_string() {
    ( cd "$FJDK_DIR" || return 1; git fetch origin main --quiet; git show origin/main:fjdk.sh 2>/dev/null | grep 'FJDK_VERSION=' | head -n 1 | sed -e 's/.*FJDK_VERSION="//' -e 's/".*//' )
}

fjdk_update() {
    echo -e "${BLUE_LIGHT}${ICON_GEAR} Checking for updates...${RESET}"
    local remote_v; remote_v=$(fetch_remote_version_string)
    if [ -z "$remote_v" ]; then echo -e "${RED}${ICON_ERROR} Failed to fetch remote info.${RESET}"; return 1; fi
    local latest_v; latest_v=$(compare_versions "$FJDK_VERSION" "$remote_v")
    if [ "$FJDK_VERSION" != "$latest_v" ]; then
        echo -e "${PURPLE}New version found: v$latest_v${RESET}"; echo -e "${BLUE_LIGHT}${ICON_DOWNLOAD} Updating fjdk...${RESET}"
        ( cd "$FJDK_DIR" || { echo -e "${RED}ERROR: fjdk dir not found.${RESET}"; return 1; }; git pull origin main --quiet
            if [ $? -eq 0 ]; then echo -e "${GREEN}${ICON_OK} Updated to v$latest_v!${RESET}"; echo "Please restart your shell."; else echo -e "${RED}${ICON_ERROR} Update failed.${RESET}"; fi )
    else echo -e "${GREEN}${ICON_OK} You are already using the latest version (v$FJDK_VERSION).${RESET}"; fi
}

fjdk_version() {
    echo -e "• 🍵 fjdk tool version: ${BOLD}v$FJDK_VERSION${RESET}"
    echo -e ""
    echo -e "• ${BLUE_LIGHT}Checking for updates...${RESET}"
    local remote_v; remote_v=$(fetch_remote_version_string)
    if [ -n "$remote_v" ]; then
        local latest_v; latest_v=$(compare_versions "$FJDK_VERSION" "$remote_v")
        if [ "$FJDK_VERSION" != "$latest_v" ]; then
            echo -e "${YELLOW}${ICON_INFO} Update available: ${GREEN}v$latest_v${RESET}"
            echo -n -e "${YELLOW}Update now? (y/N) ${RESET}"; read -r -n 1 answer; echo ""
            if [[ "$answer" =~ ^[Yy]$ ]]; then fjdk_update; fi
        else echo -e "${GREEN}${ICON_OK} Latest version.${RESET}"; fi
    else echo -e "${YELLOW}${ICON_WARN} Could not verify remote version.${RESET}"; fi
}

fjdk_config() {
    local key=$1; local value=$2
    if [ -z "$key" ]; then echo -e "${PURPLE}Current Configuration:${RESET}"; echo -e "  Config File: $FJDK_CONFIG_FILE"; cat "$FJDK_CONFIG_FILE" 2>/dev/null; return; fi
    echo -e "${RED}${ICON_ERROR} Unknown configuration key: '$key'.${RESET}"
}

fjdk_using() {
    local global_v="None"; local global_status="${BLUE_LIGHT}Standard${RESET}"
    if [ -L "$FJDK_CURRENT_LINK" ]; then
        local target=$(readlink "$FJDK_CURRENT_LINK")
        global_v=$(basename "$target")
        if [ ! -d "$target" ]; then global_v="${RED}❌ JDK $global_v (Not Found)${RESET}"; fi
        if [ -n "$FJDK_GLOBAL_MODE" ]; then global_status="${RED}${BOLD}HIJACKED (Global Mode)${RESET}"; fi
    fi

    check_path_precedence
    local session_v="Unknown"; local session_source=""; local status_msg="${GREEN}OK${RESET}"; local reason_msg=""
    local java_bin=$(command -v java 2>/dev/null)
    local active_ws_broken=0
    local missing_target_name=""

    if [ -n "$FJDK_ACTIVE_WS" ]; then
        local ws_link="$FJDK_WORKSPACES_DIR/$FJDK_ACTIVE_WS/current"
        if [ -L "$ws_link" ]; then
             local target=$(readlink "$ws_link")
             if [ ! -d "$target" ] || [[ "$target" == *"/null_jdk" ]]; then 
                 active_ws_broken=1
                 if [ -f "$FJDK_WORKSPACES_DIR/$FJDK_ACTIVE_WS/.missing_target" ]; then
                     missing_target_name=$(cat "$FJDK_WORKSPACES_DIR/$FJDK_ACTIVE_WS/.missing_target")
                 else
                     missing_target_name="Unknown"
                 fi
             fi
        fi
    fi

    if [ $active_ws_broken -eq 1 ]; then
        session_v="${RED}Not Set${RESET}"
        session_source="${PURPLE}Workspace ($FJDK_ACTIVE_WS)${RESET}"
        status_msg="${RED}MISSING JDK${RESET}"
        reason_msg="Expected JDK '${BOLD}$missing_target_name${RESET}' not found. Fallback blocked."
        
    elif [ -z "$java_bin" ]; then
        session_v="${RED}Not Found${RESET}"
        session_source="Missing"
    else
        local real_java_bin=$(readlink -f "$java_bin" 2>/dev/null || echo "$java_bin")
        if [[ "$real_java_bin" == *"$FJDK_DIR"* ]]; then
            if [[ "$real_java_bin" == *"$FJDK_WORKSPACES_DIR"* ]]; then
                 session_source="${PURPLE}Workspace ($FJDK_ACTIVE_WS)${RESET}"
                 session_v=$(basename "$(dirname "$(dirname "$real_java_bin")")")
            else
                 session_source="${GREEN}Global Link${RESET}"
                 session_v=$(basename "$(readlink "$FJDK_CURRENT_LINK")")
            fi
        else
            local sys_v=$("$java_bin" -version 2>&1 | head -n 1 | cut -d'"' -f2)
            session_v="System ($sys_v)"
            session_source="${RED}System/External${RESET}"
            status_msg="${YELLOW}Not managed by FJDK${RESET}"
        fi
    fi

    echo -e "${BOLD}FJDK Status Report${RESET}"
    echo -e "---------------------------------------------------"
    echo -e "${ICON_GLOBE}  Global Config:  ${BOLD}$global_v${RESET}"
    echo -e "    Mode:           $global_status"
    echo -e ""
    echo -e "${ICON_PROMPT}  Current Shell:  ${BOLD}$session_v${RESET}"
    echo -e "    Source:         $session_source"
    echo -e "    Status:         $status_msg"
    if [ -n "$reason_msg" ]; then echo -e "    Reason:         $reason_msg"; fi
    if [ "$session_v" != "${RED}Not Set${RESET}" ] && [ "$session_v" != "${RED}Not Found${RESET}" ]; then echo -e "    Path:           $java_bin"; fi
    echo -e "---------------------------------------------------"
    
    if [ "$session_v" != "${RED}Not Set${RESET}" ] && [ -x "$java_bin" ]; then
        if [[ "$java_bin" != *"/null_jdk/"* ]]; then
             java -version 2>&1 | head -n 1
        fi
    fi
}

fjdk_help() {
    echo -e "${GREEN}--------------------------------------------------------------${RESET}"
    echo -e "${BOLD}🍵 FJDK${RESET} (Flavours JDK - Manager)"
    echo -e "Usage: fjdk <command> [arguments]"
    echo -e ""
    echo -e "${BOLD}Core Commands:${RESET}"
    echo -e "  ${GREEN}install${RESET}                   Open Interactive list of versions to install (From Azul/Zulu)"
    echo -e "  ${GREEN}install <version>${RESET}         Install a JDK from Azul API (Version omission opens interactive menu)"
    echo -e "  ${GREEN}install -e <path>${RESET}         Install from a local .tar.gz file"
    echo -e "  ${GREEN}import${RESET}                    Import the system's currently installed JDK"
    echo -e "  ${GREEN}remove | uninstall${RESET}        Uninstall a specific JDK version"
    echo -e "  ${GREEN}use <version>${RESET}             Switch the active JDK version (Global or Workspace)"
    echo -e "  ${GREEN}using${RESET}                     Show the current active version and status"
    echo -e "  ${GREEN}list | ls${RESET}                 List installed/imported local versions"
    echo -e "  ${GREEN}list | ls -remote${RESET}         List available versions for download"
    echo -e ""
    echo -e "${BOLD}Workspace Management:${RESET}"
    echo -e "  ${GREEN}ws${RESET}                        Open Interactive Workspace Manager (Select/Create/Enter)"
    echo -e "  ${GREEN}ws -exit${RESET}                  Exit the current workspace (Restore global context)"
    echo -e "  ${GREEN}ws -map${RESET}                   Visualize Workspaces and projects tree"
    echo -e "  ${GREEN}ws -set <name>${RESET}            Create a new workspace manually"
    echo -e "  ${GREEN}ws -remove [name]${RESET}         Delete a workspace (Config + Folder)"
    echo -e "  ${GREEN}ws -gm${RESET}                    Enable Global Mode (Hijack system JDK with WS version)"
    echo -e "  ${GREEN}ws -add [path]${RESET}            Register a directory to the active workspace"
    echo -e "  ${GREEN}ws -del [path]${RESET}            Unregister a directory from the active workspace"
    echo -e ""
    echo -e "${BOLD}Other:${RESET}"
    echo -e "  ${GREEN}update${RESET}                    Update fjdk to the latest version"
    echo -e "  ${GREEN}-v | -version${RESET}             Show fjdk version"
    echo -e "  ${GREEN}-h | -help${RESET}                Show this help message"
    echo -e ""
    echo -e "${GREEN}--------------------------------------------------------------${RESET}"

}

get_all_local_versions() {
    ls -1 "$FJDK_VERSIONS_DIR" 2>/dev/null
    ls -1 "$FJDK_EXTERNAL_DIR" 2>/dev/null
}

fjdk_list_remote() {
    echo -e "${BLUE_LIGHT}${ICON_CLOUD} Fetching versions...${RESET}"
    local local_versions; local_versions=$(get_all_local_versions)
    local remote_versions; remote_versions=$(fetch_api_feature_versions)
    if [ -z "$remote_versions" ] || [ "$remote_versions" = "ERROR_API" ]; then echo -e "${RED}API Error.${RESET}" >&2; return 1; fi
    echo -e "${GREEN}Available Feature Versions:${RESET}"
    echo "$remote_versions" | while read -r v; do
        local tag=""; if echo "$local_versions" | grep -q -E "(jdk-${v}|jdk${v}u)"; then tag="${GREEN}[Installed]${RESET}"; fi
        echo -e "  v$v $tag"
    done
}

fjdk_list_local() {
    echo -e "${BLUE_LIGHT}${ICON_LIST} Versions in: ${BOLD}$FJDK_DIR${RESET}"
    local versions_manual; versions_manual=$(ls -1 "$FJDK_VERSIONS_DIR" 2>/dev/null)
    local versions_external; versions_external=$(ls -1 "$FJDK_EXTERNAL_DIR" 2>/dev/null)
    if [ -z "$versions_manual" ] && [ -z "$versions_external" ]; then echo -e "${YELLOW}None.${RESET}"; return; fi
    
    local current_version=""; if [ -L "$FJDK_CURRENT_LINK" ]; then current_version=$(basename "$(readlink "$FJDK_CURRENT_LINK")"); fi
    
    if [ -n "$FJDK_ACTIVE_WS" ]; then
         if [ -L "$FJDK_WORKSPACES_DIR/$FJDK_ACTIVE_WS/current" ]; then
             current_version=$(basename "$(readlink "$FJDK_WORKSPACES_DIR/$FJDK_ACTIVE_WS/current")")
         else current_version="none"; fi
         echo -e "${PURPLE}${ICON_WS} Context: Workspace '$FJDK_ACTIVE_WS'${RESET}"
    fi

    if [ -n "$versions_manual" ]; then
        echo -e "${PURPLE}Versions (Installed):${RESET}"
        echo "$versions_manual" | while read -r v; do
            if [ "$v" = "$current_version" ]; then echo -e "${GREEN}  $v (Active)${RESET}"; else echo -e "  $v"; fi
        done
    fi
    if [ -n "$versions_external" ]; then
        echo -e "${PURPLE}Versions (Imported):${RESET}"
        echo "$versions_external" | while read -r v; do
            if [ "$v" = "$current_version" ]; then echo -e "${GREEN}  $v (Active)${RESET}"; else echo -e "  $v"; fi
        done
    fi
}

fjdk_uninstall() {
    local version_name=$1
    if [ -z "$version_name" ]; then
        version_name=$(get_all_local_versions | fzf --prompt "${ICON_PROMPT} Uninstall: ")
        if [ -z "$version_name" ]; then echo -e "${RED}Aborted.${RESET}" >&2; return 1; fi
    fi
    local install_path=""
    if [ -d "$FJDK_VERSIONS_DIR/$version_name" ]; then install_path="$FJDK_VERSIONS_DIR/$version_name"
    elif [ -d "$FJDK_EXTERNAL_DIR/$version_name" ]; then install_path="$FJDK_EXTERNAL_DIR/$version_name"
    fi
    if [ ! -d "$install_path" ]; then echo -e "${RED}${ICON_ERROR} Not found.${RESET}" >&2; return 1; fi
    if [ -z "$install_path" ] || [ "$install_path" = "/" ]; then echo -e "${RED}Critical Error: Invalid path.${RESET}"; return 1; fi

    # 1. Global Link
    if [ -L "$FJDK_CURRENT_LINK" ] && [ "$(readlink "$FJDK_CURRENT_LINK")" = "$install_path" ]; then 
        rm "$FJDK_CURRENT_LINK"
    fi
    
    # 2. Workspace Links (Salvando metadados antes de destruir)
    local ws_list=$(ls -1 "$FJDK_WORKSPACES_DIR" 2>/dev/null)
    while read -r ws; do
        local ws_link="$FJDK_WORKSPACES_DIR/$ws/current"
        if [ -L "$ws_link" ] && [ "$(readlink "$ws_link")" = "$install_path" ]; then
            echo -e "${YELLOW}${ICON_WARN} Workspace '$ws' was using this version. Switching to Null State.${RESET}"
            
            # Salva o nome da versão perdida para exibição futura
            echo "$version_name" > "$FJDK_WORKSPACES_DIR/$ws/.missing_target"
            
            ln -sfn "$FJDK_NULL_DIR" "$ws_link"
        fi
    done <<< "$ws_list"

    rm -rf "$install_path"
    hash -r 2>/dev/null
    echo -e "${GREEN}${ICON_TRASH} Uninstalled $version_name.${RESET}"
}

fjdk_use() {
    local version_query=$1
    if [ -z "$version_query" ]; then
        version_query=$(get_all_local_versions | fzf --prompt "${ICON_PROMPT} Use: ")
        if [ -z "$version_query" ]; then echo -e "${RED}Aborted.${RESET}" >&2; return 1; fi
    fi
    
    local version_path
    version_path=$( (ls -d "$FJDK_VERSIONS_DIR"/*${version_query}* 2>/dev/null; ls -d "$FJDK_EXTERNAL_DIR"/*${version_query}* 2>/dev/null) | sort -rV | head -n 1)

    if [ -z "$version_path" ]; then echo -e "${RED}${ICON_ERROR} Not found.${RESET}" >&2; return 1; fi
    local version_name=$(basename "$version_path")
    
    local target_link="$FJDK_CURRENT_LINK"
    local context_msg="Global"
    
    if [ -n "$FJDK_ACTIVE_WS" ]; then
        mkdir -p "$FJDK_WORKSPACES_DIR/$FJDK_ACTIVE_WS"
        target_link="$FJDK_WORKSPACES_DIR/$FJDK_ACTIVE_WS/current"
        context_msg="Workspace: $FJDK_ACTIVE_WS"
        
        rm -f "$FJDK_WORKSPACES_DIR/$FJDK_ACTIVE_WS/.missing_target"
    fi
    
    ln -sfn "$version_path" "$target_link"
    
    if [ -n "$FJDK_GLOBAL_MODE" ] && [ -n "$FJDK_ACTIVE_WS" ]; then
        ln -sfn "$version_path" "$FJDK_CURRENT_LINK"
        echo -e "${RED}${ICON_GLOBE} Global Link updated (GM Active)${RESET}"
    fi
    
    hash -r 2>/dev/null
    echo -e "${GREEN}${ICON_OK} Using ($context_msg): ${BOLD}$version_name${RESET}"
    check_path_precedence
    
    if [ -f "$target_link/bin/java" ]; then "$target_link/bin/java" -version; fi
}

fjdk_ws_map() {
    echo -e "${BOLD}FJDK Workspace Map${RESET}"
    
    local sys_java_bin=$(type -ap java 2>/dev/null | grep -v "$FJDK_DIR" | head -n 1)
    local sys_java_v=""
    if [ -n "$sys_java_bin" ]; then sys_java_v=$("$sys_java_bin" -version 2>&1 | head -n 1 | cut -d'"' -f2); fi

    # GLOBAL NODE
    local global_v="Not Set"; local global_marker=""
    if [ -L "$FJDK_CURRENT_LINK" ]; then 
        local target_path=$(readlink "$FJDK_CURRENT_LINK")
        global_v=$(basename "$target_path")
        
        if [ ! -d "$target_path" ]; then
             global_v="${RED}❌ JDK $global_v (Not Found)${RESET}"
             if [ -z "$FJDK_ACTIVE_WS" ] && [ -n "$sys_java_v" ]; then
                global_v="$global_v ${YELLOW}-> Fallback: System ($sys_java_v)${RESET}"
             fi
        fi
    elif [ -n "$sys_java_v" ]; then global_v="System ($sys_java_v)"; fi
    
    if [ -z "$FJDK_ACTIVE_WS" ]; then global_marker=" ${YELLOW}${BOLD}<< CURRENT SHELL${RESET}"; fi
    if [ -n "$FJDK_GLOBAL_MODE" ]; then global_v="$global_v ${RED}(Hijacked)${RESET}"; fi
    
    echo -e "${ICON_GLOBE} Global [${RESET}${global_v}${RESET}]$global_marker"
    
    # WORKSPACES
    local ws_list=$(ls -1 "$FJDK_WORKSPACES_DIR" 2>/dev/null)
    if [ -z "$ws_list" ]; then return; fi
    echo -e "${ICON_TREE_BRANCH} ${ICON_WS} Workspaces"
    
    while read -r ws; do
        local ws_v="Not Set"; local ws_color=$RESET; local prefix=$ICON_TREE_BRANCH; local ws_marker=""
        if [ "$FJDK_ACTIVE_WS" = "$ws" ]; then ws_color="${PURPLE}${BOLD}"; ws_marker=" ${YELLOW}${BOLD}<< CURRENT SHELL${RESET}"; fi
        
        if [ -L "$FJDK_WORKSPACES_DIR/$ws/current" ]; then
            local target_path=$(readlink "$FJDK_WORKSPACES_DIR/$ws/current")
            ws_v=$(basename "$target_path")
            
            # Logica de Exibição de Erro
            if [ ! -d "$target_path" ] || [[ "$target_path" == *"/null_jdk" ]]; then
                local missing_name="$ws_v"
                
                # Tenta recuperar o nome original do arquivo .missing_target
                if [ -f "$FJDK_WORKSPACES_DIR/$ws/.missing_target" ]; then
                    missing_name=$(cat "$FJDK_WORKSPACES_DIR/$ws/.missing_target")
                elif [[ "$missing_name" == "null_jdk" ]]; then
                    missing_name="Unknown"
                fi
                
                ws_v="${RED}❌ JDK $missing_name (Not Found)${RESET}"
            fi
        fi
        echo -e "    ${prefix} ${ws_color}$ws${RESET} [$ws_v]$ws_marker"
        local dirs=$(get_config_var "WS_DIRS_${ws}")
        if [ -n "$dirs" ]; then
            local old_ifs="$IFS"; IFS=':'; for d in $dirs; do echo -e "    ${ICON_TREE_V}   ${ICON_TREE_BRANCH} ${CYAN}$d${RESET}"; done; IFS="$old_ifs"
        fi
    done <<< "$ws_list"
}

check_dir_owner() {
    local target_dir=$1
    if [ ! -f "$FJDK_CONFIG_FILE" ]; then return 1; fi
    
    while read -r line; do
        if [[ "$line" == WS_DIRS_* ]]; then
            local key=${line%%=*}
            local value=${line#*=}
            local ws_name=${key#WS_DIRS_}
            
            if [[ ":$value:" == *":$target_dir:"* ]]; then
                echo "$ws_name"
                return 0
            fi
        fi
    done < "$FJDK_CONFIG_FILE"
    return 1
}

fjdk_ws() {
    mkdir -p "$FJDK_WORKSPACES_DIR"
    local arg1=$1
    local arg2=$2
    
    # --- MAP ---
    if [ "$arg1" = "-map" ]; then
        fjdk_ws_map
        return 0
    fi

    # --- REMOVE (Interactive) ---
    if [ "$arg1" = "-remove" ]; then
        local ws_to_remove=$arg2
        if [ -z "$ws_to_remove" ]; then
            local ws_list=$(ls -1 "$FJDK_WORKSPACES_DIR" 2>/dev/null)
            if [ -z "$ws_list" ]; then echo -e "${YELLOW}No workspaces found.${RESET}"; return 0; fi
            ws_to_remove=$(echo "$ws_list" | fzf --prompt "${ICON_TRASH} Select Workspace to Remove: ")
            if [ -z "$ws_to_remove" ]; then echo -e "${RED}Aborted.${RESET}"; return 1; fi
        fi

        if [ -d "$FJDK_WORKSPACES_DIR/$ws_to_remove" ]; then
            if [ "$FJDK_ACTIVE_WS" = "$ws_to_remove" ]; then
                echo -e "${RED}Cannot remove active workspace. Exit it first.${RESET}"; return 1
            fi
            rm -rf "$FJDK_WORKSPACES_DIR/$ws_to_remove"
            remove_config_key "WS_DIRS_${ws_to_remove}"
            echo -e "${GREEN}${ICON_TRASH} Workspace '$ws_to_remove' deleted.${RESET}"
            echo -e "${BLUE_LIGHT}(Note: Your actual project folders were NOT deleted)${RESET}"
        else
            echo -e "${RED}Workspace '$ws_to_remove' not found.${RESET}"
        fi
        return 0
    fi

    # --- EXIT LOGIC ---
    if [ "$arg1" = "-exit" ]; then
        if [ -z "$FJDK_ACTIVE_WS" ]; then echo -e "${YELLOW}No active workspace.${RESET}"; return 0; fi
        
        local ws_bin="$FJDK_WORKSPACES_DIR/$FJDK_ACTIVE_WS/current/bin"
        if [[ ":$PATH:" == *":$ws_bin:"* ]]; then export PATH=${PATH//$ws_bin:/}; fi
        
        if [ -n "$FJDK_GLOBAL_MODE" ]; then
            echo -e "${BLUE_LIGHT}${ICON_GLOBE} Restoring Global JDK...${RESET}"
            if [ -f "$FJDK_GLOBAL_BACKUP" ]; then
                local original_target=$(cat "$FJDK_GLOBAL_BACKUP")
                if [ -n "$original_target" ]; then ln -sfn "$original_target" "$FJDK_CURRENT_LINK"; fi
                rm "$FJDK_GLOBAL_BACKUP"
            fi
            unset FJDK_GLOBAL_MODE
        fi
        
        echo -e "${PURPLE}${ICON_SWITCH} Exiting workspace: $FJDK_ACTIVE_WS${RESET}"
        unset FJDK_ACTIVE_WS
        return 0
    fi

    # --- SET (CREATE) ---
    if [ "$arg1" = "-set" ]; then
        if [ -z "$arg2" ]; then echo -e "${RED}Name required.${RESET}" >&2; return 1; fi
        mkdir -p "$FJDK_WORKSPACES_DIR/$arg2"
        echo -e "${GREEN}${ICON_OK} Workspace '$arg2' created.${RESET}"
        return 0
    fi
    
    # --- ADD DIRECTORY ---
    if [ "$arg1" = "-add" ]; then
        if [ -z "$FJDK_ACTIVE_WS" ]; then echo -e "${RED}No active workspace.${RESET}" >&2; return 1; fi
        
        local target_input=$arg2
        local target_dir=""

        if [ -n "$target_input" ]; then
            if [ ! -d "$target_input" ]; then
                echo -e "${RED}${ICON_ERROR} Directory not found: $target_input${RESET}" >&2; return 1
            fi
            target_dir=$(cd "$target_input" && pwd)
        else
            target_dir=$(pwd)
        fi
        
        local owner=$(check_dir_owner "$target_dir")
        if [ -n "$owner" ] && [ "$owner" != "$FJDK_ACTIVE_WS" ]; then
            echo -e "${RED}${ICON_ERROR} Conflict: This directory belongs to workspace '${BOLD}$owner${RESET}${RED}'.${RESET}"
            return 1
        fi

        local current_dirs=$(get_config_var "WS_DIRS_${FJDK_ACTIVE_WS}")
        if [[ ":$current_dirs:" == *":$target_dir:"* ]]; then echo -e "${YELLOW}Already added.${RESET}"; return 0; fi
        
        local new_dirs="${current_dirs}:${target_dir}"; new_dirs=${new_dirs#:} 
        save_config_var "WS_DIRS_${FJDK_ACTIVE_WS}" "$new_dirs"
        
        echo -e "${GREEN}${ICON_LOCK} Directory registered to '$FJDK_ACTIVE_WS': $target_dir${RESET}"
        return 0
    fi

    # --- DEL DIRECTORY ---
    if [ "$arg1" = "-del" ]; then
         if [ -z "$FJDK_ACTIVE_WS" ]; then echo -e "${RED}No active workspace.${RESET}" >&2; return 1; fi
         
         local target_input=$arg2
         local target_dir=""

         if [ -n "$target_input" ]; then
             if [ ! -d "$target_input" ]; then
                 echo -e "${RED}${ICON_ERROR} Directory not found: $target_input${RESET}" >&2; return 1
             fi
             target_dir=$(cd "$target_input" && pwd)
         else
             target_dir=$(pwd)
         fi
         
         local current_dirs=$(get_config_var "WS_DIRS_${FJDK_ACTIVE_WS}")
         
         # Verifica se o diretório está na lista antes de tentar remover
         if [[ ":$current_dirs:" != *":$target_dir:"* ]]; then
             echo -e "${YELLOW}Directory not found in workspace configuration.${RESET}"
             return 1
         fi

         # Remove o diretório da lista
         local new_dirs=${current_dirs//$target_dir/}
         new_dirs=${new_dirs//::/:}; new_dirs=${new_dirs#:}; new_dirs=${new_dirs%:} 
         
         # Verifica se recebeu uma lista vazia - saída forçada
         if [ -z "$new_dirs" ]; then
             echo -e "${YELLOW}${ICON_WARN} Warning: This is the last directory in '${FJDK_ACTIVE_WS}'.${RESET}"
             echo -e "${YELLOW}Removing it will exit the workspace.${RESET}"
             echo -n -e "${RED}Confirm removal and exit? (y/N) ${RESET}"; read -r -n 1 answer; echo ""
             
             if [[ ! "$answer" =~ ^[Yy]$ ]]; then return 1; fi

             save_config_var "WS_DIRS_${FJDK_ACTIVE_WS}" ""
             echo -e "${YELLOW}${ICON_TRASH} Directory removed. Exiting workspace...${RESET}"
             
             fjdk_ws -exit
             return 0
         fi

         save_config_var "WS_DIRS_${FJDK_ACTIVE_WS}" "$new_dirs"
         echo -e "${YELLOW}${ICON_TRASH} Directory removed from '$FJDK_ACTIVE_WS'.${RESET}"
         return 0
    fi

    # --- MAIN MENU (INTERACTIVE) ---
    local gm_flag=0
    if [ "$arg1" = "-gm" ] || [ "$arg2" = "-gm" ] || [ "$3" = "-gm" ]; then gm_flag=1; fi

    if [ -n "$FJDK_ACTIVE_WS" ] && [ -n "$FJDK_GLOBAL_MODE" ]; then
        echo -e "${RED}${ICON_ERROR} Global Workspace Active: ${BOLD}$FJDK_ACTIVE_WS${RESET}"
        echo -e "${RED}${ICON_GLOBE} System JDK is hijacked (Global Mode). Safety lock engaged.${RESET}"
        echo -e "${YELLOW}You must exit to restore system state first.${RESET}"
        echo -e "Run: ${GREEN}fjdk ws -exit${RESET}"
        return 1
    fi

    local ws_list=$(ls -1 "$FJDK_WORKSPACES_DIR")
    local selection
    selection=$(echo -e "$ws_list\n[+ Create New +]" | fzf --prompt "${ICON_WS} Select Workspace: ")
    
    if [ -z "$selection" ]; then echo -e "${RED}Aborted.${RESET}"; return 1; fi
    if [ "$selection" = "[+ Create New +]" ]; then
        echo -n -e "${GREEN}${ICON_PROMPT} New Workspace Name: ${RESET}"; read new_ws_name
        if [ -n "$new_ws_name" ]; then fjdk_ws -set "$new_ws_name"; selection="$new_ws_name"; else return 1; fi
    fi
    
    # --- FOLDER SELECTION MENU ---
    local allowed_dirs=$(get_config_var "WS_DIRS_${selection}")
    local selected_dir=""
    
    local OPT_NONE="[None (Stay here)]"
    local OPT_ADD="[+ Add Current Dir +]"
    local OPT_CUSTOM="[+ Add Custom Path +]"
    local fzf_input=""

    # Monta o menu dependendo se já existem pastas ou não
    if [ -z "$allowed_dirs" ]; then
        echo -e "${YELLOW}${ICON_INFO} Workspace '${selection}' is empty.${RESET}"
        # Se vazio, obriga a adicionar (Regra: precisa de 1 pasta), logo NÃO mostra "None"
        fzf_input="${OPT_ADD}\n${OPT_CUSTOM}"
    else
        # Se tem pastas, mostra "None" no topo, seguido das pastas e opções de adição
        fzf_input="${OPT_NONE}\n"
        fzf_input="${fzf_input}$(echo "$allowed_dirs" | tr ':' '\n')\n"
        fzf_input="${fzf_input}${OPT_ADD}\n${OPT_CUSTOM}"
    fi

    local user_choice=$(echo -e "$fzf_input" | fzf --prompt "${ICON_FOLDER} Select Folder to Enter: ")

    if [ -z "$user_choice" ]; then echo -e "${RED}Aborted.${RESET}"; return 1; fi

    # Logica de Tratamento da Escolha
    if [ "$user_choice" = "$OPT_NONE" ]; then
        # Mantém o diretório atual
        selected_dir="."
        
    elif [ "$user_choice" = "$OPT_ADD" ] || [ "$user_choice" = "$OPT_CUSTOM" ]; then
        local target_path_to_add=""

        if [ "$user_choice" = "$OPT_ADD" ]; then
            target_path_to_add=$(pwd)
        elif [ "$user_choice" = "$OPT_CUSTOM" ]; then
            echo -n -e "${GREEN}${ICON_PROMPT} Enter path: ${RESET}"; read -e input_path
            if [ -z "$input_path" ] || [ ! -d "$input_path" ]; then
                echo -e "${RED}${ICON_ERROR} Invalid directory.${RESET}"; return 1
            fi
            target_path_to_add=$(cd "$input_path" && pwd)
        fi

        # Verificação de Conflito
        local owner=$(check_dir_owner "$target_path_to_add")
        if [ -n "$owner" ] && [ "$owner" != "$selection" ]; then
            echo -e "${RED}${ICON_ERROR} Conflict: This directory belongs to workspace '${BOLD}$owner${RESET}${RED}'.${RESET}"
            return 1
        fi
        
        if [[ ":$allowed_dirs:" != *":$target_path_to_add:"* ]]; then
            local new_dirs="${allowed_dirs}:${target_path_to_add}"
            new_dirs=${new_dirs#:} 
            save_config_var "WS_DIRS_${selection}" "$new_dirs"
            echo -e "${GREEN}${ICON_LOCK} Directory registered to '$selection': $target_path_to_add${RESET}"
        fi
        selected_dir="$target_path_to_add"
    else
        selected_dir="$user_choice"
    fi
    
    # --- ACTIVATE & ENTER ---
    echo -e "${BLUE_LIGHT}Entering $selected_dir ...${RESET}"
    cd "$selected_dir" || return 1
    
    if [ -n "$FJDK_ACTIVE_WS" ]; then
        local old_bin="$FJDK_WORKSPACES_DIR/$FJDK_ACTIVE_WS/current/bin"
        export PATH=${PATH//$old_bin:/}
    fi
    
    export FJDK_ACTIVE_WS="$selection"
    
    # Auto-Repair com Persistência de Nome
    local ws_current_link="$FJDK_WORKSPACES_DIR/$FJDK_ACTIVE_WS/current"
    if [ -L "$ws_current_link" ] && [ ! -d "$(readlink "$ws_current_link")" ]; then
         # Tenta ler o nome do link quebrado antes de sobrescrever
         local broken_name=$(basename "$(readlink "$ws_current_link")")
         echo "$broken_name" > "$FJDK_WORKSPACES_DIR/$FJDK_ACTIVE_WS/.missing_target"
         
         ln -sfn "$FJDK_NULL_DIR" "$ws_current_link"
    fi
    
    local ws_bin="$ws_current_link/bin"
    export PATH="$ws_bin:$PATH"
    
    if [ $gm_flag -eq 1 ]; then
        echo -e "${RED}${ICON_GLOBE} Enabling GLOBAL MODE...${RESET}"
        if [ -L "$FJDK_CURRENT_LINK" ]; then readlink "$FJDK_CURRENT_LINK" > "$FJDK_GLOBAL_BACKUP"; fi
        local ws_current_target=$(readlink "$ws_current_link")
        if [ -n "$ws_current_target" ]; then ln -sfn "$ws_current_target" "$FJDK_CURRENT_LINK"; fi
        export FJDK_GLOBAL_MODE=1
    fi

    echo -e "${PURPLE}${ICON_ROCKET} Activated: ${BOLD}$FJDK_ACTIVE_WS${RESET}"
    fjdk_using
}

fjdk_install() {
    local feature_version=$1
    if [ -z "$feature_version" ]; then
        feature_version=$(fetch_api_feature_versions | fzf --prompt "${ICON_PROMPT} Install version: ")
        if [ -z "$feature_version" ]; then echo -e "${RED}Aborted.${RESET}" >&2; return 1; fi
    fi
    
    local patch_info
    echo -e "${BLUE_LIGHT}${ICON_INFO} Provider: [Azul]${RESET}"
    patch_info=$(fetch_latest_patch_info_azul "$feature_version")

    if [ -z "$patch_info" ] || [[ "$patch_info" == "ERROR"* ]]; then
        echo -e "${RED}${ICON_ERROR} Error fetching info from Azul.${RESET}" >&2; return 1; fi
    
    local release_name=$(echo "$patch_info" | cut -d'|' -f1) 
    local download_url=$(echo "$patch_info" | cut -d'|' -f3) 
    local sha256_hash=$(echo "$patch_info" | cut -d'|' -f4) 
    
    local dir_name="$release_name" 
    local install_path="$FJDK_VERSIONS_DIR/$dir_name"
    local file_name=$(basename "$download_url"); local tmp_file="/tmp/$file_name"

    if [ -d "$install_path" ]; then echo -e "${YELLOW}${ICON_WARN} Already installed.${RESET}"; return 0; fi
    
    echo -e "${BLUE_LIGHT}Downloading ${BOLD}$release_name${RESET}..."
    curl -L -# -o "$tmp_file" "$download_url"
    if [ $? -ne 0 ]; then echo -e "${RED}${ICON_ERROR} Download failed.${RESET}" >&2; rm -f "$tmp_file"; return 1; fi
    
    verify_sha256 "$tmp_file" "$sha256_hash"
    if [ $? -ne 0 ]; then rm "$tmp_file"; return 1; fi
    
    echo -e "${BLUE_LIGHT}${ICON_GEAR} Extracting...${RESET}"
    mkdir -p "$install_path"
    tar -xzf "$tmp_file" -C "$install_path" --strip-components=1
    if [ $? -ne 0 ]; then echo -e "${RED}${ICON_ERROR} Extraction failed.${RESET}" >&2; rm -rf "$install_path"; return 1; fi
    
    if [ -d "$install_path/Contents/Home" ]; then mv "$install_path/Contents/Home/"* "$install_path/"; rm -rf "$install_path/Contents"; fi
    remove_quarantine "$install_path"
    rm "$tmp_file"
    if [ ! -f "$install_path/bin/java" ]; then echo -e "${RED}${ICON_ERROR} Java bin not found.${RESET}" >&2; rm -rf "$install_path"; return 1; fi
    echo -e "${GREEN}${ICON_OK} Installed: $dir_name${RESET}"
}

fjdk_import() {
    echo -e "${BLUE_LIGHT}${ICON_IMPORT} Importing system JDK...${RESET}"
    local java_bin; java_bin=$(command -v java)
    if [ -z "$java_bin" ]; then echo -e "${RED}${ICON_ERROR} No java found in PATH.${RESET}" >&2; return 1; fi
    local real_java_bin; real_java_bin=$(readlink -f "$java_bin")
    if [[ "$real_java_bin" == *"$FJDK_VERSIONS_DIR"* ]] || [[ "$real_java_bin" == *"$FJDK_EXTERNAL_DIR"* ]]; then
        echo -e "${YELLOW}${ICON_WARN} Already managed by fjdk.${RESET}"; return 0; fi
    
    local java_home; java_home=$(dirname "$(dirname "$real_java_bin")")
    echo -e "${GREEN}Found: ${BOLD}$java_home${RESET}"
    local dir_name; echo -n -e "${GREEN}${ICON_PROMPT}${RESET} Name (Default: jdk-$(basename "$java_home")): "; read dir_name
    if [ -z "$dir_name" ]; then dir_name="jdk-$(basename "$java_home")"; fi
    local install_path="$FJDK_EXTERNAL_DIR/$dir_name"
    if [ -d "$install_path" ]; then echo -e "${RED}Directory exists.${RESET}" >&2; return 1; fi
    echo -e "1) Copy | 2) Move"; echo -n -e "${ICON_PROMPT} "; read ch
    case $ch in 1) cp -R "$java_home" "$install_path" ;; 2) sudo mv "$java_home" "$install_path"; sudo chown -R "$(whoami)" "$install_path" 2>/dev/null || true ;; *) return 1 ;; esac
    remove_quarantine "$install_path"
    echo -e "${GREEN}${ICON_OK} Imported: $dir_name${RESET}"
}

fjdk_install_external() {
    local file_path=$1
    if [ -z "$file_path" ]; then echo -e "${RED}Usage: fjdk install -e /path/file.tar.gz${RESET}" >&2; return 1; fi
    file_path=$(eval echo "\"$file_path\"")
    if [ ! -f "$file_path" ]; then echo -e "${RED}File not found.${RESET}" >&2; return 1; fi
    echo -e "${YELLOW}Do you have a SHA256 checksum to verify? (Press Enter to skip)${RESET}"
    echo -n -e "${ICON_LOCK} Hash: "; read manual_hash
    if [ -n "$manual_hash" ]; then verify_sha256 "$file_path" "$manual_hash"; if [ $? -ne 0 ]; then return 1; fi; fi

    local selected_file_name=$(basename "$file_path")
    local dir_name=""; local guess=$(echo "$selected_file_name" | grep -E -o '(jdk|openjdk)-[0-9u.\-b]+')
    if [ -n "$guess" ]; then dir_name=$(echo "$guess" | sed 's/openjdk-/jdk-/'); fi
    local choice_name=0; if [ -n "$dir_name" ]; then echo -e "${GREEN}Use name: ${BOLD}$dir_name${RESET}? (1=Yes, 2=No): "; read cn; if [ "$cn" = "2" ]; then choice_name=1; fi; else choice_name=1; fi
    if [ $choice_name -eq 1 ]; then echo -n -e "${ICON_PROMPT} Name: "; read dir_name; fi
    if [ -z "$dir_name" ]; then echo -e "${RED}Name required.${RESET}"; return 1; fi
    local install_path="$FJDK_EXTERNAL_DIR/$dir_name"
    if [ -d "$install_path" ]; then echo -e "${RED}Directory exists.${RESET}" >&2; return 1; fi

    echo -e "${BLUE_LIGHT}${ICON_GEAR} Extracting...${RESET}"
    local temp_extract_dir; temp_extract_dir=$(mktemp -d)
    tar -xzf "$file_path" -C "$temp_extract_dir"
    if [ $? -ne 0 ]; then echo -e "${RED}Extract failed.${RESET}" >&2; rm -rf "$temp_extract_dir"; return 1; fi
    
    local java_bin_found; java_bin_found=$(find "$temp_extract_dir" -type f -path "*/bin/java" | head -n 1)
    if [ -z "$java_bin_found" ]; then echo -e "${RED}Invalid JDK.${RESET}" >&2; rm -rf "$temp_extract_dir"; return 1; fi
    local real_java_home; real_java_home=$(dirname "$(dirname "$java_bin_found")")
    mkdir -p "$install_path"
    if mv "$real_java_home"/* "$install_path/" 2>/dev/null; then echo -e "${GREEN}${ICON_OK} Structure normalized.${RESET}"; else cp -R "$real_java_home"/* "$install_path/"; fi
    rm -rf "$temp_extract_dir"; remove_quarantine "$install_path"
    if [ ! -f "$install_path/bin/java" ]; then echo -e "${RED}Install failed.${RESET}" >&2; rm -rf "$install_path"; return 1; fi
    echo -e "${GREEN}${ICON_OK} Installed: $dir_name${RESET}"
    echo -n -e "${YELLOW}Use now? (y/N) ${RESET}"; read -r -n 1 answer; echo ""
    if [[ "$answer" =~ ^[Yy]$ ]]; then fjdk_use "$dir_name"; fi
}

fjdk() {
    mkdir -p "$FJDK_VERSIONS_DIR"; mkdir -p "$FJDK_EXTERNAL_DIR"; mkdir -p "$FJDK_WORKSPACES_DIR"
    local command=$1; shift
    case $command in
        install) if [ "$1" = "-e" ]; then fjdk_install_external "$2"; else fjdk_install "$@"; fi ;;
        import) fjdk_import "$@" ;;
        use) fjdk_use "$@" ;;
        list|ls) if [ "$1" = "-remote" ]; then fjdk_list_remote; else fjdk_list_local; fi ;;
        remove) fjdk_uninstall "$@" ;;
        using) fjdk_using ;;
        ws) fjdk_ws "$@" ;;
        update) fjdk_update ;; 
        config) fjdk_config "$@" ;;
        -v|-version) fjdk_version ;;
        -h|-help) fjdk_help ;;
        *) fjdk_help; return 1 ;;
    esac
}