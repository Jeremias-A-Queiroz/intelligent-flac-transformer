#!/usr/bin/env bash
#
# ift.sh — Intelligent FLAC transcoder for iPod (AAC) or T-Rex 3 (MP3)
# Copyright (C) 2025  <your name/email>
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.

# Version history
# 0.1.0 - initial version (not numbered)
# 0.2.0 - added debug flag (-d), direct format flags (-mp3, -aac), version (-v) and help (-h),
#         error handling with clear guidance for debugging

set -euo pipefail

# Global flags
debug=false
target=""
show_version=false
show_help=false

# --- Parse command-line options ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        -aac) target="aac" ;;         # set target to AAC
        -mp3) target="mp3" ;;         # set target to MP3
        -d)   debug=true ;;           # enable debug log
        -v)   show_version=true ;;   # print version
        -h)   show_help=true ;;      # print help
        *)    echo "Unknown option: $1" >&2; exit 1 ;;
    esac
    shift
done

if $show_version; then
    echo "ift.sh version 0.2.0"
    exit 0
fi

if $show_help; then
    cat <<EOF
ift.sh - Intelligent FLAC Transcoder
Version 0.2.0

Usage: $0 [-mp3|-aac] [-d] [-v] [-h]
  -mp3    Directly transcode to MP3 (LAME V4, 16-bit 44.1kHz)
  -aac    Directly transcode to AAC (fdkaac, adaptive VBR, 16-bit 44.1kHz or 48kHz)
  -d      Enable debug logging to debug.log in the current directory
  -v      Print version and exit
  -h      Show this help

No format flag: interactive prompt.

Basic workflow:
  1. Scans all FLAC files in the current directory.
  2. Extracts metadata (title, artist, album, track, date, genre, cover).
  3. Determines if SoX resampling is needed based on target and source bit-depth/sample rate.
  4. For MP3: always converts to 16-bit 44.1kHz; encodes with LAME -V 4.
  5. For AAC: uses adaptive fdkaac quality based on high-frequency energy analysis.
     - Levels: -m 5 (no lowpass), -m 4 -w 17000 (lowpass at 17kHz), -m 4 (no explicit lowpass).
  6. After AAC encoding, repacks .m4a files with faststart to prevent iPod reboots.

Dependencies: flac (metaflac), sox, fdkaac, lame (for MP3), ffmpeg, awk, bash 4+
EOF
    exit 0
fi

# --- Setup debug logging ---
if $debug; then
    exec 3>> debug.log
    log_debug() { echo "$(date '+%Y-%m-%d %H:%M:%S') - $*" >&3; }
else
    exec 3>/dev/null
    log_debug() { :; }
fi

# --- Error trap ---
trap 'log_debug "ERROR occurred (exit code $?). Aborting."; echo "Error occurred. Re-run with -d for debug log or with bash -x for low-level trace." >&2; exit 1' ERR

# --- Interactive prompt if no format flag given ---
if [ -z "$target" ]; then
    read -r -p "Output format (aac/mp3)? " target
    if [ "$target" != "aac" ] && [ "$target" != "mp3" ]; then
        echo "Error: unknown type '$target', please choose 'aac' or 'mp3'" >&2
        exit 1
    fi
fi

log_debug "Target format set to: $target"

# --- Helper: choose fdkaac parameters based on high-frequency energy ---
analyze_aac_params() {
    local flac_file="$1"
    local r_ref r_mid r_high d_high d_mid params

    log_debug "Analyzing AAC quality for: $flac_file"

    r_ref=$(ffmpeg -i "$flac_file" -ac 1 -af "volumedetect" -f null - 2>&1 |
            awk '/mean_volume/ {print $5}')
    log_debug "  Full-range mean volume: $r_ref dB"

    r_mid=$(ffmpeg -i "$flac_file" -ac 1 \
            -af "highpass=f=15500,lowpass=f=17000,volumedetect" \
            -f null - 2>&1 |
            awk '/mean_volume/ {print $5}')
    log_debug "  15.5k-17k band mean volume: $r_mid dB"

    r_high=$(ffmpeg -i "$flac_file" -ac 1 \
             -af "highpass=f=17000,volumedetect" \
             -f null - 2>&1 |
             awk '/mean_volume/ {print $5}')
    log_debug "  >17k band mean volume: $r_high dB"

    # Decision based on relative levels
    params=$(awk -v ref="$r_ref" -v mid="$r_mid" -v high="$r_high" '
    BEGIN {
        d_high = high - ref
        d_mid  = mid - ref
        if (d_high >= -31.0) {
            print "-m 5"
            reason = "strong >17k"
        } else if (d_mid >= -31.0) {
            print "-m 4 -w 17000"
            reason = "weak >17k but active 15.5k-17k"
        } else {
            print "-m 4"
            reason = "no useful energy above 15.5k"
        }
    }' | tee >(cat >&3) 2>/dev/null)  # capture params and also log them

    log_debug "  Decision: $params"
    echo "$params"
}

# --- Main conversion loop ---
for f in *.flac; do
    # Skip if glob did not match
    [ -e "$f" ] || continue

    log_debug "--- Processing: $f ---"

    # Clean up temporary cover file
    rm -f /tmp/cover.jpg

    # Extract metadata (ignore missing tags gracefully)
    metaflac --export-picture-to=/tmp/cover.jpg "$f" 2>/dev/null || true
    log_debug "  Cover export attempted"

    TITLE=$(metaflac --show-tag=TITLE "$f" 2>/dev/null | cut -d= -f2-) || true
    ARTIST=$(metaflac --show-tag=ARTIST "$f" 2>/dev/null | cut -d= -f2-) || true
    ALBUM=$(metaflac --show-tag=ALBUM "$f" 2>/dev/null | cut -d= -f2-) || true
    TRACK=$(metaflac --show-tag=TRACKNUMBER "$f" 2>/dev/null | cut -d= -f2-) || true
    DATE=$(metaflac --show-tag=DATE "$f" 2>/dev/null | cut -d= -f2-) || true
    GENRE=$(metaflac --show-tag=GENRE "$f" 2>/dev/null | cut -d= -f2-) || true
    log_debug "  Metadata extracted: title='$TITLE' artist='$ARTIST' album='$ALBUM' track='$TRACK' date='$DATE' genre='$GENRE'"

    SAMPLERATE=$(metaflac --show-sample-rate "$f")
    BPS=$(metaflac --show-bps "$f")
    log_debug "  Source: $BPS-bit @ ${SAMPLERATE}Hz"

    # --- Determine whether SoX is needed and set output sample rate ---
    need_sox=false
    if [ "$target" = "aac" ]; then
        # iPod natively supports 16-bit 44100 & 48000
        if [ "$BPS" -eq 16 ] && { [ "$SAMPLERATE" -eq 44100 ] || [ "$SAMPLERATE" -eq 48000 ]; }; then
            need_sox=false
            rate_out="$SAMPLERATE"
        else
            need_sox=true
            rate_out=48000   # AAC target: down‑convert everything else to 16/48k
        fi
    else  # mp3
        # T‑Rex only likes 16-bit 44100
        if [ "$BPS" -eq 16 ] && [ "$SAMPLERATE" -eq 44100 ]; then
            need_sox=false
            rate_out=44100
        else
            need_sox=true
            rate_out=44100   # MP3 target: always 16/44.1k
        fi
    fi
    log_debug "  Resampling needed: $need_sox, target rate: $rate_out Hz"

    # Build piped decode chain
    decode_pipe=( flac -s -d --force-raw-format --endian=little --sign=signed -c "$f" )

    # Insert SoX if needed
    if $need_sox; then
        decode_pipe+=( \|  sox -G -r "$SAMPLERATE" -c 2 -b "$BPS" -e signed-integer -t raw -  \
                            -b 16 -t raw - rate -h "$rate_out" )
    fi

    # Cover artwork argument for encoder
    COVER_ARGS=()
    if [ -f /tmp/cover.jpg ]; then
        if [ "$target" = "aac" ]; then
            COVER_ARGS=(--tag-from-file "covr:/tmp/cover.jpg")
        else
            COVER_ARGS=(--ti "/tmp/cover.jpg")
        fi
        log_debug "  Cover will be embedded"
    else
        log_debug "  No cover found"
    fi

    # --- Encoder specific part ---
    if [ "$target" = "aac" ]; then
        # Analyse and get fdkaac quality parameters
        fdkaac_params=$(analyze_aac_params "$f")

        log_debug "  Encoding to AAC with: $fdkaac_params"
        # Run the pipeline and encode
        eval "${decode_pipe[@]}" | \
            fdkaac \
                -p 2 \
                $fdkaac_params \
                --raw \
                --raw-channels 2 \
                --raw-rate "$rate_out" \
                --raw-format s16L \
                --moov-before-mdat \
                --title "$TITLE" \
                --artist "$ARTIST" \
                --album "$ALBUM" \
                --track "$TRACK" \
                --date "$DATE" \
                --genre "$GENRE" \
                "${COVER_ARGS[@]}" \
                -o "${f%.flac}.m4a" -
    else
        # MP3: always VBR quality 4
        srate_lame=$(awk "BEGIN {printf \"%.1f\", $rate_out/1000}")
        log_debug "  Encoding to MP3 (LAME -V 4 @ ${srate_lame}kHz)"
        eval "${decode_pipe[@]}" | \
            lame \
                -r \
                -s "$srate_lame" \
                --bitwidth 16 \
                --signed \
                --little-endian \
                -V 4 \
                --tt "$TITLE" \
                --ta "$ARTIST" \
                --tl "$ALBUM" \
                --tn "$TRACK" \
                --ty "$DATE" \
                --tg "$GENRE" \
                "${COVER_ARGS[@]}" \
                - "${f%.flac}.mp3"
    fi

    rm -f /tmp/cover.jpg
    log_debug "  Conversion completed for $f"
done

# --- AAC post‑processing: repack with fast‑start to prevent iPod reboots ---
if [ "$target" = "aac" ]; then
    log_debug "Repacking .m4a files for iPod compatibility..."
    mkdir -p repacked
    for m4a in *.m4a; do
        [ -e "$m4a" ] || continue
        log_debug "  Repacking $m4a"
        ffmpeg -y -i "$m4a" -c copy -movflags +faststart "repacked/$m4a"
    done
    log_debug "Repacking finished."
fi

log_debug "All conversions completed."
echo "All conversions completed."
