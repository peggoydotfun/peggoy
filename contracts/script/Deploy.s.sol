// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {PeggoyMachine} from "../src/PeggoyMachine.sol";
import {PeggoyFeeForwarder, IPonsFeeEscrow} from "../src/PeggoyFeeForwarder.sol";
import {PeggoyDrop, IPeggoyMachine} from "../src/PeggoyDrop.sol";

/// Robinhood Chain mainnet (4663). Deploy BEFORE launch; the token is set at launch with setStakingToken.
///
///   SAFE=0x<team Safe 2-of-3> [LAUNCHER=0x..] [GENESIS=1791039600] \
///   forge script script/Deploy.s.sol --rpc-url robinhood --broadcast --private-key $(cat ../ops/keys/deployer.key)
///
/// - Owner of the Machine = a TimelockController (48 h). Proposer and executor = the Safe. No admin.
/// - LAUNCHER (default: the deployer) may call setStakingToken once, then has no power at all. Using the deployer
///   keeps launch fast (one signature at 15:00 UTC instead of two); the worst it can do is set a wrong token
///   before anyone stakes, which only means redeploying.
/// - FEE_FORWARDER: set it as the $PEGGOY creator-fee wallet when creating the token on Pons (buybacks OFF).
///   Pons credits creator fees to its escrow; anyone calls forwarder.pull() to move them into the Machine.
/// - DROP: appointed later with setDropDistributor through the Safe → timelock (48 h).
contract Deploy is Script {
    // Pons v2 fee escrow on Robinhood Chain (docs.ponsfamily.com → Contracts)
    address constant PONS_FEE_ESCROW = 0xd3AFEB2a57f70eF218Aa82451c51B2fb0416Ac9e;

    function run() external {
        address safe = vm.envAddress("SAFE");
        uint256 genesis = vm.envOr("GENESIS", uint256(1791039600)); // Sat 03 Oct 2026 15:00 UTC
        require(block.chainid == 4663 || block.chainid == 31337, "not Robinhood Chain mainnet");
        require(safe.code.length > 0, "SAFE is not a contract: create it on app.safe.global first");

        vm.startBroadcast();
        address launcher = vm.envOr("LAUNCHER", msg.sender);
        address[] memory roles = new address[](1);
        roles[0] = safe;
        TimelockController timelock = new TimelockController(48 hours, roles, roles, address(0));
        PeggoyMachine machine = new PeggoyMachine(address(timelock), launcher, genesis);
        PeggoyFeeForwarder forwarder = new PeggoyFeeForwarder(IPonsFeeEscrow(PONS_FEE_ESCROW), payable(address(machine)));
        PeggoyDrop drop = new PeggoyDrop(IPeggoyMachine(address(machine)));
        vm.stopBroadcast();

        require(machine.owner() == address(timelock), "owner");
        console2.log("TIMELOCK", address(timelock));
        console2.log("MACHINE ", address(machine));
        console2.log("LAUNCHER", launcher);
        console2.log("FEE_FORWARDER (Pons creator-fee wallet)", address(forwarder));
        console2.log("DROP    ", address(drop));
        console2.log("next: ./deploy.sh machine <MACHINE> <TIMELOCK> <FORWARDER> <DROP>; create $PEGGOY on Pons with fee wallet = FEE_FORWARDER; setStakingToken(<CA>); ./deploy.sh ca <CA>");
    }
}
