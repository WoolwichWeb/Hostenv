{ ... }:
let
  hostenvInputs =
    let
      resolveHostenvInput = { inputs, context ? "hostenv" }:
        if inputs ? hostenv
        then inputs.hostenv
        else if inputs ? self
        then inputs.self
        else
          builtins.throw ''
            The Hostenv input is missing from ${context}.

            Define one of:
            - inputs.hostenv in a provider or project flake;
            - inputs.self inside Hostenv itself.
          '';

      requireInput = { inputs, name, context ? "hostenv" }:
        if builtins.hasAttr name inputs then
          inputs.${name}
        else if name == "hostenv" then
          resolveHostenvInput { inherit inputs context; }
        else
          let
            hostenvInput =
              if inputs ? hostenv then inputs.hostenv
              else if inputs ? self then inputs.self
              else null;
          in
          if hostenvInput != null
            && hostenvInput ? inputs
            && builtins.hasAttr name hostenvInput.inputs
          then
            hostenvInput.inputs.${name}
          else
            builtins.throw ''
              Required flake input '${name}' is missing from ${context}.

              Hostenv checked:
              - inputs.${name};
              - inputs.hostenv.inputs.${name}; and
              - inputs.self.inputs.${name}.
            '';
    in
    {
      inherit resolveHostenvInput requireInput;
    };
in
{
  config.flake.lib.hostenvInputs = hostenvInputs;
}
