{ pkgs, envs, makeHostenv, inputs, documentationEnabled }:

(import ./integration { inherit pkgs envs makeHostenv inputs; })
  // (import ./unit {
    inherit pkgs makeHostenv documentationEnabled;
    hostenv = inputs.self;
  })
