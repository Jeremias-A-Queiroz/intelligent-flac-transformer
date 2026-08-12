# ipod-fdkaac-transformer

# Historic versions

- 0.1.0 - initial version
- 0.2.0 - added debug flag (-d), direct format flags (-mp3, -aac), version (-v) and help (-h),
          error handling with clear guidance for debugging
- 0.3.0 - added final summary report showing SoX usage and AAC quality
          decisions
- 0.3.1 - removed eval pipeline (spaces in filenames), individual cover temp files,
          dependency fail-fast check
- 0.4.0 - replaced fdkaac tag injection with AtomicParsley for iPod container compatibility;
          added cover art sanitization (200x200 baseline JPEG); removed ffmpeg repacking step
          entirely; kept all audio analysis and SoX logic intact.
