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
# 0.4.0 - replaced fdkaac tag injection with AtomicParsley for iPod container compatibility;
#         added cover art sanitization (200x200 baseline JPEG); removed ffmpeg repacking step
#         entirely; kept all audio analysis and SoX logic intact.
# 0.5.0 - feat: implement interactive pre-flight metadata validation
#         refactor: decouple tag extraction from audio processing loop
#         perf: process cover art sanitization only once per album
#         feat: add support for multi-disc and total tracks tags
#         fix: bash arithmetic evaluation triggering set -e on track count
# 0.6.0 - feat: extract audio analysis to a pre-flight phase
#         feat: add processing strategy summary and confirmation prompt
#         refactor: worker phase now relies entirely on pre-calculated arrays
#         style: update interactive prompts to formal English


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

# Arrays for audio analysis strategy
TRACK_BPS=()
TRACK_SRATE=()
TRACK_NEEDS_SOX=()
TRACK_OUT_SRATE=()
TRACK_AAC_PARAMS=()
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
    echo "ift.sh version 0.6.0"
    exit 0
fi

if $show_help; then
    cat <<EOF
ift.sh - Intelligent FLAC Transcoder
Version 0.6.0

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
    read -r -p "Please select the desired output format (aac/mp3): " target
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
# PHASE 1: PRE-FLIGHT SCAN & METADATA VALIDATION
# =============================================================================
log_debug "Starting Pre-flight scan..."

for f in *.flac; do
    [ -e "$f" ] || continue
    FILE_PATHS+=("$f")
    TOTAL_TRACKS=$((TOTAL_TRACKS + 1))
done

if [ "$TOTAL_TRACKS" -eq 0 ]; then
    echo "No FLAC files found in the current directory."
    exit 0
fi

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

    if [ "$i" -eq 0 ]; then
        ALBUM_TITLE="$t_album"
        ALBUM_ARTIST="$t_artist"
        ALBUM_GENRE="$t_genre"
        ALBUM_YEAR="$t_year"
        
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

while true; do
    clear
    echo "=== Metadata Validation ==="
    
    read -r -p "Album Title [$ALBUM_TITLE]: " input; [ -n "$input" ] && ALBUM_TITLE="$input"
    read -r -p "Album Artist [$ALBUM_ARTIST]: " input; [ -n "$input" ] && ALBUM_ARTIST="$input"
    read -r -p "Genre [$ALBUM_GENRE]: " input; [ -n "$input" ] && ALBUM_GENRE="$input"
    read -r -p "Release Year [$ALBUM_YEAR]: " input; [ -n "$input" ] && ALBUM_YEAR="$input"

    read -r -p "Does this release consist of multiple discs? (y/n) [n]: " is_multidisc
    if [[ "$is_multidisc" =~ ^[Yy]$ ]]; then
        read -r -p "Current Disc Number [$DISC_NUM]: " input; [ -n "$input" ] && DISC_NUM="$input"
        read -r -p "Total Number of Discs [$TOTAL_DISCS]: " input; [ -n "$input" ] && TOTAL_DISCS="$input"
    else
        DISC_NUM="1"
        TOTAL_DISCS="1"
    fi

    if [ -z "$ALBUM_COVER" ] || [ ! -f "$ALBUM_COVER" ]; then
        if [ -f "cover.jpg" ] || [ -f "cover.png" ]; then
            local_cov=$(ls cover.* | head -n 1)
            read -r -p "Local file '$local_cov' detected. Use this as the album cover? (y/n) [y]: " use_local
            if [[ -z "$use_local" || "$use_local" =~ ^[Yy]$ ]]; then
                ALBUM_COVER="$local_cov"
            fi
        fi
    fi
    
    if [ -z "$ALBUM_COVER" ] || [ ! -f "$ALBUM_COVER" ]; then
        read -r -p "Please provide the path to the cover image (leave blank to skip): " input
        [ -n "$input" ] && ALBUM_COVER="$input"
    fi

    echo -e "\n--- Validating Tracks ---"
    for i in "${!FILE_PATHS[@]}"; do
        if [ -z "${TRACK_TITLES[$i]}" ]; then
            read -r -p "Title missing for '${FILE_PATHS[$i]}'. Please enter the title: " input
            TRACK_TITLES[$i]="$input"
        fi
        if [ -z "${TRACK_NUMS[$i]}" ]; then
            read -r -p "Track number missing for '${FILE_PATHS[$i]}'. Please enter the track number: " input
            TRACK_NUMS[$i]="$input"
        fi
    done

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
        [Cc]*) echo "Operation cancelled by the user."; exit 0 ;;
        *) echo "Restarting validation..." ;;
    esac
done

# =============================================================================
# PHASE 2: AUDIO PRE-ANALYSIS & STRATEGY
# =============================================================================
log_debug "Starting Audio Pre-analysis Phase..."
echo "Analyzing audio streams. Please wait..."

for i in "${!FILE_PATHS[@]}"; do
    f="${FILE_PATHS[$i]}"
    
    srate=$(metaflac --show-sample-rate "$f")
    bps=$(metaflac --show-bps "$f")
    
    TRACK_SRATE+=("$srate")
    TRACK_BPS+=("$bps")
    
    need_sox=false
    rate_out=44100
    aac_params=""

    if [ "$target" = "aac" ]; then
        if [ "$bps" -eq 16 ] && { [ "$srate" -eq 44100 ] || [ "$srate" -eq 48000 ]; }; then
            rate_out="$srate"
        else
            need_sox=true
            rate_out=48000
        fi
        aac_params=$(analyze_aac_params "$f")
    else
        if [ "$bps" -eq 16 ] && [ "$srate" -eq 44100 ]; then
            rate_out=44100
        else
            need_sox=true
            rate_out=44100
        fi
    fi

    TRACK_NEEDS_SOX+=("$need_sox")
    TRACK_OUT_SRATE+=("$rate_out")
    TRACK_AAC_PARAMS+=("$aac_params")
done

# Display Processing Strategy Summary
clear
echo "========================================"
echo "      PROCESSING STRATEGY SUMMARY       "
echo "========================================"

for i in "${!FILE_PATHS[@]}"; do
    srate_in_fmt=$(awk "BEGIN {print ${TRACK_SRATE[$i]}/1000 \"k\"}")
    srate_out_fmt=$(awk "BEGIN {print ${TRACK_OUT_SRATE[$i]}/1000 \"k\"}")
    bps_in="${TRACK_BPS[$i]}"
    
    if ${TRACK_NEEDS_SOX[$i]}; then
        sox_str="SoX: ${bps_in}/${srate_in_fmt} -> 16/${srate_out_fmt}"
    else
        sox_str="Audio: ${bps_in}/${srate_in_fmt} (Unchanged)"
    fi
    
    if [ "$target" = "aac" ]; then
        enc_str="FDKAAC: ${TRACK_AAC_PARAMS[$i]}"
    else
        enc_str="LAME: VBR V4"
    fi
    
    printf "%02d - %s\n    [ %s ] [ %s ]\n" "${TRACK_NUMS[$i]}" "${FILE_PATHS[$i]}" "$sox_str" "$enc_str"
    
    # Store for final summary
    summary_lines+=("${FILE_PATHS[$i]} : $sox_str ; $enc_str")
done
echo "========================================"

read -r -p "Do you wish to proceed with this processing strategy? (y - Proceed / c - Cancel): " confirm_strat
case "$confirm_strat" in
    [Yy]*) echo "Starting conversion..." ;;
    *) echo "Operation cancelled by the user."; exit 0 ;;
esac

# =============================================================================
# PHASE 3: WORKER (PROCESSING)
# =============================================================================
log_debug "Starting Worker Phase..."

if [ -n "$ALBUM_COVER" ] && [ -f "$ALBUM_COVER" ]; then
    log_debug "Optimizing cover art: $ALBUM_COVER"
    ffmpeg -y -i "$ALBUM_COVER" -vf "scale='min(200,iw)':'min(200,ih)'" \
        -pix_fmt yuvj420p -frames:v 1 -q:v 5 "$TMP_OPT_COVER" 2>/dev/null || true
fi

for i in "${!FILE_PATHS[@]}"; do
    f="${FILE_PATHS[$i]}"
    log_debug "--- Processing: $f ---"

    need_sox="${TRACK_NEEDS_SOX[$i]}"
    rate_out="${TRACK_OUT_SRATE[$i]}"
    srate="${TRACK_SRATE[$i]}"
    bps="${TRACK_BPS[$i]}"

    if [ "$target" = "aac" ]; then
        fdkaac_params="${TRACK_AAC_PARAMS[$i]}"
        tmp_naked="/tmp/tmp_naked_$(basename "$f" .flac).m4a"

        if $need_sox; then
            flac -s -d --force-raw-format --endian=little --sign=signed -c "$f" | \
                sox -G -r "$srate" -c 2 -b "$bps" -e signed-integer -t raw - \
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
                sox -G -r "$srate" -c 2 -b "$bps" -e signed-integer -t raw - \
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
done

# --- Final summary report ---
echo ""
echo "========== Conversion Summary =========="
printf '%s\n' "${summary_lines[@]}"
echo "========================================"

log_debug "All conversions completed."
echo "All conversions completed."
