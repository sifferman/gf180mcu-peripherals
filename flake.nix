{
  nixConfig = {
    extra-substituters = [
      "https://nix-cache.fossi-foundation.org"
    ];
    extra-trusted-public-keys = [
      "nix-cache.fossi-foundation.org:3+K59iFwXqKsL7BNu6Guy0v+uTlwsxYQxjspXzqLYQs="
    ];
  };

  inputs = {
    librelane.url = "github:librelane/librelane/dev";
  };

  outputs =
    {
      self,
      librelane,
      ...
    }:
    let
      nix-eda = librelane.inputs.nix-eda;
      devshell = librelane.inputs.devshell;
      nixpkgs = nix-eda.inputs.nixpkgs;
      lib = nixpkgs.lib;
    in
    {
      # Outputs
      legacyPackages = nix-eda.forAllSystems (
        system:
        import nixpkgs {
          inherit system;
          overlays = [
            nix-eda.overlays.default
            devshell.overlays.default
            # Bump yosys-slang past the pinned 35de0406 to upstream master, which fixes the
            # crash on verilog-ethernet's wide CRC `lfsr` (the static-select fast-path commits
            # 2d4b055/7332909 cut constexpr step cost so the per-eval budget no longer
            # accumulates past the limit). Lets the design elaborate with the real CRC hash
            # without the --max-constexpr-steps workaround. Placed before librelane's overlay
            # so its bundled yosys-with-plugins (default.nix yosys-plugin-set) picks it up.
            (final: prev: {
              yosys-slang = prev.yosys-slang.override {
                rev = "b2b718c5a66ad525858298466f7ecaa60497393e"; # povik/yosys-slang master, 2026-06-21
                rev-date = "2026-06-21";
                hash = "sha256-EGdgyrKXanbSyidhKnhLX+PRmewfPmjDTVvodGiNENU=";
              };
            })
            librelane.overlays.default
          ];
        }
      );

      packages = nix-eda.forAllSystems (system: {
        inherit (self.legacyPackages.${system}.python3.pkgs) ;
      });

      devShells = nix-eda.forAllSystems (
        system:
        let
          pkgs = (self.legacyPackages.${system});
          callPackage = lib.callPackageWith pkgs;
        in
        {
          default = pkgs.librelane-shell.override ({
            extra-packages = with pkgs; [
              # Utilities
              gnumake
              gnugrep
              gawk

              # Simulation
              iverilog
              verilator

              # SPICE (ngspice 46 from nix-eda; >=42 is required for the gf180 BSIM4
              # models — the host's ngspice-34 rejects params like mulu0). Used by
              # `make dco-spice` for the ring-DCO frequency-vs-code characterization.
              ngspice

              # Waveform viewing
              gtkwave
              surfer
            ];

            extra-python-packages =
              ps: with ps; [
                # Verification
                cocotb

                # For KLayout Python DRC runner
                docopt

                # For logo generation
                pillow
              ];
          });
        }
      );
    };
}
