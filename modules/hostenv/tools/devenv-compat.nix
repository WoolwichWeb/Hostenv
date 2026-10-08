{ ... }:
{
  flake.modules.hostenv.tools-devenv-compat =
    { lib, ... }:
    {
      options.hostenv.compatibility.devenv.enable =
        lib.mkEnableOption "devenv compatibility measures"
        // {
          default = true;
        };

      options.hostenv.compatibility.devenv.script = lib.mkOption {
        description = "Script to run when entering a project's dev shell";
        type = lib.types.lines;
        default = ''

          # If hostenv is running inside a Devenv shell, then we attempt to handle
          # it gracefully using its internal PATH
          if [ -n "''${DEVENV_ROOT:-}" ]; then

            # _DEVENV_PATH is exported so we can alter it
            if [ -n "''${_DEVENV_PATH:-}" ]; then
              export _DEVENV_PATH="$PATH"

            # _DEVENV_PATH is not exported, so warn the user
            else

              echo >&2
              echo -e "⚠️  \033[1mDevenv will restore its own PATH and break Hostenv.\033[0m" >&2
              cat >&2 <<'EOF'

          Please add:

            enterShell = '''
              export _DEVENV_PATH
            ''';

          to your 'devenv.nix' to allow Hostenv to coexist with Devenv.

          EOF

            fi

            # Unset Devenv environment variables that will interfere with
            # Hostenv operations; direnv will restore them on exit.
            unset \
              DRUSH_OPTIONS_URI \
              MYSQL_HISTFILE \
              WEBROOT \
              BASH_COMPLETION_USER_DIR

          fi
          # End of Hostenv + Devenv compatibility script

        '';
      };

    };
}
