// Step 1, on real accounts: do the ModuleKit tests (Safe7579, Nexus, Kernel,
// ERC-7579 reference) notice a broken gate? Run by hand during step 1;
// committed in step 3.
//
// These tests build under Foundry only, and forge.exe is blocked on this
// machine by Smart App Control, so they run in the Foundry Docker image, as
// every catalogue now does by default; under --hardhat this one is skipped.

export default {
  name: "accounts",
  runner: "forge-docker",
  tests: ["test/accounts/*"],
  mutants: [
    { name: "submit open to any caller", file: "contracts/gate/PolicyGate.sol",
      find: "        external\n        onlyAccount\n        nonReentrant\n        returns (bytes32 orderHash)",
      replace: "        external\n        nonReentrant\n        returns (bytes32 orderHash)" },
    { name: "unknown-call check removed", file: "contracts/gate/PolicyGate.sol",
      find: "if (address(decoder) == address(0)) revert PolicyGate_UnknownCall(target, selector);",
      replace: "" },
    { name: "account allowed as target everywhere", file: "contracts/gate/DecoderRegistry.sol",
      find: "return target == address(0) || target == account || target == address(this);",
      replace: "return target == address(0) || target == address(this);" },
    { name: "gate allowed as target everywhere", file: "contracts/gate/DecoderRegistry.sol",
      find: "return target == address(0) || target == account || target == address(this);",
      replace: "return target == address(0) || target == account;" },
    { name: "owner path open to anyone", file: "contracts/gate/GateBase.sol",
      find: "if (!_installations[msg.sender].installed) revert Gate_NotInstalled(msg.sender);",
      replace: "" },
    { name: "widening applies at once", file: "contracts/gate/ConfigManager.sol",
      find: "} else if (change == ConfigChange.TIGHTEN) {",
      replace: "} else if (change == ConfigChange.TIGHTEN || change == ConfigChange.WIDEN) {" },
    { name: "market call skipped", file: "contracts/gate/PolicyGate.sol",
      find: "bytes[] memory results = _execute(account, target, callData);",
      replace: "bytes[] memory results = new bytes[](1);" },
    { name: "uninstall leaves installed", file: "contracts/gate/GateBase.sol",
      find: "installation.installed = false;",
      replace: "" },
    { name: "executor claims to be a validator only", file: "contracts/gate/PolicyGate.sol",
      find: "return moduleTypeId == MODULE_TYPE_EXECUTOR;",
      replace: "return moduleTypeId == 1;" },
  ],
};
