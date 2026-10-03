// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IPonsFeeEscrow {
    function balanceOf(address recipient) external view returns (uint256);
    function claim() external;
}

/// @title PEGGOY fee forwarder
/// @notice The $PEGGOY creator-fee wallet on Pons. Pons v2 credits creator fees to an escrow that recipients must
///         claim themselves, so fees pointed straight at the Machine would sit in the escrow forever. This contract
///         is the recipient instead: anyone may call `pull()`, which claims the ETH from the Pons escrow and forwards
///         every wei to the Machine, where it is split 80/20 into the stream and the Drop.
/// @dev    No owner, no admin, nothing to configure: escrow and Machine are fixed at deploy. Keep Pons buybacks OFF
///         for $PEGGOY: a buyback vest is credited in the launch token, which this contract does not forward.
contract PeggoyFeeForwarder {
    IPonsFeeEscrow public immutable escrow;
    address payable public immutable machine;

    event Forwarded(uint256 amount);

    error ZeroAddress();
    error ForwardFailed();

    constructor(IPonsFeeEscrow escrow_, address payable machine_) {
        if (address(escrow_) == address(0) || machine_ == address(0)) revert ZeroAddress();
        escrow = escrow_;
        machine = machine_;
    }

    /// @dev The escrow pays claims here; anything else sent here is forwarded on the next pull.
    receive() external payable {}

    /// @notice ETH waiting for the Machine: claimable in the Pons escrow plus anything already held here.
    function pending() external view returns (uint256) {
        return escrow.balanceOf(address(this)) + address(this).balance;
    }

    /// @notice Claims from the Pons escrow (if anything is owed) and forwards all ETH to the Machine. Anyone may call.
    function pull() external returns (uint256 forwarded) {
        if (escrow.balanceOf(address(this)) != 0) escrow.claim();
        forwarded = address(this).balance;
        if (forwarded != 0) {
            (bool ok,) = machine.call{value: forwarded}("");
            if (!ok) revert ForwardFailed();
            emit Forwarded(forwarded);
        }
    }
}
