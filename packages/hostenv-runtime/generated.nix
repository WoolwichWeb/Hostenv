{ mkDerivation, aeson, base, bytestring, containers, directory
, filepath, lib, process, text, transformers, turtle, unix
}:
mkDerivation {
  pname = "hostenv-runtime";
  version = "0.1.0.0";
  src = ./.;
  isLibrary = true;
  isExecutable = true;
  libraryHaskellDepends = [
    aeson base bytestring containers directory filepath process text
    transformers turtle unix
  ];
  executableHaskellDepends = [ base ];
  description = "Small commands run by Hostenv-managed systems";
  license = lib.meta.getLicenseFromSpdxId "GPL-3.0-or-later";
  mainProgram = "hostenv-system";
}
