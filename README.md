# Intelligent FLAC Transcoder (ift.sh) 🎵

![Linux](https://img.shields.io/badge/Linux-FCC624?style=for-the-badge&logo=linux&logoColor=black)
![GNU Bash](https://img.shields.io/badge/Bash-4EAA25?style=for-the-badge&logo=gnu-bash&logoColor=white)
![Emacs](https://img.shields.io/badge/Emacs-7F5AB6?style=for-the-badge&logo=gnu-emacs&logoColor=white)
![License](https://img.shields.io/badge/License-GPLv3-blue.svg?style=for-the-badge)

## Introduction

Welcome to the **Intelligent FLAC Transcoder** (`ift.sh`). I originally developed this script as a personal utility to feed my daily audio devices—specifically, an Apple iPod 5.5gen and an Amazfit T-Rex 3 smartwatch. However, the script has matured and is performing so exceptionally well that I have decided to share it with the community. 

Whether you are maintaining a legacy digital audio player or simply want an automated, highly optimized pipeline to convert your lossless FLAC library into portable formats, `ift.sh` is designed to handle the heavy lifting with precision.

## Key Features & Goals

This script does not simply convert files; it analyzes them to make intelligent encoding decisions. 

*   🧠 **Adaptive Bitrate Optimization**: The script measures volume across specific high and mid-frequency bands. Based on this audio analysis, it dynamically assigns the optimal Variable Bitrate (VBR) parameters for each individual track, entirely avoiding bitrate waste on acoustically simple files.
*   🎛️ **Smart Resampling & Downsampling**: Utilizing `SoX`, it evaluates the source FLAC's bit-depth and sample rate. High-resolution files are safely and cleanly downsampled (e.g., to 16-bit/44.1kHz or 48kHz) only when strictly necessary for the target encoder.
*   🔊 **Volume Normalization Tags**: Automatically calculates and injects Apple's `iTunNORM` (Sound Check) and standard `ReplayGain` values directly into the metadata.
*   🖼️ **Cover Art Sanitization**: Extracts album art and optimizes it to a baseline 200x200 JPEG. This ensures perfect display compatibility and prevents memory crashes on older devices like the iPod Video.
*   💿 **Provenance Tracking**: Scans your directory for `.log` (EAC/XLD) or `.cue` files to extract CD catalog numbers and Disc IDs, embedding this provenance data directly into the track's comment tag.
*   ✅ **Interactive Pre-Flight Validation**: Before any conversion begins, the script presents an interactive prompt to validate and correct album metadata, track numbers, and multi-disc tags.

## Encoders & iPod Compatibility

The script supports three primary output targets, each tailored for specific hardware capabilities:

### Nero AAC (`-nero`)
*   **Best for:** iPod 5.5gen and older.
*   **Why:** Nero AAC provides extremely fine-grained control over VBR levels and maintains flawless playback compatibility with older Apple hardware, preventing frame truncation and device reboots. 
*   **Download:** You can obtain the Nero AAC encoder binaries from [RareWares](https://www.rarewares.org/rrw/neroaac.php).

### FDK AAC (`-aac`)
*   **Best for:** iPod 6th Gen (Classic) and newer devices.
*   **Why:** FDK AAC is a modern, highly efficient encoder. However, the resulting files are better suited for devices with slightly more powerful CPUs.

### LAME MP3 (`-mp3`)
*   **Best for:** Amazfit T-Rex 3 and legacy MP3 players.
*   **Why:** Encodes to a standard LAME V4 (VBR). Perfect for devices that lack AAC support or where MP3 remains the most stable container.

## Prerequisites & Dependencies

The script dynamically checks for dependencies based on your chosen output format. 
*   **Core:** `bash`, `flac`, `sox`, `ffmpeg`, `awk`
*   **For `-aac`:** `fdkaac`, `AtomicParsley`
*   **For `-nero`:** `neroAacEnc`, `neroAacTag`
*   **For `-mp3`:** `lame`

*Note: This script was written and thoroughly tested on Linux using Emacs. Windows and macOS users will require medium to advanced technical knowledge to adapt the script and satisfy the necessary PATH dependencies.*

## Usage

Run the script in a directory containing your `.flac` files. If no format flag is provided, the script will prompt you interactively.

```bash
# Convert to Nero AAC (Recommended for older iPods)
./ift.sh -nero

# Convert to FDK AAC
./ift.sh -aac

# Convert to MP3
./ift.sh -mp3

# Additional flags
./ift.sh -d   # Enable debug logging (debug.log)
./ift.sh -h   # Show help
```

## Roadmap & Known Limitations

The script is actively being improved. The following features are planned:

*   **[Issue #21] Adaptive VBR for MP3:** Implement dynamic VBR calculation for LAME MP3 generation, bringing it on par with the current AAC/Nero frequency-analysis logic.
*   **[Issue #13] Interactive VBR Selection:** Allow the user to interactively define target VBR values during the pre-flight phase. 
    *   *Current Workaround:* Advanced users can manually edit the `awk` sections (`analyze_aac_params` and `analyze_nero_params`) directly in the source code to tweak the VBR thresholds.

## License

This software is released under the GNU General Public License v3.0 (GPLv3).
