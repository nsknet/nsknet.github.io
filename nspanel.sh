#!/bin/bash
set -e

[ "$EUID" -eq 0 ] && SUDO="" || SUDO="sudo"

# Ensure git is installed
command -v git >/dev/null 2>&1 || { $SUDO apt-get update -y && $SUDO apt-get install -y git; }

# Locate repository and panel directories
if [ -f "NsPanel/run.sh" ]; then
    REPO_DIR="."
    PANEL_DIR="NsPanel"
elif [ -f "run.sh" ]; then
    REPO_DIR=".."
    PANEL_DIR="."
else
    REPO_DIR="nsknet.github.io"
    PANEL_DIR="nsknet.github.io/NsPanel"
    if [ ! -d "$REPO_DIR" ]; then
        echo "Cloning NsPanel repository..."
        git clone https://github.com/nsknet/nsknet.github.io.git "$REPO_DIR"
    fi
fi

# Detect branch from environment (BRANCH / GIT_BRANCH) or arguments
TARGET_BRANCH="${BRANCH:-${GIT_BRANCH:-}}"

if [ -z "$TARGET_BRANCH" ]; then
    for arg in "$@"; do
        if [ "$arg" = "-b" ] || [ "$arg" = "--branch" ]; then
            continue
        elif [ -n "$arg" ] && [ "$arg" != "--" ]; then
            TARGET_BRANCH="$arg"
            break
        fi
    done
fi

if [ -z "$TARGET_BRANCH" ]; then
    case "$0" in
        bash|sh|/bin/bash|/usr/bin/bash|/bin/sh|/usr/bin/sh|--|*nspanel.sh)
            ;;
        *)
            TARGET_BRANCH="$0"
            ;;
    esac
fi

# Fetch latest branches & commits
if [ -d "$REPO_DIR/.git" ]; then
    git -C "$REPO_DIR" fetch --all --prune --quiet 2>/dev/null || true

    CURRENT_BRANCH=$(git -C "$REPO_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "main")
    DEFAULT_BRANCH="${CURRENT_BRANCH:-main}"

    # If branch was not specified via args/env, prompt when running in an interactive terminal
    if [ -z "$TARGET_BRANCH" ]; then
        RAW_BRANCHES=($(git -C "$REPO_DIR" branch -r 2>/dev/null | sed "s/origin\///" | tr -d " *" | grep -v "HEAD" | sort -u))
        BRANCH_LIST=()
        if [[ " ${RAW_BRANCHES[@]} " =~ " ${DEFAULT_BRANCH} " ]]; then
            BRANCH_LIST+=("$DEFAULT_BRANCH")
        fi
        for b in "${RAW_BRANCHES[@]}"; do
            if [ "$b" != "$DEFAULT_BRANCH" ]; then
                BRANCH_LIST+=("$b")
            fi
        done

        if [ ${#BRANCH_LIST[@]} -gt 1 ] && [ -t 0 ]; then
            echo ""
            echo "Available branches:"
            for i in "${!BRANCH_LIST[@]}"; do
                b="${BRANCH_LIST[$i]}"
                if [ "$b" = "$DEFAULT_BRANCH" ]; then
                    echo "  $((i+1))) $b (current/default)"
                else
                    echo "  $((i+1))) $b"
                fi
            done
            read -t 10 -p "Select branch [1-${#BRANCH_LIST[@]}, default: $DEFAULT_BRANCH]: " USER_INPUT || true
            echo ""
            if [[ "$USER_INPUT" =~ ^[0-9]+$ ]] && [ "$USER_INPUT" -ge 1 ] && [ "$USER_INPUT" -le "${#BRANCH_LIST[@]}" ]; then
                TARGET_BRANCH="${BRANCH_LIST[$((USER_INPUT-1))]}"
            elif [ -n "$USER_INPUT" ]; then
                TARGET_BRANCH="$USER_INPUT"
            else
                TARGET_BRANCH="$DEFAULT_BRANCH"
            fi
        else
            TARGET_BRANCH="$DEFAULT_BRANCH"
        fi
    fi

    echo "Using branch: $TARGET_BRANCH"
    git -C "$REPO_DIR" checkout "$TARGET_BRANCH" 2>/dev/null || git -C "$REPO_DIR" checkout -b "$TARGET_BRANCH" "origin/$TARGET_BRANCH" 2>/dev/null || true
    git -C "$REPO_DIR" pull origin "$TARGET_BRANCH" 2>/dev/null || git -C "$REPO_DIR" pull 2>/dev/null || true
fi

cd "$PANEL_DIR"
chmod +x run.sh 2>/dev/null || true
$SUDO ./run.sh "$@"

