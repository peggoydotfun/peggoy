// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PeggoyMachine} from "../src/PeggoyMachine.sol";
import {PeggoyFeeForwarder, IPonsFeeEscrow} from "../src/PeggoyFeeForwarder.sol";

/// Mirrors the Pons v2 fee escrow surface: credits accrue per recipient, the recipient claims to itself.
contract MockEscrow is IPonsFeeEscrow {
    mapping(address => uint256) public balanceOf;

    function credit(address recipient) external payable {
        balanceOf[recipient] += msg.value;
    }

    function claim() external {
        uint256 amount = balanceOf[msg.sender];
        balanceOf[msg.sender] = 0;
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "send");
    }
}

contract PeggoyFeeForwarderTest is Test {
    PeggoyMachine m;
    MockEscrow escrow;
    PeggoyFeeForwarder fwd;

    function setUp() public {
        vm.warp(1791039600);
        m = new PeggoyMachine(address(this), address(this), 1791039600);
        escrow = new MockEscrow();
        fwd = new PeggoyFeeForwarder(escrow, payable(address(m)));
        vm.deal(address(this), 100 ether);
    }

    function test_pull_claimsEscrow_andFeedsTheMachine_8020() public {
        escrow.credit{value: 5 ether}(address(fwd));
        assertEq(fwd.pending(), 5 ether);
        vm.prank(address(0xBEEF)); // anyone
        assertEq(fwd.pull(), 5 ether);
        assertEq(escrow.balanceOf(address(fwd)), 0);
        assertEq(address(fwd).balance, 0);
        assertEq(m.queued(), 4 ether);
        assertEq(m.dropPot(0), 1 ether);
    }

    function test_pull_forwardsDirectEthToo_andIsSafeWhenEmpty() public {
        assertEq(fwd.pull(), 0);
        (bool ok,) = address(fwd).call{value: 1 ether}("");
        assertTrue(ok);
        escrow.credit{value: 2 ether}(address(fwd));
        assertEq(fwd.pull(), 3 ether);
        assertEq(address(m).balance, 3 ether);
    }

    function test_constructorRejectsZero() public {
        vm.expectRevert(PeggoyFeeForwarder.ZeroAddress.selector);
        new PeggoyFeeForwarder(IPonsFeeEscrow(address(0)), payable(address(m)));
        vm.expectRevert(PeggoyFeeForwarder.ZeroAddress.selector);
        new PeggoyFeeForwarder(escrow, payable(address(0)));
    }

    /// The real Pons escrow on Robinhood Chain answers the forwarder's calls (run with --fork-url).
    function test_fork_realPonsEscrow() public {
        if (block.chainid != 4663) return;
        IPonsFeeEscrow real = IPonsFeeEscrow(0xd3AFEB2a57f70eF218Aa82451c51B2fb0416Ac9e);
        PeggoyFeeForwarder f = new PeggoyFeeForwarder(real, payable(address(m)));
        assertEq(f.pending(), 0);
        assertEq(f.pull(), 0); // nothing owed yet: no claim, no revert
    }
}
