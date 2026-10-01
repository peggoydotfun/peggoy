// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {PeggoyMachine} from "../src/PeggoyMachine.sol";

contract MockToken is ERC20 {
    constructor() ERC20("PEGGOY", "PEGGOY") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// Takes 1% on every transfer, to prove the Machine credits what actually arrives.
contract TaxedToken is ERC20 {
    constructor() ERC20("TAXED", "TAX") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) {
            uint256 fee = value / 100;
            super._update(from, address(0xdead), fee);
            value -= fee;
        }
        super._update(from, to, value);
    }
}

contract Distributor {
    receive() external payable {}

    function pull(PeggoyMachine m, uint256 epoch) external returns (uint256) {
        return m.releaseDrop(epoch);
    }
}

contract EthRefuser {
    function stakeVia(PeggoyMachine m, MockToken t, uint256 amt) external {
        t.approve(address(m), amt);
        m.stake(amt);
    }

    function claimVia(PeggoyMachine m) external {
        m.claim();
    }

    function claimToVia(PeggoyMachine m, address to) external {
        m.claimTo(to);
    }
}

contract Reenterer {
    PeggoyMachine public m;
    bool public reentered;

    constructor(PeggoyMachine m_) {
        m = m_;
    }

    function stakeVia(MockToken t, uint256 amt) external {
        t.approve(address(m), amt);
        m.stake(amt);
    }

    function claimVia() external {
        m.claim();
    }

    receive() external payable {
        try m.claim() {
            reentered = true;
        } catch {}
    }
}

contract PeggoyMachineTest is Test {
    uint256 constant GENESIS = 1791039600; // Sat 03 Oct 2026 15:00 UTC
    uint256 constant WEEK = 7 days;

    PeggoyMachine m;
    MockToken t;
    TimelockController timelock;
    address safe = address(0x5AFE);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address carol = address(0xCA201);
    address griefer = address(0xBAD);

    function setUp() public {
        vm.warp(GENESIS);
        address[] memory roles = new address[](1);
        roles[0] = safe;
        timelock = new TimelockController(48 hours, roles, roles, address(0));
        m = new PeggoyMachine(address(timelock), safe, GENESIS);
        t = new MockToken();
        vm.prank(safe);
        m.setStakingToken(address(t));
        for (uint256 i; i < 4; i++) {
            address u = [alice, bob, carol, griefer][i];
            t.mint(u, 1_000_000e18);
            vm.prank(u);
            t.approve(address(m), type(uint256).max);
            vm.deal(u, 100 ether);
        }
        vm.deal(address(this), 1_000 ether);
    }

    // ---------------------------------------------------------------- helpers

    function _send(uint256 amount) internal {
        (bool ok,) = address(m).call{value: amount}("");
        assertTrue(ok);
    }

    function _stake(address u, uint256 amount) internal {
        vm.prank(u);
        m.stake(amount);
    }

    /// Runs an owner call through the 48 h timelock, as the Safe would.
    function _timelocked(bytes memory data) internal {
        bytes32 salt = keccak256(data);
        vm.prank(safe);
        timelock.schedule(address(m), 0, data, bytes32(0), salt, 48 hours);
        skip(48 hours);
        vm.prank(safe);
        timelock.execute(address(m), 0, data, bytes32(0), salt);
    }

    // ---------------------------------------------------------------- launcher / owner

    function test_launcherSetsTokenOnce_thenNothing() public {
        PeggoyMachine fresh = new PeggoyMachine(address(timelock), safe, GENESIS);
        vm.expectRevert(PeggoyMachine.NotLauncher.selector);
        fresh.setStakingToken(address(t));
        vm.prank(safe);
        vm.expectRevert(PeggoyMachine.NotAContract.selector);
        fresh.setStakingToken(address(0x1234));
        vm.prank(safe);
        fresh.setStakingToken(address(t));
        address other = address(new MockToken());
        vm.prank(safe);
        vm.expectRevert(PeggoyMachine.TokenAlreadySet.selector);
        fresh.setStakingToken(other);
        // the launcher is not the owner
        vm.prank(safe);
        vm.expectRevert();
        fresh.setMinRoll(0.5 ether);
    }

    function test_ownerIsTimelock_paramsNeed48h() public {
        assertEq(m.owner(), address(timelock));
        vm.prank(safe);
        vm.expectRevert();
        m.setMinRoll(0.5 ether);

        bytes memory data = abi.encodeCall(PeggoyMachine.setMinRoll, (0.5 ether));
        vm.prank(safe);
        timelock.schedule(address(m), 0, data, bytes32(0), bytes32(0), 48 hours);
        skip(47 hours);
        vm.prank(safe);
        vm.expectRevert();
        timelock.execute(address(m), 0, data, bytes32(0), bytes32(0));
        skip(1 hours);
        vm.prank(safe);
        timelock.execute(address(m), 0, data, bytes32(0), bytes32(0));
        assertEq(m.minRoll(), 0.5 ether);
    }

    function test_paramBounds() public {
        vm.startPrank(address(timelock));
        vm.expectRevert(PeggoyMachine.BadParam.selector);
        m.setDropBps(3_001);
        vm.expectRevert(PeggoyMachine.BadParam.selector);
        m.setMinRoll(0);
        vm.expectRevert(PeggoyMachine.BadParam.selector);
        m.setMinRoll(1 ether + 1);
        vm.expectRevert(PeggoyMachine.BadParam.selector);
        m.setRewardsDuration(12 hours);
        vm.expectRevert(PeggoyMachine.BadParam.selector);
        m.setRewardsDuration(31 days);
        vm.stopPrank();
    }

    function test_noRescuePath_recoverNeverStakingToken() public {
        vm.prank(address(timelock));
        vm.expectRevert(PeggoyMachine.CannotRecoverStakingToken.selector);
        m.recoverERC20(address(t), address(timelock), 1);
    }

    // ---------------------------------------------------------------- split + stream

    function test_receive_splits80_20() public {
        _send(10 ether);
        assertEq(m.queued(), 8 ether);
        assertEq(m.dropPot(0), 2 ether);
    }

    function test_singleStaker_getsWholeStream() public {
        _stake(alice, 1_000e18);
        _send(10 ether);
        m.roll();
        skip(WEEK);
        assertApproxEqAbs(m.earned(alice), 8 ether, 1e6);
        uint256 before = alice.balance;
        vm.prank(alice);
        m.claim();
        assertApproxEqAbs(alice.balance - before, 8 ether, 1e6);
    }

    function test_twoStakers_proRata() public {
        _stake(alice, 1_000e18);
        _stake(bob, 3_000e18);
        _send(10 ether);
        m.roll();
        skip(WEEK);
        assertApproxEqAbs(m.earned(alice), 2 ether, 1e6);
        assertApproxEqAbs(m.earned(bob), 6 ether, 1e6);
    }

    function test_lateStake_cannotSnipeDeposit() public {
        _stake(alice, 1_000e18);
        _send(10 ether);
        m.roll();
        skip(WEEK - 1 hours);
        _stake(bob, 1_000_000e18); // whale one hour before the end
        skip(1 hours);
        assertLt(m.earned(bob), 0.5 ether);
        assertGt(m.earned(alice), 7.5 ether);
    }

    /// The NIMORI griefing: right after a round ends, 1 wei + kick locked real rewards out for 7 days.
    function test_dustRoll_cannotLockOutRealRewards() public {
        _stake(alice, 1_000e18);
        vm.startPrank(griefer);
        (bool ok,) = address(m).call{value: 2}("");
        assertTrue(ok);
        m.roll(); // a 7-day round streaming 1 wei
        vm.stopPrank();

        _send(10 ether); // real fees arrive
        m.roll(); // anyone can roll them in at once: queued >= minRoll
        skip(WEEK);
        assertApproxEqAbs(m.earned(alice), 8 ether, 1e6);
    }

    function test_rollMidPeriod_belowMinRoll_reverts() public {
        _stake(alice, 1_000e18);
        _send(1 ether);
        m.roll();
        _send(0.01 ether); // 0.008 to the stream: below minRoll
        vm.expectRevert(PeggoyMachine.TooEarly.selector);
        m.roll();
        _send(0.01 ether); // 0.016 queued now
        m.roll();
        assertEq(m.queued(), 0);
    }

    function test_rollMidPeriod_leftoverRollsIn() public {
        _stake(alice, 1_000e18);
        _send(10 ether);
        m.roll();
        skip(WEEK / 2);
        _send(10 ether);
        m.roll();
        assertApproxEqAbs(m.remainingInPeriod(), 4 ether + 8 ether, 1e6);
        skip(WEEK);
        assertApproxEqAbs(m.earned(alice), 16 ether, 1e6);
    }

    function test_rollWithNothingQueued_reverts() public {
        vm.expectRevert(PeggoyMachine.NothingQueued.selector);
        m.roll();
    }

    function test_streamWithNoStakers_returnsToQueue() public {
        _send(10 ether);
        m.roll();
        skip(WEEK / 2);
        _stake(alice, 1_000e18);
        assertApproxEqAbs(m.queued(), 4 ether, 1e6);
        skip(WEEK);
        assertApproxEqAbs(m.earned(alice), 4 ether, 1e6);
        m.roll();
        skip(WEEK);
        assertApproxEqAbs(m.earned(alice), 8 ether, 1e6);
    }

    function test_withdrawAlwaysWorks_evenMidPeriod() public {
        _stake(alice, 1_000e18);
        _send(10 ether);
        m.roll();
        skip(1 days);
        vm.prank(alice);
        m.withdraw(1_000e18);
        assertEq(t.balanceOf(alice), 1_000_000e18);
    }

    function test_cannotWithdrawMoreThanStaked() public {
        _stake(alice, 1_000e18);
        vm.prank(alice);
        vm.expectRevert();
        m.withdraw(1_000e18 + 1);
    }

    function test_exit_withdrawsAndClaims() public {
        _stake(alice, 1_000e18);
        _send(10 ether);
        m.roll();
        skip(WEEK);
        uint256 before = alice.balance;
        vm.prank(alice);
        m.exit();
        assertEq(m.balanceOf(alice), 0);
        assertApproxEqAbs(alice.balance - before, 8 ether, 1e6);
    }

    function test_taxedToken_creditsReceivedAmount() public {
        PeggoyMachine tm = new PeggoyMachine(address(timelock), safe, GENESIS);
        TaxedToken tt = new TaxedToken();
        vm.prank(safe);
        tm.setStakingToken(address(tt));
        tt.mint(alice, 1_000e18);
        vm.startPrank(alice);
        tt.approve(address(tm), 1_000e18);
        tm.stake(1_000e18);
        vm.stopPrank();
        assertEq(tm.balanceOf(alice), 990e18);
        assertEq(tm.totalSupply(), 990e18);
    }

    function test_claimTo_forContractsThatRefuseEth() public {
        EthRefuser r = new EthRefuser();
        t.mint(address(r), 1_000e18);
        r.stakeVia(m, t, 1_000e18);
        _send(10 ether);
        m.roll();
        skip(WEEK);
        vm.expectRevert(PeggoyMachine.EthTransferFailed.selector);
        r.claimVia(m);
        r.claimToVia(m, carol);
        assertApproxEqAbs(carol.balance, 100 ether + 8 ether, 1e6);
    }

    function test_reentrancyOnClaim_blocked() public {
        Reenterer r = new Reenterer(m);
        t.mint(address(r), 1_000e18);
        r.stakeVia(t, 1_000e18);
        _send(10 ether);
        m.roll();
        skip(WEEK);
        r.claimVia();
        assertFalse(r.reentered());
    }

    // ---------------------------------------------------------------- balls

    function test_balls_areStakeTimesSeconds() public {
        _stake(alice, 100e18);
        skip(1 days);
        assertEq(m.ballsOf(alice, 0), 100e18 * 1 days);
        assertEq(m.totalBalls(0), 100e18 * 1 days);
    }

    /// One wallet with 1,000 or ten wallets with 100 each: same balls in total. Splitting buys nothing.
    function test_balls_sybilNeutral() public {
        _stake(alice, 1_000e18);
        address[10] memory farm;
        for (uint256 i; i < 10; i++) {
            farm[i] = address(uint160(0xF000 + i));
            t.mint(farm[i], 100e18);
            vm.startPrank(farm[i]);
            t.approve(address(m), 100e18);
            m.stake(100e18);
            vm.stopPrank();
        }
        skip(3 days);
        uint256 farmBalls;
        for (uint256 i; i < 10; i++) farmBalls += m.ballsOf(farm[i], 0);
        assertEq(farmBalls, m.ballsOf(alice, 0));
        assertEq(m.totalBalls(0), 2 * m.ballsOf(alice, 0));
    }

    function test_balls_splitAcrossEpochs() public {
        skip(WEEK - 1 days); // 1 day left in epoch 0
        _stake(alice, 10e18);
        skip(1 days + 2 days); // crosses into epoch 1
        assertEq(m.currentEpoch(), 1);
        assertEq(m.ballsOf(alice, 0), 10e18 * 1 days);
        assertEq(m.ballsOf(alice, 1), 10e18 * 2 days);
        // booking on an action keeps the same numbers
        _stake(alice, 10e18);
        assertEq(m.ballsOf(alice, 0), 10e18 * 1 days);
        assertEq(m.ballsOf(alice, 1), 10e18 * 2 days);
        skip(1 days);
        assertEq(m.ballsOf(alice, 1), 10e18 * 2 days + 20e18 * 1 days);
    }

    function test_balls_idleForManyEpochs_bookedOnNextAction() public {
        _stake(alice, 1e18);
        skip(10 * WEEK + 1 days);
        _stake(alice, 1e18);
        for (uint256 e; e < 10; e++) assertEq(m.ballsOf(alice, e), 1e18 * WEEK);
        assertEq(m.ballsOf(alice, 10), 1e18 * 1 days);
    }

    function test_balls_stopAfterWithdraw() public {
        _stake(alice, 5e18);
        skip(1 days);
        vm.prank(alice);
        m.withdraw(5e18);
        skip(2 days);
        assertEq(m.ballsOf(alice, 0), 5e18 * 1 days);
        assertEq(m.totalBalls(0), 5e18 * 1 days);
    }

    function testFuzz_totalBalls_equalsSumOfUsers(uint96 a, uint96 b, uint96 c, uint32 d1, uint32 d2, uint32 d3) public {
        uint256 x = bound(a, 1, 1_000_000e18);
        uint256 y = bound(b, 1, 1_000_000e18);
        uint256 z = bound(c, 1, 1_000_000e18);
        _stake(alice, x);
        skip(bound(d1, 0, 20 days));
        _stake(bob, y);
        skip(bound(d2, 0, 20 days));
        vm.prank(alice);
        m.withdraw(x / 2 + 1 > x ? x : x / 2 + 1);
        _stake(carol, z);
        skip(bound(d3, 0, 20 days));
        uint256 last = m.currentEpoch();
        for (uint256 e; e <= last; e++) {
            assertEq(m.totalBalls(e), m.ballsOf(alice, e) + m.ballsOf(bob, e) + m.ballsOf(carol, e));
        }
    }

    // ---------------------------------------------------------------- drop

    function test_drop_onlyDistributor_afterEpoch_once() public {
        Distributor d = new Distributor();
        _send(10 ether); // 2 ETH to epoch 0
        vm.expectRevert(PeggoyMachine.NotDistributor.selector);
        m.releaseDrop(0);

        _timelocked(abi.encodeCall(PeggoyMachine.setDropDistributor, (address(d))));
        // still epoch 0 after the 48 h wait: not over yet
        vm.expectRevert(PeggoyMachine.EpochNotOver.selector);
        d.pull(m, 0);

        skip(WEEK);
        assertEq(d.pull(m, 0), 2 ether);
        assertEq(address(d).balance, 2 ether);
        vm.expectRevert(PeggoyMachine.AlreadyReleased.selector);
        d.pull(m, 0);
    }

    function test_drop_distributorCanBeAppointedOnlyOnce() public {
        Distributor d = new Distributor();
        vm.prank(address(timelock));
        m.setDropDistributor(address(d));
        address other = address(new Distributor());
        vm.prank(address(timelock));
        vm.expectRevert(PeggoyMachine.AlreadySet.selector);
        m.setDropDistributor(other);
    }

    function test_drop_unreleasedPotRollsForward_byAnyone() public {
        _send(10 ether);
        skip(WEEK + 29 days);
        vm.expectRevert(PeggoyMachine.TooEarly.selector);
        m.rollDrop(0);
        skip(1 days);
        uint256 e = m.currentEpoch();
        vm.prank(griefer);
        m.rollDrop(0);
        assertEq(m.dropPot(0), 0);
        assertEq(m.dropPot(e), 2 ether);
    }

    function test_dropPot_isNotStreamed() public {
        _stake(alice, 1_000e18);
        _send(10 ether);
        m.roll();
        skip(30 days);
        assertApproxEqAbs(m.earned(alice), 8 ether, 1e6);
        assertEq(address(m).balance, 10 ether);
    }

    // ---------------------------------------------------------------- solvency

    function testFuzz_solvent(uint96 s1, uint96 s2, uint96 e1, uint96 e2, uint32 dt1, uint32 dt2) public {
        uint256 a = bound(s1, 1e9, 1_000_000e18);
        uint256 b = bound(s2, 1e9, 1_000_000e18);
        uint256 x = bound(e1, 1, 300 ether);
        uint256 y = bound(e2, 1, 300 ether);
        _stake(alice, a);
        _send(x);
        if (m.queued() > 0) m.roll();
        skip(bound(dt1, 0, 40 days));
        _stake(bob, b);
        _send(y);
        if (m.queued() >= m.minRoll() || block.timestamp >= m.periodFinish()) {
            if (m.queued() > 0) m.roll();
        }
        skip(bound(dt2, 0, 40 days));

        uint256 owed = m.earned(alice) + m.earned(bob) + m.queued() + m.remainingInPeriod();
        uint256 last = m.currentEpoch();
        for (uint256 e; e <= last; e++) owed += m.dropPot(e);
        assertGe(address(m).balance, owed);

        vm.prank(alice);
        m.exit();
        vm.prank(bob);
        m.exit();
        assertEq(t.balanceOf(address(m)), 0);
    }
}
