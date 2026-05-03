<!-- SPDX-FileCopyrightText: © 2024 Jeffrey C. Ollie <jeff@ocjtech.us> -->
<!-- SPDX-License-Identifier: MIT -->

# Install Zig on your Buildkite agent

## Example

```yml
steps:
  - command: zig env
    plugins:
      - jcollie/install-zig#v1.0.0

```

## Configuration

## Developing

### Building the binaries

To build the binaries, you'll need Zig 0.16.0 installed. There is a Nix flake
that can be used to set up a development environment:

```shell
nix develop
```

Zig can also be installed in whatever other means you like. There are no
external dependencies that won't be fetched by Zig during the build process.

To build a debug version of the binary for your local system, run:

```shell
zig build
```
The binary will be available as

This command will run Zig's unit tests:
```shell
zig build tests
```

To build the "release" binaries, run:

```shell
zig build release
```
The binaries will be written to the source tree at
`hooks/pre-command-<arch>-<os>` and should be committed to the repo. This
command should be run before any commit to ensure that the binaries are
up-to-date.

### BuildKite tests

To run the tests:

```shell
podman run -it --rm -v "$PWD:/plugin:ro" docker.io/buildkite/plugin-linter --id jcollie/install-zig
```
