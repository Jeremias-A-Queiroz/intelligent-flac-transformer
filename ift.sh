#!/usr/bin/env bash
#
# ift.sh — Intelligent FLAC transcoder for iPod (AAC) or T-Rex 3 (MP3)
# Copyright (C) 2025  jeremias@infralinux.com.br
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.

# Version history
# 0.1.0 - initial version (not numbered)
# 0.2.0 - added debug flag (-d), direct format flags (-mp3, -aac), version (-v) and help (-h)
# 0.2.1 - added final summary report showing SoX usage and AAC quality decisions
# 0.2.2 - removed eval pipeline (spaces in filenames), individual cover temp files
# 0.3.0 - replaced fdkaac tag injection with AtomicParsley; added cover art sanitization
# 0.5.0 - feat: implement interactive pre-flight metadata validation
#         refactor: decouple tag extraction from audio processing loop
#         perf: process cover art sanitization only once per album
#         feat: add support for multi-disc and total tracks tags
#         fix: bash arithmetic evaluation triggering set -e on track count

set -euo pipefail

# Global flags & variables
debug=false
target=""
show_version=false
show_help=false

# Metadata globals
ALBUM_TITLE=""
ALBUM_ARTIST=""
ALBUM_GENRE=""
ALBUM_YEAR=""
ALBUM_COVER=""
DISC_NUM="1"
TOTAL_DISCS="1"
TOTAL_TRACKS=0

# Arrays for track-specific data
FILE_PATHS=()
TRACK_TITLES=()
TRACK_NUMS=()
summary_lines=()

# Temp files
TMP_EXTRACTED_COVER="/tmp/ift_extracted_cover_$$.jpg"
TMP_OPT_COVER="/tmp/ift_opt_cover_$$.jpg"

# --- Parse command-line options ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        -aac) target="aac" ;;
        -mp3) target="mp3" ;;
        -d)   debug=true ;;
        -v)   show_version=true ;;
        -h)   show_help=true ;;
        *)    echo "Unknown option: $1" >&2; exit 1 ;;
    esac
    shift
done

if $show_version; then
    echo "ift.sh version 0.5.0"
    exit 0
fi

if $show_help; then
    cat <<EOF
ift.sh - Intelligent FLAC Transcoder
Version 0.5.0

Usage: $0 [-mp3|-aac] [-d] [-v] [-h]
  -mp3    Directly transcode to MP3 (LAME V4, 16-bit 44.1kHz)
  -aac    Directly transcode to AAC (fdkaac, adaptive VBR)
  -d      Enable debug logging to debug.log in the current directory
  -v      Print version and exit
  -h      Show this help

No format flag: interactive prompt.
EOF
    exit 0
fi

# --- Dependency Check ---
for cmd in flac sox fdkaac lame ffmpeg awk AtomicParsley; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "Error: Required dependency '$cmd' not found in PATH." >&2
        exit 1
    fi
done

# --- Setup debug logging & Traps ---
if $debug; then
    exec 3>> debug.log
    log_debug() { echo "$(date '+%Y-%m-%d %H:%M:%S') - $*" >&3; }
else
    exec 3>/dev/null
    log_debug() { :; }
fi

cleanup() {
    rm -f "$TMP_EXTRACTED_COVER" "$TMP_OPT_COVER" /tmp/tmp_naked_*.m4a
}
trap 'log_debug "ERROR occurred (exit code $?). Aborting."; cleanup; echo "Error occurred. Re-run with -d for debug log." >&2; exit 1' ERR
trap cleanup EXIT

# --- Target Format Prompt ---
if [ -z "$target" ]; then
    read -r -p "Please select the output format (aac/mp3): " target
    if [ "$target" != "aac" ] && [ "$target" != "mp3" ]; then
        echo "Error: Invalid format '$target'. Please choose 'aac' or 'mp3'." >&2
        exit 1
    fi
fi
log_debug "Target format set to: $target"

# --- Helper: AAC Analysis ---
analyze_aac_params() {
    local flac_file="$1"
    local r_ref r_mid r_high params

    r_ref=$(ffmpeg -i "$flac_file" -ac 1 -af "volumedetect" -f null - 2>&1 | awk '/mean_volume/ {print $5}')
    r_mid=$(ffmpeg -i "$flac_file" -ac 1 -af "highpass=f=15500,lowpass=f=17000,volumedetect" -f null - 2>&1 | awk '/mean_volume/ {print $5}')
    r_high=$(ffmpeg -i "$flac_file" -ac 1 -af "highpass=f=17000,volumedetect" -f null - 2>&1 | awk '/mean_volume/ {print $5}')

    params=$(awk -v ref="$r_ref" -v mid="$r_mid" -v high="$r_high" '
    BEGIN {
        d_high = high - ref
        d_mid  = mid - ref
        if (d_high >= -31.0) print "-m 5"
        else if (d_mid >= -31.0) print "-m 4 -w 17000"
        else print "-m 4"
    }')
    echo "$params"
}

# =============================================================================
# PHASE 1: PRE-FLIGHT SCAN & VALIDATION
# =============================================================================
log_debug "Starting Pre-flight scan..."

# Glob files
for f in *.flac; do
    [ -e "$f" ] || continue
    FILE_PATHS+=("$f")
    # Fix: avoid post-increment returning 0 and triggering set -e
    TOTAL_TRACKS=$((TOTAL_TRACKS + 1))
done

if [ "$TOTAL_TRACKS" -eq 0 ]; then
    echo "No FLAC files found in the current directory."
    exit 0
fi

# Extract initial metadata to arrays and check consistency
for i in "${!FILE_PATHS[@]}"; do
    f="${FILE_PATHS[$i]}"
    
    t_title=$(metaflac --show-tag=TITLE "$f" 2>/dev/null | cut -d= -f2- || true)
    t_num=$(metaflac --show-tag=TRACKNUMBER "$f" 2>/dev/null | cut -d= -f2- || true)
    t_album=$(metaflac --show-tag=ALBUM "$f" 2>/dev/null | cut -d= -f2- || true)
    t_artist=$(metaflac --show-tag=ARTIST "$f" 2>/dev/null | cut -d= -f2- || true)
    t_genre=$(metaflac --show-tag=GENRE "$f" 2>/dev/null | cut -d= -f2- || true)
    t_year=$(metaflac --show-tag=DATE "$f" 2>/dev/null | cut -d= -f2- || true)

    TRACK_TITLES+=("$t_title")
    TRACK_NUMS+=("$t_num")

    # Consistency check for album globals
    if [ "$i" -eq 0 ]; then
        ALBUM_TITLE="$t_album"
        ALBUM_ARTIST="$t_artist"
        ALBUM_GENRE="$t_genre"
        ALBUM_YEAR="$t_year"
        
        # Try to extract embedded cover from the first track
        if metaflac --export-picture-to="$TMP_EXTRACTED_COVER" "$f" 2>/dev/null; then
            ALBUM_COVER="$TMP_EXTRACTED_COVER"
        fi
    else
        [ "$ALBUM_TITLE" != "$t_album" ] && ALBUM_TITLE=""
        [ "$ALBUM_ARTIST" != "$t_artist" ] && ALBUM_ARTIST=""
        [ "$ALBUM_GENRE" != "$t_genre" ] && ALBUM_GENRE=""
        [ "$ALBUM_YEAR" != "$t_year" ] && ALBUM_YEAR=""
    fi
done

# Interactive Validation Loop
while true; do
    clear
    echo "=== Metadata Validation ==="
    
    # Prompt for Album globals
    read -r -p "Album Title [$ALBUM_TITLE]: " input; [ -n "$input" ] && ALBUM_TITLE="$input"
    read -r -p "Album Artist [$ALBUM_ARTIST]: " input; [ -n "$input" ] && ALBUM_ARTIST="$input"
    read -r -p "Genre [$ALBUM_GENRE]: " input; [ -n "$input" ] && ALBUM_GENRE="$input"
    read -r -p "Release Year [$ALBUM_YEAR]: " input; [ -n "$input" ] && ALBUM_YEAR="$input"

    # Multi-disc prompt
    read -r -p "Is this a multi-disc release? (y/n) [n]: " is_multidisc
    if [[ "$is_multidisc" =~ ^[Yy]$ ]]; then
        read -r -p "Current Disc Number [$DISC_NUM]: " input; [ -n "$input" ] && DISC_NUM="$input"
        read -r -p "Total Number of Discs [$TOTAL_DISCS]: " input; [ -n "$input" ] && TOTAL_DISCS="$input"
    else
        DISC_NUM="1"
        TOTAL_DISCS="1"
    fi

    # Cover Art prompt
    if [ -z "$ALBUM_COVER" ] || [ ! -f "$ALBUM_COVER" ]; then
        if [ -f "cover.jpg" ] || [ -f "cover.png" ]; then
            local_cov=$(ls cover.* | head -n 1)
            read -r -p "Local '$local_cov' found. Use as album cover? (y/n) [y]: " use_local
            if [[ -z "$use_local" || "$use_local" =~ ^[Yy]$ ]]; then
                ALBUM_COVER="$local_cov"
            fi
        fi
    fi
    
    if [ -z "$ALBUM_COVER" ] || [ ! -f "$ALBUM_COVER" ]; then
        read -r -p "Provide path to cover image (leave blank to skip): " input
        [ -n "$input" ] && ALBUM_COVER="$input"
    fi

    # Track-level validation
    echo -e "\n--- Validating Tracks ---"
    for i in "${!FILE_PATHS[@]}"; do
        if [ -z "${TRACK_TITLES[$i]}" ]; then
            read -r -p "Missing Title for '${FILE_PATHS[$i]}'. Enter title: " input
            TRACK_TITLES[$i]="$input"
        fi
        if [ -z "${TRACK_NUMS[$i]}" ]; then
            read -r -p "Missing Track Number for '${FILE_PATHS[$i]}'. Enter number: " input
            TRACK_NUMS[$i]="$input"
        fi
    done

    # Display Summary Form
    clear
    echo "========================================"
    echo "          ALBUM METADATA SUMMARY        "
    echo "========================================"
    echo "Artist:      $ALBUM_ARTIST"
    echo "Album:       $ALBUM_TITLE"
    echo "Genre:       $ALBUM_GENRE"
    echo "Year:        $ALBUM_YEAR"
    echo "Disc:        $DISC_NUM of $TOTAL_DISCS"
    echo "Cover Path:  ${ALBUM_COVER:-None}"
    echo "----------------------------------------"
    for i in "${!FILE_PATHS[@]}"; do
        printf "%02d - %s (%s)\n" "${TRACK_NUMS[$i]}" "${TRACK_TITLES[$i]}" "${FILE_PATHS[$i]}"
    done
    echo "========================================"

    read -r -p "Are the provided details correct? (y - Proceed / n - Edit / c - Cancel): " confirm
    case "$confirm" in
        [Yy]*) break ;;
        [Cc]*) echo "Operation cancelled by user."; exit 0 ;;
        *) echo "Restarting validation..." ;;
    esac
done

# =============================================================================
# PHASE 2: WORKER (PROCESSING)
# =============================================================================
log_debug "Starting Worker Phase..."

# Optimize cover art ONCE for the entire album
if [ -n "$ALBUM_COVER" ] && [ -f "$ALBUM_COVER" ]; then
    log_debug "Optimizing cover art: $ALBUM_COVER"
    ffmpeg -y -i "$ALBUM_COVER" -vf "scale='min(200,iw)':'min(200,ih)'" \
        -pix_fmt yuvj420p -frames:v 1 -q:v 5 "$TMP_OPT_COVER" 2>/dev/null || true
else
    log_debug "No valid cover art provided. Skipping cover optimization."
fi

# Main processing loop using array indices
for i in "${!FILE_PATHS[@]}"; do
    f="${FILE_PATHS[$i]}"
    log_debug "--- Processing: $f ---"

    SAMPLERATE=$(metaflac --show-sample-rate "$f")
    BPS=$(metaflac --show-bps "$f")
    
    # Determine SoX usage
    need_sox=false
    sox_detail="none"
    if [ "$target" = "aac" ]; then
        if [ "$BPS" -eq 16 ] && { [ "$SAMPLERATE" -eq 44100 ] || [ "$SAMPLERATE" -eq 48000 ]; }; then
            rate_out="$SAMPLERATE"
        else
            need_sox=true
            rate_out=48000
            sox_detail="${BPS}/${SAMPLERATE%??}k -> 16/${rate_out%??}k"
        fi
    else
        if [ "$BPS" -eq 16 ] && [ "$SAMPLERATE" -eq 44100 ]; then
            rate_out=44100
        else
            need_sox=true
            rate_out=44100
            sox_detail="${BPS}/${SAMPLERATE%??}k -> 16/${rate_out%??}k"
        fi
    fi

    # Encode and Tag
    aac_quality=""
    if [ "$target" = "aac" ]; then
        fdkaac_params=$(analyze_aac_params "$f")
        aac_quality="$fdkaac_params"
        tmp_naked="/tmp/tmp_naked_$(basename "$f" .flac).m4a"

        if $need_sox; then
            flac -s -d --force-raw-format --endian=little --sign=signed -c "$f" | \
                sox -G -r "$SAMPLERATE" -c 2 -b "$BPS" -e signed-integer -t raw - \
                    -b 16 -t raw - rate -h "$rate_out" | \
                fdkaac -p 2 $fdkaac_params --raw --raw-channels 2 --raw-rate "$rate_out" --raw-format s16L -o "$tmp_naked" -
        else
            flac -s -d --force-raw-format --endian=little --sign=signed -c "$f" | \
                fdkaac -p 2 $fdkaac_params --raw --raw-channels 2 --raw-rate "$rate_out" --raw-format s16L -o "$tmp_naked" -
        fi

        cov_flag=()
        [ -f "$TMP_OPT_COVER" ] && cov_flag=(--artwork "$TMP_OPT_COVER")

        AtomicParsley "$tmp_naked" \
            --title "${TRACK_TITLES[$i]}" \
            --artist "$ALBUM_ARTIST" \
            --album "$ALBUM_TITLE" \
            --tracknum "${TRACK_NUMS[$i]}/$TOTAL_TRACKS" \
            --disk "$DISC_NUM/$TOTAL_DISCS" \
            --year "$ALBUM_YEAR" \
            --genre "$ALBUM_GENRE" \
            "${cov_flag[@]}" \
            --overWrite >/dev/null 2>&1

        mv -f "$tmp_naked" "${f%.flac}.m4a"

    else
        srate_lame=$(awk "BEGIN {printf \"%.1f\", $rate_out/1000}")
        
        COVER_ARGS=()
        [ -f "$TMP_OPT_COVER" ] && COVER_ARGS=(--ti "$TMP_OPT_COVER")

        if $need_sox; then
            flac -s -d --force-raw-format --endian=little --sign=signed -c "$f" | \
                sox -G -r "$SAMPLERATE" -c 2 -b "$BPS" -e signed-integer -t raw - \
                    -b 16 -t raw - rate -h "$rate_out" | \
                lame -r -s "$srate_lame" --bitwidth 16 --signed --little-endian -V 4 \
                    --tt "${TRACK_TITLES[$i]}" --ta "$ALBUM_ARTIST" --tl "$ALBUM_TITLE" \
                    --tn "${TRACK_NUMS[$i]}/$TOTAL_TRACKS" --ty "$ALBUM_YEAR" --tg "$ALBUM_GENRE" \
                    --tv "TPOS=$DISC_NUM/$TOTAL_DISCS" "${COVER_ARGS[@]}" - "${f%.flac}.mp3"
        else
            flac -s -d --force-raw-format --endian=little --sign=signed -c "$f" | \
                lame -r -s "$srate_lame" --bitwidth 16 --signed --little-endian -V 4 \
                    --tt "${TRACK_TITLES[$i]}" --ta "$ALBUM_ARTIST" --tl "$ALBUM_TITLE" \
                    --tn "${TRACK_NUMS[$i]}/$TOTAL_TRACKS" --ty "$ALBUM_YEAR" --tg "$ALBUM_GENRE" \
                    --tv "TPOS=$DISC_NUM/$TOTAL_DISCS" "${COVER_ARGS[@]}" - "${f%.flac}.mp3"
        fi
    fi

    # Build summary
    line="$f : SoX: $sox_detail"
    [ "$target" = "aac" ] && line+=" ; AAC: $aac_quality" || line+=" ; MP3: VBR V4"
    summary_lines+=("$line")
done

# --- Final summary report ---
echo ""
echo "========== Conversion Summary =========="
printf '%s\n' "${summary_lines[@]}"
echo "========================================"

log_debug "All conversions completed."
echo "All conversions completed."
