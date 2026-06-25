# buildsmith

GitHub Actions workflows for automating Windows builds of multiple software projects. Handles environment setup, dependency installation, compilation, and artifact packaging.

## Included Workflows

- **Aseprite** – An animated sprite editor and pixel art tool with support for custom builds using Skia.
- **gopls** – The official Go language server, providing IDE features for Go development.
- **lazygit** – A simple terminal UI for git commands, written in Go.
- **Nushell** – A modern shell written in Rust with structured data support.

## Features

- Full build automation using GitHub Actions  
- Environment setup (MSYS2, Qt, Visual Studio, etc.)  
- Artifact upload for easy access  
- Support for custom input versions and configurations

## Usage

All workflows are manually triggered via `workflow_dispatch` and accept input parameters to customize builds.

## License

This repository is provided as-is for automation purposes. Refer to individual project licenses for redistribution or commercial use.
