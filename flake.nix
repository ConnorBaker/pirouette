{
  description = "A flake for pirouette";

  nixConfig = {
    accept-flake-config = true;
    allow-import-from-derivation = true;
    extra-substituters = [
      "https://haskell-library-pirouette.cachix.org"
      "https://cache.iog.io"
      "https://iohk.cachix.org"
      "https://nix-community.cachix.org"
      "https://haskell-language-server.cachix.org"
      "https://haskell-library-tasty-json.cachix.org"
      "https://cache.nixos.org"
    ];
    extra-trusted-public-keys = [
      "haskell-library-pirouette.cachix.org-1:QAmaIrajvcVqadDrc3NfSQDpNF3CVu3SI4EdsQ4zDPw="
      "hydra.iohk.io:f/Ea+s+dFdN+3Y/G+FDgSq+a5NEWhJGzdjvKNGv0/EQ="
      "iohk.cachix.org-1:DpRUyj7h7V830dp/i6Nti+NEO2/nhblbov/8MW7Rqoo="
      "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
      "haskell-language-server.cachix.org-1:juFfHrwkOxqIOZShtC4YC1uT1bBcq2RSvC7OMKx0Nz8="
      "haskell-library-tasty-json.cachix.org-1:srj2Qko32LAYrp8ZumHEZll3KSnc1ysPlT8Z5iebiXY="
      "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
    ];
  };

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
              shell.tools = {
                ormolu = "0.5.0.1";
                hlint = "3.5";
              };
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
                hpack
                jq
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
