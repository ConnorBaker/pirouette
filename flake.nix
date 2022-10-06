{
  description = "A flake for pirouette";

  inputs = {
    haskell-nix.url = "github:input-output-hk/haskell.nix";
    nixpkgs.follows = "haskell-nix/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    tasty-json.url = "github:connorbaker/tasty-json";
  };

  outputs = {
    self,
    haskell-nix,
    nixpkgs,
    flake-utils,
    tasty-json,
  }:
    flake-utils.lib.eachSystem ["x86_64-linux"] (system: let
      tasty-json-reporter.src = "${tasty-json}";
      compiler-nix-name = "ghc902";
      index-state = "2022-04-07T00:00:00Z";
      overlays = [
        haskell-nix.overlay
        (final: prev: let
          # Declare common bindings we'll use later
          # TODO: Isn't this the same haskell-nix as the inputs above?
          #       Can we use inherit earlier?
          inherit (final) makeWrapper haskell-nix;
          cabal-install = haskell-nix.cabal-install.${compiler-nix-name};
        in {
          pirouette =
            haskell-nix.cabalProject'
            {
              inherit compiler-nix-name cabal-install index-state;
              src = ./.;
              modules = [
                {
                  packages = {
                    # We must supply the location of the source file otherwise
                    # Cabal will complain about not knowing how to unpack the
                    # given archive
                    inherit tasty-json-reporter;
                    pirouette.components.tests.spec = with pkgs; {
                      build-tools = [makeWrapper];
                      postInstall = ''wrapProgram $out/bin/spec --set PATH ${lib.makeBinPath [cvc4]}'';
                    };
                  };
                }
              ];
              # We prefer shell.buildInputs to shell.tools because we can
              # specify cabal-install and haskell-language-server instead of
              # using a differently packaged version.
              # For example, HLS offered through shell.tools does not include
              # the wrapper, which some IDEs and plugins use exclusively.
              shell.buildInputs = with pkgs; [
                cabal-install
                cvc4
                haskell-language-server
                haskellPackages.graphmod
                hlint
                hpack
                ormolu
                xdot
              ];
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
        devShells.default = flake.devShell.overrideAttrs (old: {
          shellHook = ''
            ${old.shellHook or ""}
            echo "Regenerating cabal files..."
            bash regenerate_cabal_files.sh
            echo "Entering shell..."
          '';
        });
        formatter = pkgs.alejandra;
      });
}
