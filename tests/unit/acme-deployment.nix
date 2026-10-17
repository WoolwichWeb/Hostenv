{ pkgs, runtime }:
pkgs.runCommand "provider-acme-process-tests" {
  nativeBuildInputs = [ pkgs.python3 runtime ];
} ''
  export HOSTENV_SYSTEM_TEST_BINARY="${runtime}/bin/hostenv-system"
  python3 -I -S ${./acme-deployment.py} -v
  touch "$out"
''
