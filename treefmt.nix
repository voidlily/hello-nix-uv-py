{ pkgs, ... }:
{
  projectRootFile = "flake.nix";
  programs.mypy.enable = true;
  programs.ruff-check.enable = true;
  programs.ruff-format.enable = true;
  programs.actionlint.enable = true;
}
