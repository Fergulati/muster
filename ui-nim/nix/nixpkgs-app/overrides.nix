# What the Logos C++ tree needs to build on nixos-unstable, at the revisions the runner
# pins. These replace attributes of the package set without rebuilding it: everything
# else, Qt included, stays nixos-unstable's own cached build, so the app and the Logos
# libraries share the very qtbase-6.11.2 the app links. This works because the Logos
# nix files call `pkgs.stdenv.mkDerivation` and name their dependencies as `pkgs.<x>`;
# a Logos derivation that went through `pkgs.callPackage` would not see these.
# Each entry says why, and when to drop it.
pkgs: {
  # The runner's compiler is GCC 14 (14.3); nixos-unstable's default is 16.
  #
  # The runner also linked spdlog 1.15 and fmt 10; nixos-unstable has 1.17 and 12, and
  # fmt 11 stopped including <cstring>, which the pinned sources relied on
  # (logos-module-loader-qt's token_source.cpp calls std::strerror without it). nixpkgs
  # has no spdlog 1.15, so every C++ translation unit of the Logos tree gets <cstring>
  # instead (CMake takes CXXFLAGS from the environment). Drop both when the pins build
  # on nixos-unstable as it is.
  stdenv = pkgs.stdenvAdapters.addAttrsToDerivation
    { CXXFLAGS = "-include cstring"; } pkgs.gcc14Stdenv;
  # Boost 1.89 removed the compiled boost_system library, and the pinned Logos CMake still
  # asks for it (`find_package(Boost REQUIRED COMPONENTS system)`; logos-protocol master
  # has since made it optional). 1.87 is the Boost the runner itself links.
  boost = pkgs.boost187;
}
