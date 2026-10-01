// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {BLS} from "./vendor/drand/BLS.sol";

interface IPeggoyMachine {
    function epochEnd(uint256 epoch) external view returns (uint256);
    function ballsOf(address user, uint256 epoch) external view returns (uint256);
    function totalBalls(uint256 epoch) external view returns (uint256);
    function releaseDrop(uint256 epoch) external returns (uint256);
}

/// @title PEGGOY Drop
/// @notice Draws and pays the weekly Drop. Nobody picks the winners, the team included:
///         1. Seed: the first drand `evmnet` round published after the week closes. The round number follows from
///            the schedule (nobody chooses it), its BLS signature is verified on chain, and nothing else is mixed in
///            (a block hash could be nudged by whoever settles or by the sequencer).
///         2. Entries: for 3 days anyone can enter any address (their own included). Weights are read from the
///            Machine (`ballsOf`), never supplied by the caller. Entering earlier or later changes nothing.
///         3. Draw: 14 slots, each an independent exponential race: an entry's key for slot i is
///            -ln(u_i) / balls, with u_i uniform from keccak(seed, i, address); the lowest key wins the slot.
///            P(win slot i) = balls / totalBalls exactly, independent across slots, so splitting a stake across
///            wallets changes nothing (sybil-neutral). One address can win more than one slot.
///         4. Payout: 1 × 40%, 3 × 10%, 10 × 3% of the pot, claimable for 30 days; whatever is left then goes back
///            to the Machine (and is split into the stream and the next Drop like any other ETH).
contract PeggoyDrop is ReentrancyGuard {
    IPeggoyMachine public immutable machine;

    uint256 public constant SLOTS = 14;
    uint256 public constant ENTRY_WINDOW = 3 days;
    uint256 public constant CLAIM_WINDOW = 30 days;

    // drand evmnet: https://api.drand.sh/v2/beacons/evmnet/info
    uint256 public constant DRAND_GENESIS = 1727521075;
    uint256 public constant DRAND_PERIOD = 3;
    string public constant DST = "BLS_SIG_BN254G1_XMD:KECCAK-256_SVDW_RO_NUL_";

    struct Draw {
        bytes32 seed;
        uint64 round;
        uint64 settledAt;
        uint256 pot;
        uint256 totalBalls;
        uint256 paidOut;
        bool swept;
    }

    mapping(uint256 => Draw) public draws;
    mapping(uint256 => mapping(address => bool)) public entered;
    mapping(uint256 => mapping(uint256 => address)) public winner;
    mapping(uint256 => mapping(uint256 => uint256)) public bestKey;
    mapping(uint256 => mapping(uint256 => bool)) public paid;

    event Settled(uint256 indexed epoch, uint64 round, bytes32 seed, uint256 pot, uint256 totalBalls);
    event Entered(uint256 indexed epoch, address indexed user, uint256 balls);
    event SlotTaken(uint256 indexed epoch, uint256 indexed slot, address indexed user);
    event Paid(uint256 indexed epoch, uint256 indexed slot, address indexed winner, address to, uint256 amount);
    event Swept(uint256 indexed epoch, uint256 amount);

    error WeekNotOver();
    error AlreadySettled();
    error BadSignature();
    error NotSettled();
    error EntryClosed();
    error EntryOpen();
    error NoWinner();
    error AlreadyPaid();
    error NotWinner();
    error ClaimOpen();
    error AlreadySwept();
    error OnlyMachine();
    error EthTransferFailed();

    constructor(IPeggoyMachine machine_) {
        machine = machine_;
    }

    /// @dev The Machine pays pots in through releaseDrop; nothing else should send ETH here.
    receive() external payable {
        if (msg.sender != address(machine)) revert OnlyMachine();
    }

    // ------------------------------------------------------------------ 1. seed

    /// @notice The drand round that seeds `epoch`: the first one published after the week closes.
    function drandRound(uint256 epoch) public view returns (uint64) {
        uint256 end = machine.epochEnd(epoch);
        // round r is published at DRAND_GENESIS + (r - 1) * PERIOD; this is the first r with that time > end
        return uint64((end - DRAND_GENESIS) / DRAND_PERIOD + 2);
    }

    /// @notice Anyone settles a finished week with the drand signature of its round; the pot moves here.
    function settle(uint256 epoch, bytes calldata signature) external nonReentrant {
        if (block.timestamp <= machine.epochEnd(epoch)) revert WeekNotOver();
        Draw storage d = draws[epoch];
        if (d.settledAt != 0) revert AlreadySettled();
        uint64 round = drandRound(epoch);
        if (!verifyDrand(round, signature)) revert BadSignature();

        d.round = round;
        d.seed = keccak256(abi.encode(sha256(signature), epoch));
        d.settledAt = uint64(block.timestamp);
        d.totalBalls = machine.totalBalls(epoch);
        d.pot = machine.releaseDrop(epoch);
        emit Settled(epoch, round, d.seed, d.pot, d.totalBalls);
    }

    /// @notice True when `signature` is drand evmnet's BLS signature for `round`.
    function verifyDrand(uint64 round, bytes calldata signature) public view returns (bool) {
        if (signature.length != 64) return false;
        BLS.PointG1 memory sig = BLS.g1Unmarshal(signature);
        if (!BLS.isOnCurveG1(sig)) return false;
        BLS.PointG1 memory message = BLS.hashToPoint(bytes(DST), abi.encodePacked(keccak256(abi.encodePacked(round))));
        (bool callOk, bool pairingOk) = BLS.verifySingle(sig, _publicKey(), message);
        return callOk && pairingOk;
    }

    // ------------------------------------------------------------------ 2. entries + 3. draw

    /// @notice Enters addresses for `epoch`. Anyone may enter anyone; balls come from the Machine.
    function enter(uint256 epoch, address[] calldata users) external {
        Draw storage d = draws[epoch];
        if (d.settledAt == 0) revert NotSettled();
        if (block.timestamp >= d.settledAt + ENTRY_WINDOW) revert EntryClosed();
        bytes32 seed = d.seed;
        for (uint256 n; n < users.length; ++n) {
            address u = users[n];
            if (entered[epoch][u]) continue;
            uint256 balls = machine.ballsOf(u, epoch);
            if (balls == 0) continue;
            entered[epoch][u] = true;
            emit Entered(epoch, u, balls);
            for (uint256 i; i < SLOTS; ++i) {
                uint256 key = keyFor(seed, i, u, balls);
                address w = winner[epoch][i];
                if (w == address(0) || key < bestKey[epoch][i]) {
                    winner[epoch][i] = u;
                    bestKey[epoch][i] = key;
                    emit SlotTaken(epoch, i, u);
                }
            }
        }
    }

    /// @notice Exponential-race key of `user` in slot `slot`: -ln(u) / balls (scaled). Lowest key wins.
    function keyFor(bytes32 seed, uint256 slot, address user, uint256 balls) public pure returns (uint256) {
        uint256 uWad = (uint256(keccak256(abi.encode(seed, slot, user))) % 1e18) + 1; // uniform in (0, 1]
        uint256 negLn = uint256(-FixedPointMathLib.lnWad(int256(uWad))); // in [0, ~41.4e18]
        return (negLn << 128) / balls;
    }

    // ------------------------------------------------------------------ 4. payout

    function slotBps(uint256 slot) public pure returns (uint256) {
        return slot == 0 ? 4_000 : slot < 4 ? 1_000 : 300;
    }

    /// @notice Pays slot `slot` of `epoch` to its winner. Anyone may call it (it only ever pays the winner).
    function claim(uint256 epoch, uint256 slot) external nonReentrant {
        address w = winner[epoch][slot];
        _pay(epoch, slot, w, w);
    }

    /// @notice For winners whose address cannot receive ETH.
    function claimTo(uint256 epoch, uint256 slot, address to) external nonReentrant {
        if (msg.sender != winner[epoch][slot]) revert NotWinner();
        _pay(epoch, slot, msg.sender, to);
    }

    /// @notice After the claim window, whatever is left (unclaimed slots, a week nobody entered) returns to the
    ///         Machine, where it is split into the stream and the current Drop like any other ETH.
    function sweep(uint256 epoch) external nonReentrant {
        Draw storage d = draws[epoch];
        if (d.settledAt == 0) revert NotSettled();
        if (block.timestamp < d.settledAt + ENTRY_WINDOW + CLAIM_WINDOW) revert ClaimOpen();
        if (d.swept) revert AlreadySwept();
        d.swept = true;
        uint256 left = d.pot - d.paidOut;
        if (left != 0) _send(address(machine), left);
        emit Swept(epoch, left);
    }

    function _pay(uint256 epoch, uint256 slot, address w, address to) internal {
        Draw storage d = draws[epoch];
        if (d.settledAt == 0) revert NotSettled();
        if (block.timestamp < d.settledAt + ENTRY_WINDOW) revert EntryOpen();
        if (d.swept) revert AlreadySwept();
        if (w == address(0) || slot >= SLOTS) revert NoWinner();
        if (paid[epoch][slot]) revert AlreadyPaid();
        paid[epoch][slot] = true;
        uint256 amount = (d.pot * slotBps(slot)) / 10_000;
        d.paidOut += amount;
        _send(to, amount);
        emit Paid(epoch, slot, w, to, amount);
    }

    function _send(address to, uint256 amount) internal {
        (bool ok,) = payable(to).call{value: amount}("");
        if (!ok) revert EthTransferFailed();
    }

    function _publicKey() internal pure returns (BLS.PointG2 memory) {
        // drand evmnet public key (G2), same encoding as randa-mu's EvmnetRegistry
        return BLS.PointG2(
            [
                0x557ec32c2ad488e4d4f6008f89a346f18492092ccc0d594610de2732c8b808f,
                0x7e1d1d335df83fa98462005690372c643340060d205306a9aa8106b6bd0b382
            ],
            [
                0x297d3a4f9749b33eb2d904c9d9ebf17224150ddd7abd7567a9bec6c74480ee0b,
                0x95685ae3a85ba243747b1b2f426049010f6b73a0cf1d389351d5aaaa1047f6
            ]
        );
    }
}
