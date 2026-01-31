# Package overlays
# Use this file to override or add custom packages

final: prev: {
  # Example: pin a specific package version
  # somePackage = prev.somePackage.overrideAttrs (old: {
  #   version = "1.2.3";
  #   src = prev.fetchFromGitHub { ... };
  # });
}
