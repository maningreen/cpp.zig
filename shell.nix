{
  mkShell,
  clang,
  zig,
  castxml,
  ...
}:
mkShell {
  packages = [
    clang
    zig
    castxml
  ];
}
