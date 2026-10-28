# Test the source passed to Composer by the Drupal module.
{ pkgs, hostenv }:
let
  lib = pkgs.lib;
  asserts = (import ../support { inherit pkgs lib; }).asserts;
  root = ./fixtures/drupal-composer-source;

  hasFiles = src: paths: lib.all (path: builtins.pathExists "${src}/${path}") paths;
  lacksFiles = src: paths: lib.all (path: !(builtins.pathExists "${src}/${path}")) paths;

  testSource = { extraSources, included, excluded }:
    let
      fixtureConfig = {
        hostenv = {
          inherit root;
          safeEnvironmentName = "test";
          environmentName = "main";
        };
        services.drupal = {
          enable = true;
          majorVersion = 11;
          codebase = {
            name = "test";
            version = "1.0";
          };
          filesDir = "/tmp/files";
          composer = {
            inherit extraSources;
            enable = true;
            dependencyHash = lib.fakeHash;
            enablePlugins = true;
            enableScripts = true;
            enableDev = false;
          };
        };
        services.phpfpm.pools.test.effectivePhpCliPackage = {
          packages.composer = null;
          buildComposerProject2 = makeAttrs:
            let
              source = (makeAttrs { }).src;
            in
            assert lib.assertMsg
              (hasFiles source included && lacksFiles source excluded)
              "Drupal Composer source filter selected unexpected files";
            "composer-source-check";
        };
      };
      fakePkgs = {
        # Return the Composer source directly so the project build phase forces it.
        stdenvNoCC.mkDerivation = attrs: if attrs ? name then attrs.src else attrs;
        writeText = _: _: "test-settings";
      };
      evaluated = lib.evalModules {
        class = "hostenv";
        modules = [
          hostenv.lib.hostenv.modules.drupal
          {
            options = {
              hostenv = lib.mkOption { type = lib.types.lazyAttrsOf lib.types.unspecified; };
              services.drupal = {
                enable = lib.mkOption { type = lib.types.bool; };
                majorVersion = lib.mkOption { type = lib.types.int; };
                codebase = lib.mkOption { type = lib.types.attrsOf lib.types.unspecified; };
                filesDir = lib.mkOption { type = lib.types.str; };
                composer = lib.mkOption { type = lib.types.attrsOf lib.types.unspecified; };
                settings.databases = lib.mkOption { type = lib.types.lines; };
              };
              services.phpfpm.pools = lib.mkOption {
                type = lib.types.lazyAttrsOf lib.types.unspecified;
              };
              # Keep unrelated profile packages unevaluated.
              profile = lib.mkOption { type = lib.types.raw; };
            };
            config = fixtureConfig // {
              _module = {
                check = false;
                args.pkgs = fakePkgs;
              };
            };
          }
        ];
      };
      project = builtins.elemAt evaluated.config.profile 0;
    in
    (builtins.tryEval (builtins.deepSeq project.buildPhase true)).success;
in
{
  drupal-composer-default-source = asserts.assertTrue "drupal-composer-default-source"
    (testSource {
      extraSources = [ ];
      included = [
        "composer.json"
        "composer.lock"
        "patches.lock.json"
      ];
      excluded = [
        "patches/one.patch"
        "patches/nested/two.patch"
        "config/patches/one.patch"
        "unrelated.txt"
      ];
    })
    "The default Composer source should contain only the root Composer metadata files.";

  drupal-composer-extra-sources = asserts.assertTrue "drupal-composer-extra-sources"
    (testSource {
      extraSources = [
        (root + /patches)
        (root + /config/patches/one.patch)
      ];
      included = [
        "composer.json"
        "composer.lock"
        "patches.lock.json"
        "patches/one.patch"
        "patches/nested/two.patch"
        "config/patches/one.patch"
      ];
      excluded = [
        "config/patches/other.patch"
        "config/composer.json"
        "patches-other/ignored.patch"
        "unrelated.txt"
      ];
    })
    "Extra Composer sources should include selected paths and descendants, but not siblings.";
}
