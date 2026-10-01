// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {PeggoyMachine} from "../src/PeggoyMachine.sol";
import {DemoToken} from "../src/DemoToken.sol";

/// Robinhood Chain TESTNET (46630) demo: same Machine and 48 h timelock as mainnet, a faucet token instead of
/// $PEGGOY, and epochs on the same Friday 15:00 UTC schedule (genesis one week before mainnet's).
///
///   forge script script/DeployTestnet.s.sol --rpc-url robinhood_testnet --broadcast --private-key <testnet key>
contract DeployTestnet is Script {
    function run() external {
        require(block.chainid == 46630, "not Robinhood Chain testnet");
        uint256 genesis = vm.envOr("GENESIS", uint256(1790434800)); // Fri 26 Sep 2026 15:00 UTC
        vm.startBroadcast();
        address[] memory roles = new address[](1);
        roles[0] = msg.sender;
        TimelockController timelock = new TimelockController(48 hours, roles, roles, address(0));
        PeggoyMachine machine = new PeggoyMachine(address(timelock), msg.sender, genesis);
        DemoToken token = new DemoToken();
        machine.setStakingToken(address(token));
        vm.stopBroadcast();
        console2.log("TIMELOCK", address(timelock));
        console2.log("MACHINE ", address(machine));
        console2.log("TOKEN   ", address(token));
    }
}
