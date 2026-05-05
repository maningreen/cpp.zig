{
  pkgs ? import <nixpkgs> { },
  ...
}:
pkgs.stdenv.mkDerivation {
  pname = "out";
  version = "0.0.0";
  src = ./.;
  buildInputs = with pkgs; [
    libclang
    zig
  ];
  nativeBuildInputs = with pkgs; [
    zig.hook
  ];

  dontUserZigCheck = true;
}
