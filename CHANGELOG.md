# Changelog

All notable changes to this project will be documented in this file. The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [0.1.0] - 2026-04-28

### Highlights

Initial release of `:snowball` as a standalone package, extracted from the original `:snowball` Hex package (which now ships only the pre-compiled stemmers as `:text_stemmer`).

This package provides the Snowball language compiler pipeline (`Snowball.Lexer`, `Snowball.Preprocessor`, `Snowball.Analyser`, `Snowball.Generator`), the `Snowball.Runtime` runtime support module that generated stemmers call into, and the `mix snowball.gen` Mix task. See the [README](README.md) for usage.
