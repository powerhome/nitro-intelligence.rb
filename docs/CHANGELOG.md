# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Support audio transcription (#6)
- Enable agent server to manage human-in-the-loop threads (#6)

### Changed
- Refactor client into multiple handlers, each specific to a type of inference (#6)
- Require Ruby 3.3 or later (#10)
- Upgrade langfuse-rb to 0.7.0 (#12)
