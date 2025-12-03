# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.1] - 2025-12-02

### Added
- `/v1` REST surface backed by shared `labeling_ir` structs with new Ecto schemas (Queue, Schema, Sample, Assignment, Label, Dataset), tenant-scoped migrations, and assignment retrieval using stored samples.
- `Anvil.API.Router` and `Anvil.API.State` wired through Plug.Cowboy to expose CRUD operations with tenant isolation enforced via `X-Tenant-ID` and actor context.

### Changed
- Label submission tolerates unknown fields in payloads to prevent component forks per ADR-002.
- Test environment uses Supertester full isolation with sandbox mode enabled for migration setup.

## [0.1.0] - 2024-12-01

### Added

- Initial release
- `Anvil.Schema` for label schema definition with 8 field types
- `Anvil.Schema.Field` - field type definitions (text, select, multiselect, range, number, boolean, date, datetime)
- `Anvil.Queue` GenServer for queue management
- `Anvil.Queue.Policy` - assignment policies (round_robin, random, expertise)
- `Anvil.Assignment` struct with lifecycle states
- `Anvil.Label` struct with validation
- `Anvil.Agreement` module for inter-rater reliability metrics
- `Anvil.Agreement.Cohen` - Cohen's kappa for 2 raters
- `Anvil.Agreement.Fleiss` - Fleiss' kappa for n raters
- `Anvil.Agreement.Krippendorff` - Krippendorff's alpha
- `Anvil.Export` module with CSV and JSONL formatters
- `Anvil.Storage` behaviour with ETS implementation
- Comprehensive test suite using Supertester

[Unreleased]: https://github.com/North-Shore-AI/anvil/compare/v0.1.1...HEAD
[0.1.1]: https://github.com/North-Shore-AI/anvil/releases/tag/v0.1.1
[0.1.0]: https://github.com/North-Shore-AI/anvil/releases/tag/v0.1.0
