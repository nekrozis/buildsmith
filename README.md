# buildsmith

GitHub Actions workflows for automating Windows builds of multiple software projects. Handles environment setup, dependency installation, compilation, and artifact packaging.

## Included Workflows

- **AList** – A file listing/WebDAV program that supports multiple storage backends, built with Go and SolidJS.
- **Aseprite** – An animated sprite editor and pixel art tool with support for custom builds using Skia.
- **Nekoray** – A cross-platform Qt-based GUI for proxy configuration, using sing-box as its backend.
- **LOVE** – A lightweight framework for developing 2D games in Lua.
- **CMD Script Runner** – Runs remote CMD scripts on GitHub-hosted Windows runners.

## Features

- Full build automation using GitHub Actions  
- Environment setup (MSYS2, Qt, Visual Studio, etc.)  
- Artifact upload for easy access  
- Support for custom input versions and configurations

## Usage

All workflows are manually triggered via `workflow_dispatch` and accept input parameters to customize builds.

## License

This repository is provided as-is for automation purposes. Refer to individual project licenses for redistribution or commercial use.
