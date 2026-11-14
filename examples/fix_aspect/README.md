```sh
bazel build --config=dwyu //...
```

Applying the fixes edits [demo/BUILD.bazel](demo/BUILD.bazel):

```sh
bazel build --config=dwyu-fix //...
git diff demo/BUILD.bazel
```

Afterwards, DWYU reports no findings:

```sh
bazel build --config=dwyu //...
```
