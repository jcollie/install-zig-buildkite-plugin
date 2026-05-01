# Install Zig on your Buildkite agent

## Example

```yml
steps:
  - command: zig env
    plugins:
      - jcollie/install-zig#v1.0.0

```

### Configuration

### Developing

To run the tests:

```shell
podman run -it --rm -v "$PWD:/plugin:ro" docker.io/buildkite/plugin-linter --id jcollie/install-zig
```
