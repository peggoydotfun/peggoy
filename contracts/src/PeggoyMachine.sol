// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title PEGGOY Machine
/// @notice Stake $PEGGOY, earn ETH. Every wei of ETH sent here is split on arrival:
///         - the stream share (80% by default) is queued, then streamed to stakers pro rata over a reward period;
///         - the drop share (20% by default) goes to the pot of the current weekly epoch (the Drop).
///         Stakers also earn balls: balance × seconds, booked per epoch on chain. Balls are linear in stake and
///         time, so splitting a stake across many wallets earns exactly the same balls (sybil-neutral).
/// @dev    Owner is a TimelockController (48 h, proposer/executor = the team Safe). The owner can only tune
///         bounded parameters and appoint the Drop distributor once. There is no pause, no lock-up and no owner
///         path to staked tokens or to ETH already streamed to stakers.
///         `launcher` (the Safe) sets the staking token exactly once at launch, then has no power left.
contract PeggoyMachine is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 private constant PRECISION = 1e18;
    uint256 public constant EPOCH = 7 days;
    uint256 public constant MIN_DURATION = 1 days;
    uint256 public constant MAX_DURATION = 30 days;
    uint256 public constant MAX_DROP_BPS = 3_000;
    uint256 public constant MAX_MIN_ROLL = 1 ether;
    /// @notice A Drop pot nobody released this long after its epoch ended rolls into the current epoch.
    uint256 public constant ROLL_GRACE = 30 days;

    /// @notice Epoch 0 starts here (Fri 03 Oct 2026 15:00 UTC on mainnet). Epochs change every Friday 15:00 UTC.
    uint256 public immutable GENESIS;
    /// @notice May call setStakingToken once. Nothing else.
    address public immutable launcher;

    IERC20 public stakingToken;

    // ------------------------------------------------------------------ stream
    uint256 public rewardsDuration = 7 days;
    uint256 public periodFinish;
    /// @notice ETH per second, scaled by 1e18.
    uint256 public rewardRateScaled;
    uint256 public lastUpdateTime;
    uint256 public rewardPerTokenStored;
    /// @notice Stream ETH received but not streaming yet.
    uint256 public queued;
    /// @notice A round can be rolled mid-period once this much is queued (no 1-wei griefing).
    uint256 public minRoll = 0.01 ether;
    /// @notice Share of incoming ETH that goes to the Drop, in basis points.
    uint256 public dropBps = 2_000;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public rewards;

    // ------------------------------------------------------------------ balls + drop
    mapping(address => uint256) public ballsLastTs;
    mapping(address => mapping(uint256 => uint256)) internal _userBalls;
    uint256 public totalBallsLastTs;
    mapping(uint256 => uint256) internal _totalBalls;

    mapping(uint256 => uint256) public dropPot;
    mapping(uint256 => bool) public dropReleased;
    /// @notice The contract that draws and pays Drop winners. Appointed once, through the timelock.
    address public dropDistributor;

    event StakingTokenSet(address indexed token);
    event Received(address indexed from, uint256 toStream, uint256 toDrop, uint256 indexed epoch);
    event RoundStarted(uint256 amount, uint256 duration, uint256 periodFinish);
    event Staked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event RewardPaid(address indexed user, address indexed to, uint256 amount);
    event DropReleased(uint256 indexed epoch, address indexed to, uint256 amount);
    event DropRolled(uint256 indexed fromEpoch, uint256 indexed toEpoch, uint256 amount);
    event RewardsDurationSet(uint256 duration);
    event MinRollSet(uint256 minRoll);
    event DropBpsSet(uint256 bps);
    event DropDistributorSet(address indexed distributor);
    event TokenRecovered(address indexed token, address indexed to, uint256 amount);

    error TokenNotSet();
    error TokenAlreadySet();
    error NotLauncher();
    error NotAContract();
    error ZeroAmount();
    error ZeroAddress();
    error TooEarly();
    error NothingQueued();
    error BadParam();
    error PeriodActive();
    error NotDistributor();
    error AlreadySet();
    error EpochNotOver();
    error AlreadyReleased();
    error CannotRecoverStakingToken();
    error EthTransferFailed();

    constructor(address owner_, address launcher_, uint256 genesis_) Ownable(owner_) {
        if (launcher_ == address(0)) revert ZeroAddress();
        launcher = launcher_;
        GENESIS = genesis_;
    }

    // ------------------------------------------------------------------ ETH in

    /// @notice Creator tax, protocol fees, anything: split between the stream queue and this epoch's Drop pot.
    receive() external payable {
        uint256 toDrop = (msg.value * dropBps) / 10_000;
        uint256 toStream = msg.value - toDrop;
        uint256 e = currentEpoch();
        queued += toStream;
        dropPot[e] += toDrop;
        emit Received(msg.sender, toStream, toDrop, e);
    }

    /// @notice Starts a new stream round with everything queued; the leftover of a running round rolls in.
    /// @dev Anyone may call it once the round is over, or mid-round once `minRoll` is queued. A 1-wei roll can no
    ///      longer lock real rewards out for a whole period: as soon as they are queued, anyone can roll them in.
    function roll() external nonReentrant {
        if (address(stakingToken) == address(0)) revert TokenNotSet();
        _updateReward(address(0));
        if (block.timestamp < periodFinish && queued < minRoll) revert TooEarly();
        uint256 amount = queued;
        if (amount == 0) revert NothingQueued();
        queued = 0;

        uint256 total = amount;
        if (block.timestamp < periodFinish) {
            total += ((periodFinish - block.timestamp) * rewardRateScaled) / PRECISION;
        }
        rewardRateScaled = (total * PRECISION) / rewardsDuration;
        lastUpdateTime = block.timestamp;
        periodFinish = block.timestamp + rewardsDuration;
        emit RoundStarted(total, rewardsDuration, periodFinish);
    }

    // ------------------------------------------------------------------ staking

    function stake(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        IERC20 token = stakingToken;
        if (address(token) == address(0)) revert TokenNotSet();
        _updateReward(msg.sender);
        _updateBalls(msg.sender);

        // Credit what actually arrived, not what was asked for (taxed tokens).
        uint256 before = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = token.balanceOf(address(this)) - before;
        if (received == 0) revert ZeroAmount();

        totalSupply += received;
        balanceOf[msg.sender] += received;
        emit Staked(msg.sender, received);
    }

    function withdraw(uint256 amount) external nonReentrant {
        _withdraw(amount);
    }

    function claim() external nonReentrant {
        _claim(msg.sender, msg.sender);
    }

    /// @notice Claim to another address (for stakers whose address cannot receive ETH).
    function claimTo(address to) external nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        _claim(msg.sender, to);
    }

    function exit() external nonReentrant {
        _withdraw(balanceOf[msg.sender]);
        _claim(msg.sender, msg.sender);
    }

    // ------------------------------------------------------------------ drop

    /// @notice Sends a finished epoch's pot to the distributor, which draws and pays the winners.
    function releaseDrop(uint256 epoch) external nonReentrant returns (uint256 amount) {
        if (msg.sender != dropDistributor || msg.sender == address(0)) revert NotDistributor();
        if (epoch >= currentEpoch()) revert EpochNotOver();
        if (dropReleased[epoch]) revert AlreadyReleased();
        dropReleased[epoch] = true;
        amount = dropPot[epoch];
        dropPot[epoch] = 0;
        if (amount != 0) _sendEth(msg.sender, amount);
        emit DropReleased(epoch, msg.sender, amount);
    }

    /// @notice Anyone may roll a pot nobody released within ROLL_GRACE of its epoch end into the current epoch.
    ///         ETH in a pot can never be stuck, and nobody can take it by hand.
    function rollDrop(uint256 epoch) external nonReentrant {
        if (block.timestamp < epochEnd(epoch) + ROLL_GRACE) revert TooEarly();
        if (dropReleased[epoch]) revert AlreadyReleased();
        uint256 amount = dropPot[epoch];
        if (amount == 0) revert NothingQueued();
        dropPot[epoch] = 0;
        uint256 e = currentEpoch();
        dropPot[e] += amount;
        emit DropRolled(epoch, e, amount);
    }

    // ------------------------------------------------------------------ views

    function currentEpoch() public view returns (uint256) {
        return block.timestamp <= GENESIS ? 0 : (block.timestamp - GENESIS) / EPOCH;
    }

    function epochEnd(uint256 epoch) public view returns (uint256) {
        return GENESIS + (epoch + 1) * EPOCH;
    }

    /// @notice Balls `user` earned in `epoch` (token-wei × seconds), including what accrued since their last action.
    function ballsOf(address user, uint256 epoch) external view returns (uint256) {
        return _userBalls[user][epoch] + _pending(balanceOf[user], ballsLastTs[user], epoch);
    }

    /// @notice All balls earned in `epoch`. Equals the sum of ballsOf over every staker.
    function totalBalls(uint256 epoch) external view returns (uint256) {
        return _totalBalls[epoch] + _pending(totalSupply, totalBallsLastTs, epoch);
    }

    function lastTimeRewardApplicable() public view returns (uint256) {
        return block.timestamp < periodFinish ? block.timestamp : periodFinish;
    }

    function rewardPerToken() public view returns (uint256) {
        if (totalSupply == 0) return rewardPerTokenStored;
        return rewardPerTokenStored + ((lastTimeRewardApplicable() - lastUpdateTime) * rewardRateScaled) / totalSupply;
    }

    function earned(address account) public view returns (uint256) {
        return rewards[account]
            + (balanceOf[account] * (rewardPerToken() - userRewardPerTokenPaid[account])) / PRECISION;
    }

    /// @notice ETH still to be streamed in the running round.
    function remainingInPeriod() public view returns (uint256) {
        if (block.timestamp >= periodFinish) return 0;
        return ((periodFinish - block.timestamp) * rewardRateScaled) / PRECISION;
    }

    // ------------------------------------------------------------------ launcher (once) + owner (timelock)

    /// @notice Sets the staking token, once, at launch. The launcher has no other power.
    function setStakingToken(address token) external {
        if (msg.sender != launcher) revert NotLauncher();
        if (address(stakingToken) != address(0)) revert TokenAlreadySet();
        if (token.code.length == 0) revert NotAContract();
        stakingToken = IERC20(token);
        emit StakingTokenSet(token);
    }

    function setRewardsDuration(uint256 duration) external onlyOwner {
        if (block.timestamp < periodFinish) revert PeriodActive();
        if (duration < MIN_DURATION || duration > MAX_DURATION) revert BadParam();
        rewardsDuration = duration;
        emit RewardsDurationSet(duration);
    }

    function setMinRoll(uint256 value) external onlyOwner {
        if (value == 0 || value > MAX_MIN_ROLL) revert BadParam();
        minRoll = value;
        emit MinRollSet(value);
    }

    function setDropBps(uint256 bps) external onlyOwner {
        if (bps > MAX_DROP_BPS) revert BadParam();
        dropBps = bps;
        emit DropBpsSet(bps);
    }

    /// @notice Appoints the Drop distributor. Once: it can never be swapped afterwards.
    function setDropDistributor(address distributor) external onlyOwner {
        if (dropDistributor != address(0)) revert AlreadySet();
        if (distributor.code.length == 0) revert NotAContract();
        dropDistributor = distributor;
        emit DropDistributorSet(distributor);
    }

    /// @notice Recovers a token sent here by mistake. Never the staking token.
    function recoverERC20(address token, address to, uint256 amount) external onlyOwner {
        if (token == address(stakingToken)) revert CannotRecoverStakingToken();
        if (to == address(0)) revert ZeroAddress();
        IERC20(token).safeTransfer(to, amount);
        emit TokenRecovered(token, to, amount);
    }

    // ------------------------------------------------------------------ internal

    function _updateReward(address account) internal {
        uint256 applicable = lastTimeRewardApplicable();
        if (totalSupply == 0) {
            // Nobody staked: what would have streamed goes back to the queue instead of being lost.
            if (applicable > lastUpdateTime) {
                queued += ((applicable - lastUpdateTime) * rewardRateScaled) / PRECISION;
            }
        } else {
            rewardPerTokenStored = rewardPerToken();
        }
        lastUpdateTime = applicable;
        if (account != address(0)) {
            rewards[account] = earned(account);
            userRewardPerTokenPaid[account] = rewardPerTokenStored;
        }
    }

    /// @dev Books balls up to now for `user` and for the total, before a balance changes.
    function _updateBalls(address user) internal {
        _book(_userBalls[user], balanceOf[user], ballsLastTs[user]);
        ballsLastTs[user] = block.timestamp;
        _book(_totalBalls, totalSupply, totalBallsLastTs);
        totalBallsLastTs = block.timestamp;
    }

    /// @dev Adds bal × seconds from `from` to now, split across epoch boundaries. One loop step per epoch
    ///      crossed since the last action (a year idle = 52 cheap steps on an L2).
    function _book(mapping(uint256 => uint256) storage book, uint256 bal, uint256 from) internal {
        uint256 to = block.timestamp;
        if (from < GENESIS) from = GENESIS;
        if (bal == 0 || to <= from) return;
        uint256 e = (from - GENESIS) / EPOCH;
        while (true) {
            uint256 end = GENESIS + (e + 1) * EPOCH;
            uint256 stop = to < end ? to : end;
            book[e] += bal * (stop - from);
            if (stop == to) break;
            from = stop;
            unchecked { ++e; }
        }
    }

    /// @dev bal × seconds of [from, now] that fall inside `epoch`.
    function _pending(uint256 bal, uint256 from, uint256 epoch) internal view returns (uint256) {
        if (bal == 0) return 0;
        uint256 start = GENESIS + epoch * EPOCH;
        uint256 end = start + EPOCH;
        uint256 a = from > start ? from : start;
        uint256 b = block.timestamp < end ? block.timestamp : end;
        return b > a ? bal * (b - a) : 0;
    }

    function _withdraw(uint256 amount) internal {
        if (amount == 0) revert ZeroAmount();
        _updateReward(msg.sender);
        _updateBalls(msg.sender);
        balanceOf[msg.sender] -= amount;
        totalSupply -= amount;
        stakingToken.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }

    function _claim(address account, address to) internal {
        _updateReward(account);
        uint256 reward = rewards[account];
        if (reward == 0) return;
        rewards[account] = 0;
        _sendEth(to, reward);
        emit RewardPaid(account, to, reward);
    }

    function _sendEth(address to, uint256 amount) internal {
        (bool ok,) = payable(to).call{value: amount}("");
        if (!ok) revert EthTransferFailed();
    }
}
