{ pkgs, makeHostenv, inputs }:
let
  lib = pkgs.lib;
  asserts = import ../support/assert.nix { inherit pkgs lib; };
  system = pkgs.stdenv.hostPlatform.system;

  mkProject = sharedHostname:
    let
      source = pkgs.writeTextDir "hostenv.nix" ''
        { ... }: {
          hostenv = {
            organisation = "org";
            project = "fixture";
            root = "/src/fixture";
          };
          defaultEnvironment = "main";
          environments.main = {
            enable = true;
            type = "production";
            virtualHosts."main.example" = { };
          };
          environments.testing = {
            enable = true;
            virtualHosts."${if sharedHostname then "main.example" else "testing.example"}" = { };
          };
        }
      '';
      evaluated = makeHostenv [ (source + /hostenv.nix) ] "main";
    in
    {
      outPath = source;
      __toString = self: toString self.outPath;
      lib.hostenv.${system}.environments = evaluated.config.environments;
    };

  project = mkProject false;
  mainUser = project.lib.hostenv.${system}.environments.main.hostenv.userName;
  testingUser = project.lib.hostenv.${system}.environments.testing.hostenv.userName;
  persistedState = {
    _description = "This metadata is not a user or a UID reservation.";
    ${mainUser} = {
      uid = 2501;
      node = "old-node";
      virtualHosts = [ "main.example" "main.example" ];
      retainedField = "keep this field";
    };
    retired = {
      uid = 4501;
      node = "retired-node";
      virtualHosts = [ "retired.example" ];
    };
    retiredOnActiveNode = {
      uid = 4502;
      node = "node-a";
      virtualHosts = [ "retired-on-active-node.example" ];
    };
  };
  stateFile = pkgs.writeText "state.json" (builtins.toJSON persistedState);
  lockFile = pkgs.writeText "flake.lock" (builtins.toJSON {
    nodes.org__fixture.original = {
      type = "git";
      url = "https://example.invalid/org/fixture.git";
      ref = "main";
    };
  });
  providerRoot = pkgs.runCommand "provider-plan-regression-root" { } ''
    mkdir -p "$out/generated"
    cp ${stateFile} "$out/generated/state.json"
    cp ${lockFile} "$out/flake.lock"
    # A stale or malformed plan must never be an input to planning.
    printf 'deliberately not JSON\n' > "$out/generated/plan.json"
  '';
  planInputs = {
    self = providerRoot;
    hostenv = inputs.self;
    org__fixture = project;
  };
  mkPlan = overrides: inputs.self.lib.provider.plan ({
    inputs = planInputs;
    inherit pkgs lib system;
    hostenvHostname = "hosting.test";
    letsEncrypt = { adminEmail = "ops@example.test"; acceptTerms = true; };
    nodeFor.default = "node-a";
    nodeSystems = {
      node-a = system;
      old-node = system;
    };
    secretsFile = "secrets/secrets.yaml";
  } // overrides);

  baseline = mkPlan { };
  plan = lib.importJSON baseline.plan;
  state = lib.importJSON baseline.state;
  replanned = mkPlan { statePath = baseline.state; };
  replannedPlan = lib.importJSON replanned.plan;
  replannedState = lib.importJSON replanned.state;
  withoutState = mkPlan { statePath = null; };
  missingState = mkPlan { statePath = providerRoot + "/generated/absent.json"; };
  noStatePlan = lib.importJSON withoutState.plan;

  # A shallow tryEval of the result attrset would not exercise these outputs.
  outputResults = value: {
    plan = builtins.tryEval (builtins.deepSeq (lib.importJSON value.plan) true);
    state = builtins.tryEval (builtins.deepSeq (lib.importJSON value.state) true);
    flake = builtins.tryEval (builtins.deepSeq (builtins.readFile value.flake) true);
    environments = builtins.tryEval (builtins.deepSeq value.environments true);
  };
  allOutputsFail = value: lib.all (result: !result.success) (builtins.attrValues (outputResults value));
  retiringPlan = mkPlan {
    nodeStatus.old-node = "retiring";
  };
  retiringPlanData = lib.importJSON retiringPlan.plan;
  retiringScheduled = builtins.tryEval (builtins.deepSeq (mkPlan {
    nodeFor.default = "old-node";
    nodeStatus.old-node = "retiring";
  }).plan true);
  unknownStatusNode = builtins.tryEval (builtins.deepSeq (mkPlan {
    nodeStatus.missing-node = "retiring";
  }).plan true);
  unknownScheduledNode = builtins.tryEval (builtins.deepSeq (mkPlan {
    nodeFor.default = "missing-node";
  }).plan true);

  stateConflict = mkPlan {
    statePath = pkgs.writeText "conflicting-state.json" (builtins.toJSON {
      other = { uid = 6001; virtualHosts = [ "main.example" ]; };
    });
  };
  newConflict = mkPlan {
    inputs = planInputs // { org__fixture = mkProject true; };
    statePath = null;
  };
  retiredConflict = mkPlan {
    statePath = pkgs.writeText "retired-conflict.json" (builtins.toJSON {
      retired-a = { uid = 6001; virtualHosts = [ "retired.example" ]; };
      retired-b = { uid = 6002; virtualHosts = [ "retired.example" ]; };
    });
  };
  quotedPaths = mkPlan {
    secretsFile = "secrets/quoted\"-\${literal}.yaml";
    nodeModules = [ "nodes/quoted\"-\${literal}.nix" ];
  };
  parsedFlake = import quotedPaths.flake;
  # Execute just the generated outputs function with a capture callback. This
  # checks emitted string values as well as syntax without fetching any repos.
  generatedArgs = parsedFlake.outputs {
    self = { };
    nixpkgs = { };
    deploy-rs = { };
    systems = { };
    parent = {
      outPath = "/provider";
      lib.provider.deployOutputs = args: args;
    };
  };

  providerOptions = (import ../../modules/entrypoints/provider/options.nix {
    inherit inputs lib;
    config.flake = inputs.self;
  }).options.provider;
  evaluateOptions = settings: (lib.evalModules {
    modules = [
      { options.provider = providerOptions; }
      { provider = settings; }
    ];
  }).config.provider.enable;
  planArguments = builtins.functionArgs inputs.self.lib.provider.plan;
  removedOptions = [
    [ "planSource" ]
    [ "planPath" ]
    [ "statePath" ]
    [ "plan" "autoInit" ]
  ];
  removedSettings = [
    { planSource = "eval"; }
    { planPath = providerRoot + "/generated/plan.json"; }
    { statePath = stateFile; }
    { plan.autoInit = false; }
  ];
in
{
  provider-plan-default-state-and-lock = asserts.assertTrue "provider-plan-default-state-and-lock" (
    plan.environments.${mainUser}.uid == 2501
    && plan.environments.${mainUser}.repo.url == "https://example.invalid/org/fixture.git"
    && lib.all (result: result.success) (builtins.attrValues (outputResults baseline))
  ) "default paths should read the provider's state and lock, never its existing plan.json";

  provider-plan-state-retention = asserts.assertTrue "provider-plan-state-retention" (
    state.retired == removeAttrs persistedState.retired [ "node" ]
    && state.${mainUser}.retainedField == "keep this field"
    && state.${mainUser}.uid == 2501
    && state.${testingUser}.uid > 4501
    && !(state.${mainUser} ? node)
    && !(state.retired ? node)
    && !(state.retiredOnActiveNode ? node)
    && !(state.${testingUser} ? node)
    && !(state ? _providerNodes)
  ) "planning must retain durable environment reservations without storing node placement or provider inventory";

  provider-plan-state-has-no-placement-history = asserts.assertTrue "provider-plan-state-has-no-placement-history" (
    !(plan.environments.${mainUser} ? previousNode)
    && !(plan.environments.${testingUser} ? previousNode)
    && plan.nodeConnections ? old-node
    && !(plan.nodeConnections ? retired-node)
  ) "migration routing must come from configured nodes rather than placement history in state";

  provider-plan-all-configured-nodes = asserts.assertTrue "provider-plan-all-configured-nodes" (
    plan.nodes ? node-a
    && plan.nodes ? old-node
    && plan.nodes.old-node.users.users == { }
    && lib.all
      (env: env.node != "old-node")
      (builtins.attrValues plan.environments)
    && !(plan.nodes ? retired-node)
  ) "every configured provider node must remain deployable even when it has no current environments";

  provider-plan-retiring-node-status = asserts.assertTrue "provider-plan-retiring-node-status" (
    retiringPlanData.nodeStatus.old-node == "retiring"
    && retiringPlanData.nodeStatus.node-a == "active"
    && retiringPlanData.nodes ? old-node
    && retiringPlanData.nodeConnections ? old-node
  ) "retiring nodes must remain in the generated provider inventory and deployment routing";

  provider-plan-retiring-node-not-scheduled = asserts.assertTrue "provider-plan-retiring-node-not-scheduled" (
    !retiringScheduled.success
  ) "provider.nodeFor must not schedule environments onto a retiring node";

  provider-plan-node-status-must-reference-inventory = asserts.assertTrue "provider-plan-node-status-must-reference-inventory" (
    !unknownStatusNode.success
  ) "provider.nodeStatus entries must reference provider.nodeSystems";

  provider-plan-node-for-must-reference-inventory = asserts.assertTrue "provider-plan-node-for-must-reference-inventory" (
    !unknownScheduledNode.success
  ) "provider.nodeFor entries must reference provider.nodeSystems";

  provider-plan-state-is-stable-across-replan = asserts.assertTrue "provider-plan-state-is-stable-across-replan" (
    replannedPlan.nodes ? old-node
    && !(replannedPlan.environments.${mainUser} ? previousNode)
    && replannedState == state
  ) "re-running plan must preserve durable reservations without introducing deployment history";

  provider-plan-optional-state = asserts.assertTrue "provider-plan-optional-state" (
    lib.importJSON missingState.plan == noStatePlan
    && builtins.isInt noStatePlan.environments.${mainUser}.uid
    && builtins.isInt noStatePlan.environments.${testingUser}.uid
    && noStatePlan.environments.${mainUser}.uid != noStatePlan.environments.${testingUser}.uid
  ) "missing and null state inputs should both support first-time planning";

  provider-plan-state-conflict-all-outputs = asserts.assertTrue "provider-plan-state-conflict-all-outputs"
    (allOutputsFail stateConflict)
    "every planner output must reject a hostname reserved by another user";

  provider-plan-new-conflict-all-outputs = asserts.assertTrue "provider-plan-new-conflict-all-outputs"
    (allOutputsFail newConflict)
    "every planner output must reject two new owners of the same hostname";

  provider-plan-retired-conflict-all-outputs = asserts.assertTrue "provider-plan-retired-conflict-all-outputs"
    (allOutputsFail retiredConflict)
    "duplicate persisted reservations must fail even when neither owner is currently enabled";

  provider-plan-generated-path-literals = asserts.assertTrue "provider-plan-generated-path-literals" (
    generatedArgs.secretsFile == "secrets/quoted\"-\${literal}.yaml"
    && generatedArgs.secretsPath == "/provider/secrets/quoted\"-\${literal}.yaml"
    && generatedArgs.nodeModules == [ "/provider/nodes/quoted\"-\${literal}.nix" ]
  ) "generated Nix must quote configurable paths and preserve their literal values";

  provider-plan-option-defaults = asserts.assertTrue "provider-plan-option-defaults" (
    (builtins.tryEval (evaluateOptions { })).success
  ) "provider defaults should still evaluate";

  provider-plan-removed-options-rejected = asserts.assertTrue "provider-plan-removed-options-rejected" (
    lib.all (path: !(lib.hasAttrByPath path providerOptions)) removedOptions
    && lib.all (settings: !(builtins.tryEval (evaluateOptions settings)).success) removedSettings
    && !(planArguments ? planSource)
    && !(planArguments ? planPath)
  ) "removed options must fail evaluation rather than survive as ignored compatibility settings";
}
