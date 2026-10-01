// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {PeggoyMachine} from "../src/PeggoyMachine.sol";

/// Robinhood Chain mainnet (4663). Deploy BEFORE launch; the token is set at launch with setStakingToken.
///
///   SAFE=0x<team Safe 2-of-3> [LAUNCHER=0x..] [GENESIS=1791039600] \
///   forge script script/Deploy.s.sol --rpc-url robinhood --broadcast --private-key $(cat ../ops/keys/deployer.key)
///
/// - Owner of the Machine = a TimelockController (48 h). Proposer and executor = the Safe. No admin.
/// - LAUNCHER (default: the deployer) may call setStakingToken once, then has no power at all. Using the deployer
///   keeps launch fast (one signature at 15:00 UTC instead of two); the worst it can do is set a wrong token
///   before anyone stakes, which only means redeploying.
contract Deploy is Script {
    function run() external {
        address safe = vm.envAddress("SAFE");
        uint256 genesis = vm.envOr("GENESIS", uint256(1791039600)); // Fri 03 Oct 2026 15:00 UTC
        require(block.chainid == 4663 || block.chainid == 31337, "not Robinhood Chain mainnet");
        require(safe.code.length > 0, "SAFE is not a contract: create it on app.safe.global first");

        vm.startBroadcast();
        address launcher = vm.envOr("LAUNCHER", msg.sender);
        address[] memory roles = new address[](1);
        roles[0] = safe;
        TimelockController timelock = new TimelockController(48 hours, roles, roles, address(0));
        PeggoyMachine machine = new PeggoyMachine(address(timelock), launcher, genesis);
        vm.stopBroadcast();

        require(machine.owner() == address(timelock), "owner");
        console2.log("TIMELOCK", address(timelock));
        console2.log("MACHINE ", address(machine));
        console2.log("LAUNCHER", launcher);
        console2.log("next: at launch, LAUNCHER calls setStakingToken(<$PEGGOY CA>), then ./deploy.sh ca <CA>");
    }
}
