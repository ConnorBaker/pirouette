{
  description = "A flake for pirouette";

  inputs = {
    haskell-nix.url = "github:input-output-hk/haskell.nix";
    nixpkgs.follows = "haskell-nix/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = {
    self,
    haskell-nix,
    nixpkgs,
    flake-utils,
  }:
    flake-utils.lib.eachSystem ["x86_64-linux"] (system: let
      overlays = [
        haskell-nix.overlay
        (final: prev: let
          inherit (final) makeWrapper cvc4;
          makeBinPath = final.lib.makeBinPath;
          ghcVersion = "902";
          compiler-nix-name = "ghc${ghcVersion}";
          cabal-install = final.haskell-nix.cabal-install.${compiler-nix-name};
          haskell-language-server = final.haskell-language-server;
          index-state = "2022-04-07T00:00:00Z";
        in {
          pirouette =
            final.haskell-nix.cabalProject'
            {
              inherit compiler-nix-name cabal-install index-state;
              src = ./.;
              modules = [
                {
                  packages = {
                    pirouette.components.tests.spec = {
                      build-tools = [makeWrapper cvc4];
                      postInstall = ''wrapProgram $out/bin/spec --set PATH ${makeBinPath [cvc4]}'';
                    };
                  };
                }
              ];
              shell = {
                tools = {
                  ormolu = {};
                  hpack = {};
                  hlint = {};
                };
                buildInputs =
                # We specify cabal-install and haskell-language-server
                # here for greater control over who provides them and the
                # version we use.
                  [cabal-install haskell-language-server]
                  ++ (with pkgs; [
                    xdot
                    haskellPackages.graphmod
                    cvc4
                  ]);
              };
            };
        })
      ];
      pkgs = import nixpkgs {
        inherit system overlays;
        inherit (haskell-nix) config;
      };
      flake = pkgs.pirouette.flake {};
    in
      (removeAttrs flake ["devShell"])
      // {
        # devShell was deprecated; update the flake attribute set.
        devShells.default = flake.devShell;
        formatter = pkgs.alejandra;
      });
}
