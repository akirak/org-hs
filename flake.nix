{
  description = "";
  inputs.nixpkgs.url = "nixpkgs";
  outputs = inputs @ {
    self,
    nixpkgs,
    ...
  }: let
    supportedSystems = ["x86_64-linux" "x86_64-darwin"];
    forAllSystems = f: nixpkgs.lib.genAttrs supportedSystems (system: f system);
    nixpkgsFor = forAllSystems (system:
      import nixpkgs {
        inherit system;
        overlays = [self.overlay];
      });

    inherit (nixpkgs.lib) pipe flip;
  in {
    overlay = final: prev: {
      haskellPackages = prev.haskellPackages.override {
        overrides = hself: hsuper: {
          slugify =
            pipe (hself.callHackageDirect {
              pkg = "slugify";
              ver = "0.1.0.1";
              sha256 = "sha256-T1dzwGbX7PgKlbW9ttZw2uHtem4alWQJJJSZQ4YHrvQ=";
            } {}) [
              final.haskell.lib.dontCheck
            ];

          pretty-simple = hself.callHackageDirect {
            pkg = "pretty-simple";
            ver = "4.1.1.0";
            sha256 = "sha256-ETVkeSs0EbKBthFHn+RA2sDJGUtnZvEStFo5MIvKbOg=";
          } {};

          org-parser = hself.callCabal2nix "org-parser" ./org-parser {};
        };
      };
    };
    packages = forAllSystems (system: {
      inherit
        (nixpkgsFor.${system}.haskellPackages)
        # I failed to build org-exporters and org-cli due to a version hell
        # (mostly on dependencies of pandoc). For now, I will build onoly org-parser.
        org-parser
        ;
    });
    checks = self.packages;
    devShell = forAllSystems (system: let
      haskellPackages = nixpkgsFor.${system}.haskellPackages;
    in
      haskellPackages.shellFor {
        packages = p: [
          # self.packages.${system}.org-parser
        ];
        withHoogle = false;
        buildInputs = with haskellPackages; [
          haskell-language-server
          ghcid
          cabal-install
        ];
        # Change the prompt to show that you are in a devShell
        shellHook = "export PS1='\\e[1;34mdev > \\e[0m'";
      });
  };
}
