// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PeggoyMachine} from "../src/PeggoyMachine.sol";
import {PeggoyDrop, IPeggoyMachine} from "../src/PeggoyDrop.sol";
import {MockToken} from "./PeggoyMachine.t.sol";

contract PeggoyDropTest is Test {
    // real drand evmnet beacons (https://api.drand.sh/v2/beacons/evmnet/rounds/<round>)
    uint64 constant R = 21118623;
    bytes constant SIG_R = hex"0c55ba05af855fedde9430997cdbc2a6c4b5436b8f9ec2c34049a0faad07a303013932fa39a24bfe504dbc203141e795eb76e74b68287b6442932fdae3027f19";
    uint64 constant R2 = 21117623;
    bytes constant SIG_R2 = hex"0483a5cb0fe7410c1ba94be5cac58d541d3a0c1e22d1e3654ff1e69eeca6b6ef2e6939797dd326921725ea4d1989c0150c01d748bc07df66968e26bc62caacf6";
    uint64 constant R3 = 21116623;
    bytes constant SIG_R3 = hex"174c208235f51e5241fb6bf4587153b797843ff90b90995a3c421e246c953a7123b27d9b5a751c5551a02af528d89c8e2bdcabe1af8f12f591bdfd9edc03c807";

    uint256 constant DRAND_GENESIS = 1727521075;
    uint256 constant WEEK = 7 days;

    PeggoyMachine m;
    PeggoyDrop drop;
    MockToken t;
    uint256 genesis;
    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address carol = address(0xCA201);

    function setUp() public {
        // place week 0 so that its seeding round is exactly R (a beacon we hold the real signature of)
        uint256 end = DRAND_GENESIS + (uint256(R) - 2) * 3;
        genesis = end - WEEK;
        vm.warp(genesis);
        m = new PeggoyMachine(address(this), address(this), genesis);
        t = new MockToken();
        m.setStakingToken(address(t));
        drop = new PeggoyDrop(IPeggoyMachine(address(m)));
        m.setDropDistributor(address(drop));
        address[3] memory us = [alice, bob, carol];
        for (uint256 i; i < 3; i++) {
            t.mint(us[i], 1_000_000e18);
            vm.prank(us[i]);
            t.approve(address(m), type(uint256).max);
        }
        vm.deal(address(this), 100 ether);
    }

    function _stake(address u, uint256 a) internal {
        vm.prank(u);
        m.stake(a);
    }

    function _fund(uint256 a) internal {
        (bool ok,) = address(m).call{value: a}("");
        assertTrue(ok);
    }

    function _weekOverAndSettle() internal {
        vm.warp(m.epochEnd(0) + 10);
        drop.settle(0, SIG_R);
    }

    function _enterAll() internal {
        address[] memory us = new address[](3);
        us[0] = alice; us[1] = bob; us[2] = carol;
        drop.enter(0, us);
    }

    // ---------------------------------------------------------------- drand

    function test_verifiesRealDrandBeacons() public view {
        assertTrue(drop.verifyDrand(R, SIG_R));
        assertTrue(drop.verifyDrand(R2, SIG_R2));
        assertTrue(drop.verifyDrand(R3, SIG_R3));
    }

    function test_rejectsWrongRoundOrTamperedSignature() public view {
        assertFalse(drop.verifyDrand(R, SIG_R2)); // right signature, wrong round
        assertFalse(drop.verifyDrand(R + 1, SIG_R));
        bytes memory bad = SIG_R;
        bad[63] = bytes1(uint8(bad[63]) ^ 1);
        assertFalse(drop.verifyDrand(R, bad));
        assertFalse(drop.verifyDrand(R, hex"1234"));
    }

    function test_drandRound_isFirstAfterWeekEnd() public view {
        assertEq(drop.drandRound(0), R);
        uint256 publishedAt = DRAND_GENESIS + (uint256(R) - 1) * 3;
        assertGt(publishedAt, m.epochEnd(0));
        assertLe(publishedAt - m.epochEnd(0), 3);
    }

    // ---------------------------------------------------------------- settle

    function test_settle_onlyAfterWeek_withTheScheduledRound() public {
        _stake(alice, 100e18);
        _fund(10 ether); // 2 ETH to the pot
        vm.expectRevert(PeggoyDrop.WeekNotOver.selector);
        drop.settle(0, SIG_R);

        vm.warp(m.epochEnd(0) + 10);
        vm.expectRevert(PeggoyDrop.BadSignature.selector);
        drop.settle(0, SIG_R2); // a real beacon, but not the scheduled one

        drop.settle(0, SIG_R);
        (bytes32 seed, uint64 round,, uint256 pot, uint256 totalBalls,,) = drop.draws(0);
        assertEq(round, R);
        assertEq(seed, keccak256(abi.encode(sha256(SIG_R), uint256(0))));
        assertEq(pot, 2 ether);
        assertEq(address(drop).balance, 2 ether);
        assertEq(totalBalls, m.totalBalls(0));

        vm.expectRevert(PeggoyDrop.AlreadySettled.selector);
        drop.settle(0, SIG_R);
    }

    function test_onlyMachineCanSendEth() public {
        (bool ok,) = address(drop).call{value: 1}("");
        assertFalse(ok);
    }

    // ---------------------------------------------------------------- entries + payout

    function test_fullWeek_entriesClaimsSweep() public {
        _stake(alice, 1_000e18);
        _stake(bob, 3_000e18);
        _fund(10 ether);
        _weekOverAndSettle();
        _enterAll(); // carol has no balls: skipped

        assertFalse(drop.entered(0, carol));
        for (uint256 i; i < 14; i++) {
            address w = drop.winner(0, i);
            assertTrue(w == alice || w == bob);
        }

        vm.expectRevert(PeggoyDrop.EntryOpen.selector);
        drop.claim(0, 0);

        vm.warp(block.timestamp + 3 days);
        address[] memory late = new address[](1);
        late[0] = alice;
        vm.expectRevert(PeggoyDrop.EntryClosed.selector);
        drop.enter(0, late);

        uint256 a0 = alice.balance;
        uint256 b0 = bob.balance;
        for (uint256 i; i < 13; i++) drop.claim(0, i); // slot 13 stays unclaimed
        uint256 slot13 = (2 ether * 300) / 10_000;
        assertEq((alice.balance - a0) + (bob.balance - b0), 2 ether - slot13);

        vm.expectRevert(PeggoyDrop.AlreadyPaid.selector);
        drop.claim(0, 0);

        vm.expectRevert(PeggoyDrop.ClaimOpen.selector);
        drop.sweep(0);
        vm.warp(block.timestamp + 30 days);
        uint256 queuedBefore = m.queued();
        drop.sweep(0);
        assertEq(address(drop).balance, 0);
        assertEq(m.queued() - queuedBefore, (slot13 * 8_000) / 10_000); // back into the Machine, split 80/20
        vm.expectRevert(PeggoyDrop.AlreadySwept.selector);
        drop.claim(0, 13);
    }

    function test_slotsAddUpToWholePot() public pure {
        uint256 sum;
        for (uint256 i; i < 14; i++) sum += i == 0 ? 4_000 : i < 4 ? 1_000 : 300;
        assertEq(sum, 10_000);
    }

    function test_enteringTwice_orOrder_changesNothing() public {
        _stake(alice, 1_000e18);
        _stake(bob, 3_000e18);
        _fund(1 ether);
        _weekOverAndSettle();
        address[] memory ba = new address[](3);
        ba[0] = bob; ba[1] = alice; ba[2] = bob;
        drop.enter(0, ba);
        address[14] memory first;
        for (uint256 i; i < 14; i++) first[i] = drop.winner(0, i);
        // same result as computing keys directly, whatever the order
        (bytes32 seed,,,,,,) = drop.draws(0);
        for (uint256 i; i < 14; i++) {
            uint256 ka = drop.keyFor(seed, i, alice, m.ballsOf(alice, 0));
            uint256 kb = drop.keyFor(seed, i, bob, m.ballsOf(bob, 0));
            assertEq(first[i], ka < kb ? alice : bob);
        }
    }

    function test_claimTo_onlyWinner() public {
        _stake(alice, 1_000e18);
        _fund(1 ether);
        _weekOverAndSettle();
        _enterAll();
        vm.warp(block.timestamp + 3 days);
        vm.prank(bob);
        vm.expectRevert(PeggoyDrop.NotWinner.selector);
        drop.claimTo(0, 0, bob);
        vm.prank(alice);
        drop.claimTo(0, 0, carol);
        assertEq(carol.balance, 0.4 ether * 2 / 10); // 40% of the 0.2 ETH pot
    }

    function test_weekNobodyEntered_sweepsBack() public {
        _fund(1 ether);
        _weekOverAndSettle();
        vm.warp(block.timestamp + 33 days);
        vm.expectRevert(PeggoyDrop.NoWinner.selector);
        drop.claim(0, 0);
        drop.sweep(0);
        assertEq(address(drop).balance, 0);
    }

    // ---------------------------------------------------------------- fairness

    /// Exponential race: P(win a slot) = balls / total. Alice holds 25% of the balls; over 4,200 slot draws she
    /// should win ~25%. Then the same 25% split across four wallets: the group still wins ~25% (sybil-neutral).
    function test_winRate_matchesBallShare_andSplittingDoesNotHelp() public view {
        uint256 aliceWins;
        uint256 farmWins;
        uint256 draws = 300 * 14;
        address[4] memory farm = [address(0xF1), address(0xF2), address(0xF3), address(0xF4)];
        for (uint256 s; s < 300; s++) {
            bytes32 seed = keccak256(abi.encode("seed", s));
            for (uint256 i; i < 14; i++) {
                uint256 kb = drop.keyFor(seed, i, bob, 3_000);
                if (drop.keyFor(seed, i, alice, 1_000) < kb) aliceWins++;
                uint256 bestFarm = type(uint256).max;
                for (uint256 f; f < 4; f++) {
                    uint256 k = drop.keyFor(seed, i, farm[f], 250);
                    if (k < bestFarm) bestFarm = k;
                }
                if (bestFarm < kb) farmWins++;
            }
        }
        // 25% ± 3.5% (≈ 5 standard deviations at 4,200 draws)
        assertApproxEqAbs(aliceWins * 10_000 / draws, 2_500, 350);
        assertApproxEqAbs(farmWins * 10_000 / draws, 2_500, 350);
    }
}
